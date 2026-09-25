import Config

# Demonstrates that compilation and packaged configuration both use :prod.
config :hello, build_environment: config_env()
