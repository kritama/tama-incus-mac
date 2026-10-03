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

## Prepare a Debian appliance

Obtain the official **Debian 13 generic ARM64 raw image** from [Debian's cloud image catalog](https://cloud.debian.org/images/cloud/trixie/). Verify the archive against Debian's published SHA512SUMS using a trusted catalog/release input, then extract `disk.raw` using the system `tar`. Use a versioned image URL for repeatability. Do not use qcow2: VZ attaches raw images directly. The image preparation tool takes a local raw image and uses only Python's standard library and macOS hdiutil; it does not run a VM.

```sh
mkdir -p .integration/appliance
python3 Integration/scripts/prepare-appliance.py \
  --root-disk /absolute/debian/disk.raw --output .integration/appliance
.build/debug/tama-incus-mac serve --state-dir "$PWD/.integration/state"
```

In another terminal, create/start using `docs/api.md` and `.integration/appliance/config.json`. The seed installs Incus from Zabbly's apt-signed stable Debian repository, required dependencies and a host-only vsock helper. The first boot requires internet and can take several minutes. It disables SSH, contains no development tools, desktop, Docker or Kubernetes, and uses systemd to mount the data disk before Incus. A pre-provisioned appliance can omit `seed_path` (JSON null) while keeping the same manifest and vsock contract.

The generated manifest records schema 1, appliance ID, arm64, raw filename, SHA-256 and vsock protocol 1. The host verifies the hash before copying; root filenames cannot leave the manifest directory. ISO/config/manifest inputs remain external; service-owned writable disks are under `<state-dir>/runtime`. Reusing a prepared output with a different raw image is refused.

## Integration acceptance

Install a standard native Incus client separately, or point `--incus` at a verified local binary. The runtime has no client dependency. Run the acceptance script against a dedicated created/ready state directory; it creates uniquely named test workloads and removes them on success. It exercises Incus container and OCI boot, exec/WebSocket, outbound networking, persistence across outer restart, offline growth, explicit shares, and nested VM boot where live capabilities permit. Preserve logs/report on failure.

```sh
python3 Integration/scripts/acceptance.py \
  --state-dir "$PWD/.integration/state" --incus /absolute/path/to/incus \
  --report .integration/acceptance.json
```

Unit tests never silently boot VMs. CI-ready commands are in `Integration/scripts/check.sh`; a self-hosted macOS ARM64 runner with Swift 6.4 is needed for opt-in hardware jobs. Run shell syntax/Python checks in addition to Swift checks. Guest systemd unit validation runs during live acceptance.

## Recovery and safety

Keep the state directory private (0700) and sockets/config private (0600). The daemon holds a nonblocking process lock; a second process cannot replace its sockets. Custom symlink roots/endpoints are rejected, while macOS's standard /var and /tmp ancestor aliases are recognized. Darwin limits Unix socket paths to 103 bytes; use a short state path.

After daemon crash, durable configuration is loaded as stopped; readiness is never reused. A boot failure retains disks and a private `serial.log`; inspect it before stopping/retrying. A graceful stop timeout leaves the running guest intact, allowing an explicit forced stop. Do not shrink or replace a live disk. Disk growth and configuration must occur while stopped; rerunning boot grows ext4. A partial create retains its disks for explicit recovery/reset rather than erasing potential data. Reset with DELETE and `confirm=true` only after stopping. It destroys all appliance Incus data.

Do not replace root disks in place to upgrade Incus. A future upgrade protocol must back up data, validate guest/helper/Incus schema compatibility, and provide rollback. Local FileVault and account permissions are the v1 host security basis; no Secure Boot/TPM requirement is imposed.
