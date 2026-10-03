# Spec Delta

## Purpose

Provides a minimal ARM64 Linux appliance with durable Incus storage and a repeatable boot contract.

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

Provisioning SHALL be idempotent and use a maintained Debian ARM64 base with authenticated package repositories, service management, Incus, its LXC/VM dependencies and the helper. It MUST omit development/desktop/orchestration software.

#### Scenario: Repeated provisioning

- **WHEN** a previously initialized data disk is booted again
- **THEN** storage and profiles remain intact and initialization does not reset workloads

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
