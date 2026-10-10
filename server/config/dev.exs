import Config

config :macus, MacusWeb.Endpoint,
  code_reloader: true,
  debug_errors: false,
  server: false

config :logger, :default_formatter, format: "[$level] $message\n"
config :phoenix, :plug_init_mode, :runtime
