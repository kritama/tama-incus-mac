defmodule Macus.Proxy.CowboyUpgradeTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Macus.TestSupport.{CowboyUpgradeHandler, NativeBackend, TLSIdentity}

  @driver Path.expand("../../../../.integration/incus-reference-driver", __DIR__)
  @reference_dir Path.expand("../../reference", __DIR__)

  setup_all do
    {output, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "."],
        cd: @reference_dir,
        stderr_to_stdout: true,
        env: [{"GOTOOLCHAIN", "local"}]
      )

    assert status == 0, output
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "mc-cw-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    server = TLSIdentity.generate(root, "server", "localhost")
    client = TLSIdentity.generate(root, "client", "fixture-client")
    %{root: root, server: server, client: client}
  end

  for protocol <- ["sftp", "nbd"] do
    @tag protocol: protocol
    test "#{protocol} upgrades preserve binary duplex traffic and coalesced bytes", context do
      initial = :binary.copy(<<0, 255, 128, 13, 10, 0, 1>>, 2_000)
      {backend, port} = start_fixture(context, initial: initial)
      socket = connect(port, context)
      on_exit(fn -> :ssl.close(socket) end)
      early = <<255, 0, 128, 1>>
      target = "/1.0/instances/fixture/#{context.protocol}?project=one+two&target=node%2Fa"
      :ok = :ssl.send(socket, [upgrade_request(target, context.protocol), early])
      {head, buffered} = read_head(socket)
      assert head =~ "HTTP/1.1 101 "
      assert String.downcase(head) =~ "upgrade: #{context.protocol}"
      assert receive_exact(socket, buffered, byte_size(initial <> early)) == initial <> early
      assert_receive {:backend_request, request}
      assert request =~ "GET #{target} HTTP/1.1"
      assert_receive {:tunnel_started, tunnel}

      # A transfer spanning many transport reads cannot be whole-body buffered.
      payload = :binary.copy(<<0, 255, 2, 128>>, 131_072)
      :ok = :ssl.send(socket, payload)
      assert receive_exact(socket, "", byte_size(payload)) == payload
      assert NativeBackend.accepted(backend) == 1
      :ok = :ssl.close(socket)
      assert_receive {:backend_closed, _}, 2_000
      assert_receive {:tunnel_closed, ^tunnel}, 2_000
    end

    @tag protocol: protocol
    test "official Incus client negotiates #{protocol} on the Cowboy TLS listener", context do
      initial = <<0, 255, 128>>
      {_backend, port} = start_fixture(context, initial: initial)
      payload = :binary.copy(<<128, 0, 255, 3>>, 16_384)
      result = native_client(port, context, payload, byte_size(initial))
      assert Base.decode64!(result["initial"]) == initial
      assert Base.decode64!(result["echo"]) == payload
      assert result["write_count"] == byte_size(payload)
      assert_receive {:backend_request, head}
      assert head =~ "GET /1.0/instances/fixture/#{context.protocol} HTTP/1.1"
      assert_receive {:backend_closed, _}, 2_000
    end
  end

  @tag protocol: "sftp"
  test "anonymous upgrade is denied before Unix backend access", context do
    {backend, port} = start_fixture(context)
    socket = connect(port, context, false)
    :ok = :ssl.send(socket, upgrade_request("/1.0/instances/fixture/sftp", "sftp"))
    {head, _body} = read_head(socket)
    assert head =~ "HTTP/1.1 403 "
    assert NativeBackend.accepted(backend) == 0
    refute_receive {:backend_request, _}, 50
    :ssl.close(socket)
  end

  @tag protocol: "sftp"
  test "backend protocol mismatch cannot produce a successful client upgrade", context do
    {_backend, port} = start_fixture(context, reply_protocol: "nbd")
    socket = connect(port, context)
    :ok = :ssl.send(socket, upgrade_request("/1.0/instances/fixture/sftp", "sftp"))
    {head, _body} = read_head(socket)
    assert head =~ "HTTP/1.1 502 "
    assert_receive {:backend_closed, _}, 2_000
    refute_receive {:tunnel_started, _}, 50
    :ssl.close(socket)
  end

  @tag protocol: "nbd"
  test "an idle native stream leaves Phoenix responsive on the same TLS listener", context do
    {_backend, port} = start_fixture(context)
    stream = connect(port, context)
    :ok = :ssl.send(stream, upgrade_request("/1.0/instances/fixture/nbd", "nbd"))
    {head, _} = read_head(stream)
    assert head =~ "HTTP/1.1 101 "
    http = connect(port, context)

    :ok =
      :ssl.send(http, "GET /no-route HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

    {head, body} = read_head(http)
    assert head =~ "HTTP/1.1 404 "
    body = receive_exact(http, body, byte_size(~s({"errors":{"detail":"Not Found"}})))
    assert Jason.decode!(body) == %{"errors" => %{"detail" => "Not Found"}}
    :ssl.close(http)
    :ssl.close(stream)
  end

  @tag protocol: "nbd"
  test "backend half-close retains the client-to-backend direction", context do
    initial = <<0, 1, 255>>
    {_backend, port} = start_fixture(context, initial: initial, half_close: true)
    remaining = <<255, 128, 0, 7>>
    result = native_client(port, context, remaining, byte_size(initial), true)
    assert Base.decode64!(result["initial"]) == initial
    assert result["read_eof"]
    assert result["write_count"] == byte_size(remaining)
    assert_receive {:backend_bytes, ^remaining}, 1_000
  end

  @tag protocol: "sftp"
  test "Cowboy's response-header guard rejects CRLF during protocol switch", context do
    {_backend, port} = start_fixture(context)
    socket = connect(port, context)

    capture_log(fn ->
      :ok = :ssl.send(socket, "GET /invalid-header HTTP/1.1\r\nHost: localhost\r\n\r\n")
      assert {:ok, response} = :ssl.recv(socket, 0, 1_000)
      assert response =~ "HTTP/1.1 500 "
      refute response =~ "x-injected"
    end)

    refute_receive {:tunnel_started, _}, 50
  end

  defp start_fixture(context, opts \\ []) do
    backend_opts =
      Map.merge(
        %{
          path: Path.join(context.root, "backend.sock"),
          protocol: context.protocol,
          observer: self(),
          initial: ""
        },
        Map.new(opts)
      )

    backend = start_supervised!({NativeBackend, backend_opts})
    handler_opts = %{path: backend_opts.path, certificate: context.client.der, observer: self()}

    dispatch =
      :cowboy_router.compile([
        {:_,
         [
           {"/1.0", CowboyUpgradeHandler, handler_opts},
           {"/1.0/instances/:name/sftp", CowboyUpgradeHandler, handler_opts},
           {"/1.0/instances/:name/nbd", CowboyUpgradeHandler, handler_opts},
           {"/invalid-header", Macus.TestSupport.InvalidHeaderHandler, []},
           {:_, Plug.Cowboy.Handler, {MacusWeb.Endpoint, []}}
         ]}
      ])

    ref = {:macus_cowboy_fixture, make_ref()}

    {:ok, _pid} =
      :cowboy.start_tls(
        ref,
        %{
          num_acceptors: 2,
          max_connections: 16,
          socket_opts: [
            ip: {127, 0, 0, 1},
            port: 0,
            certfile: String.to_charlist(context.server.certfile),
            keyfile: String.to_charlist(context.server.keyfile),
            cacertfile: String.to_charlist(context.client.cafile),
            verify: :verify_peer,
            fail_if_no_peer_cert: false,
            versions: [:"tlsv1.3"],
            alpn_preferred_protocols: ["http/1.1"]
          ]
        },
        %{env: %{dispatch: dispatch}, invalid_response_headers: :error_terminate}
      )

    on_exit(fn -> :cowboy.stop_listener(ref) end)
    {backend, :ranch.get_port(ref)}
  end

  defp connect(port, context, identity \\ true) do
    opts = [
      :binary,
      active: false,
      verify: :verify_peer,
      exit_on_close: false,
      cacertfile: String.to_charlist(context.server.cafile),
      server_name_indication: ~c"localhost",
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
      versions: [:"tlsv1.3"]
    ]

    opts =
      if identity,
        do:
          opts ++
            [
              certfile: String.to_charlist(context.client.certfile),
              keyfile: String.to_charlist(context.client.keyfile)
            ],
        else: opts

    {:ok, socket} = :ssl.connect(~c"localhost", port, opts, 2_000)
    socket
  end

  defp upgrade_request(target, protocol),
    do: [
      "GET ",
      target,
      " HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: ",
      protocol,
      "\r\n\r\n"
    ]

  defp native_client(port, context, payload, initial_size, half_close \\ false) do
    input = %{
      "url" => "https://localhost:#{port}",
      "protocol" => context.protocol,
      "server_cert" => File.read!(context.server.certfile),
      "tls_ca" => File.read!(context.server.cafile),
      "client_cert" => File.read!(context.client.certfile),
      "client_key" => File.read!(context.client.keyfile),
      "payload" => Base.encode64(payload),
      "read_initial" => initial_size,
      "half_close" => half_close
    }

    path = Path.join(context.root, "native-client.json")
    File.write!(path, Jason.encode!(input))
    File.chmod!(path, 0o600)
    {output, status} = System.cmd(@driver, [path], stderr_to_stdout: true)
    assert status == 0, output
    Jason.decode!(output)
  end

  defp read_head(socket, bytes \\ "") do
    case :binary.split(bytes, "\r\n\r\n") do
      [head, body] ->
        {head, body}

      [_] ->
        {:ok, bytes_next} = :ssl.recv(socket, 0, 2_000)
        read_head(socket, bytes <> bytes_next)
    end
  end

  defp receive_exact(_socket, bytes, size) when byte_size(bytes) == size, do: bytes

  defp receive_exact(socket, bytes, size) when byte_size(bytes) < size do
    {:ok, next} = :ssl.recv(socket, size - byte_size(bytes), 2_000)
    receive_exact(socket, bytes <> next, size)
  end
end
