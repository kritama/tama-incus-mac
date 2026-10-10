defmodule Macus do
  @moduledoc """
  Host gateway for the private Swift runtime and canonical Incus API.

  Swift owns Apple Virtualization.framework and VM disks. This OTP application
  owns gateway connections, authentication and the private Swift adapter.
  Shared client/tools/tasks are supplied by verified embedded Opsmaru services
  in this BEAM with no second endpoint, Repo or launchd job. Restarting the
  gateway must never stop the independently supervised Swift service.
  """
end
