# Tasks

## 1. Runtime and persistence

- [ ] 1.1 Implement Codable configuration/status/errors and serialized lifecycle actor; verify transition, concurrency and capability unit tests.
- [ ] 1.2 Implement private state paths, process lock, atomic configuration, verified manifest/root copy and sparse data disk growth; verify disk/path/manifest safety tests and document recovery.

## 2. Native virtualization and guest

- [ ] 2.1 Implement main-actor Apple VZ EFI/storage/NAT/vsock/entropy/VirtioFS adapter and dynamic nested support; verify real configuration validation and document entitlement signing.
- [ ] 2.2 Provide Debian NoCloud provisioning, safe persistent filesystem setup, Incus initialization and host-CID-only helper; verify helper/provisioning syntax and document image preparation.

## 3. Local APIs

- [ ] 3.1 Implement private Unix listeners, bounded control HTTP routes and explicit delete confirmation; verify HTTP/parser/route tests and document tama-machine contract.
- [ ] 3.2 Implement duplex transparent Incus relay and live health probes; verify stream/half-close tests and document privileged socket semantics.

## 4. Service delivery

- [ ] 4.1 Provide minimal CLI, signal shutdown, launchd template and honest Homebrew release guidance; verify executable help/capabilities and document installation.
- [ ] 4.2 Configure debug/release/unit/format CI commands and separate opt-in hardware test runner; verify native builds, tests, format and strict OpenSpec validation.

## 5. Hardware acceptance

- [ ] 5.1 Boot ARM64 Linux and Incus through signed Swift VZ process; record successful readiness and host Incus API access without SSH.
- [ ] 5.2 Boot a standard Incus system container and OCI instance, prove exec/WebSocket and outbound networking; record actual API/command evidence.
- [ ] 5.3 Restart outer VM and prove persistent instance data plus stopped-state disk growth; record integration report.
- [ ] 5.4 Boot nested Incus VM when supported or record explicit unsupported host skip; verify live guest agent command execution.
- [ ] 5.5 Complete available CodeRabbit review and resolve actionable findings, rerun affected checks; retain review evidence and report any unavailable review honestly.
