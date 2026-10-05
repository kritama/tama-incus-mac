# tama-incus-mac

A headless macOS compatibility layer that boots a Linux Incus host using Apple's **Virtualization.framework directly**. Tama uses native Incus on Linux and this appliance on macOS; Incus remains the workload API and portable artifact layer.

Requires Apple Silicon, macOS 15+ and Swift 6.4. One SwiftPM library, a minimal `tama-incus-mac` daemon and a thin `tim` client in this same package; no third-party Swift dependencies, separate client repository or host VM runtime.

**Development status:** The native host service builds and passes unit tests. The appliance uses Alpine Linux with OpenRC and signed APK packages. Hardware acceptance results and distribution limitations are recorded in [the acceptance record](docs/acceptance.md).

```sh
swift build -Xswiftc -warnings-as-errors
swift test -Xswiftc -warnings-as-errors
swift build -c release -Xswiftc -warnings-as-errors
swift format format --in-place --recursive Package.swift Sources Tests
swift format lint --strict --recursive Package.swift Sources Tests
codesign --force --sign - --entitlements Packaging/virtualization.entitlements .build/debug/tama-incus-mac
.build/debug/tama-incus-mac capabilities
.build/debug/tama-incus-mac serve
.build/debug/tim --help
```

The service exposes `~/.tama/incus-mac/runtime.sock` for outer VM lifecycle and `~/.tama/incus-mac/incus.sock` for transparent Incus traffic over vsock. It uses EFI/raw disks, a separate persistent Incus disk, native NAT, explicit VirtioFS shares, dynamic nesting detection and live guest health. Normal use needs no GUI or SSH. Instance/image/profile/project/network/storage/migration operations belong to Incus.

- [Prepare an appliance and run hardware acceptance](docs/development.md)
- [tim CLI](docs/cli.md)
- [Runtime API and tama-machine contract](docs/api.md)
- [Architecture and scope](docs/architecture.md)
- [Per-user launchd packaging](Packaging/README.md)
- [OpenSpec design and decisions](openspec/changes/archive/2026-10-04-native-incus-runtime/design.md)
- [Implementation and acceptance checklist](openspec/changes/archive/2026-10-04-native-incus-runtime/tasks.md)
- [Git Flow development workflow](docs/development.md#git-flow)

Unit tests and hardware acceptance are separate. Automatic appliance downloads/upgrades, production signed/notarized releases, service forwarding and custom DNS are future work. Appliance preparation verifies the official Alpine raw archive and creates a NoCloud seed; initial provisioning requires internet access.
