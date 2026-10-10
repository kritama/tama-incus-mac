defmodule Macus.Incus.InventoryTest do
  use ExUnit.Case, async: true

  alias Macus.Incus.Inventory

  @inventory Path.expand("../../../priv/incus/inventory.json", __DIR__)

  test "pinned inventory records complete provenance and evidence slots" do
    inventory = Jason.decode!(File.read!(@inventory))
    reference = Jason.decode!(File.read!(Path.join(Path.dirname(@inventory), "reference.json")))
    assert inventory["reference"] == reference
    assert length(inventory["entries"]) == 1280
    assert length(inventory["sources"]) == 86
    assert Inventory.diff(inventory, inventory) == %{added: [], removed: [], changed: []}

    for source <- inventory["sources"] do
      assert source["sha256"] =~ ~r/\A[0-9a-f]{64}\z/
    end

    for entry <- inventory["entries"] do
      assert entry["line"] > 0
      assert is_binary(entry["signature"])
      assert Map.has_key?(entry, "elixir")
      assert is_list(entry["evidence"])
    end
  end

  test "added, removed and changed declarations cannot disappear into a count" do
    inventory = Jason.decode!(File.read!(@inventory))
    [removed, changed | rest] = inventory["entries"]
    added = %{changed | "id" => "client/function/NewPublicOperation"}
    altered = %{changed | "signature" => "func NewShape() error"}
    next = %{inventory | "entries" => [added, altered | rest]}

    assert Inventory.diff(inventory, next) == %{
             added: [added["id"]],
             removed: [removed["id"]],
             changed: [changed["id"]]
           }
  end

  test "duplicate IDs fail visibly" do
    entry = %{"id" => "same"}

    assert_raise ArgumentError, fn ->
      Inventory.diff(%{"entries" => [entry, entry]}, %{"entries" => []})
    end
  end
end
