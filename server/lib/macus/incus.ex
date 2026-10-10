defmodule Macus.Incus do
  @moduledoc """
  Consumer boundary for the shared `Opsmaru.Incus` library. Any compatibility
  functions added here may only delegate to a verified pinned dependency,
  configured against the existing `incus.sock` bridge. Portable codecs,
  request behavior and client parity belong to Opsmaru; this module does not
  supply a fallback implementation while that foundation is unavailable.
  Historical inventory comparison helpers remain verification inputs and
  cannot establish typed-client or raw-proxy coverage.
  """
end
