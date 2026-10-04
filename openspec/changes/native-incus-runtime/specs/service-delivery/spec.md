# Spec Delta

## Purpose

Delivers a headless per-user service with safe local permissions and independently recorded hardware acceptance.

## ADDED Requirements

### Requirement: SwiftPM delivery

The project SHALL build and test with SwiftPM and strict Swift 6 concurrency, with one library and a minimal executable. Debug/release builds, formatting and warnings-as-errors SHALL be canonical commands.

#### Scenario: Clean toolchain build

- **WHEN** the documented build and test commands run on the supported toolchain
- **THEN** they succeed without concurrency diagnostics

### Requirement: Installation

A foreground service and launchd LaunchAgent template SHALL support per-user installation without root privileges. VZ entitlements SHALL be documented and applied to integration binaries. Installation MUST NOT require a GUI.

#### Scenario: Local installation

- **WHEN** a user runs the signed executable
- **THEN** owner-only endpoints become available without SSH or a VM CLI

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
