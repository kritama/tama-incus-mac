defmodule Macus.Runtime.Client do
  @moduledoc """
  One request per private Swift Unix socket, without VM lifecycle ownership.

  Callers supply trusted configuration and the host's verified owner UID, never
  request-selected paths or identities. Validation is observational. The same
  monotonic deadline covers connect, send and receive. Request bodies are
  limited to 1 MiB, response headers to 16 KiB and response bodies to 16 MiB,
  matching the native control API/client bounds. Connections are always closed
  and potentially accepted mutations are never retried.
  """

  import Bitwise
  alias Macus.{Configuration, Runtime.Error, Runtime.Response}

  @request_limit 1_048_576
  @header_limit 16_384
  @response_limit 16 * 1_048_576
  @routes [
    {"GET", "/v1/runtime/status"},
    {"GET", "/v1/runtime/capabilities"},
    {"GET", "/v1/runtime/health"},
    {"GET", "/v1/runtime/config"},
    {"GET", "/v1/runtime/progress"},
    {"POST", "/v1/runtime/create"},
    {"POST", "/v1/runtime/start"},
    {"POST", "/v1/runtime/stop"},
    {"POST", "/v1/runtime/restart"},
    {"PUT", "/v1/runtime/config"},
    {"DELETE", "/v1/runtime"}
  ]

  @enforce_keys [:socket, :owner_uid]
  defstruct [:socket, :owner_uid]
  @type t :: %__MODULE__{socket: binary(), owner_uid: non_neg_integer()}

  @spec new(Configuration.t(), non_neg_integer()) :: {:ok, t()} | {:error, Error.t()}
  def new(%Configuration{} = config, uid) when is_integer(uid) and uid >= 0 do
    path = Configuration.runtime_socket(config)

    if String.starts_with?(path, "/") and byte_size(path) <= 103 and
         not String.contains?(path, <<0>>) do
      {:ok, %__MODULE__{socket: path, owner_uid: uid}}
    else
      failure(:invalid_request, :not_dispatched)
    end
  end

  def new(_, _), do: failure(:invalid_request, :not_dispatched)

  @spec request(t(), binary(), binary(), binary(), keyword()) ::
          {:ok, Response.t()} | {:error, Error.t()}
  def request(client, method, path, body \\ "", opts \\ [])

  def request(%__MODULE__{} = client, method, path, body, opts) when is_binary(body) do
    timeout = Keyword.get(opts, :timeout_ms, 15_000)

    if {method, path} in @routes and byte_size(body) <= @request_limit and
         is_integer(timeout) and timeout in 1..3_600_000 do
      deadline = now() + timeout

      with :ok <- safe_socket(client), {:ok, remaining} <- remaining(deadline) do
        connect(client, method, path, body, deadline, remaining)
      end
    else
      failure(:invalid_request, :not_dispatched)
    end
  end

  def request(_, _, _, _, _), do: failure(:invalid_request, :not_dispatched)

  defp connect(client, method, path, body, deadline, timeout) do
    opts = [
      hostname: "localhost",
      mode: :passive,
      protocols: [:http1],
      max_header_list_size: @header_limit,
      transport_opts: [
        timeout: timeout,
        send_timeout: timeout,
        send_timeout_close: true,
        buffer: 65_536
      ]
    ]

    case Mint.HTTP.connect(:http, {:local, String.to_charlist(client.socket)}, 0, opts) do
      {:ok, conn} ->
        try do
          with {:ok, remaining} <- remaining(deadline) do
            case :inet.setopts(Mint.HTTP.get_socket(conn), send_timeout: remaining) do
              :ok ->
                send_request(conn, method, path, body, deadline)

              {:error, reason} ->
                failure(transport_code(%Mint.TransportError{reason: reason}), :not_dispatched)
            end
          end
        after
          Mint.HTTP.close(conn)
        end

      {:error, error} ->
        failure(transport_code(error), :not_dispatched)
    end
  end

  defp send_request(conn, method, path, body, deadline) do
    headers = [
      {"host", "localhost"},
      {"accept", "application/json"},
      {"content-type", "application/json"},
      {"content-length", Integer.to_string(byte_size(body))},
      {"connection", "close"}
    ]

    outcome = if method == "GET", do: :read_only, else: :unknown

    case Mint.HTTP.request(conn, method, path, headers, body) do
      {:ok, conn, ref} ->
        receive_response(conn, ref, deadline, outcome, %{
          status: nil,
          headers: [],
          chunks: [],
          size: 0,
          done: false
        })

      {:error, _conn, error} ->
        failure(transport_code(error), outcome)
    end
  end

  defp receive_response(conn, ref, deadline, outcome, state) do
    case remaining(deadline) do
      {:ok, timeout} ->
        case Mint.HTTP.recv(conn, 0, timeout) do
          {:ok, conn, events} ->
            case consume(events, ref, state) do
              {:ok, %{done: true} = state} ->
                {:ok,
                 %Response{
                   status: state.status,
                   headers: state.headers,
                   body: state.chunks |> Enum.reverse() |> IO.iodata_to_binary()
                 }}

              {:ok, state} ->
                receive_response(conn, ref, deadline, outcome, state)

              {:error, code} ->
                failure(code, outcome)
            end

          {:error, _conn, %Mint.TransportError{reason: :closed}, events} ->
            code =
              if state.status != nil or Enum.any?(events, &match?({:status, _, _}, &1)),
                do: :invalid_response,
                else: :unavailable

            failure(code, outcome)

          {:error, _conn, error, _events} ->
            failure(transport_code(error), outcome)
        end

      {:error, _} ->
        failure(:timeout, outcome)
    end
  end

  defp consume([], _ref, state), do: {:ok, state}

  defp consume([{:status, ref, status} | rest], ref, %{status: nil} = state)
       when status in 200..599, do: consume(rest, ref, %{state | status: status})

  defp consume([{:headers, ref, headers} | rest], ref, state) do
    headers = state.headers ++ headers

    with :ok <- valid_headers(headers) do
      consume(rest, ref, %{state | headers: headers})
    end
  end

  defp consume([{:data, ref, bytes} | rest], ref, state) do
    if byte_size(bytes) <= @response_limit - state.size do
      consume(rest, ref, %{
        state
        | size: state.size + byte_size(bytes),
          chunks: [bytes | state.chunks]
      })
    else
      {:error, :response_too_large}
    end
  end

  defp consume([{:done, ref} | rest], ref, %{status: status} = state) when is_integer(status),
    do: consume(rest, ref, %{state | done: true})

  defp consume(_, _, _), do: {:error, :invalid_response}

  defp valid_headers(headers) do
    lengths = for {"content-length", value} <- headers, do: value
    encodings = for {"transfer-encoding", value} <- headers, do: String.downcase(value)

    bytes =
      Enum.reduce(headers, 2, fn {key, value}, acc ->
        acc + byte_size(key) + byte_size(value) + 4
      end)

    cond do
      bytes > @header_limit ->
        {:error, :invalid_response}

      length(lengths) > 1 or length(encodings) > 1 ->
        {:error, :invalid_response}

      lengths != [] and encodings != [] ->
        {:error, :invalid_response}

      encodings not in [[], ["chunked"]] ->
        {:error, :invalid_response}

      lengths != [] ->
        value = hd(lengths)

        if Regex.match?(~r/\A[0-9]+\z/, value) do
          if String.to_integer(value) <= @response_limit,
            do: :ok,
            else: {:error, :response_too_large}
        else
          {:error, :invalid_response}
        end

      true ->
        :ok
    end
  end

  defp safe_socket(client) do
    path = system_alias(client.socket)
    parent = Path.dirname(path)

    with {:ok, %File.Stat{type: :directory, uid: uid, mode: mode}} <- File.lstat(parent),
         true <- uid == client.owner_uid and band(mode, 0o777) == 0o700,
         :ok <- safe_ancestors(parent, client.owner_uid),
         {:ok, %File.Stat{uid: uid, mode: mode}} <- File.lstat(path),
         true <-
           uid == client.owner_uid and band(mode, 0o170000) == 0o140000 and
             band(mode, 0o777) == 0o600 do
      :ok
    else
      {:error, :enoent} -> failure(:unavailable, :not_dispatched)
      _ -> failure(:unsafe_socket, :not_dispatched)
    end
  end

  defp safe_ancestors("/", _uid), do: :ok

  defp safe_ancestors(path, uid) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory, uid: owner, mode: mode}} ->
        sticky_system = owner == 0 and band(mode, 0o1000) != 0

        if owner in [0, uid] and (band(mode, 0o022) == 0 or sticky_system),
          do: safe_ancestors(Path.dirname(path), uid),
          else: failure(:unsafe_socket, :not_dispatched)

      _ ->
        failure(:unsafe_socket, :not_dispatched)
    end
  end

  defp system_alias(path) do
    Enum.reduce([{"/var", "/private/var"}, {"/tmp", "/private/tmp"}], path, fn {alias_path,
                                                                                destination},
                                                                               path ->
      expected_alias =
        case File.read_link(alias_path) do
          {:ok, target} -> Path.expand(target, Path.dirname(alias_path)) == destination
          _ -> false
        end

      if String.starts_with?(path, alias_path <> "/") and expected_alias do
        destination <> String.replace_prefix(path, alias_path, "")
      else
        path
      end
    end)
  end

  defp remaining(deadline) do
    case deadline - now() do
      remaining when remaining > 0 -> {:ok, remaining}
      _ -> failure(:timeout, :not_dispatched)
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
  defp transport_code(%Mint.TransportError{reason: :timeout}), do: :timeout

  defp transport_code(%Mint.TransportError{reason: reason})
       when reason in [:closed, :econnrefused, :enoent],
       do: :unavailable

  defp transport_code(%Mint.HTTPError{}), do: :invalid_response
  defp transport_code(_), do: :unavailable
  defp failure(code, outcome), do: {:error, %Error{code: code, outcome: outcome}}
end
