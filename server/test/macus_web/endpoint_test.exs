defmodule MacusWeb.EndpointTest do
  use ExUnit.Case, async: true

  test "fixture application starts without a public listener" do
    assert Process.whereis(Macus.Supervisor)
    assert Process.whereis(MacusWeb.Endpoint)
    refute MacusWeb.Endpoint.config(:server)
    refute MacusWeb.Endpoint.config(:http)
    refute MacusWeb.Endpoint.config(:https)
  end

  test "unsupported requests preserve the body and fail without backend access" do
    conn = Plug.Test.conn(:post, "/not-a-route", <<0, 255, 1, 2>>)

    conn = MacusWeb.Endpoint.call(conn, MacusWeb.Endpoint.init([]))
    assert conn.status == 404
    assert Jason.decode!(conn.resp_body) == %{"errors" => %{"detail" => "Not Found"}}
    assert {:ok, <<0, 255, 1, 2>>, _conn} = Plug.Conn.read_body(conn)
  end
end
