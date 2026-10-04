# Tasks

## 1. Runtime and persistence

- [x] 1.1 Implement Codable configuration/status/errors and serialized lifecycle actor; verify transition, concurrency and capability unit tests.
- [x] 1.2 Implement private state paths, process lock, atomic configuration, verified manifest/root copy and sparse data disk growth; verify disk/path/manifest safety tests and document recovery.

## 2. Native virtualization and guest

- [x] 2.1 Implement main-actor Apple VZ EFI/storage/NAT/vsock/entropy/VirtioFS adapter and dynamic nested support; verify real configuration validation and document entitlement signing.
- [x] 2.2 Replace prototype guest provisioning and systemd units with Alpine POSIX/BusyBox-compatible APK provisioning and OpenRC services; order cgroup/kernel setup and persistent storage before Incus, then start the host-CID-only helper. Verify shell/helper syntax and idempotent restart behavior.
- [x] 2.3 Update image preparation and documentation for the pinned Alpine ARM64 EFI raw archive, verified upstream checksum/signature, manifest digest and NoCloud seed. Record image/package versions, use a new appliance ID and isolated test state, and preserve existing runtime disks.
- [x] 2.4 Verify maintained signed stable-branch Incus LTS (at least 7.0.1), LXC and OCI packages, explicit ARM64 QEMU/firmware dependencies, cgroup v2, vsock/VirtioFS and conditional KVM support; reject unsigned packages and mixed edge repositories.

## 3. Local APIs

- [x] 3.1 Implement private Unix listeners, bounded control HTTP routes and explicit delete confirmation; verify HTTP/parser/route tests and document tama-machine contract.
- [x] 3.2 Implement duplex transparent Incus relay and live health probes; verify stream/half-close tests and document privileged socket semantics.

## 4. Service delivery

- [x] 4.1 Provide minimal CLI, signal shutdown, launchd template and honest Homebrew release guidance; verify executable help/capabilities and document installation.
- [x] 4.2 Configure debug/release/unit/format CI commands and separate opt-in hardware test runner; verify native builds, tests, format and strict OpenSpec validation.
- [x] 4.3 Add GitHub Actions for debug/release builds, unit tests, formatting, guest syntax and strict OpenSpec validation; verify PR checks on the supported macOS/Swift runner.

## 5. Hardware acceptance

- [x] 5.1 Boot the selected Alpine ARM64 appliance and Incus through the signed Swift VZ process; record successful OpenRC startup, readiness and host Incus API access without SSH. Earlier prototype boot evidence does not satisfy this task.
- [x] 5.2 Boot a standard Incus system container and OCI instance, prove exec/WebSocket, outbound networking and cached OCI image reuse after outer restart; record actual API/command evidence.
- [x] 5.3 Restart outer VM and prove persistent instance data plus stopped-state disk growth; record integration report.
- [x] 5.4 Boot nested Incus VM when supported or record explicit unsupported host skip; verify live guest agent command execution.
- [x] 5.5 Complete available CodeRabbit review and resolve actionable findings, rerun affected checks; retain review evidence and report any unavailable review honestly.
- [x] 5.6 Extend hardware acceptance to exercise explicitly configured read-only and writable VirtioFS shares through standard Incus disk devices; prove host/container reads, read-only rejection and write propagation with recorded evidence.

## 6. PR review hardening

- [x] 6.1 Clarify complete JSON configuration requirements and test omitted fields and exact custom values.
- [x] 6.2 Revalidate cached readiness inside start's mutation gate; test dead and unhealthy guests without prior status polling.
- [x] 6.3 Supervise both guest listeners as one process, retry transient accept failures and test fatal failure with active streams.
- [x] 6.4 Replace blocking host relay pumps with bounded nonblocking I/O; test backpressure, half-close, cancellation and independent control progress with many idle streams.
- [x] 6.5 Persist confirmed reset intent and complete interrupted cleanup on restart; test recovery and invalid intent without deleting unconfirmed data.
- [x] 6.6 Run canonical checks, strict validation and fresh isolated hardware acceptance; complete available CodeRabbit review and record verification evidence.

PR publication, head CI and review-thread resolution are tracked on GitHub separately from implementation task completion.
