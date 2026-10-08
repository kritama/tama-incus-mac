# Macus

A headless macOS compatibility layer that boots a Linux Incus host using Apple's **Virtualization.framework directly**. Tama uses native Incus on Linux and this appliance on macOS; Incus remains the workload API and portable artifact layer.

Requires Apple Silicon, macOS 15+ and Swift 6.4. One SwiftPM library (`Macus`) and one `macus` command for foreground serving and local runtime/client setup; no third-party Swift dependencies, separate client repository or host VM runtime.

**Development status:** Installation is currently from source. There is no published Macus Homebrew formula. `macus start` downloads and verifies the pinned Alpine appliance; it does not upgrade an existing root image or install Homebrew. Hardware results and distribution limitations are recorded in [the acceptance record](docs/acceptance.md).

The service exposes `runtime.sock` for outer VM lifecycle and `incus.sock` for transparent Incus traffic over vsock. Both are private Unix sockets in the selected state directory; the default is `~/.tama/incus-mac`. Normal use needs no GUI or SSH. Instance/image/profile/project/network/storage/migration operations belong to Incus.

## Start Macus

On a supported Apple Silicon Mac with macOS 15+, install the entitled `macus` executable, then run one command:

```sh
macus start
```

Start checks virtualization support and the executable entitlement, downloads and verifies the pinned Alpine appliance, prepares its seed, activates a per-user background service, creates the runtime when it is absent, waits through the expected kernel restart, and registers the standard Incus client as remote `macus`. Progress shows the active stage. A download shows bytes, and a percentage only when the length is known. Other waits show elapsed time. Success means live Incus readiness and a working client, not merely that a process launched.

Homebrew must already be installed if `incus` is not on `PATH`. Start installs the official `incus` formula in that case and does not install Homebrew or use sudo. If the selected remote already points elsewhere, start fails without overwriting it; choose another `--remote`. Repeating start reuses an existing runtime, storage backend and client registration. It does not replace disks or change resource settings. If the client step fails after the runtime is ready, retry `macus start`; it will not reboot a ready guest to repeat client setup.

`--json --progress none` writes one result object to stdout. Closing the terminal does not stop a launchd-owned service. If start reuses a foreground `macus serve`, it says so: closing that terminal still stops the daemon.

`serve`, `runtime`, `doctor` and `client setup` remain explicit lower-level commands. They do not download an appliance or activate a service.

## Test a fresh installation

Use a clean supported Mac or a new macOS account to exercise first-use prerequisites. The walkthrough also works alongside an existing installation when it uses a separate prefix, state directory and Incus client configuration. Each new test starts with a new short test root. This is opt-in hardware acceptance: `macus start` boots a real Linux VM. Keep the test root and its logs on failure.

```sh
export MACUS_TEST_ROOT="$(mktemp -d /private/tmp/macus-fresh.XXXXXX)"
git clone --branch develop https://github.com/upmaru/macus.git "$MACUS_TEST_ROOT/src"
cd "$MACUS_TEST_ROOT/src"
Packaging/install-local.sh --prefix "$MACUS_TEST_ROOT/install"
export PATH="$MACUS_TEST_ROOT/install/bin:$PATH"
export MACUS_STATE_DIR="$MACUS_TEST_ROOT/state"
export INCUS_CONF="$MACUS_TEST_ROOT/client"
mkdir -m 700 "$INCUS_CONF"
macus start --remote macus-fresh
incus list macus-fresh:
```

The installed binary does not need the checkout after installation. A nondefault `MACUS_STATE_DIR` uses a session-only service and does not replace the default LaunchAgent. Passing unit tests is not this hardware acceptance.

## Advanced manual preparation

The blocks below are the debug path. They are not required for `macus start`. Use them to inspect image verification, the control API or a foreground daemon. This path boots a real VM. Keep the test root on failure. The kernel-update retry is the one expected first-boot interruption when you drive `runtime start` yourself.

### 1. Check prerequisites and create an isolated checkout

Install Xcode with Swift 6.4, select that toolchain, and install [Homebrew](https://brew.sh). Image preparation needs Python 3.11+ and GnuPG. Reserve 4 GiB RAM for the guest and disk space for the downloaded image, a writable root of at least 12 GiB, and a 32 GiB sparse data disk. Internet access is required for downloads, guest package installation and workload images.

```sh
brew install python gnupg
swift --version
python3 -c 'import sys; assert sys.version_info >= (3, 11), "Python 3.11+ required"'
gpg --version

export MACUS_TEST_ROOT="$(mktemp -d /private/tmp/macus-fresh.XXXXXX)"
git clone --branch develop https://github.com/upmaru/macus.git "$MACUS_TEST_ROOT/src"
cd "$MACUS_TEST_ROOT/src"
export PATH="$MACUS_TEST_ROOT/install/bin:$PATH"
export MACUS_STATE_DIR="$MACUS_TEST_ROOT/state"
export INCUS_CONF="$MACUS_TEST_ROOT/client"
mkdir -m 700 "$INCUS_CONF"
printf 'Keep this test-root path for the second terminal: %s\n' "$MACUS_TEST_ROOT"
```

GitHub access to the repository is required. The short test path avoids Darwin's 103-byte Unix socket path limit. `/private/tmp` may be cleaned on a host reboot. If you also want to test rebooting macOS, choose a fresh, short, persistent test root from the outset; keep its absolute path fixed after appliance creation.

### 2. Install and inspect the actual installed command

```sh
Packaging/install-local.sh --prefix "$MACUS_TEST_ROOT/install"
command -v macus
codesign --verify --strict "$MACUS_TEST_ROOT/install/bin/macus"
macus --help
macus capabilities
```

The installer builds and ad-hoc signs one release executable with the virtualization entitlement. `command -v` should point into the new test prefix, and capabilities should report `supported: true` and `virtualization: apple-vz`. Stop here if host virtualization is unsupported. `nested_virtualization: false` does not prevent container testing; nested Incus VMs need usable guest KVM and separate acceptance.

### 3. Download, verify and prepare the Alpine appliance

Use the pinned ARM64 EFI/cloud-init metal image from [Alpine's cloud image catalog](https://alpinelinux.org/cloud/), including its checksum, signature and published signing key:

```sh
mkdir -p "$MACUS_TEST_ROOT/downloads"
base=https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/cloud
image=alpine-3.24.2-aarch64-cloudinit-metal-r0.raw.tar.gz
curl -fL "$base/$image" -o "$MACUS_TEST_ROOT/downloads/$image"
curl -fL "$base/$image.sha512" -o "$MACUS_TEST_ROOT/downloads/$image.sha512"
curl -fL "$base/$image.asc" -o "$MACUS_TEST_ROOT/downloads/$image.asc"
curl -fL https://alpinelinux.org/keys/tomalok.asc -o "$MACUS_TEST_ROOT/downloads/tomalok.asc"
python3 Integration/scripts/verify-appliance.py \
  --archive "$MACUS_TEST_ROOT/downloads/$image" \
  --checksum-file "$MACUS_TEST_ROOT/downloads/$image.sha512" \
  --signature "$MACUS_TEST_ROOT/downloads/$image.asc" \
  --signing-key "$MACUS_TEST_ROOT/downloads/tomalok.asc" \
  --output "$MACUS_TEST_ROOT/verified-alpine"
python3 Integration/scripts/prepare-appliance.py \
  --root-disk "$MACUS_TEST_ROOT/verified-alpine/disk.raw" \
  --output "$MACUS_TEST_ROOT/appliance" \
  --appliance-id "macus-fresh-$(basename "$MACUS_TEST_ROOT")"
```

Verification checks SHA-512 and the pinned Alpine signing fingerprint in an isolated GnuPG keyring, then records raw-image provenance. Preparation creates `manifest.json`, `seed.iso` and a complete `config.json` with 4 CPUs, 4096 MiB RAM, 32 GiB data, no filesystem shares and a 600-second readiness timeout. Keep the verified image and appliance directory on the same filesystem; preparation hard-links the immutable raw input. Inspect the generated config before proceeding.

### 4. Serve the runtime and create the appliance

In **terminal A**, keep the daemon in the foreground:

```sh
macus serve
```

In **terminal B**, set `MACUS_TEST_ROOT` to the exact path printed in step 1, then restore the same environment:

```sh
export MACUS_TEST_ROOT=/private/tmp/macus-fresh.REPLACE_ME
export PATH="$MACUS_TEST_ROOT/install/bin:$PATH"
export MACUS_STATE_DIR="$MACUS_TEST_ROOT/state"
export INCUS_CONF="$MACUS_TEST_ROOT/client"
cd "$MACUS_TEST_ROOT/src"
macus --json runtime status
curl --fail-with-body --silent --show-error --max-time 1200 \
  --unix-socket "$MACUS_STATE_DIR/runtime.sock" \
  -H 'Content-Type: application/json' \
  --data-binary "@$MACUS_TEST_ROOT/appliance/config.json" \
  http://localhost/v1/runtime/create
macus --json runtime status
```

Status should initially be `absent`, then `stopped` after creation. Macus currently has no CLI `init` or `runtime create` command; creating the appliance uses the [existing control API](docs/api.md). `serve` exposes the sockets but does not boot the VM. Creation stages the verified writable root and persistent data disk.

### 5. Boot and verify readiness

In terminal B:

```sh
macus runtime start
macus --json runtime status
macus doctor
```

First boot installs guest packages, prepares fresh ZFS storage and initializes Incus. The expected result is `state: ready` and a successful doctor report with live guest health. Host capabilities alone do not establish Incus readiness.

The pinned cloud image may need the qualified ZFS kernel update. If the first start reports that the guest exited before Incus became ready, inspect:

```sh
tail -n 100 "$MACUS_STATE_DIR/serial.log"
macus --json runtime status
```

If the log contains `TAMA_ZFS_KERNEL_REBOOT_REQUIRED` and the guest has stopped, run `macus runtime start` again, then repeat status and doctor. The next boot continues provisioning. Do not recreate or delete the runtime for this expected update. If `TAMA_ZFS_QUALIFIED_REVISION_UNAVAILABLE` appears, or another error occurs, preserve the state and log and consult [recovery and safety](docs/development.md#recovery-and-safety); do not substitute unqualified packages or format the data disk.

### 6. Set up Incus and run a workload

```sh
macus client setup --remote macus-fresh
incus info macus-fresh:
incus storage show macus-fresh:default
incus profile show macus-fresh:default
incus launch images:debian/13 macus-fresh:smoke -c boot.autostart=true
incus exec macus-fresh:smoke -- uname -m
incus exec macus-fresh:smoke -- sh -c 'printf "macus-ok\n" > /root/macus-proof'
incus exec macus-fresh:smoke -- getent hosts deb.debian.org
```

Setup reuses `incus` on PATH or installs the [official Homebrew Incus formula](https://formulae.brew.sh/formula/incus) if Homebrew is available. To exercise that installation branch, start with no Incus executable on PATH. It does not install Homebrew. If setup succeeds but `incus` is not on PATH, add `$(brew --prefix incus)/bin` to PATH before the remaining commands. `INCUS_CONF` keeps this test's remote registrations separate, and omitting `--set-default` preserves the default remote.

Check that Incus reports a responding Linux server, the fresh default storage driver is `zfs`, and the default profile points its root disk at that pool. The container should run, report ARM64 architecture and resolve the Debian mirror. `exec` exercises the standard Incus WebSocket transport through the Unix/vsock relay.

### 7. Verify persistence and stop cleanly

```sh
macus runtime restart
incus list macus-fresh:
incus exec macus-fresh:smoke -- cat /root/macus-proof
macus runtime stop
macus --json runtime status
```

After restart, wait for `smoke` to show `RUNNING` before reading the file; it should still contain `macus-ok`. After stop, status should be `stopped`. In terminal A, press Ctrl-C to exit the daemon. Run `macus serve` again with the same environment, then in terminal B:

```sh
macus --json runtime status
macus runtime start
macus doctor
incus list macus-fresh:
incus exec macus-fresh:smoke -- cat /root/macus-proof
```

The restarted daemon should load the existing appliance as `stopped`; the subsequent start should preserve the same workload and file. To finish a successful test, remove only the test container and stop the runtime:

```sh
incus delete macus-fresh:smoke --force
macus runtime stop
```

Press Ctrl-C in terminal A. Keep the test root for inspection; use a new root for the next fresh-install run. Preserve workloads and logs if any check fails. For optional launchd installation after the foreground flow passes, see [packaging](Packaging/README.md).

This walkthrough verifies installation, readiness, a system container, DNS resolution and restart persistence. OCI, nested VMs, storage growth and VirtioFS require the separate [hardware acceptance procedure](docs/development.md#integration-acceptance). Passing build/unit checks is not hardware acceptance.

## Development checks and references

From an existing source checkout, the canonical checks are:

```sh
Integration/scripts/check.sh
mise trust
mise install node npm:@fission-ai/openspec
mise run spec:validate
```

`mise trust` and tool installation are one-time setup. See [development setup](docs/development.md) for selecting Xcode, native formatting and debug builds.

- [Prepare an appliance and run hardware acceptance](docs/development.md)
- [Macus CLI](docs/cli.md)
- [Runtime API and tama-machine contract](docs/api.md)
- [Architecture and scope](docs/architecture.md)
- [Per-user launchd packaging](Packaging/README.md)
- [OpenSpec design and decisions](openspec/changes/archive/2026-10-04-native-incus-runtime/design.md)
- [Implementation and acceptance checklist](openspec/changes/archive/2026-10-04-native-incus-runtime/tasks.md)
- [Git Flow development workflow](docs/development.md#git-flow)

`macus start` acquires the pinned appliance. Automatic root-image upgrades, production signed/notarized releases, service forwarding and custom DNS remain future work.

## Macus naming and compatibility

`macus` replaces both `tama-incus-mac` and `tim`: use `macus serve`, `macus capabilities`, `macus runtime status`, `macus doctor` and `macus client setup`. The Swift module is `Macus`. New client registrations default to remote name `macus`; pass `--remote tama-mac` to reuse an existing registration.

The default state directory remains `~/.tama/incus-mac` to preserve existing appliances. Both serving and client commands accept `MACUS_STATE_DIR`, with legacy `TIM_STATE_DIR` as fallback; an explicit `--state-dir` takes precedence. Persistent guest/service/storage identifiers also remain compatible. Historical acceptance reports retain the names of the binaries they tested.
