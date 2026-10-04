# Spec Delta

## Purpose

Provides a minimal Alpine Linux ARM64 appliance with durable Incus storage and a repeatable boot contract.

## ADDED Requirements

### Requirement: Image contract

Appliance input SHALL be an ARM64 EFI-bootable raw disk plus a manifest containing schema version, appliance ID, SHA-256 digest and vsock protocol version. The host SHALL verify the digest before creating its writable copy.

#### Scenario: Tampered input

- **WHEN** the image digest differs from the manifest
- **THEN** creation fails before attaching or booting the image

### Requirement: Headless boot

The appliance SHALL boot without GUI or SSH and initialize Incus, networking and the host helper automatically. Normal runtime operation MUST NOT require guest login.

#### Scenario: First boot

- **WHEN** a valid base image and seed are booted
- **THEN** Incus becomes available through vsock without interactive commands

### Requirement: Separate persistent storage

Incus state SHALL reside on a separate data disk mounted before Incus starts. Existing recognizable filesystems MUST NOT be formatted. Unknown nonblank data MUST fail provisioning.

#### Scenario: Restart persistence

- **WHEN** an instance exists and the outer VM restarts
- **THEN** the same Incus instance and data remain available

### Requirement: Appliance provisioning

Provisioning SHALL be idempotent and use a pinned, maintained Alpine Linux ARM64 base, OpenRC service management and signature-verified APK packages from main/community repositories on the same stable release branch. It SHALL install Incus with its LXC, OCI and ARM64 VM dependencies and the helper. It MUST NOT mix edge repositories, bypass package signature verification or include development/desktop/orchestration software.

#### Scenario: Repeated provisioning

- **WHEN** a previously initialized data disk is booted again
- **THEN** storage and profiles remain intact and initialization does not reset workloads

#### Scenario: Alpine service ordering

- **WHEN** OpenRC starts services on first boot or a subsequent boot
- **THEN** cgroup/kernel prerequisites and persistent storage are ready before Incus starts, and helper health reports readiness only after the Incus API responds

#### Scenario: Alpine kernel support

- **WHEN** the selected Alpine image is validated on a supported Mac
- **THEN** EFI, virtio storage/networking, vsock, configured VirtioFS, and container kernel prerequisites work, and nested VM capability additionally requires usable guest KVM and ARM64 VM dependencies

### Requirement: Disk growth

Stopped-state disk growth SHALL preserve existing bytes. The guest SHALL grow its filesystem on boot before starting Incus; shrink SHALL be unsupported.

#### Scenario: Offline growth

- **WHEN** the user increases the disk size and starts the VM
- **THEN** existing Incus data remains intact and new capacity becomes usable

### Requirement: Upgrade boundary

The appliance manifest and state layout SHALL be versioned. Unsupported schema/protocol versions MUST be rejected. Automatic root-image replacement SHALL be deferred until backup and Incus schema compatibility are proven.

#### Scenario: Unknown manifest

- **WHEN** the manifest schema is newer than supported
- **THEN** creation returns a clear incompatibility error
