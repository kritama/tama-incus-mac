defmodule Macus.Runtime do
  @moduledoc """
  Private Swift runtime API boundary. Lifecycle, configuration and health use
  `runtime.sock`; VM ownership and implementation remain entirely in Swift.
  """

  alias Macus.Runtime.Client

  for endpoint <- [:status, :capabilities, :health, :config, :progress] do
    path = "/v1/runtime/#{endpoint}"

    def unquote(endpoint)(client, opts \\ []),
      do: Client.request(client, "GET", unquote(path), "", opts)
  end

  def create(client, config, opts \\ []),
    do: json(client, "POST", "/v1/runtime/create", config, opts)

  def update(client, config, opts \\ []),
    do: json(client, "PUT", "/v1/runtime/config", config, opts)

  def start(client, budget \\ nil, opts \\ [])
  def start(client, nil, opts), do: Client.request(client, "POST", "/v1/runtime/start", "", opts)
  def start(client, budget, opts), do: json(client, "POST", "/v1/runtime/start", budget, opts)

  def stop(client, payload \\ nil, opts \\ [])
  def stop(client, nil, opts), do: Client.request(client, "POST", "/v1/runtime/stop", "", opts)
  def stop(client, payload, opts), do: json(client, "POST", "/v1/runtime/stop", payload, opts)

  def restart(client, opts \\ []),
    do: Client.request(client, "POST", "/v1/runtime/restart", "", opts)

  def delete(client, payload, opts \\ []),
    do: json(client, "DELETE", "/v1/runtime", payload, opts)

  defp json(client, method, path, payload, opts) do
    case Jason.encode(payload) do
      {:ok, body} ->
        Client.request(client, method, path, body, opts)

      {:error, _} ->
        {:error, %Macus.Runtime.Error{code: :invalid_request, outcome: :not_dispatched}}
    end
  end
end
