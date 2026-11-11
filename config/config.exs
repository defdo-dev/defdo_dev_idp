import Config

# The package reads the host's env through defdo_auth_client, never Mix.env().
config :defdo_auth_client, :env, config_env()
