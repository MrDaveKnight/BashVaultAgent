BashVaultAgent, or BashiVA, is a simple daemon written in Bash
to mimic HashiCorp's vault-agent which is written in Go.
It ...
- Logs into the HashiCorp Vault server via AppRole authentication
- Downloads secrets on behalf of an application
- Injects those secrets into the application by generating
  an application native configuration file on disk that is based on
  a template, and signalling the application to refresh/restart
  when changes are available

BashiVA was built to support AIX.
It has been tested on AIX, Linux and MacOS.

Template Example:

  If in Vault at the API path identified by the "WEBDB" tag,
  the secret value of the "password" field is "tiger", then ...

  This line in a config template

    \<password\> {{ WEBDB::password }} \<\/password\>

  Would be replaced by this line in the app config file

    \<password\> tiger \<\/password\>
