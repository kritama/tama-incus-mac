# Local API contract

The daemon serves two owner-only Unix sockets in its state directory, default `~/.tama/incus-mac`. `runtime.sock` controls the outer VM. `incus.sock` carries unmodified Incus HTTP, WebSockets, exec, events and streaming operations. Possession of either socket grants privileged control of the Linux appliance; run clients as the same macOS user. No TCP listener or SSH is used.

## Runtime API v1

| Method | Path | Payload / response |
| --- | --- | --- |
| GET | `/v1/runtime/status` | State, socket path, uptime and optional last error |
| GET | `/v1/runtime/capabilities` | Host support and live Incus/workload evidence |
| GET | `/v1/runtime/health` | Live guest protocol, Incus version/extensions and KVM |
| GET | `/v1/runtime/config` | Complete configuration |
| POST | `/v1/runtime/create` | Complete configuration; creates verified writable root and persistent data |
| POST | `/v1/runtime/start` | No body; waits for readiness |
| POST | `/v1/runtime/stop` | Optional `{"force":false}`; waits for graceful shutdown |
| POST | `/v1/runtime/restart` | No body; graceful stop, then start |
| PUT | `/v1/runtime/config` | Complete replacement; only when stopped |
| DELETE | `/v1/runtime` | `{"confirm":true}`; only when stopped; destroys Incus state |

States: `absent`, `stopped`, `starting`, `ready`, `stopping`, `failed`. Start/create/stop are idempotent when their postcondition is already satisfied. Lifecycle/configuration mutations return 409 during another mutation; status remains readable. Initial boot allows 600 seconds by default; clients must use a matching response timeout. Stop never silently forces shutdown on timeout. Deletion leaves the externally supplied source image/seed and logs intact.

JSON uses snake_case. Configuration schema 1 requires every field shown below; API clients can use the generated `config.json`:

```json
{
  "schema_version": 1,
  "cpu_count": 4,
  "memory_mib": 4096,
  "data_disk_gib": 32,
  "appliance_manifest_path": "/absolute/appliance/manifest.json",
  "seed_path": "/absolute/appliance/seed.iso",
  "nested_virtualization": true,
  "shares": [],
  "readiness_timeout_seconds": 600,
  "shutdown_timeout_seconds": 60
}
```

A share is `{"name":"workspace","path":"/absolute/project","read_only":true}`. Names contain ASCII letters, digits, `_` or `-`, up to 36 bytes; paths must be existing directories. The guest exposes them under `/mnt/tama-shares/<name>`; callers use standard Incus disk devices to pass them to workloads. Shares never appear implicitly.

Resource bounds: 1–64 CPUs (also limited by VZ), 512–262144 MiB RAM (also limited by VZ), 1–16384 GiB data, 1–1800 second readiness and 1–300 second shutdown. Updates cannot change appliance/seed identity or shrink data. Growing the disk preserves bytes and grows ext4 at the next boot.

Error envelope: `{"error":{"code":"conflict","message":"A runtime mutation is already in progress"}}`. Codes: `invalid_request`/`invalid_configuration` (400), `not_found` (404), `conflict` (409), `unavailable`/`io` (503), `timeout` (504). Invalid JSON yields 400. Control requests use HTTP/1.0 or 1.1 with one request per connection, at most 16 KiB headers and 1 MiB body. Chunked transfer and duplicate lengths are rejected. Incus traffic has its own stream socket and does not inherit control HTTP restrictions.

## tama-machine integration

On Linux, connect directly to native Incus. On macOS, start the service if necessary, read capabilities/status, create with the appliance configuration if absent, start, then connect to the returned `incus_socket` with a Unix HTTP transport. Existing Incus SDKs can use the socket unchanged. Do not create a second workload API.

```sh
STATE="$HOME/.tama/incus-mac"
curl --unix-socket "$STATE/runtime.sock" http://localhost/v1/runtime/status
curl --unix-socket "$STATE/runtime.sock" -H 'Content-Type: application/json' \
  --data-binary @/absolute/appliance/config.json http://localhost/v1/runtime/create
curl --unix-socket "$STATE/runtime.sock" -X POST http://localhost/v1/runtime/start
curl --unix-socket "$STATE/incus.sock" http://localhost/1.0
```

The standard Incus CLI can connect using `INCUS_SOCKET="$STATE/incus.sock"`; isolate `INCUS_CONF` for test clients. The runtime performs no instance/image/profile/project/network/storage/remote/transfer translations. Standard Incus artifacts remain portable to remote Incus hosts.
