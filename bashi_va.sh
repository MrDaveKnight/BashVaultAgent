#!/usr/bin/env bash

# Bash function note - can not use local variables to store stdout function 
# call returns if you also want to leverage $? for the return value

logged_in=0
login_attempts=0
login_attempts_max=4
comm_error_count=0

config="nada"
verbose=0
vault_token="nada"
encrypting_secrets=0
decrypting_env=0

usage () {
  cat << EOF
Usage:  APP_ROLE_SECRET="<app_role_secret>" bashi_va.sh [-dehv] -c <file> 
  -c  Config <file> 
  -d  Decrypt APP_ROLE_SECRET env variable 
  -e  Encrypt secrets in config files 
  -h  Usage
  -v  Verbose
EOF
}

login () {
  # Uses the AppRole autentication mechanism
  # The App Role ID is passed in via the configuration file
  # The App Role Secret is passed in via an environment variable
  # This technique is analogous to MFA, Multi-Factor Authentication

  local secret="${APP_ROLE_SECRET}"
  local salt="-salt"
  if [ ${salted} != "true" ]
  then 
    salt="-nosalt"
  fi

  if [ ${decrypting_env} -eq 1 ]
  then
    # Decrypt APP_ROLE_SECRET
    # Assumes newlines and slashes ('/') were transformed to
    # dashes '-' and underscores '_'!
    secret=$(echo "${APP_ROLE_SECRET}" | tr '\-_' '\n/' | \
      openssl enc -${cipher} -base64 -k ${decryption_password} ${salt} -d)
  fi

  echo "Logging into vault..."
  local login_payload="{\"role_id\":\"${app_role_id}\",\"secret_id\":\"${secret}\"}"
  login_response=$(curl --silent --connect-timeout 5 --request POST \
  --data ${login_payload} ${vault_address}/v1/auth/approle/login)
  local retval=$?
  if [ $retval -ne 0 ]
  then
    echo "ERROR: communication problems during login" >&2
    echo $login_response >&2
    return $retval
  fi

  echo -n "${login_response}" | grep "permission denied" > /dev/null
  if [ $? -eq 0 ]
  then
    echo "ERROR: login returned permission denied!" >&2
    echo "ERROR: please verify app role ID and Secret are still valid" >&2
    return 105
  fi

  vault_token=$(read_field_value "$login_response" "client_token" "string")

  if [ "${vault_token}X" = "X" ]
  then
    echo "ERROR: login returned an empty token!" >&2
    return 106
  fi
  return 0
}

cleanup() {
 rv=$?
 rm -f .bashi_vault_agent_config_tmp.tx
 exit $rv
}
trap "cleanup" INT TERM EXIT

renew_token() {
  if [ $verbose -eq 1 ]
  then
    echo "INFO: vault token renewal scheduled"
  fi
  logged_in=0
  login_attempts=0
}
trap "renew_token" HUP

read_field_value () {
  # usage: read_field value "<json string>" "<field_name>" "<field_type>"
  # <field_type> should be "string", "number" or "bool"
  # We can not assume jq is installed, but we can assume awk


  retval=0

  local response_json=$1
  local field_name=$2
  local field_type=$3
  field_value="nada"

  if [ $field_type = "string" ]
  then
    # String values always have this form -
    #    "client_token":"s.1BsRp3oNZtFI5IAl5v5oM7fx"
    # Using " as the field separator, the value is always 2 fields
    # past the key (the : is in between)
    field_value=$(echo ${response_json} | awk -F'"' -v fname=${field_name} '{for(i=1; i<(NF-1); i++){if($i == fname){field_value=$(i+2); exit}}} END {printf("%s", field_value)}')
    if [ $? -ne 0 ]
    then
      retval=101 # Leave room for curl error codes
    fi

  elif [ $field_type = "bool" ] || [ $field_type = "number" ]
  then
    # Bools and numbers will always have this form -
    #     "orphan":true or "lease_duration":0
    # They can be trailed by a "," or a "}", for example
    # "orphan":true, or "orphan":true}
    # So, make it easy. Just separate fields on all of those characters,
    # including the :. The value will then be 2 fields past the key again
    field_value=$(echo ${response_json} | awk -F '"|,|:|{|}' -v fname=${field_name} '{for(i=1; i<(NF-1); i++){if($i == fname){field_value=$(i+2); exit}}} END {printf("%s", field_value)}')

    if [ $? -ne 0 ]
    then
      retval=103 # Leave room for curl error codes
    fi

  else

    # This is a programing error
    exit 1

  fi

  echo -n $field_value
  return $retval
}

get_secret () {
  # $1 is vault API path (will return a json string)
  # $2 is field name in json to parse
  # $3 is field type in json to parse

  retval=0
  secret_string="<unknown>"

  vault_response=$(curl --silent --connect-timeout 5 \
    --header "X-Vault-Token: ${vault_token}" --request GET \
    ${vault_address}/v1/secret/data/$1)
  retval=$?
  if [ $retval -eq 0 ]
  then

    # Here is where we try to determine if your token lease expired
    echo -n "${vault_response}" | grep "permission denied" > /dev/null
    if [ $? -eq 0 ]
    then
      retval=102
      logged_in=0
      login_attempts=0
    else
      secret_string=$(read_field_value "${vault_response}" "$2" $3)
      retval=$?
    fi
  else
    echo "ERROR: get_secret curl failed!" >&2
  fi

  echo -n "${secret_string}"
  return $retval
}

init_config_staging () {

  for c in "${configs[@]}"
  do
    IFS=':' read -ra c_items <<< "$c"
    local template=${c_items[0]}
    local staging_template="${template}_STAGING"
    if [ ! -f ${template} ]
    then
      echo "WARNING: Configured template ${template} does not exist" >&2
    else
      cp "${template}" "${staging_template}"
      if [ $? -ne 0 ]
      then
        echo "WARNING: cp of ${template} to ${staging_template} failed" >&2
      fi
    fi
  done
}

encrypt_secret () {
  # $1 is the unencrypted secret
  # Returns a >> MODIFIED << base64url encoded version of encrypted secret. 
  #
  # Why? Because '/' and '\n' can not be handled in the "to-string" of the sed command
  # that is writing the re-encrypted secret values to the config files.
  #
  # Here are the transforms done
  #  '/' is replaced by '_'
  #  '\n' is replaced by '-' (in standard base64url, '+' is replaced by '-')
  # 
  # Therefore, the application reading and decrypting this variable will have to 
  # replace '_' with '/', and '-' with '/n' before doing a base64 decode, 
  # followed by the decrypt. 
  #
  # To decrypt asyncronous cipher text created with a public key:
  #   echo "<cipher text>" | tr '\-_' '\n/' | 
  #    openssl base64 -d | openssl rsautl -decrypt -inkey <private.key> -keyform pem
  # 
  # To decrypt syncronously cipher text created with a shared secret password:
  #   echo "<cipher text>" | tr '\-_' '\n/' | 
  #     openssl enc -<cipher> -base64 -k <shared_password> [-salt | -nosalt] -d 
  #
  # See the openssl algorithms below for more understanding. Most of the configuration options
  # are in the bashi_va.cfg file. 

  local secret=$1
  retval=0
  encrypted_encoded_secret="undefined"

  if [ ${encryption_method} = "a" ]        # s|a : symmetric or asymmetric encryption of secrets
  then
  
    encrypted_encoded_secret=$(echo -n "${secret}" | openssl rsautl -encrypt \
      -inkey ${encryption_public_key_file} -keyform pem -pubin | openssl base64 | tr '/\n' '_-')

    if [ "${encrypted_encoded_secret}X" = "X" ]
    then
      encrypted_encoded_secret="encryption_failure"
      retval=107
    fi
    echo -n "${encrypted_encoded_secret}"
    return $retval

  else

    encrypted_encoded_secret=$(echo -n "${secret}" | openssl enc \
      -${cipher} -base64 -k ${encryption_password} ${salt} | tr '/\n' '_-')
    retval=$?
    echo -n "${encrypted_encoded_secret}"
    return $?

  fi
}

push_config () {

  for c in "${configs[@]}"
  do
    IFS=':' read -ra c_items <<< "$c"
    local staging_template="${c_items[0]}_STAGING"
    local config_file=${c_items[1]}
    local script=${c_items[2]}

    if [ -f "${staging_template}" ]
    then

      local diff_result=0

      if [ -f "${config_file}" ]
      then

        # Test to see if anything changed in the config. If not, don't do anything
        # diff returns 0 if nothing changed.
        diff "${staging_template}" "${config_file}" > /dev/null
        diff_result=$?
      else
        # config file does not exist yet, force the initial copy
        diff_result=1
      fi
      if [ $diff_result -eq 1 ]
      then
        mv -f "${staging_template}" "${config_file}"
        if [ $? -ne 0 ]
        then
          echo "WARNING: cp failed during configuration push!" >&2
        else
          bash -c "${script}"
          if [ $? -ne 0 ]
          then
            echo "WARNING: the following re-configuration script failed:" >&2
            echo "${script}"
          fi
        fi
      elif [ $diff_result -gt 1 ]
      then
        rm "${staging_template}"
        echo "ERROR: with configuration file diff!" >&2
      else
        rm "${staging_template}"
      fi
    fi
  done
}

refresh_configs () {

  retval=0

  init_config_staging

  for secret_spec in "${secrets[@]}"
  do
    IFS=':' read -ra spec_items <<< "$secret_spec"
    local template_prefix=${spec_items[0]}
    local vault_path=${spec_items[1]}
    for ((i=2; i<${#spec_items[@]}; i++))
    do
      IFS='|' read -ra field_spec <<< "${spec_items[i]}"
      local secret_name="${field_spec[0]}"
      secret_value=$(get_secret "${vault_path}" "${secret_name}" "${field_spec[1]}")
      retval=$?
      if [ $retval -ne 0 ]
      then
        echo "WARNING: secret read failed with error code: ${retval}" >&2
        echo "WARNING: failed path - ${vault_path}::${secret_name}" >&2
      fi

      if [ ${encrypting_secrets} -eq 1 ]
      then

        secret_value=$(encrypt_secret "${secret_value}") 
        if [ $? -ne 0 ]
        then
          echo "ERROR: secret re-encryption failed for ${vault_path}::${secret_name}" >&2
        fi

      fi

      local replacement_target="${template_prefix}::${secret_name}"
      for cfg in "${configs[@]}"
      do
        IFS=':' read -ra cfg_items <<< "$cfg"
        local template_file="${cfg_items[0]}_STAGING"

        

        # AIX sed does not have -i option (that is the gnu verions)
        sed "s/{{ *${replacement_target} *}}/${secret_value}/g" \
          ${template_file} > .bashi_vault_agent_config_tmp.txt
        if [ $? -ne 0 ]
        then
          echo "WARNING: sed failed during configuration staging!" >&2
        fi
        mv .bashi_vault_agent_config_tmp.txt ${template_file}
        if [ $? -ne 0 ]
        then
          echo "WARNING: mv failed during configuration staging!" >&2
        fi
      done
    done
  done

  push_config
  return $retval
}


while getopts ":c:dehv" opt; do
  case ${opt} in
    d )
      decrypting_env=1
      ;;
    e )
      encrypting_secrets=1
      ;;
    h )
      usage
      exit 0
      ;;
    c )
      config=$OPTARG
      ;;
    v )
      verbose=1
      ;;
   \? )
      usage
      exit 0
      ;;
  esac
done
shift $((OPTIND -1))

if [ -z "${APP_ROLE_SECRET}" ]
then
  echo "ERROR: no APP_ROLE_SECRET provided!" >&2
  usage
  exit 1
fi

#################
# Configuration
#################

#
# Declare required variables
#

refresh_interval="nada"
app_role_id="nada"
vault_address="nada"

#
# Load
#

if [ ! -f $config ]
then
  echo "ERROR: no config file provided!" >&2
  usage
  exit 1
fi
source $config

#
# Validate
#

if [ refresh_interval = "nada" ]
then
  echo "ERROR: no refresh interval configured!" >&2
  usage
  exit 1
elif [ app_role_id = "nada" ]
then
  echo "ERROR: no refresh interval configured!" >&2
  usage
  exit 1
elif [ vault_address = "nada" ]
then
  echo "ERROR: no vault server address configured!" >&2
  usage
  exit 1
fi

if [ ${encrypting_secrets} -eq 1 ]
then
  if [ "${encryption_method}X" = "X" ]
  then
    echo "ERROR: no encryption method configured!" >&2
    usage
    exit 1
  elif [ "${encryption_method}" != "a" ] && [ "${encryption_method}" != "s" ] 
  then
    echo "ERROR: ${encryption_method} is an invalid encryption method (s|a)"  >&2
    usage
    exit 1
  fi 

  if [ "${encryption_method}" = "s" ]
  then
    if [ "${encryption_password}X" = "X" ]
    then
      echo "ERROR: no encryption password configured!" >&2
      usage
      exit 1
    fi 
  else 
    if [ "${encryption_public_key_file}X" = "X" ]
    then
      echo "ERROR: no public key file configured!" >&2
      usage
      exit 1
    elif [ ! -f "${encryption_public_key_file}" ]
    then
      echo "ERROR: can not find ${encryption_public_key_file}!" >&2
      usage
      exit 1
    fi 
  fi 
fi

if [ ${decrypting_env} -eq 1 ]
then
  if [ "${cipher}X" = "X" ]
  then
    echo "ERROR: no symmetric cipher configured!" >&2
    usage
    exit 1
  elif [ "${salted}X" = "X" ]
  then
    echo "ERROR: no salt flag configured!" >&2
    usage
    exit 1
  elif [ "${decryption_password}X" = "X" ]
  then
    echo "ERROR: no decryption password configured!" >&2
    usage
    exit 1
  fi 
fi

#
# End validation
#

if [ $verbose -eq 1 ]
then
  echo ""
  echo "Managing the following secrets:"
  for s in "${secrets[@]}"
  do
    echo $s
  done
  echo ""
  echo "Managing the following configurations:"
  for c in "${configs[@]}"
  do
    echo $c
  done
  echo ""
fi

#################
# Main loop
#################

echo "Refreshing tokens and secrets (CNTL-C to stop)"

while true
do

  if [ $login_attempts -gt $login_attempts_max ]
  then
    echo "ERROR: could not login to vault! Aborting" >&2
    exit 2
  elif [ $logged_in -ne 1 ]
  then
    login_attempts=$((login_attempts + 1))

    #################
    # Login to Vault
    #################
    login

    if [ $? -eq 0 ]
    then
      logged_in=1
      login_attempts=0
    else
      echo "WARNING: failed an attempt to login to vault!" >&2
    fi
  fi

  #################
  # Do your job
  #################
  if [ $logged_in -eq 1 ]
  then
    refresh_configs

    if [ $? -ne 0 ]
    then
      comm_error_count=$((comm_error_count + 1))
    else
      comm_error_count=0
    fi
  fi

  if [ $verbose -eq 1 ]
  then
    echo "Sleeping for $refresh_interval seconds"
  fi
  sleep $refresh_interval
done
