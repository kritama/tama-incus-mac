# Development and appliance preparation

Requires Apple Silicon, macOS 15+, Xcode/Swift 6.4. `swift build`, `swift test`, release builds and `swift format` are the native development workflow; no Xcode project, SwiftLint, external web framework or VM runtime is required. Hardware acceptance is opt-in and separate from unit tests.

## Build and sign

```sh
swift build -Xswiftc -warnings-as-errors
swift test -Xswiftc -warnings-as-errors
swift build -c release -Xswiftc -warnings-as-errors
swift format format --in-place --recursive Package.swift Sources Tests
swift format lint --strict --recursive Package.swift Sources Tests
codesign --force --sign - --entitlements Packaging/virtualization.entitlements .build/debug/tama-incus-mac
.build/debug/tama-incus-mac capabilities
```

VZ requires `com.apple.security.virtualization` on the executable. Development signing is ad hoc. Production signing/notarization is a future release task. Apple APIs detect unsupported hardware/policy; nested support is never inferred from the model name.

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
.build/debug/tama-incus-mac serve --state-dir "$PWD/.integration/state"
```

Verification uses an isolated GnuPG keyring and pins the official cloud signer fingerprint `F26ADFADBAE702EF7AF637459DA7EF23BFFCDF22`. It refuses checksum/signature mismatches, unexpected archive members and replacement of a different existing raw image. Preparation records archive provenance and the raw SHA-256 in the manifest, and uses macOS `hdiutil` for the NoCloud ISO. Output and source must be on the same volume for the immutable raw hard link. No qcow conversion is used.

In another terminal, create/start through the [control API](api.md) using `.integration/appliance/config.json`. First boot waits for IPv4 DHCP, installs maintained Incus LTS (at least 7.0.1), its OpenRC/VM packages and explicit OCI dependencies from the signed Alpine v3.24 main/community repositories, initializes persistent storage and starts OpenRC services. The helper waits for Incus startup cleanup/autostart readiness on every boot; responding to `/1.0` alone is insufficient. CA installation uses the official HTTP repository with normal APK signature verification before switching all remaining package operations to HTTPS. There are no edge repositories or unsigned-package exceptions. Resolved packages are recorded in `/var/log/tama-appliance-packages.txt` and private host `serial.log`. Incus manages QEMU/KVM inside Linux; the Mac invokes no VM CLI. SSH is disabled.

Use a new appliance ID and a new state directory when changing the base image. Existing root/data disks are preserved; there is no automatic Debian-to-Alpine migration. A pre-provisioned appliance can omit `seed_path` (JSON null) while retaining the manifest/vsock contract. The host verifies the source and staged raw SHA-256 before boot; writable root/data disks live under `<state-dir>/runtime`.

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
  --report .integration/acceptance.json
```

Unit tests never boot VMs. `Integration/scripts/check.sh` runs debug/release builds, Swift tests, strict formatting, shell syntax and Python compilation. GitHub Actions runs these and pinned OpenSpec strict validation on the `xcode-27` macOS ARM64 runner. Hardware acceptance stays opt-in on a physical supported Mac with the virtualization entitlement; hosted CI success does not establish hardware acceptance.

## Recovery and safety

Keep the state directory private (0700) and sockets/config private (0600). The daemon holds a nonblocking process lock; a second process cannot replace its sockets. Custom symlink roots/endpoints are rejected, while macOS's standard /var and /tmp ancestor aliases are recognized. Darwin limits Unix socket paths to 103 bytes; use a short state path.

After daemon crash, durable configuration is loaded as stopped; readiness is never reused. A boot failure retains disks and a private `serial.log`; inspect it before stopping/retrying. A graceful stop timeout leaves the running guest intact, allowing an explicit forced stop. Do not shrink or replace a live disk. Disk growth and configuration must occur while stopped; rerunning boot grows ext4. A partial create retains its disks for explicit recovery/reset rather than erasing potential data. Reset with DELETE and `confirm=true` only after stopping. It destroys all appliance Incus data.

Guest initialization records persistent pending/started markers on a newly formatted data disk. A failure before preseed begins can retry on reboot. If preseed starts and fails or is interrupted, provisioning refuses to replay it automatically; preserve the disk and inspect diagnostics before explicit recovery/reset. Reused disks without pending initialization keep their existing Incus configuration, including custom pool names.

Do not replace root disks in place to upgrade Incus. A future upgrade protocol must back up data, validate guest/helper/Incus schema compatibility, and provide rollback. Local FileVault and account permissions are the v1 host security basis; no Secure Boot/TPM requirement is imposed.
