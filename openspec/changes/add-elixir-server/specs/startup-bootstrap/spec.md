# Spec Delta

## MODIFIED Requirements

### Requirement: One-command first use

`macus start` SHALL verify the complete installed package, acquire and verify the appliance, prepare defaults and local gateway credentials, activate both per-user services, create an absent runtime, provision and boot Linux, and configure the standard Incus client through the public server. Success SHALL require authenticated server availability, live guest/Incus readiness and a successful standard-client check. No separate server install, foreground terminal, source checkout or guest login SHALL be required.

#### Scenario: Fresh installation

- **WHEN** the installed Macus executable is run with `macus start` on a supported host with internet access and an available Incus client or existing Homebrew
- **THEN** it completes with both services available, a ready runtime and a working named HTTPS Incus remote without another terminal or manual preparation steps

#### Scenario: Guest booted but client failed

- **WHEN** Incus becomes ready but client installation or registration fails
- **THEN** start exits unsuccessfully, identifies the failed stage, and reports that the runtime remains ready so the user can retry safely

### Requirement: Predictable preflight and defaults

Start SHALL validate arguments, supported virtualization, state-path safety, the running executable's virtualization entitlement, client-install prerequisites, the matching installed Elixir release, and selected gateway configuration before downloads or service/runtime mutation. Fresh defaults SHALL be 4 CPUs, 4096 MiB memory, a 32 GiB data disk, no host shares, and nesting only where supported. Missing Homebrew SHALL produce an actionable prerequisite error without installing Homebrew or using sudo.

#### Scenario: Missing host prerequisite

- **WHEN** neither Incus nor Homebrew is available
- **THEN** start fails before downloading or creating runtime files and explains how to satisfy the prerequisite

#### Scenario: Invalid invocation

- **WHEN** start receives an unsupported flag, invalid remote, relative state directory, or unsafe endpoint path
- **THEN** it returns usage or configuration failure before creating state or running installation commands

#### Scenario: Unsupported nesting

- **WHEN** the host supports native virtualization but cannot enable nesting
- **THEN** system-container readiness can succeed and the result truthfully reports VM capability unavailable

#### Scenario: Incomplete installed package

- **WHEN** the Elixir release is missing, incompatible with the Swift build or has invalid listener/TLS configuration
- **THEN** start fails before appliance acquisition or guest creation and reports how to repair the installed package

### Requirement: Repeatable startup

Start SHALL reuse valid existing configuration, disks, and matching public client registrations, gateway credentials and compatible registrations for both services. It MUST NOT replace a root image, migrate storage, shrink disks, reset workloads, or override resource settings. A healthy ready runtime SHALL be checked live; a stopped runtime SHALL be started. Running unhealthy runtimes and incomplete durable creation SHALL fail with explicit recovery guidance.

#### Scenario: Already ready

- **WHEN** start is repeated against a healthy ready runtime with a working client
- **THEN** it returns success without re-downloading the appliance, recreating disks, restarting the VM, or reinstalling the client

#### Scenario: Existing legacy storage

- **WHEN** an existing stopped ext4/dir runtime is selected
- **THEN** start uses its existing configuration and storage without replacing it with the fresh-install ZFS default

#### Scenario: Partial runtime creation

- **WHEN** owned runtime disks exist without committed configuration
- **THEN** start preserves those files, reports the inconsistency, and does not silently create or reset another runtime

#### Scenario: Gateway stopped while VM ready

- **WHEN** Swift owns a healthy running guest but the matching server job is stopped
- **THEN** start recovers only that server service, rechecks public connectivity and leaves the VM running

### Requirement: Bounded operation and interruption

Start SHALL use one overall monotonic deadline across acquisition, both service activations, credential/endpoint checks, provisioning, expected reboot, and client setup. Timeout and cancellation SHALL stop coordinator-owned downloads and subprocesses, release bootstrap ownership, and preserve committed runtime state. Cancellation SHALL identify a still-running guest and how to stop it explicitly; it MUST NOT force-stop or delete existing workloads.

#### Scenario: Deadline across stages

- **WHEN** earlier stages consume most of the selected timeout
- **THEN** later stages use only the remaining budget and no retry resets the deadline

#### Scenario: Interrupt during boot

- **WHEN** the user interrupts start while the background service is provisioning Linux
- **THEN** the command restores the terminal, exits as interrupted, preserves disks and logs, and reports whether the guest continues running

### Requirement: Low-level command compatibility

Existing `serve`, `runtime`, `doctor`, and `client setup` commands SHALL remain available; normal runtime, doctor and setup requests SHALL use the public server, while serve SHALL remain the private Swift foreground daemon. Their documented installation side effects and state resolution SHALL be retained; only high-level start SHALL implicitly acquire an appliance and activate the complete service pair; explicit connect may activate/recover only the installed Elixir job for enrollment without guest provisioning. Explicit low-level start SHALL benefit from safe expected-reboot handling without provisioning an absent runtime.

#### Scenario: Read-only inspection

- **WHEN** status or doctor is run against an absent installation
- **THEN** it does not download an image, create a runtime, install Incus, or activate a service

#### Scenario: Low-level absent start

- **WHEN** `macus runtime start` targets an absent runtime
- **THEN** it retains its explicit not-created failure and directs the user to the high-level start experience

## ADDED Requirements

### Requirement: Embedded compute preflight

Startup SHALL validate the bundled shared dependency, embedded mode and selected backend/state before activating the server. Shared workers SHALL remain inside the existing Elixir service; no third job, public listener or separate dependency activation SHALL be introduced.

#### Scenario: Invalid dependency mode

- **WHEN** Macus startup detects standalone shared-service configuration or a missing pinned payload
- **THEN** it fails preflight without starting another endpoint or mutating the guest

### Requirement: Central-independent local startup

Local startup SHALL not require central enrollment, external user login or central availability. An already enrolled connector SHALL reconnect independently after server activation, without extending local readiness requirements or provisioning a registration. Connector failures MUST NOT restart or stop a healthy VM.

#### Scenario: Start while central offline

- **WHEN** an enrolled installation starts locally while central is unreachable
- **THEN** normal local startup can succeed and connection status reports central unavailability separately
