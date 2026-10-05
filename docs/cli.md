# tim

`tim` is the local client for this repository. One SwiftPM package and one installation supply both `tama-incus-mac` and `tim`. There is no separate client product. The executable only parses arguments and calls the library client; it does not import Virtualization.framework or wrap a host VM CLI. Workload operations belong to the standard `incus` client. `tim` does not implement `list` or `show`.

## Commands

```text
tim [--state-dir ABSOLUTE_PATH] [--json] [--timeout SECONDS] <command>

runtime status
runtime start
runtime stop [--force]
runtime restart
doctor
client setup [--remote NAME] [--set-default] [--incus ABSOLUTE_PATH]
```

`tim` and `tim --help` print this contract and exit 0. Global flags may appear around the command. `--force` is valid only on `runtime stop`. `--remote`, `--set-default` and `--incus` are valid only on `client setup`. `list`, `show` and other workload commands fail before networking or installation. The default remote name is `tama-mac`. `--incus` must be an absolute executable and skips PATH and Homebrew; it is the isolated-acceptance hook.

State directory precedence is `--state-dir`, then `TIM_STATE_DIR`, then `~/.tama/incus-mac`. Every selected path must be absolute. Selecting it does not create the directory. Status, doctor and lifecycle commands never run `brew` or change Incus client configuration.

Timeout is an integer from 1 to 3600 seconds and one monotonic deadline for each request or subprocess, including connect, write, read and child output. The default is 10 seconds for status and doctor, and 650 seconds for start, stop, restart and client setup. Restart includes shutdown plus boot. Setup uses the same default because installing the Incus CLI can be slow. Raise `--timeout` when those operations need longer.

Exit status is 0 on success, 1 on operational failure and 2 on invalid arguments. `--json` writes the result to stdout. Operational and usage errors go to stderr as `{"error":{"code":"...","message":"..."}}` when `--json` is set. Setup installation progress also goes to stderr so the JSON result stays valid. Stable codes include `conflict`, `timeout`, `unavailable`, `invalid_configuration`, `invalid_request` and `io`.

## Outer runtime and the standard Incus CLI

`runtime` commands and `doctor` describe the outer Apple VZ appliance through `/v1/runtime/*`. `runtime stop --force` sends `{"force":true}`. These commands do not list or mutate instances.

`client setup` reads runtime status and continues only when API version is 1 and the outer runtime is ready. It does not boot a stopped appliance. It validates the returned `incus_socket` as a private owner-only socket, then registers `unix:<path>` with standard `incus remote` commands. It honors `INCUS_CONF`. Repeating setup for the same name and socket is idempotent. A name that already points elsewhere fails with `conflict` and is not overwritten. The default remote changes only with `--set-default`. Unrelated remotes, projects, aliases and certificates are left in place. Connectivity is `incus list <remote>:`, so instance listing stays an Incus operation.

If `--incus` is omitted, setup uses an `incus` executable on `PATH`. Otherwise, when Homebrew is already installed (`PATH`, `/opt/homebrew/bin/brew` or `/usr/local/bin/brew`), it runs `brew install incus` for the official formula and discovers the binary through `brew --prefix` even if that bin directory is not on `PATH`. `HOMEBREW_NO_AUTO_UPDATE=1` is set when absent so setup does not update unrelated formulae. An existing Homebrew copy is reused without reinstalling. If Homebrew is missing, setup tells the operator to install it from https://brew.sh and does not install Homebrew, use a shell installer, sudo, another package manager or a custom tap. `TIM_BREW_FALLBACK=0` disables the two standard Homebrew locations for tests; users should not set it.

Subprocesses use fixed argument arrays, preserve the relevant environment, drain bounded output while the child runs, and are terminated and reaped on failure, deadline or cancellation. Full client configuration and credentials are not printed.

## Transport limits

The client opens a new nonblocking Unix connection per control request. Headers are limited to 16 KiB and bodies to 16 MiB. It accepts content-length, chunked and connection-close bodies, and rejects ambiguous or truncated framing. Before connecting, it rejects unsafe symlink ancestry, a non-socket endpoint, and a socket or parent directory that is not mode-private and owned by the current user. The peer UID must match. These checks do not create or chmod state.

## Installation

Local installation from source requires Swift and is documented in [development](development.md) and [packaging](../Packaging/README.md). It installs both release executables into one prefix and does not install the Incus CLI or a launch agent. `tim client setup` is the explicit later step for the standard Incus CLI. Production signed, notarized or Homebrew delivery of tama-incus-mac remains future work.
