# Macus server

Headless Phoenix/Cowboy OTP application `:macus`. Swift owns the VM and
private Unix sockets; this application supplies the public gateway.
Macus owns runtime/auth/proxy/host integration. The revised plan consumes
Opsmaru's shared client and later MCP/task services in this same BEAM, without
its endpoint/Repo or another job. That verified dependency is not available
in this lockfile yet; no duplicate fallback is implemented here.
See [the development guide](../docs/development.md) and
[the implementation plan](../openspec/changes/add-elixir-server/tasks.md).

From this directory:

```sh
mise exec -- mix deps.get
mise exec -- mix format --check-formatted
mise exec -- mix compile --warnings-as-errors
mise exec -- mix test
```

The scaffold starts its supervision tree without opening a listener, accessing
backend sockets or creating runtime state. Gateway HTTPS and authentication
are pending implementation; `mix phx.server` does not enable a listener yet.
Explicit calls to `Macus.Runtime` now use the private Swift adapter. Its fixture
tests verify routes, limits, deadlines, concurrency and passive socket safety:

```sh
mise exec -- mix test test/macus/runtime/client_test.exs
```
