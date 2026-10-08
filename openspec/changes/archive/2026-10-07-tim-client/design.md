# Design

## Context

See proposal.md for motivation. The runtime already has bounded HTTP over private Unix sockets, versioned snake_case status/error JSON, standard transparent Incus traffic and real Alpine acceptance. Its executable currently only serves the daemon or probes host capabilities. Both daemon and client belong to this macOS-only package; tama-machine can continue consuming the APIs independently. The standard Incus CLI remains the workload client. The official Homebrew formula is https://formulae.brew.sh/formula/incus (7.5.1 at planning time).

## Goals / Non-Goals

**Goals:** Two small entrypoints in one install, explicit local lifecycle, truthful diagnostics, explicit setup of the standard Incus CLI against a ready local socket, and real executable verification.

**Non-Goals:** Workload inspection or mutation, Incus command aliases, new daemon APIs, remote TLS/LAN support, Linux/GUI requirements, automatic daemon or appliance installation/start, installing Homebrew, bundling an Incus binary in the runtime installer, release signing/notarization or a formula before actual release artifacts exist.

## Decisions

1. Keep SwiftPM's existing library and add a `tim` executable with client logic in `Sources/TamaIncusMac/Client`. This reuses safe descriptor/value types without another package or third-party dependency. Neither the client entrypoint nor its command modules call VZ. Separate tiny entrypoints have explicit roles.
2. Implement local HTTP transport using owned nonblocking descriptors, poll and a monotonic total deadline on the existing blocking-I/O worker queue. Bound headers to 16 KiB and bodies to 16 MiB. Support content-length, chunked and connection-close responses; reject ambiguous framing and malformed/truncated data. Verify endpoint ancestry, current-user socket ownership and peer UID; do not mutate state paths.
3. Parse a small explicit command/flag grammar. `--state-dir` overrides `TIM_STATE_DIR` and the normal default; `--json` and `--timeout 1..3600` are global. Only runtime stop permits `--force`. Only `client setup` permits `--remote`, `--set-default` and `--incus`. `list` and `show` are unknown commands and fail before networking. Defaults are 10 seconds for read-only requests and 650 seconds for lifecycle and client-setup responses. Setup uses the lifecycle default because Homebrew installation can be slow; users with longer boot or install needs must raise `--timeout`.
4. `tim client setup` resolves `incus` from PATH first. An absolute `--incus` override skips PATH and Homebrew and is the isolated-acceptance hook. If neither finds an executable and Homebrew is already available at PATH, `/opt/homebrew/bin/brew` or `/usr/local/bin/brew`, setup runs `brew install incus` with a fixed argument array and discovers the installed binary through `brew --prefix` even when that bin directory is not on PATH. It does not install Homebrew, run a shell installer, use sudo, add taps, invoke another package manager, or upgrade unrelated formulae. `HOMEBREW_NO_AUTO_UPDATE=1` avoids a general Homebrew update. Status, doctor and lifecycle commands never run brew or change Incus client configuration. An existing functioning `incus` is reused without upgrade. Install progress goes to stderr so `--json` stdout stays a single result.
5. Setup reads compatible runtime status and uses `incus_socket` only when the outer runtime is ready. It does not boot an absent or stopped runtime. The socket must be an absolute private owner-only socket with safe ancestry. Registration uses standard `incus remote` commands under the caller's `INCUS_CONF`, never handwritten client YAML or a translated server API. The default remote name is `tama-mac`. Repeating setup for the same name and `unix:` address is idempotent. A name already configured for another address fails with `conflict` and does not overwrite it. `--set-default` is the only way to switch the default; otherwise the previous default and unrelated remotes, projects, aliases and TLS material are preserved. Connectivity is checked with `incus list <remote>:` so the standard client, not tim, performs instance listing. Full client configuration and credentials are not logged.
6. Subprocesses use executable paths and argument arrays, preserve the relevant environment, drain both pipes while the child runs, cap captured output, and are terminated and reaped on deadline, failure or cancellation. `--json` results go to stdout; operational errors go to stderr as `{"error":{"code":...,"message":...}}`. Exit codes 0/1/2 distinguish success, operation and usage. Doctor gathers only GET observations and never boots or repairs anything.
7. A single opt-in `Packaging/install-local.sh --prefix ABSOLUTE_PATH` builds release products, stages/signs/verifies both tools, then installs them in prefix/bin. The daemon gets the existing VZ entitlement; tim runs without virtualization entitlement. State paths and launchd are untouched. This install does not install the Incus CLI. Prefix defaults to ~/.local. No formula or checksum is fabricated in this slice.

## Risks / Trade-offs

- Homebrew installation changes host packages and can take minutes → only `client setup` may invoke it, fixture processes prove the exact command and timeout, and real acceptance uses the already verified Incus binary unless an actual brew install is recorded separately.
- A remote add could clobber client configuration → standard remote commands, isolated `INCUS_CONF` in tests, conflict on address mismatch, and default changes only with `--set-default`.
- Slow brew or incus output can deadlock or grow without bound → concurrent pipe drains, output cap, and one total deadline.
- First install still requires Swift and a prepared runtime → document that accurately. Published signed distribution remains a later slice.
- Prior list/show hardware evidence cannot prove setup → the new acceptance gate records registration and `incus list` separately from historical lifecycle results.

## Migration Plan

The existing daemon invocation, endpoints and state remain compatible. `tim list` and `tim show` are removed before this slice is released. Install both release executables together into an isolated prefix. Setup acceptance uses a fresh Incus client directory and does not replace the in-use appliance or its installed prefix. Rollback removes only these two installed tools or restores prior binaries, retaining Incus state and unrelated client configuration. Keep this feature branch separate from develop until reviewed and accepted.
