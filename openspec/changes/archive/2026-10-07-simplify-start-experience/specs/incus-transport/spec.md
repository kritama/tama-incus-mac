# Spec Delta

## MODIFIED Requirements

### Requirement: Control API

The service SHALL implement GET status, capabilities, health, config and progress; POST create, start, stop and restart; PUT config; and DELETE runtime beneath /v1/runtime. Responses SHALL use versioned Codable JSON and stable error codes. Start SHALL accept an optional bounded remaining-time budget without changing saved configuration; an empty body SHALL retain existing behavior. Progress SHALL be read-only and independently readable during boot.

#### Scenario: Unknown route

- **WHEN** a client requests an unsupported control path
- **THEN** HTTP 404 is returned with a machine-readable error

#### Scenario: Progress during startup

- **WHEN** a client reads progress while another connection waits for start
- **THEN** it receives the current operation and provisioning phase without blocking on completion or reporting false readiness

#### Scenario: Remaining startup budget

- **WHEN** start receives a valid remaining-time budget
- **THEN** the daemon bounds the entire boot and expected restart by that budget and its configured readiness limit without persisting a resource or timeout update

#### Scenario: Invalid startup budget

- **WHEN** start receives an invalid, unbounded, or malformed budget payload
- **THEN** it returns a configuration/request error before booting or altering durable state
