# Architecture

```text
macOS tama-machine
  ├─ Unix HTTP runtime.sock → runtime actor → main-actor VZ controller
  └─ Unix stream incus.sock → duplex relay → VZ virtio socket
                                              ↓ host CID 2 only
                                       Alpine appliance (OpenRC)
                                         ├─ Incus Unix socket (vsock 8443)
                                         ├─ read-only health (vsock 8444)
                                         ├─ persistent ext4 /var/lib/incus
                                         └─ Incus workloads and portable artifacts
```

SwiftPM has one library and one executable. `Application` owns state and orchestration for the outer VM; `Virtualization` is the only area importing Apple's VZ framework. A protocol at that boundary permits deterministic tests. Configuration/status are Sendable value types. The runtime actor holds a mutation gate across awaits, so reentrancy cannot delete or reconfigure a starting machine. VZ objects remain on the main actor and its default main dispatch queue; blocking socket I/O runs on a concurrent GCD queue with immutable descriptor ownership. Stream relays use bounded buffers and preserve half-close and protocol upgrades.

EFI boots an ARM64 raw root disk. Alpine uses OpenRC/cloud-init and signed stable-branch APK packages. Storage mounts before Incus, and the host-CID-only helper starts after successful initialization. D-Bus, nftables, cgroup v2 and ARM64 QEMU/firmware are explicit guest dependencies. Virtio devices provide block storage, NAT, socket, entropy and explicit optional filesystem shares. Root is copied and expanded to at least 12 GiB. Incus state resides on a separate ext4 disk (32 GiB default) using Incus directory storage. Existing ext4 is checked/grown; a truly blank disk is initialized; unknown nonblank data is refused.

VZ host capability detection controls nested virtualization. Live guest evidence controls Incus readiness, OCI (`instance_oci` extension) and VM (`/dev/kvm` plus enabled host nesting) availability. Incus itself owns inner QEMU/KVM, LXC, images, instances, storage, network bridges, profiles and migrations. The macOS process invokes no VM CLI. The guest helper has no shell-command endpoint.

The detailed decisions, rejected alternatives, normative requirements and recorded acceptance tasks are in [the OpenSpec change](../openspec/changes/archive/2026-10-04-native-incus-runtime/design.md). Future work includes prebuilt signed appliance catalogs/downloads, transactional root upgrades, signed/notarized distribution, service forwarding, custom DNS, memory ballooning and sleep/resume policy. These features do not replace Incus workload operations.
