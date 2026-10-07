# Spec Delta

## MODIFIED Requirements

### Requirement: SwiftPM delivery

The project SHALL build and test with SwiftPM and strict Swift 6 concurrency, with a package named macus, library product Macus and one minimal macus executable serving daemon and client commands. Debug/release builds, formatting and warnings-as-errors SHALL be canonical commands.

#### Scenario: Clean toolchain build

- **WHEN** the documented build and test commands run on the supported toolchain
- **THEN** they succeed without concurrency diagnostics and produce the Macus library and macus executable

## ADDED Requirements

### Requirement: Unified Macus command

The macus command SHALL expose foreground serve, host capabilities, runtime status/start/stop/restart, doctor and standard Incus client setup. Help SHALL describe both serving and client commands. Workload commands SHALL remain standard Incus operations. Invalid serve flags MUST fail before creating state. Client JSON errors and exit status semantics SHALL be preserved.

#### Scenario: Unified discovery

- **WHEN** macus --help is requested
- **THEN** help lists serve and the client commands without contacting sockets or creating state

#### Scenario: Host-only capabilities

- **WHEN** macus capabilities is requested
- **THEN** host capabilities are returned without booting a guest or creating runtime state

#### Scenario: Invalid serving arguments

- **WHEN** macus serve is requested with unsupported flags or a relative state directory
- **THEN** it fails before creating files or starting the VM

### Requirement: Macus source installation

Local installation SHALL provide one macus executable signed with the virtualization entitlement and verify it in the selected prefix. The launchd template SHALL use com.kritama.macus. Installation MUST preserve runtime data and reject symlink or non-file executable destinations. It MUST NOT activate a launch agent or install the Incus CLI. New client setup SHALL default to remote name macus and retain existing remote conflict and default-switch rules.

#### Scenario: Isolated installation

- **WHEN** macus is installed into an isolated prefix
- **THEN** one entitled executable provides both serve help and runtime client commands without creating runtime state or activating services

### Requirement: Existing appliance compatibility

Daemon and client SHALL resolve state from --state-dir, then MACUS_STATE_DIR, then legacy TIM_STATE_DIR, then ~/.tama/incus-mac. Persistent reset intent, guest service and storage identifiers SHALL remain compatible. The rename MUST NOT move, recreate or delete existing appliance data or alter existing Incus client registrations.

#### Scenario: Legacy state selection

- **WHEN** only TIM_STATE_DIR is set
- **THEN** both serve and client commands select that same directory without migrating data

#### Scenario: Explicit state precedence

- **WHEN** both environment variables and an explicit --state-dir are supplied
- **THEN** the flag wins, and without it MACUS_STATE_DIR wins over TIM_STATE_DIR
