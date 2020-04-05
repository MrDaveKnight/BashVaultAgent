# BashVaultAgent

BashVaultAgent, or BashiVA, is a simple daemon written in Bash
to mimic HashiCorp's vault-agent written in Go.
It ...
  - Authenticates with the HashiCorp Vault server via AppRole
  - Downloads secrets from Vault on behalf of an application
  - Injects those secrets into an application by generating
    a configuration file from a template and secrets, and signalling the 
    application to refresh or restart when the configuration file is available

BashiVA was built specifically to support AIX, and to be simple
and easily customizable. It was built in accordance with the UNIX Philosopy and
stands on the shoulders of giants, namely - curl, awk, sed, diff, cp, mv & rm.
  
It has been tested on AIX (7.1, 7.2), Linux and MacOS.

```
Usage:  APP_ROLE_SECRET="<app_role_secret>" bashi_va.sh [-dehv] -c <file>
    -c  Config <file> 
    -d  Decrypt APP_ROLE_SECRET env variable 
    -e  Encrypt secrets in config files 
    -h  Usage
    -v  Verbose
```

## Example

  If in Vault at the API path identified by the "WEBDB" tag,
  the secret value of the "password" field is "tiger", then ...

  This line in a config template

    <password> {{ WEBDB::password }} </password>

  Will be replaced by this line in the application's config file

    <password> tiger </password>

## Workflow

1. Install two files: bashi_va.sh and bashi_va.cfg
2. In the vault server, configure AppRole, policies and secrets for each app
2. Copy your app configuration files, and edit copies to create config templates
3. Configure bashi_va.cfg
4. Run bashi_va.sh

## More Information

Please read the comments in the bashi_va.cfg file
