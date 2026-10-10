defmodule Macus.MCP do
  @moduledoc """
  Consumer composition boundary for maintained TamaMCP transport, shared
  Opsmaru Incus tools/cache/task services and Macus-owned runtime tools.
  Macus supplies verified caller scopes, host/backend bindings and runtime
  safety. Shared journal/runner implementation belongs to Opsmaru and runs
  once inside this BEAM with its endpoint and Repo disabled. Durable task
  capabilities require library contracts and Macus consumer recovery evidence.
  """
end
