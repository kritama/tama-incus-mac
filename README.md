# tama-incus-mac

A headless macOS compatibility layer that boots a Linux Incus host using Apple's **Virtualization.framework directly**. Tama uses native Incus on Linux and this appliance on macOS; Incus remains the workload API and portable artifact layer.

Requires Apple Silicon, macOS 15+ and Swift 6.4. One SwiftPM library and one small executable; no third-party Swift dependencies or host VM runtime.

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

Unit tests and hardware acceptance are separate. See docs/acceptance.md for the recorded results and remaining limitations. Automatic appliance downloads/upgrades, production signed/notarized releases, service forwarding and custom DNS are future work. The initial development appliance is prepared from a verified local Debian raw image; first boot installs signed Incus packages and requires internet.
