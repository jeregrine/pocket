import Config

config :gpui_native, GPUI.Native, host: :vanilla
config :gpui_native, build_native: config_env() != :test
