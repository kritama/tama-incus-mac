# Spec Delta

## Purpose

Manages the outer Linux host lifecycle without taking ownership of Incus workloads.

## ADDED Requirements

### Requirement: Explicit lifecycle

The service SHALL expose absent, stopped, starting, ready, stopping and failed states. Readiness MUST require an authenticated guest helper and a responding Incus API.

#### Scenario: Booting is not ready

- **WHEN** the outer VM starts but Incus is unavailable
- **THEN** status remains starting and never advertises Incus availability

### Requirement: Serialized mutations

The service SHALL reject competing lifecycle/configuration mutations with HTTP 409 while an operation is active, except an explicit force stop SHALL cancel an active boot wait. Repeated create/start/stop requests SHALL be idempotent when already satisfied.

#### Scenario: Competing start

- **WHEN** start is waiting for guest readiness and another mutation arrives
- **THEN** the second mutation returns conflict without changing disks or VZ state

### Requirement: Graceful and forced stop

Stop SHALL request guest shutdown and wait with a bounded deadline. A timeout MUST retain an actionable error and MUST NOT silently force stop. An explicit force flag SHALL permit immediate stop.

#### Scenario: Shutdown timeout

- **WHEN** the guest does not stop before its deadline
- **THEN** the request fails with timeout and the caller can explicitly force stop

#### Scenario: Emergency stop during boot

- **WHEN** the VM is starting and an explicit force stop is requested
- **THEN** the boot wait is cancelled, the outer VM is stopped, and the mutation gate remains owned until stop completes

### Requirement: Recovery

A daemon restart SHALL reconstruct durable configuration and stopped state, never reuse persisted ready evidence. Unexpected guest exit SHALL revoke readiness.

#### Scenario: Stale readiness

- **WHEN** the daemon restarts after being killed while ready
- **THEN** it reports stopped and probes again only after starting the VM

### Requirement: Resource updates

CPU, memory, disk growth, nesting preference and shares SHALL be validated and updated only when stopped. Disk shrink SHALL be rejected. Invalid updates MUST preserve prior configuration.

#### Scenario: Shrink rejected

- **WHEN** a caller requests a smaller data disk
- **THEN** HTTP 400 is returned and prior disk size and configuration remain intact

### Requirement: Destructive reset

Delete SHALL require an explicit confirmation payload and a stopped outer VM. It SHALL remove only service-owned runtime files and SHALL leave externally supplied appliance images intact.

#### Scenario: Running deletion

- **WHEN** delete is requested while the VM is running
- **THEN** HTTP 409 is returned and Incus data is preserved

### Requirement: Live idempotent start

A repeated start SHALL validate running state and guest health within its mutation gate before returning ready. An exited guest SHALL be started again; a running unhealthy guest SHALL revoke readiness and require explicit stop before recovery.

#### Scenario: Exit without status polling

- **WHEN** a previously ready guest exits and start is requested before another status poll
- **THEN** cached readiness is revoked and a new boot is attempted

### Requirement: Interrupted confirmed reset

The service SHALL durably record explicit reset intent before deleting owned files. On restart it SHALL complete an interrupted confirmed reset before loading configuration. Invalid intent or incomplete state without confirmed intent SHALL preserve data and fail safely.

#### Scenario: Reset interruption

- **WHEN** the daemon restarts after confirmed deletion removed disks but left configuration
- **THEN** it completes only the confirmed service-owned cleanup and reports absent
