# Spec Delta

## ADDED Requirements

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
