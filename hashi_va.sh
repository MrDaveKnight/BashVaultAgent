#!/usr/bin/env bash

logged_in=0
login_attempts=0
login_attempts_max=4

config="nada"
verbose=0
vault_token="nada"

usage () {
  cat << EOF
Usage:  APP_ROLE_SECRET="<app_role_secret>" hashi_va.sh [-hv] -c <file>
  -c  Config <file> name
  -h  Usage
  -v  Verbose
EOF
}

login () {
  # Uses the AppRole autentication mechanism
  # The App Role ID is passed in via the configuration file
  # The App Role Secret is passed in via an environment variable
  # This technique is analogous to MFA, Multi-Factor Authentication

  echo "Logging into vault..."
  cat << EOM > login_payload.json
  {
    "role_id": "${app_role_id}",
    "secret_id": "${APP_ROLE_SECRET}"
  }
EOM


  #local login_response=$(cat token.json)
  local login_response=$(curl --silent --request POST \
  --data @login_payload.json ${vault_address}/v1/auth/approle/login)
  local retval=$?
  if [ $retval -ne 0 ]
  then
    echo "Error encountered logging into vault"
    echo $login_response
    return $retval
  fi

  local errors=$(read_field_value "$login_response" "errors" "string")
  if [ errors = "permission denied" ]
  then
    echo "ERROR: login returned permission denied, aborting!"
    return 105
  fi

  vault_token=$(read_field_value "$login_response" "client_token" "string")

  # For DEBUG ONLY
  # echo "Vault token: $vault_token"

  if [ $vault_token = "" ]
  then
    echo "ERROR: login returned an empty token, aborting!"
    return 106
  fi
  return 0
}

cleanup() {
 rv=$?
 rm -f .hashi_vault_agent_config_tmp.tx
 exit $rv
}
trap "cleanup" INT TERM EXIT

read_field_value () {
  # usage: read_field value "<json string>" "<field_name>" "<field_type>"
  # <field_type> should be "string", "number" or "bool"
  # We can not assume jq is installed, but we can assume awk


  local retval=0

  local response_json=$1
  local field_name=$2
  local field_type=$3
  local field_value="nada"

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
      retval=102 # Leave room for curl error codes
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

  local retval=0
  local secret_string="N/A"

  local vault_response=$(curl --silent --header "X-Vault-Token: ${vault_token}" --request GET \
  ${vault_address}/v1/secret/data/$1)
  retval=$?
  if [ $retval -eq 0 ]
  then
    secret_string=$(read_field_value "${vault_response}" "$2" $3)
    retval=$?
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
      echo "WARNING: Configured template ${template} does not exist"
    else
      cp "${template}" "${staging_template}"
      if [ $? -ne 0 ]
      then
        echo "WARNING: cp of ${template} to ${staging_template} failed"
      fi
    fi
  done
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
        cp -f "${staging_template}" "${config_file}"
        if [ $? -ne 0 ]
        then
          echo "WARNING: cp failed during configuration push!"
        else
          bash -c "${script}"
          if [ $? -ne 0 ]
          then
            echo "WARNING: the following re-configuration script failed:"
            echo "${script}"
          fi
        fi
      elif [ $diff_result -gt 1 ]
      then
        rm "${staging_template}"
        echo "ERROR: with configuration file diff!"
      else
        rm "${staging_template}"
      fi
    fi
  done
}

refresh_configs () {

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
      local secret_value=$(get_secret "${vault_path}" "${secret_name}" "${field_spec[1]}")
      local code=$?
      if [ $code -ne 0 ]
      then
        echo "WARNING: secret read failed with error code: ${code}"
      fi
      local replacement_target="${template_prefix}::${secret_name}"
      for cfg in "${configs[@]}"
      do
        IFS=':' read -ra cfg_items <<< "$cfg"
        local template_file="${cfg_items[0]}_STAGING"

        # AIX sed does not have -i option (that is the gnu verions)
        sed "s/{{ *${replacement_target} *}}/${secret_value}/g" \
          ${template_file} > .hashi_vault_agent_config_tmp.txt
        if [ $? -ne 0 ]
        then
          echo "WARNING: sed failed during configuration staging!"
        fi
        mv .hashi_vault_agent_config_tmp.txt ${template_file}
        if [ $? -ne 0 ]
        then
          echo "WARNING: mv failed during configuration staging!"
        fi
      done
    done
  done

  push_config
}

while getopts ":hva:c:n:i:r:" opt; do
  case ${opt} in
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
  esac
done
shift $((OPTIND -1))

if [ -z ${APP_ROLE_SECRET} ]
then
  echo "ERROR: no APP_ROLE_SECRET provided!"
  usage
  exit 1
fi

# DEBUG ONLY
echo "APP_ROLE_SECRET: $APP_ROLE_SECRET"

#################
# Configuration
#################

# Declare
refresh_interval="nada"
app_role_id="nada"
vault_address="nada"

# Load
if [ ! -f $config ]
then
  echo "ERROR: no config file provided!"
  usage
  exit 1
fi
source $config

# Validate
if [ refresh_interval = "nada" ]
then
  echo "ERROR: no refresh interval configured!"
  usage
  exit 1
elif [ app_role_id = "nada" ]
then
  echo "ERROR: no refresh interval configured!"
  usage
  exit 1
elif [ vault_address = "nada" ]
then
  echo "ERROR: no vault server address configured!"
  usage
  exit 1
fi

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
    echo "ERROR: could not login to vault! Aborting"
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
      echo "WARNING: failed an attempt to login to vault!"
    fi
  fi

  #################
  # Do your job
  #################
  refresh_configs

  if [ $verbose -eq 1 ]
  then
    echo "Sleeping for $refresh_interval seconds"
  fi
  sleep $refresh_interval
done
