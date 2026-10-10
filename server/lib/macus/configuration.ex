defmodule Macus.Configuration do
  @moduledoc """
  Passive runtime path configuration. Resolving paths performs no filesystem
  access, creates no state and opens no listener. Ownership, ancestry and
  credentials must be checked by the gateway state boundary before use.
  """

  @enforce_keys [:state_dir]
  defstruct [:state_dir]

  @type t :: %__MODULE__{state_dir: String.t()}

  @spec new(String.t()) :: {:ok, t()} | {:error, :invalid_state_dir}
  def new(path) when is_binary(path) do
    if Path.type(path) == :absolute and not String.contains?(path, <<0>>) do
      {:ok, %__MODULE__{state_dir: path}}
    else
      {:error, :invalid_state_dir}
    end
  end

  def new(_), do: {:error, :invalid_state_dir}

  @spec gateway_dir(t()) :: String.t()
  def gateway_dir(%__MODULE__{state_dir: path}), do: Path.join(path, "server")

  @spec runtime_socket(t()) :: String.t()
  def runtime_socket(%__MODULE__{state_dir: path}), do: Path.join(path, "runtime.sock")

  @spec incus_socket(t()) :: String.t()
  def incus_socket(%__MODULE__{state_dir: path}), do: Path.join(path, "incus.sock")
end
