# Development and appliance preparation

Requires Apple Silicon, macOS 15+, Xcode/Swift 6.4. `swift build`, `swift test`, release builds and `swift format` are the native development workflow; no Xcode project, SwiftLint, external web framework or VM runtime is required. Hardware acceptance is opt-in and separate from unit tests.

## OpenSpec with mise

Install [mise](https://mise.jdx.dev/getting-started.html), then run these commands from the repository root:

```sh
mise trust
mise install node npm:@fission-ai/openspec
mise exec -- openspec --version
mise run spec:validate
```

`mise.toml` pins Node.js 26.10.0 and OpenSpec 1.14.0. OpenSpec is installed through mise's npm backend independently of any global npm installation. CI also pins OpenSpec 1.14.0.

Use `mise exec -- openspec ...` for planning and implementation commands, including in agent sessions and shells without mise activation:

```sh
mise exec -- openspec list
mise exec -- openspec status --change rename-to-macus --json
mise exec -- openspec instructions apply --change rename-to-macus --json
mise exec -- openspec validate --all --strict --no-interactive
```

The status and apply examples target the current `rename-to-macus` change; substitute the active change name for later work.

The canonical checks remain:

```sh
Integration/scripts/check.sh
mise run spec:validate
```

Swift and native swift-format come from the selected Xcode toolchain. Hardware acceptance remains explicit and opt-in, uses isolated state directories, and is recorded separately from these checks.

## Build and sign

```sh
swift build -Xswiftc -warnings-as-errors
swift test --no-parallel -Xswiftc -warnings-as-errors
swift build -c release -Xswiftc -warnings-as-errors
swift format format --in-place --recursive Package.swift Sources Tests
swift format lint --strict --recursive Package.swift Sources Tests
codesign --force --sign - --entitlements Packaging/virtualization.entitlements .build/debug/macus
.build/debug/macus capabilities
.build/debug/macus --help
```

VZ requires `com.apple.security.virtualization` on the daemon executable. Development signing is ad hoc. Production signing/notarization is a future release task. Apple APIs detect unsupported hardware/policy; nested support is never inferred from the model name.

## Macus command

`macus` is the single command built by this SwiftPM package. `serve` runs the foreground daemon; runtime commands control the outer VM and client setup configures the standard Incus CLI. Workload commands belong to `incus`. Invocation and transport limits are in [the CLI reference](cli.md).

Local source installation requires Swift. It builds the release executable, ad-hoc signs and verifies it, then installs it:

```sh
Packaging/install-local.sh --prefix /absolute/isolated/prefix
```

The unified executable receives the virtualization entitlement for serve mode. The command does not create runtime state or install a launch agent. Ad-hoc development signatures are not notarized production artifacts. A future release package or formula must include macus and real checksums; none is published here.

## Git Flow

The long-lived branches are `main` for released history and `develop` for integration. The initial implementation lives on `feature/native-incus-runtime`; `main` and `develop` begin at the SwiftPM bootstrap commit. Publishing the feature branch does not finish the feature or mark hardware acceptance complete.

Create `feature/<name>` from `develop` and merge completed, validated features back into `develop`. Create `release/<version>` from `develop`; finish the validated release into both `main` and `develop` and tag it on `main`. Create urgent `hotfix/<name>` branches from `main` and finish them into both long-lived branches. Branch publication and finishing are separate actions; release readiness requires the acceptance evidence in OpenSpec.

Use normal Git commands or a Git Flow client with these branch names. Local `gitflow.*` configuration records `main`, `develop`, `feature/`, `release/`, `hotfix/` and `support/`; the repository does not require a Git Flow CLI.

## Alpine appliance preparation

The pinned base is **Alpine 3.24.2 aarch64 cloud-init metal r0**, which includes ARM64 EFI and the Linux kernel/modules needed by VZ and Incus. Download the official raw archive, SHA-512 file and detached signature, plus the signing key linked from [Alpine's cloud image page](https://alpinelinux.org/cloud/). GnuPG is a preparation dependency; runtime operation needs no GnuPG or host VM tool.

```sh
mkdir -p .integration/cache
base=https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/cloud
image=alpine-3.24.2-aarch64-cloudinit-metal-r0.raw.tar.gz
curl -fL "$base/$image" -o ".integration/cache/$image"
curl -fL "$base/$image.sha512" -o ".integration/cache/$image.sha512"
curl -fL "$base/$image.asc" -o ".integration/cache/$image.asc"
curl -fL https://alpinelinux.org/keys/tomalok.asc -o .integration/cache/tomalok.asc
python3 Integration/scripts/verify-appliance.py \
  --archive ".integration/cache/$image" \
  --checksum-file ".integration/cache/$image.sha512" \
  --signature ".integration/cache/$image.asc" \
  --signing-key .integration/cache/tomalok.asc \
  --output .integration/cache/verified-alpine
python3 Integration/scripts/prepare-appliance.py \
  --root-disk .integration/cache/verified-alpine/disk.raw \
  --output .integration/appliance --appliance-id alpine-3.24.2-incus-v1
.build/debug/macus serve --state-dir "$PWD/.integration/state"
```

Verification uses an isolated GnuPG keyring and pins the official cloud signer fingerprint `F26ADFADBAE702EF7AF637459DA7EF23BFFCDF22`. It refuses checksum/signature mismatches, unexpected archive members and replacement of a different existing raw image. Preparation records archive provenance and the raw SHA-256 in the manifest, and uses macOS `hdiutil` for the NoCloud ISO. Output and source must be on the same volume for the immutable raw hard link. No qcow conversion is used.

`macus start` uses the same pinned archive through the shipped catalog in `Integration/catalog/alpine-3.24.2.json`. Refresh that catalog only after the signature command above succeeds, then record the measured archive size, raw size and digests. Do not invent checksums or trust a checksum downloaded beside the image by itself. Embedded guest scripts come from `Integration/guest`:

```sh
python3 Integration/scripts/sync-guest-payload.py --check
python3 Integration/scripts/check-catalog.py
```

Neither command creates state or boots a VM. A partial download or corrupt cache is discarded or moved aside and rehashed before reuse. It is not booted. Runtime disks are not replaced to recover a bad cache.

In another terminal, create/start through the [control API](api.md) using `.integration/appliance/config.json`. First boot waits for IPv4 DHCP, installs maintained Incus LTS (at least 7.0.1), its OpenRC/VM packages and explicit OCI dependencies from the signed Alpine v3.24 main/community repositories, initializes persistent storage and starts OpenRC services. The helper waits for Incus startup cleanup/autostart readiness on every boot; responding to `/1.0` alone is insufficient. CA installation uses the official HTTP repository with normal APK signature verification before switching all remaining package operations to HTTPS. There are no edge repositories or unsigned-package exceptions. New appliances set `images.auto_update_interval=0`; image refreshes remain explicit standard Incus operations while the selected LTS shutdown/cache behavior is verified. Existing Incus configurations are preserved. Resolved packages are recorded in `/var/log/tama-appliance-packages.txt` and private host `serial.log`. Incus manages QEMU/KVM inside Linux; the Mac invokes no VM CLI. SSH is disabled.

Use a new appliance ID and a new state directory when changing the base image. Existing root/data disks are preserved; there is no automatic Debian-to-Alpine migration. A pre-provisioned appliance can omit `seed_path` (JSON null) while retaining the manifest/vsock contract. The host verifies the source and staged raw SHA-256 before boot; writable root/data disks live under `<state-dir>/runtime`.

## Start acceptance runner

`Integration/scripts/start-acceptance.py` is opt-in and does not boot hardware unless `--hardware` is passed. Its `--report` path is validated before any directory creation or executable invocation. A report inside the state directory, installation prefix, ordinary Incus configuration, or a symlink is refused so runtime disks and configuration cannot be overwritten by the report. Put the report in a separate directory.

## Integration acceptance

Install a standard native Incus client separately, or point `--incus` at a verified local binary. The runtime has no client dependency. The runner configures a standard `unix:` remote in an isolated client directory, because macOS clients have no implicit local server. It creates uniquely named workloads/remotes and removes workloads on success; failures preserve instances and diagnostics.

Configure dedicated read-only and writable share fixtures before creating the test runtime. Use only disposable directories: the runner writes uniquely named files and removes those files afterward. For example, create `.integration/share-fixtures/readonly` and `writable`, allow the privileged test container to access them with mode 0777, and add these entries to the prepared configuration using absolute paths:

```json
"shares": [
  {"name": "readonly", "path": "/absolute/project/.integration/share-fixtures/readonly", "read_only": true},
  {"name": "writable", "path": "/absolute/project/.integration/share-fixtures/writable", "read_only": false}
]
```

The ready-runtime test exercises an ordinary unprivileged system container, versioned `docker.io/library/alpine:3.23` OCI boot, exec/WebSocket, outbound networking, persistence across an outer restart, stopped-state disk growth verified inside the guest, cached OCI image reuse after restart, and nested VM guest-agent execution where supported. The nested VM explicitly disables Secure Boot because the selected Alpine ARM64 firmware provides the unsigned AAVMF pair, consistent with the v1 scope. A separate privileged container verifies the underlying VZ read-only and writable shares through standard Incus disk devices; this isolates share semantics from unprivileged UID mapping. Configure shares explicitly; no home directory is exposed by default.

```sh
python3 Integration/scripts/acceptance.py \
  --state-dir "$PWD/.integration/state" --incus /absolute/path/to/incus \
  --report .integration/zfs-acceptance.json
```

The opt-in idle-stream regression holds 80 incomplete Incus requests open while probing control status, guest health and normal Incus API requests. Run it against an already ready isolated runtime before workload acceptance:

```sh
python3 Integration/scripts/relay-stress.py \
  --state-dir "$PWD/.integration/state" --report .integration/relay-stress.json
```

Host relays use nonblocking readiness notifications with at most 64 KiB buffered per direction. A fatal listener failure exits the entire guest helper so OpenRC can restart it; transient accept failures retry. Guest health becomes available only after the relay listener starts.

Swift tests run with explicit `--no-parallel` so unrelated subprocess fixture startup does not consume another test's short deadline on CI. Concurrency and cancellation tests still launch their own concurrent work and keep their original timing assertions.

Unit tests never boot VMs. `Integration/scripts/check.sh` runs debug/release builds, Swift tests, strict formatting, shell syntax, Python compilation and guest-listener regression tests. GitHub Actions runs these and pinned OpenSpec strict validation on the `xcode-27` macOS ARM64 runner. Hardware acceptance stays opt-in on a physical supported Mac with the virtualization entitlement; hosted CI success does not establish hardware acceptance.

## ZFS qualification

Fresh appliances provision ZFS when the data disk is blank, the data disk is at least 4 GiB, and guest MemTotal is at least 3670016 KiB. The hardware-qualified host configuration is 4096 MiB RAM. The guest check does not reject every host configuration below 4096 MiB. The qualified package pair is Alpine v3.24 `linux-lts`/`zfs-lts` 6.18.55-r0 and ZFS 2.4.4-r0. Bootstrap registers `tama-bootstrap` before a kernel mismatch powers off, so the next boot continues without another cloud-init runcmd. The current boot also emits `MACUS_OBSERVATION v1 stage=kernel_transition state=expected_reboot`. `macus start` and a compatible daemon consume one durable allowance and restart that runtime within the remaining deadline. A stale log line, a second request, or a daemon restart does not replenish the allowance. If automatic recovery fails, inspect `serial.log` and run `macus runtime start` again. Do not delete the runtime for this expected update. The first EFI kernel update removes unused `/boot/dtbs-lts` because the cloud image's EFI partition otherwise lacks staging space. A label alone is not a recognized ext4 appliance; repair and writable mount happen only after a read-only `noload` inspection finds the Incus layout. The appliance does not change Incus-owned workload datasets. Workload reservations are requested through Incus pool configuration. Filesystem creation-time reservations are hardware-measured; zvol refreservation remains none. Mixed workloads were measured on 8–11 GiB data disks, not at the 4 GiB guest floor. A storage failure is logged in `/var/log/tama-storage.log` and readiness stays withheld; do not format or replace the disk to clear it. See the [qualification results](zfs-qualification.md).

## Recovery and safety

Keep the state directory private (0700) and sockets/config private (0600). The daemon holds a nonblocking process lock; a second process cannot replace its sockets. Custom symlink roots/endpoints are rejected, while macOS's standard /var and /tmp ancestor aliases are recognized. Darwin limits Unix socket paths to 103 bytes; use a short state path.

After daemon crash, durable configuration is loaded as stopped; readiness is never reused. A boot failure retains disks and a private `serial.log`; inspect it before stopping/retrying. A graceful stop timeout leaves the running guest intact, allowing an explicit forced stop. Do not shrink or replace a live disk. Disk growth and configuration must occur while stopped. The next boot grows a recognized ext4 filesystem or expands the owned ZFS vdev with `zpool online -e`; it does not recreate the pool. A partial create retains its disks for explicit recovery/reset rather than erasing potential data. Reset with DELETE and `confirm=true` only after stopping. It destroys all appliance Incus data. Confirmed reset records durable intent before removing files; restart completes interrupted cleanup. Invalid intent or unmarked incomplete state is preserved for explicit recovery.

Guest initialization records persistent pending/started markers on a newly formatted data disk. A failure before preseed begins can retry on reboot. If preseed starts and fails or is interrupted, provisioning refuses to replay it automatically; preserve the disk and inspect diagnostics before explicit recovery/reset. Reused disks without pending initialization keep their existing Incus configuration, including custom pool names.

Do not replace root disks in place to upgrade Incus. A future upgrade protocol must back up data, validate guest/helper/Incus schema compatibility, and provide rollback. Local FileVault and account permissions are the v1 host security basis; no Secure Boot/TPM requirement is imposed.
