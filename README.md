BashVaultAgent, or HashiVA, is a simple daemon written in Bash
to mimic much of vault-agent's functionality. It ...
- Logs into the HashiCorp Vault server via AppRole authentication
- Downloads secrets on behalf of an application
- Injects those secrets into the application by generating
  an application native configuration file on disk that is based on
  a template, and signalling the application to refresh/restart
  when changes are available

HashiVA was built to support AIX.
It has been tested on AIX and MacOS.

Template Example:

  If in Vault at the path identified by the "WEBDB" short name,
  the secret value of the "password" field is "tiger", then ...

  This line of in a config template
    <password> {{ WEBDB::password }} </password>

  Would be replaced by this line in the app config file
    <password> tiger </password>
