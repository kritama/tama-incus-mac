# host-integration Specification

## Purpose

Integrates native Apple virtualization devices with truthful capabilities, networking and explicit host directory sharing.

## Requirements

### Requirement: Supported hosts

The runtime SHALL support Apple Silicon on macOS 15+ and use Apple Virtualization.framework directly. Unsupported hardware or denied virtualization policy SHALL produce explicit capability errors.

#### Scenario: No virtualization

- **WHEN** the platform reports virtualization unavailable
- **THEN** start fails before changing durable runtime state

### Requirement: Native devices

The outer VM SHALL use EFI boot, virtio block, NAT networking, virtio socket, entropy and optional VirtioFS through native VZ devices. It MUST NOT depend on another host VM runtime or custom hypervisor.

#### Scenario: Native configuration

- **WHEN** the runtime starts
- **THEN** all VM execution occurs through Apple VZ APIs

### Requirement: Nested capability

Nested virtualization SHALL be detected dynamically and enabled only when supported and configured. Workload VM availability MUST additionally require guest KVM and Incus readiness.

#### Scenario: Unsupported nesting

- **WHEN** host nested virtualization is unavailable
- **THEN** system containers and OCI can become ready while VM capability remains false

### Requirement: Truthful workload capabilities

System container availability SHALL require guest readiness. OCI SHALL additionally require the Incus OCI API extension. VM SHALL require enabled nesting and accessible guest KVM. Incus version SHALL come from the live server.

#### Scenario: OCI unavailable

- **WHEN** Incus responds without the OCI extension
- **THEN** OCI capability is false even though system containers are available

### Requirement: Network defaults

Guest and Incus workloads SHALL have outbound connectivity through host NAT and an Incus managed bridge. Privileged management MUST NOT be exposed on the LAN. Workload service forwarding and custom DNS SHALL be future capabilities.

#### Scenario: Outbound access

- **WHEN** a workload connects to the internet
- **THEN** traffic passes through the Incus bridge and Apple NAT

### Requirement: Explicit shares

Host shares SHALL require absolute existing directory paths and unique validated names. Read-only SHALL be the default. The service MUST NOT automatically share the home directory or root filesystem.

#### Scenario: No implicit filesystem exposure

- **WHEN** a runtime is created with no shares
- **THEN** no macOS directory is exposed to the guest
