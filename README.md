# tama-incus-mac

A headless macOS compatibility layer that boots a Linux Incus host using Apple's **Virtualization.framework directly**. Tama uses native Incus on Linux and this appliance on macOS; Incus remains the workload API and portable artifact layer.

Requires Apple Silicon, macOS 15+ and Swift 6.4. One SwiftPM library and one small executable; no third-party Swift dependencies or host VM runtime.

**Development status:** The native host service builds and passes unit tests. The specified appliance OS is Alpine Linux with OpenRC and signed APK packages; guest scripts currently remain a Debian prototype pending migration. Incus readiness and workload hardware acceptance have not passed. This initial implementation is suitable for development review; it is not a completed usable Incus host.

```sh
swift build -Xswiftc -warnings-as-errors
swift test -Xswiftc -warnings-as-errors
swift build -c release -Xswiftc -warnings-as-errors
swift format format --in-place --recursive Package.swift Sources Tests
swift format lint --strict --recursive Package.swift Sources Tests
codesign --force --sign - --entitlements Packaging/virtualization.entitlements .build/debug/tama-incus-mac
.build/debug/tama-incus-mac capabilities
.build/debug/tama-incus-mac serve
```

The service exposes `~/.tama/incus-mac/runtime.sock` for outer VM lifecycle and `~/.tama/incus-mac/incus.sock` for transparent Incus traffic over vsock. It uses EFI/raw disks, a separate persistent Incus disk, native NAT, explicit VirtioFS shares, dynamic nesting detection and live guest health. Normal use needs no GUI or SSH. Instance/image/profile/project/network/storage/migration operations belong to Incus.

- [Prepare an appliance and run hardware acceptance](docs/development.md)
- [Runtime API and tama-machine contract](docs/api.md)
- [Architecture and scope](docs/architecture.md)
- [Per-user launchd packaging](Packaging/README.md)
- [OpenSpec design and decisions](openspec/changes/native-incus-runtime/design.md)
- [Implementation and acceptance checklist](openspec/changes/native-incus-runtime/tasks.md)
- [Git Flow development workflow](docs/development.md#git-flow)

Unit tests and hardware acceptance are separate. See [the acceptance record](docs/acceptance.md) for results and remaining limitations. Automatic appliance downloads/upgrades, production signed/notarized releases, service forwarding and custom DNS are future work. The existing prototype preparation script uses a verified local Debian raw image and internet package installation; Alpine preparation is tracked in OpenSpec.
