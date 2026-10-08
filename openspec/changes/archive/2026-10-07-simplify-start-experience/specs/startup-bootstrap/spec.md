# Spec Delta

## Purpose

Makes first use and repeated startup of the native Macus runtime a single observable operation that finishes only when the standard Incus client can reach a live server.

## ADDED Requirements

### Requirement: One-command first use

`macus start` SHALL acquire and verify the appliance, prepare defaults, activate a per-user service, create an absent runtime, provision and boot Linux, and configure the standard Incus client. Success SHALL require live guest/Incus readiness and a successful client connectivity check. No foreground server, create API call, source checkout, or guest login SHALL be required.

#### Scenario: Fresh installation

- **WHEN** the installed Macus executable is run with `macus start` on a supported host with internet access and an available Incus client or existing Homebrew
- **THEN** it completes with a ready runtime and a working named Incus remote without another terminal or manual preparation steps

#### Scenario: Guest booted but client failed

- **WHEN** Incus becomes ready but client installation or registration fails
- **THEN** start exits unsuccessfully, identifies the failed stage, and reports that the runtime remains ready so the user can retry safely

### Requirement: Predictable preflight and defaults

Start SHALL validate arguments, supported virtualization, state-path safety, the running executable's virtualization entitlement, and client-install prerequisites before downloads or service/runtime mutation. Fresh defaults SHALL be 4 CPUs, 4096 MiB memory, a 32 GiB data disk, no host shares, and nesting only where supported. Missing Homebrew SHALL produce an actionable prerequisite error without installing Homebrew or using sudo.

#### Scenario: Missing host prerequisite

- **WHEN** neither Incus nor Homebrew is available
- **THEN** start fails before downloading or creating runtime files and explains how to satisfy the prerequisite

#### Scenario: Invalid invocation

- **WHEN** start receives an unsupported flag, invalid remote, relative state directory, or unsafe endpoint path
- **THEN** it returns usage or configuration failure before creating state or running installation commands

#### Scenario: Unsupported nesting

- **WHEN** the host supports native virtualization but cannot enable nesting
- **THEN** system-container readiness can succeed and the result truthfully reports VM capability unavailable

### Requirement: Repeatable startup

Start SHALL reuse valid existing configuration, disks, and matching client registrations. It MUST NOT replace a root image, migrate storage, shrink disks, reset workloads, or override resource settings. A healthy ready runtime SHALL be checked live; a stopped runtime SHALL be started. Running unhealthy runtimes and incomplete durable creation SHALL fail with explicit recovery guidance.

#### Scenario: Already ready

- **WHEN** start is repeated against a healthy ready runtime with a working client
- **THEN** it returns success without re-downloading the appliance, recreating disks, restarting the VM, or reinstalling the client

#### Scenario: Existing legacy storage

- **WHEN** an existing stopped ext4/dir runtime is selected
- **THEN** start uses its existing configuration and storage without replacing it with the fresh-install ZFS default

#### Scenario: Partial runtime creation

- **WHEN** owned runtime disks exist without committed configuration
- **THEN** start preserves those files, reports the inconsistency, and does not silently create or reset another runtime

### Requirement: Standard client integration

Start SHALL reuse the established client discovery, official Homebrew installation, and remote-registration rules. It SHALL honor `INCUS_CONF`, `--incus`, and `--remote`; the default remote name SHALL be macus. It MUST NOT overwrite a conflicting remote or change the default remote unless `--set-default` is supplied. Workload operations SHALL remain standard Incus commands.

#### Scenario: Remote conflict

- **WHEN** the selected remote name already points to a different endpoint
- **THEN** start fails with conflict, preserves the existing remote and runtime data, and suggests selecting another remote

#### Scenario: Isolated client configuration

- **WHEN** start uses an isolated state directory, `INCUS_CONF`, and an explicit Incus executable
- **THEN** it configures only that client directory and does not run Homebrew or alter the user's ordinary client configuration

### Requirement: Serialized bootstrap and safe retries

Only one startup coordinator SHALL mutate a selected state's bootstrap resources at a time. Concurrent starts SHALL return a clear conflict without starting another daemon or changing disks. Interrupted downloads/preparation SHALL be retryable using verified completed artifacts. Unsafe partial or corrupt artifacts MUST NOT be trusted. Failure cleanup SHALL preserve runtime disks, Incus data, and diagnostics.

#### Scenario: Concurrent first starts

- **WHEN** two start commands target the same absent state directory
- **THEN** one owns bootstrap and the other fails with conflict without duplicate creation or service activation

#### Scenario: Interrupted image download

- **WHEN** a download is interrupted and start is rerun
- **THEN** no partial image is booted, any complete cached image is reverified before reuse, and the download/preparation can be retried

### Requirement: Bounded operation and interruption

Start SHALL use one overall monotonic deadline across acquisition, service startup, provisioning, expected reboot, and client setup. Timeout and cancellation SHALL stop coordinator-owned downloads and subprocesses, release bootstrap ownership, and preserve committed runtime state. Cancellation SHALL identify a still-running guest and how to stop it explicitly; it MUST NOT force-stop or delete existing workloads.

#### Scenario: Deadline across stages

- **WHEN** earlier stages consume most of the selected timeout
- **THEN** later stages use only the remaining budget and no retry resets the deadline

#### Scenario: Interrupt during boot

- **WHEN** the user interrupts start while the background service is provisioning Linux
- **THEN** the command restores the terminal, exits as interrupted, preserves disks and logs, and reports whether the guest continues running

### Requirement: Truthful progress

Start SHALL identify preflight, acquisition, verification, preparation, service activation, runtime creation, guest provisioning, readiness, and client setup as pending, active, complete, failed, or skipped. It SHALL show byte progress only when measurable, elapsed waiting time otherwise, and distinguish the expected reboot. It MUST NOT show success based only on process launch, progress markers, or cached readiness.

#### Scenario: Download with unknown length

- **WHEN** the server does not supply a trustworthy content length
- **THEN** progress shows downloaded bytes and activity without inventing a percentage or completion estimate

#### Scenario: Slow guest provisioning

- **WHEN** guest packages are still being installed
- **THEN** progress shows the observed provisioning stage and elapsed time while runtime readiness remains false

### Requirement: Terminal and machine output

Start SHALL support `--progress auto|plain|none`. Auto SHALL animate only on a capable interactive stderr terminal; plain output SHALL preserve readable stage transitions without cursor escapes. `--json` SHALL disable animation and write one final result object to stdout, keeping progress on stderr. Renderers SHALL restore terminal state after success, error, timeout, and interruption.

#### Scenario: Redirected output

- **WHEN** start runs with stderr redirected or `TERM=dumb`
- **THEN** it emits plain progress without ANSI animation or raw guest/subprocess output

#### Scenario: Machine-readable result

- **WHEN** `macus start --json --progress none` succeeds
- **THEN** stdout contains one JSON result with runtime readiness, live capabilities, selected state, remote, and resolved client path

### Requirement: Low-level command compatibility

Existing `serve`, `runtime`, `doctor`, and `client setup` commands SHALL remain available. Their documented installation side effects and state resolution SHALL be retained; only the new high-level start command SHALL implicitly acquire an appliance and activate a background service. Explicit low-level start SHALL benefit from safe expected-reboot handling without provisioning an absent runtime.

#### Scenario: Read-only inspection

- **WHEN** status or doctor is run against an absent installation
- **THEN** it does not download an image, create a runtime, install Incus, or activate a service

#### Scenario: Low-level absent start

- **WHEN** `macus runtime start` targets an absent runtime
- **THEN** it retains its explicit not-created failure and directs the user to the high-level start experience
