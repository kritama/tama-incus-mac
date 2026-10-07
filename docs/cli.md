# macus

`macus` is the single command for foreground serving, host capability discovery, local runtime control and standard Incus CLI setup. The executable delegates to the Macus library; Virtualization.framework code lives in `Sources/Macus/Virtualization`. Workload operations belong to the standard `incus` client.

## Commands

```text
macus [--state-dir ABSOLUTE_PATH] [--json] [--timeout SECONDS] <command>

serve [--state-dir ABSOLUTE_PATH]
capabilities
runtime status
runtime start
runtime stop [--force]
runtime restart
doctor
client setup [--remote NAME] [--set-default] [--incus ABSOLUTE_PATH]
start [--remote NAME] [--set-default] [--incus ABSOLUTE_PATH] [--progress auto|plain|none]
```

`macus` and `macus --help` print this contract and exit 0. For client commands, global flags may appear around the command. `macus serve` runs the foreground daemon and accepts only its optional `--state-dir` after `serve`; `macus capabilities` reports host capabilities without contacting the daemon or booting a guest. These two modes do not accept client JSON/timeout flags. `--force` is valid only on `runtime stop`. `--remote`, `--set-default` and `--incus` are valid on `start` and `client setup`. `--progress` is valid only on `start`. `list`, `show` and other workload commands fail before networking or installation. The default remote name is `macus`. `--incus` must be an absolute executable and skips PATH and Homebrew; it is the isolated-acceptance hook.

`start` is the high-level first-use command. It validates the host, entitlement and Incus/Homebrew prerequisite, acquires the pinned Alpine appliance, prepares its seed, activates a per-user background service when no compatible daemon exists, creates an absent runtime, waits through the expected kernel restart, and registers the standard Incus client. `serve`, `runtime`, `doctor` and `client setup` stay explicit lower-level commands. They do not download an appliance or activate a service. `runtime start` still fails when the runtime has not been created and does not provision an absent installation.

State directory precedence is `--state-dir`, then `MACUS_STATE_DIR`, then legacy `TIM_STATE_DIR`, then `~/.tama/incus-mac`. Every selected path must be absolute. Selecting it does not create the directory. Status, doctor and lifecycle commands never run `brew` or change Incus client configuration.

Timeout is an integer from 1 to 3600 seconds and one monotonic deadline for each request or subprocess, including connect, write, read and child output. The default is 10 seconds for status and doctor, and 650 seconds for runtime start, stop, restart and client setup. `macus start` defaults to 1800 seconds so first provisioning, the expected kernel restart and client installation share one deadline. Later stages, including each Incus or Homebrew child, receive only the remaining whole seconds. A partial second is not rounded up into a new per-command timeout. Standalone `client setup` still gives each of its own commands the selected timeout. Restart includes shutdown plus boot. Setup uses the 650-second default because installing the Incus CLI can be slow. Raise `--timeout` when those operations need longer.

`--progress auto` animates on an interactive stderr terminal whose `TERM` is not `dumb`. Redirected stderr, `TERM=dumb`, `--progress plain` and `--json` use plain stage lines without cursor escapes. `--progress none` suppresses progress. `--json` writes one result object to stdout. Progress, when enabled, stays on stderr. Byte percentages appear only when a trustworthy total length is known. Exit 130 means start was interrupted; the command does not force-stop a daemon-owned guest.

Exit status is 0 on success, 1 on operational failure and 2 on invalid arguments. `--json` writes the result to stdout. Operational and usage errors go to stderr as `{"error":{"code":"...","message":"..."}}` when `--json` is set. Setup installation progress also goes to stderr so the JSON result stays valid. Stable codes include `conflict`, `timeout`, `unavailable`, `invalid_configuration`, `invalid_request` and `io`.

## Outer runtime and the standard Incus CLI

`runtime` commands and `doctor` describe the outer Apple VZ appliance through `/v1/runtime/*`. `runtime stop --force` sends `{"force":true}`. These commands do not list or mutate instances.

`client setup` reads runtime status and continues only when API version is 1 and the outer runtime is ready. It does not boot a stopped appliance. It validates the returned `incus_socket` as a private owner-only socket, then registers `unix:<path>` with standard `incus remote` commands. It honors `INCUS_CONF`. Repeating setup for the same name and socket is idempotent. A name that already points elsewhere fails with `conflict` and is not overwritten. The default remote changes only with `--set-default`. Unrelated remotes, projects, aliases and certificates are left in place. Connectivity is `incus list <remote>:`, so instance listing stays an Incus operation.

If `--incus` is omitted, setup uses an `incus` executable on `PATH`. Otherwise, when Homebrew is already installed (`PATH`, `/opt/homebrew/bin/brew` or `/usr/local/bin/brew`), it runs `brew install incus` for the official formula and discovers the binary through `brew --prefix` even if that bin directory is not on `PATH`. `HOMEBREW_NO_AUTO_UPDATE=1` is set when absent so setup does not update unrelated formulae. An existing Homebrew copy is reused without reinstalling. If Homebrew is missing, setup tells the operator to install it from https://brew.sh and does not install Homebrew, use a shell installer, sudo, another package manager or a custom tap. `MACUS_BREW_FALLBACK=0` disables the two standard Homebrew locations for tests; users should not set it.

Subprocesses use fixed argument arrays, preserve the relevant environment, drain bounded output while the child runs, and are terminated and reaped on failure, deadline or cancellation. Full client configuration and credentials are not printed.

## Transport limits

The client opens a new nonblocking Unix connection per control request. Headers are limited to 16 KiB and bodies to 16 MiB. It accepts content-length, chunked and connection-close bodies, and rejects ambiguous or truncated framing. Before connecting, it rejects unsafe symlink ancestry, a non-socket endpoint, and a socket or parent directory that is not mode-private and owned by the current user. The peer UID must match. These checks do not create or chmod state.

## Installation

Local installation from source requires Swift and is documented in [development](development.md) and [packaging](../Packaging/README.md). It installs one release executable with the virtualization entitlement into the prefix and does not install the Incus CLI or a launch agent. `macus client setup` is the explicit later step for the standard Incus CLI. Production signed, notarized or Homebrew delivery of macus remains future work.

`macus` replaces both legacy executable names. The existing state path and persisted formats are retained. New registrations use `macus`; pass `--remote tama-mac` to reuse the earlier default remote.
