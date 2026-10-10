defmodule MacusWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :macus

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  # Each protocol boundary owns body framing, authentication and upgrades.
  # Do not consume Incus or MCP bytes in a shared parser.
  plug MacusWeb.Router
end
