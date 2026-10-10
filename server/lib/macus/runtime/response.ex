defmodule Macus.Runtime.Response do
  @moduledoc "Private Swift HTTP response, preserving native status and JSON bytes."
  @enforce_keys [:status, :body]
  defstruct [:status, :body, headers: []]
  @type t :: %__MODULE__{status: integer(), body: binary(), headers: [{binary(), binary()}]}
end

defmodule Macus.Runtime.Error do
  @moduledoc """
  Bounded private-transport failure. `:unknown` means a mutation may have reached
  Swift; it never authorizes automatic retry or implies remote cancellation.
  Errors contain no socket paths, request bytes or backend exception text.
  """
  @enforce_keys [:code, :outcome]
  defstruct [:code, :outcome]
  @type t :: %__MODULE__{code: atom(), outcome: :not_dispatched | :read_only | :unknown}
end
