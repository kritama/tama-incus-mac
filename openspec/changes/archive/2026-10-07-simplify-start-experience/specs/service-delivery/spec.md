# Spec Delta

## MODIFIED Requirements

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

## ADDED Requirements

### Requirement: Service identity and isolation

New startup-managed registrations SHALL use the com.upmaru.macus namespace and bind a stable executable path to one absolute state directory. Isolated state directories SHALL receive distinct service identities without replacing the default user's agent. Existing compatible daemons SHALL be reused. Foreign or conflicting registrations and legacy agents targeting the same state SHALL be detected before activating another service.

#### Scenario: Isolated startup service

- **WHEN** start targets a nondefault isolated state directory
- **THEN** its service and logs are isolated, the default registration remains unchanged, and the isolated service is not automatically registered for future logins

#### Scenario: Legacy service conflict

- **WHEN** an incompatible legacy agent is registered against the selected state
- **THEN** start preserves that registration and data, reports how to transition it explicitly, and does not create a second daemon

### Requirement: Startup diagnostics

The background service SHALL expose current bootstrap phase, elapsed operation time, failure reason, and live readiness separately through private control status or progress reporting. Diagnostic files SHALL retain owner-only permissions. Progress text SHALL be terminal-safe and MUST NOT print client credentials, raw guest logs, or unbounded subprocess output.

#### Scenario: Startup fails after service activation

- **WHEN** guest readiness times out
- **THEN** the user can inspect the failed stage, runtime state, and private diagnostic paths without losing the runtime or Incus data
