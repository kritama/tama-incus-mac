# service-delivery Specification

## Purpose

Delivers a headless per-user service with safe local permissions and independently recorded hardware acceptance.

## Requirements

### Requirement: SwiftPM delivery

The project SHALL build and test with SwiftPM and strict Swift 6 concurrency, with a package named macus, library product Macus and one minimal macus executable serving daemon and client commands. Debug/release builds, formatting and warnings-as-errors SHALL be canonical commands.

#### Scenario: Clean toolchain build

- **WHEN** the documented build and test commands run on the supported toolchain
- **THEN** they succeed without concurrency diagnostics and produce the Macus library and macus executable

### Requirement: Installation

A foreground service and launchd LaunchAgent SHALL support per-user installation without root privileges. The high-level start command SHALL activate a background service when no compatible daemon exists. VZ entitlements SHALL be documented and applied to integration binaries. Executable installation alone MUST NOT activate services or create runtimes. Installation MUST NOT require a GUI application.

#### Scenario: Local installation

- **WHEN** a user runs the signed executable
- **THEN** owner-only endpoints become available without SSH or a VM CLI

#### Scenario: First high-level start

- **WHEN** start finds no compatible daemon for the selected state
- **THEN** it registers and activates a per-user service using the installed entitled executable, and waits for its private control endpoint

#### Scenario: Existing foreground service

- **WHEN** a compatible same-user foreground daemon already serves the selected state
- **THEN** start reuses it without installing a competing agent and reports its foreground ownership

### Requirement: Security

Private directories SHALL be mode 0700 and sockets/state mode 0600. A single process SHALL own the state lock. Symlink endpoints and foreign ownership MUST be rejected; persisted inputs SHALL not contain API secrets.

#### Scenario: Second daemon

- **WHEN** another daemon uses the same state directory
- **THEN** it fails without unlinking the active sockets

### Requirement: Observability

The service SHALL expose state, uptime, failure reason, Incus version and readiness through JSON and structured Apple logging. Guest serial output SHALL be available locally with private permissions.

#### Scenario: Boot failure

- **WHEN** guest boot fails or readiness times out
- **THEN** status reports failure and the owner can inspect the serial log

### Requirement: Acceptance evidence

Unit tests SHALL cover lifecycle, configuration, persistence and HTTP framing without booting a VM. Hardware acceptance SHALL independently prove Linux/Incus boot, container/OCI boot, WebSockets, restart persistence and nested VM boot or explicit unsupported skip.

#### Scenario: No false completion

- **WHEN** only unit tests have passed
- **THEN** hardware acceptance tasks remain incomplete

### Requirement: Future scope

Automatic appliance upgrade, signed/notarized distribution, transparent service exposure, DNS, memory ballooning and sleep migration SHALL remain documented future features. They MUST NOT block the minimal Incus endpoint or introduce workload orchestration.

#### Scenario: Scope review

- **WHEN** an agent workload needs orchestration or cloud placement
- **THEN** those operations remain outside this runtime

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

Local installation SHALL provide one macus executable signed with the virtualization entitlement and verify it in the selected prefix. The current launchd template SHALL use com.upmaru.macus. Legacy com.kritama.macus registrations SHALL be detected and MUST NOT be implicitly unloaded. Installation MUST preserve runtime data and reject symlink or non-file executable destinations. It MUST NOT activate a launch agent or install the Incus CLI. New client setup SHALL default to remote name macus and retain existing remote conflict and default-switch rules.

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

### Requirement: Service identity and isolation

New startup-managed registrations SHALL use the com.upmaru.macus namespace and bind a stable executable path to one absolute state directory. Isolated state directories SHALL receive distinct service identities without replacing the default user's agent. Existing compatible daemons SHALL be reused. Foreign or conflicting registrations and legacy agents targeting the same state SHALL be detected before activating another service.

#### Scenario: Isolated startup service

- **WHEN** start targets a nondefault isolated state directory
- **THEN** its service and logs are isolated, the default registration remains unchanged, and the isolated service is not automatically registered for future logins

#### Scenario: Loaded matching job

- **WHEN** the selected label is already running or starting and launchctl reports the same executable and state while its control endpoint is not yet open
- **THEN** start waits for that endpoint within the original deadline and does not bootstrap, kickstart, or replace the plist

#### Scenario: Stopped matching job

- **WHEN** the selected label is registered but not running and launchctl reports the same executable and arguments
- **THEN** start kickstarts only that job without forcing, bootstrapping again, or replacing its plist, then waits for the endpoint within the original deadline

#### Scenario: Legacy service conflict

- **WHEN** an incompatible legacy agent is registered against the selected state
- **THEN** start preserves that registration and data, reports how to transition it explicitly, and does not create a second daemon

### Requirement: Startup diagnostics

The background service SHALL expose current bootstrap phase, elapsed operation time, failure reason, and live readiness separately through private control status or progress reporting. Diagnostic files SHALL retain owner-only permissions. Progress text SHALL be terminal-safe and MUST NOT print client credentials, raw guest logs, or unbounded subprocess output.

#### Scenario: Startup fails after service activation

- **WHEN** guest readiness times out
- **THEN** the user can inspect the failed stage, runtime state, and private diagnostic paths without losing the runtime or Incus data
