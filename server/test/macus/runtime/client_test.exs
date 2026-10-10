defmodule Macus.Runtime.ClientTest do
  use ExUnit.Case, async: true

  alias Macus.{Configuration, Runtime}
  alias Macus.Runtime.{Client, Error, Response}
  alias Macus.TestSupport.HTTPFixture

  setup do
    root = Path.join("/private/tmp", "mc-runtime-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    uid = File.stat!(root).uid
    {:ok, config} = Configuration.new(root)
    {:ok, client} = Client.new(config, uid)
    %{root: root, uid: uid, config: config, client: client}
  end

  test "all private lifecycle/config/inspection methods retain native bodies", context do
    fixture = fixture(context, fn _ -> %{status: 200, body: %{version: 1, state: "stopped"}} end)
    config = %{"version" => 1, "cpu_count" => 4}

    calls = [
      {fn -> Runtime.status(context.client) end, "GET", "/v1/runtime/status", ""},
      {fn -> Runtime.capabilities(context.client) end, "GET", "/v1/runtime/capabilities", ""},
      {fn -> Runtime.health(context.client) end, "GET", "/v1/runtime/health", ""},
      {fn -> Runtime.config(context.client) end, "GET", "/v1/runtime/config", ""},
      {fn -> Runtime.progress(context.client) end, "GET", "/v1/runtime/progress", ""},
      {fn -> Runtime.create(context.client, config) end, "POST", "/v1/runtime/create",
       Jason.encode!(config)},
      {fn -> Runtime.update(context.client, config) end, "PUT", "/v1/runtime/config",
       Jason.encode!(config)},
      {fn -> Runtime.start(context.client) end, "POST", "/v1/runtime/start", ""},
      {fn -> Runtime.start(context.client, %{remaining_seconds: 29}) end, "POST",
       "/v1/runtime/start", ~s({"remaining_seconds":29})},
      {fn -> Runtime.stop(context.client) end, "POST", "/v1/runtime/stop", ""},
      {fn -> Runtime.stop(context.client, %{force: true}) end, "POST", "/v1/runtime/stop",
       ~s({"force":true})},
      {fn -> Runtime.restart(context.client) end, "POST", "/v1/runtime/restart", ""},
      {fn -> Runtime.delete(context.client, %{confirm: true}) end, "DELETE", "/v1/runtime",
       ~s({"confirm":true})}
    ]

    for {call, _, _, _} <- calls do
      assert {:ok, %Response{status: 200, body: body}} = call.()
      assert Jason.decode!(body) == %{"version" => 1, "state" => "stopped"}
    end

    for {request, {_call, method, path, body}} <- Enum.zip(HTTPFixture.requests(fixture), calls) do
      assert request.method == method
      assert request.target == path
      assert request.body == body
      assert request.headers["content-length"] == Integer.to_string(byte_size(body))
      assert request.headers["connection"] == "close"
    end
  end

  test "native conflicts, timeout status and errors stay byte-for-byte responses", context do
    raw = ~s({"error":{"code":"conflict","message":"Runtime is running"}})
    fixture(context, fn _ -> %{raw: response(409, [{"content-length", byte_size(raw)}], raw)} end)

    assert {:ok, %Response{status: 409, body: ^raw}} =
             Runtime.delete(context.client, %{confirm: true})
  end

  test "request bounds and route allowlist fail before backend access", context do
    fixture = fixture(context, fn _ -> %{status: 200, body: %{}} end)

    for {method, path, body, opts} <- [
          {"POST", "/1.0/instances", "", []},
          {"GET", "/v1/runtime/status\r\nX: injected", "", []},
          {"POST", "/v1/runtime/create", :binary.copy("x", 1_048_577), []},
          {"GET", "/v1/runtime/status", "", [timeout_ms: 0]},
          {"GET", "/v1/runtime/status", "", [timeout_ms: 3_600_001]}
        ] do
      assert {:error, %Error{code: :invalid_request, outcome: :not_dispatched}} =
               Client.request(context.client, method, path, body, opts)
    end

    assert HTTPFixture.requests(fixture) == []
  end

  test "exact request-body limit is accepted", context do
    fixture =
      fixture(context, fn _ -> %{status: 400, body: %{error: %{code: "invalid_request"}}} end)

    body = :binary.copy("x", 1_048_576)

    assert {:ok, %Response{status: 400}} =
             Client.request(context.client, "POST", "/v1/runtime/create", body)

    assert [%{body: ^body}] = HTTPFixture.requests(fixture)
  end

  test "chunked and close-delimited responses are bounded and decoded", context do
    for {name, wire} <- [
          {:chunked,
           response(
             200,
             [{"transfer-encoding", "chunked"}],
             "3\r\nabc\r\n2\r\nde\r\n0\r\nx-end: yes\r\n\r\n"
           )},
          {:close, response(200, [], "abcde")}
        ] do
      fixture(
        context,
        fn _ ->
          %{
            wire_chunks: [
              {0, binary_part(wire, 0, 12)},
              {0, binary_part(wire, 12, byte_size(wire) - 12)}
            ]
          }
        end,
        name
      )

      assert {:ok, %Response{status: 200, body: "abcde"}} = Runtime.status(context.client)
      stop_supervised!(name)
    end
  end

  test "ambiguous, oversized and truncated responses fail visibly", context do
    cases = [
      {response(200, [{"content-length", 2}, {"content-length", 2}], "{}"), :invalid_response},
      {response(
         200,
         [{"content-length", 2}, {"transfer-encoding", "chunked"}],
         "2\r\n{}\r\n0\r\n\r\n"
       ), :invalid_response},
      {response(200, [{"content-length", 16_777_217}], ""), :response_too_large},
      {response(200, [{"content-length", 5}], "{}"), :invalid_response},
      {response(200, [{"x-long", :binary.copy("x", 16_385)}], ""), :invalid_response},
      {response(200, [{"transfer-encoding", "gzip"}], "invalid"), :invalid_response}
    ]

    for {{wire, code}, index} <- Enum.with_index(cases) do
      id = {:wire, index}
      fixture(context, fn _ -> %{raw: wire} end, id)
      assert {:error, %Error{code: ^code}} = Runtime.status(context.client)
      stop_supervised!(id)
    end
  end

  test "one total deadline covers slow response stages and closes without retry", context do
    observer = self()

    fixture =
      fixture(context, fn _ ->
        send(observer, {:request_observed, self()})

        %{
          wire_chunks: [
            {60, "HTTP/1.1 200 OK\r\n"},
            {60, "Content-Length: 2\r\n\r\n"},
            {60, "{}"}
          ]
        }
      end)

    before = System.monotonic_time(:millisecond)

    assert {:error, %Error{code: :timeout, outcome: :unknown}} =
             Runtime.start(context.client, nil, timeout_ms: 100)

    assert System.monotonic_time(:millisecond) - before < 400
    assert_receive {:request_observed, worker}
    monitor = Process.monitor(worker)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 400
    assert length(HTTPFixture.requests(fixture)) == 1
  end

  test "progress remains available while a start request waits", context do
    observer = self()

    fixture(context, fn request ->
      if request.target == "/v1/runtime/start" do
        send(observer, {:start_waiting, self()})

        receive do
          :finish -> :ok
        after
          1_000 -> :ok
        end
      end

      %{status: 200, body: %{version: 1}}
    end)

    start = Task.async(fn -> Runtime.start(context.client) end)
    assert_receive {:start_waiting, worker}
    assert {:ok, %Response{status: 200}} = Runtime.progress(context.client, timeout_ms: 200)
    send(worker, :finish)
    assert {:ok, %Response{status: 200}} = Task.await(start)
  end

  test "streamed response limit closes the request before an unbounded body accumulates",
       context do
    chunk = :binary.copy("x", 1_048_576)

    wire =
      [{0, response(200, [{"transfer-encoding", "chunked"}], "")}] ++
        List.duplicate({0, ["100000\r\n", chunk, "\r\n"]}, 17) ++ [{0, "0\r\n\r\n"}]

    fixture(context, fn _ -> %{wire_chunks: wire} end)

    assert {:error, %Error{code: :response_too_large, outcome: :read_only}} =
             Runtime.status(context.client)
  end

  test "missing and unsafe sockets never create or repair state", context do
    assert {:error, %Error{code: :unavailable}} = Runtime.status(context.client)
    refute File.exists?(context.client.socket)
    File.write!(context.client.socket, "marker")
    File.chmod!(context.client.socket, 0o600)
    assert {:error, %Error{code: :unsafe_socket}} = Runtime.status(context.client)
    assert File.read!(context.client.socket) == "marker"
  end

  test "standard macOS temp alias resolves to the same owned socket", context do
    fixture(context, fn _ -> %{status: 200, body: %{version: 1}} end)

    {:ok, config} =
      Configuration.new(String.replace_prefix(context.root, "/private/tmp/", "/tmp/"))

    {:ok, client} = Client.new(config, context.uid)
    assert {:ok, %Response{status: 200}} = Runtime.status(client)
  end

  test "owner, mode and symlink checks happen before connection", context do
    fixture = fixture(context, fn _ -> %{status: 200, body: %{}} end)
    {:ok, foreign} = Client.new(context.config, context.uid + 1)
    assert {:error, %Error{code: :unsafe_socket}} = Runtime.status(foreign)
    File.chmod!(context.client.socket, 0o666)
    assert {:error, %Error{code: :unsafe_socket}} = Runtime.status(context.client)
    File.chmod!(context.client.socket, 0o600)
    original = context.client.socket <> ".owned"
    File.rename!(context.client.socket, original)
    File.ln_s!(original, context.client.socket)
    assert {:error, %Error{code: :unsafe_socket}} = Runtime.status(context.client)
    assert HTTPFixture.requests(fixture) == []
    File.rm!(context.client.socket)
    File.rename!(original, context.client.socket)
  end

  defp fixture(context, handler, id \\ :runtime_fixture) do
    start_supervised!(
      {HTTPFixture, [transport: :gen_tcp, path: context.client.socket, handler: handler]},
      id: id
    )
  end

  defp response(status, headers, body) do
    [
      "HTTP/1.1 ",
      Integer.to_string(status),
      " Fixture\r\n",
      Enum.map(headers, fn {name, value} -> [name, ": ", to_string(value), "\r\n"] end),
      "Connection: close\r\n\r\n",
      body
    ]
    |> IO.iodata_to_binary()
  end
end
