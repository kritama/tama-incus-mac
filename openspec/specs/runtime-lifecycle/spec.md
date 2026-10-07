# runtime-lifecycle Specification

## Purpose

Manages the outer Linux host lifecycle without taking ownership of Incus workloads.

## Requirements

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

### Requirement: Expected bootstrap kernel restart

During fresh provisioning, start SHALL automatically restart a stopped guest at most once when the current boot emitted the trusted expected-kernel-reboot signal. The allowance SHALL be durably scoped to the fresh bootstrap and remain bounded across coordinator or daemon restarts. Unexpected exits, stale signals, and repeated reboot requests SHALL fail. Live helper and Incus readiness SHALL still be required.

#### Scenario: Expected first-boot shutdown

- **WHEN** fresh provisioning signals the qualified-kernel transition and the guest actually stops
- **THEN** start records the consumed allowance, boots the same runtime once more within the remaining deadline, and waits for live readiness

#### Scenario: Stale log marker

- **WHEN** an old serial log contains an expected-reboot marker and the current guest exits without a current-boot signal
- **THEN** start reports unexpected exit and does not automatically restart

#### Scenario: Repeated transition request

- **WHEN** the guest requests another kernel restart after the fresh-bootstrap allowance was consumed
- **THEN** start fails with an actionable error rather than entering a reboot loop or deleting the runtime

#### Scenario: Force stop during transition

- **WHEN** explicit force stop cancels a boot while an expected restart is pending
- **THEN** the mutation gate remains owned through cancellation and stop, and no pending automatic restart occurs
