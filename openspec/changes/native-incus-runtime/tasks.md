# Tasks

## 1. Runtime and persistence

- [x] 1.1 Implement Codable configuration/status/errors and serialized lifecycle actor; verify transition, concurrency and capability unit tests.
- [x] 1.2 Implement private state paths, process lock, atomic configuration, verified manifest/root copy and sparse data disk growth; verify disk/path/manifest safety tests and document recovery.

## 2. Native virtualization and guest

- [x] 2.1 Implement main-actor Apple VZ EFI/storage/NAT/vsock/entropy/VirtioFS adapter and dynamic nested support; verify real configuration validation and document entitlement signing.
- [ ] 2.2 Replace prototype guest provisioning and systemd units with Alpine POSIX/BusyBox-compatible APK provisioning and OpenRC services; order cgroup/kernel setup and persistent storage before Incus, then start the host-CID-only helper. Verify shell/helper syntax and idempotent restart behavior.
- [ ] 2.3 Update image preparation and documentation for the pinned Alpine ARM64 EFI raw archive, verified upstream checksum/signature, manifest digest and NoCloud seed. Record image/package versions, use a new appliance ID and isolated test state, and preserve existing runtime disks.
- [ ] 2.4 Verify signed stable-branch Incus/LXC/OCI packages, explicit ARM64 QEMU/firmware dependencies, cgroup v2, vsock/VirtioFS and conditional KVM support; reject unsigned packages and mixed edge repositories.

## 3. Local APIs

- [x] 3.1 Implement private Unix listeners, bounded control HTTP routes and explicit delete confirmation; verify HTTP/parser/route tests and document tama-machine contract.
- [x] 3.2 Implement duplex transparent Incus relay and live health probes; verify stream/half-close tests and document privileged socket semantics.

## 4. Service delivery

- [x] 4.1 Provide minimal CLI, signal shutdown, launchd template and honest Homebrew release guidance; verify executable help/capabilities and document installation.
- [x] 4.2 Configure debug/release/unit/format CI commands and separate opt-in hardware test runner; verify native builds, tests, format and strict OpenSpec validation.

## 5. Hardware acceptance

- [ ] 5.1 Boot the selected Alpine ARM64 appliance and Incus through the signed Swift VZ process; record successful OpenRC startup, readiness and host Incus API access without SSH. Earlier prototype boot evidence does not satisfy this task.
- [ ] 5.2 Boot a standard Incus system container and OCI instance, prove exec/WebSocket and outbound networking; record actual API/command evidence.
- [ ] 5.3 Restart outer VM and prove persistent instance data plus stopped-state disk growth; record integration report.
- [ ] 5.4 Boot nested Incus VM when supported or record explicit unsupported host skip; verify live guest agent command execution.
- [x] 5.5 Complete available CodeRabbit review and resolve actionable findings, rerun affected checks; retain review evidence and report any unavailable review honestly.
