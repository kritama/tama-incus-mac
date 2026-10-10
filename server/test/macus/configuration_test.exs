defmodule Macus.ConfigurationTest do
  use ExUnit.Case, async: true

  alias Macus.Configuration

  test "path resolution is passive and preserves significant whitespace" do
    root = Path.join(System.tmp_dir!(), "macus-absent-#{System.unique_integer([:positive])} ")
    refute File.exists?(root)
    assert {:ok, config} = Configuration.new(root)
    assert Configuration.gateway_dir(config) == root <> "/server"
    assert Configuration.runtime_socket(config) == root <> "/runtime.sock"
    assert Configuration.incus_socket(config) == root <> "/incus.sock"
    refute File.exists?(root)
  end

  test "rejects relative, missing and NUL-containing state paths" do
    for path <- [nil, "", "state", "~/state", "/tmp/state" <> <<0>>] do
      assert {:error, :invalid_state_dir} = Configuration.new(path)
    end
  end
end
