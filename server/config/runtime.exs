import Config

# Passive until gateway-owned HTTPS configuration and credentials are provided.
# PHX_SERVER and PORT must not enable a cleartext or wildcard listener.
config :macus, MacusWeb.Endpoint, server: false

# Resolve selected state passively. The gateway validates it before any access.
state_dir =
  System.get_env("MACUS_STATE_DIR") || System.get_env("TIM_STATE_DIR") ||
    Path.expand("~/.tama/incus-mac")

config :macus, :state_dir, state_dir
