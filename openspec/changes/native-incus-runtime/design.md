# Design

## Context

See proposal.md for the motivation. Phase 0 was initialized with SwiftPM and verified with Swift 6.4. The installed SDK exposes nested virtualization at macOS 15. The target is Apple Silicon and headless per-user operation. Incus local Unix access is privileged, so bridge possession is equivalent to control of the Linux appliance.

## Goals / Non-Goals

**Goals:** One outer VM, durable Incus data, truthful readiness, transparent local transport and native VZ execution. Keep Apple objects isolated on the main actor (the VZ default main dispatch queue); keep blocking stream I/O off that actor.

**Non-Goals:** GUI, cross-platform layer, Incus wrappers, custom hypervisor/network stack, workload orchestration or migration implementation. QEMU is allowed only inside Linux as an Incus dependency, never as the host runtime.

## Decisions

1. **SwiftPM, Swift 6 language mode, macOS 15 minimum.** One library/executable, Swift Testing, native swift-format and no SwiftLint or web framework. macOS 15 is the first nested VZ release; older systems add branches without helping this product. An Xcode project adds no required functionality.
2. **Main-actor VZ adapter and actor runtime service.** VZ lifecycle and connection ownership stay on its required queue. Actor state models explicit transitions. A mutation gate remains held across await points to prevent reentrant start/delete/config races. Value configurations and status are Sendable/Codable; one VM protocol enables fake lifecycle tests.
3. **Debian 13 generic ARM64 EFI raw disk.** Use the maintained general kernel image (broader KVM/VirtioFS support than a cloud-only kernel), systemd and cloud-init NoCloud seed. Incus stable packages come from an apt-signed Zabbly repository; its key is obtained through HTTPS. Avoid IncusOS Secure Boot/TPM requirements and a custom OS builder. Raw disks eliminate a host qcow conversion/runtime dependency. A provisioning script makes an ISO using macOS hdiutil; it is an image tool, not a VM runtime. A production prebuilt appliance can use the same manifest contract.
4. **External immutable source, service-owned writable root, separate sparse ext4 data disk.** Verify streaming SHA-256 before copying. Root is at least 12 GiB for first-boot package installation. Data is mounted at /var/lib/incus before any Incus socket/service starts; a blank disk can be formatted, an ext4 disk reused, unknown data refused. ext4 dir storage is the simplest initial portable option; Incus retains ownership of storage pools. Grow raw data offline, resize2fs on next boot; never shrink.
5. **Two Unix sockets and two vsock ports.** runtime.sock serves bounded HTTP/1.1 control. incus.sock is a byte-stream proxy to guest port 8443, which connects /var/lib/incus/unix.socket; port 8444 serves read-only health and guest KVM evidence. The helper restricts peers to host CID 2. No SSH, TLS translation, path prefix, LAN listener or Incus operation mapping. Preserve WebSocket upgrades and half-close using duplex bounded-buffer pumps. Same-user access is intentional and fully privileged in the guest.
6. **NAT and Incus bridge.** VZNATNetworkDeviceAttachment plus Incus-managed IPv4/IPv6 bridge gives outbound connectivity. Forwarding services to the Mac and custom DNS are future work, avoiding a second networking control plane.
7. **Capability evidence in layers.** VZ reports host support; configuration enables nesting only when allowed. Guest health reports usable /dev/kvm and live Incus version/extensions. Container capability follows readiness, OCI checks `container_oci`, VM requires all nesting/KVM/readiness conditions. Never infer support from chip names.
8. **Opt-in VirtioFS.** Share configured named directories read-only by default through one VZ multi-directory share, mounted by guest bootstrap. Users apply standard Incus disk devices from those guest paths. No automatic home exposure.
9. **Per-user service and private state.** Default ~/.tama/incus-mac; use a short state path if the Darwin Unix socket 104-byte limit is exceeded. Hold an advisory lock for process lifetime. Private directory/file modes, peer UID checks, reject symlink state roots/sockets and avoid deleting anything outside known runtime files. A launchd template is user opt-in; do not install it while developing.
10. **Bounded synchronous control responses.** Start waits for readiness (default 600 seconds on initial provisioning, configurable upper bound); independent status reads remain possible. Stop waits 60 seconds by default, explicit force is separate. One request per connection, bounded HTTP headers/body and connection count. Errors expose stable codes; destructive delete requires {"confirm":true}.
11. **Recovery and upgrades.** Do not trust saved running state after daemon restart. Root/data remain durable; unexpected VM exit invalidates health. Retain diagnostics and data on boot failures. Recover by force stop and start after fixing inputs. Future root swap requires a backup, Incus version/schema compatibility check and rollback strategy; no automatic downgrade or schema migration in v1.

## API contract

All control responses encode snake_case JSON. Status contains `api_version:1`, `state`, `incus_socket`, `last_error`, `uptime_seconds`. Error: {"error":{"code":"conflict|invalid_configuration|not_found|unavailable|timeout|io|invalid_request","message":"..."}}. GET /v1/runtime/status, /capabilities, /health, /config. POST /create accepts a complete configuration; POST /start and /restart need no body; POST /stop accepts optional {"force":false}; PUT /config takes a complete replacement; DELETE /v1/runtime requires {"confirm":true}. Unsupported verbs/paths return 404. Mutation conflicts return 409, malformed/invalid input 400, absent state 404, readiness timeout 504, operational failure 503. Endpoint readiness never claims features based only on configuration.

Configuration schema 1: cpu_count (default 4), memory_mib (4096), data_disk_gib (32), appliance_manifest_path (absolute), seed_path (optional absolute ISO), nested_virtualization (true), shares (name/path/read_only), readiness_timeout_seconds (600), shutdown_timeout_seconds (60). Manifest schema 1: id, architecture=arm64, root_disk filename relative to manifest directory, sha256, vsock_protocol=1. Root filename cannot escape its directory. Config updates keep image/seed identity fixed; image upgrades require a future protocol.

## Risks / Trade-offs

- First boot uses internet/package mirrors → checksum base, apt signature verification, bounded readiness timeout, private serial diagnostics; future releases publish pre-provisioned signed appliances.
- Host VZ entitlement and execution policy → ad-hoc sign development binary, probe real support, report denied execution without claiming integration passed.
- Nested KVM is host/kernel dependent → live capability checks and conditional integration acceptance.
- Same-user Incus access is full guest privilege → mode 0700 directories/0600 sockets, peer UID/CID restriction, no network listener.
- Streaming clients can hold resources → bounded connection pool, I/O buffering, close both ends on stop/failure, separate control listener.
- Guest reset/root failure → refuse unknown filesystem formatting; retain data and record recoverable failure.
- Sleep or daemon termination may crash workloads → graceful SIGTERM/SIGINT handling; crash consistency is filesystem/Incus responsibility, suspend/resume policy is future work.

## Migration Plan

Greenfield: compile and sign, prepare verified image/seed, serve an isolated directory, create/start through control API, run standard Incus acceptance, stop, inspect evidence. Per-user launchd packaging is optional after validation. Rollback stops the service and preserves its data directory; deletion is explicit. Binary and appliance releases will be independently versioned.

## Test strategy and feature boundary

Unit tests fake the VZ boundary and assert transitions, mutation conflicts, timeout/error retention, live capability derivation, disk safety, manifest verification, framing and path containment. Hardware tests invoke the real signed Swift VZ service; use standard Incus operations for container, OCI, nested VM, exec/WebSocket and persistence. Save a machine-readable report and do not substitute unit success for acceptance. Initial scope includes all control endpoints, outbound NAT, optional shares and disk growth. Future scope: signed/notarized Homebrew release, appliance download catalog/root upgrades, sleep handling, service forwarding and DNS, memory ballooning and production performance tuning.

## Sources checked

- SwiftPM documentation: https://docs.swift.org/package-manager/documentation/packagemanager/
- VZ platform: https://developer.apple.com/documentation/virtualization/vzgenericplatformconfiguration (also verified installed SDK headers).
- Incus API/security: https://linuxcontainers.org/incus/docs/main/faq/ and https://linuxcontainers.org/incus/docs/main/api/
- OCI instances: https://linuxcontainers.org/incus/docs/main/howto/instances_create/
- Debian image catalog: https://cloud.debian.org/images/cloud/trixie/latest/
- Incus stable packages: https://pkgs.zabbly.com/incus/stable/
