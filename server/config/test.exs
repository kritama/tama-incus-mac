import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :macus, MacusWeb.Endpoint,
  secret_key_base: "0T/MKhAODm79BKpmGpYHuVerOL3kBX3LaHN2cFYDXkNObLM7iqWpNjufLFTlnKrR",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
