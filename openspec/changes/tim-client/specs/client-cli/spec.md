# Spec Delta

## Purpose

Lets users operate the native outer runtime and configure the standard Incus CLI from the bundled local tim client.

## ADDED Requirements

### Requirement: Runtime controls

The client SHALL provide runtime status, start, stop and restart using the existing control API. Forced stop SHALL require an explicit --force flag on stop. It SHALL distinguish the outer runtime from Incus instances and MUST NOT implement workload commands.

#### Scenario: Explicit force

- **WHEN** tim runtime stop --force is requested
- **THEN** the client sends the existing forced-stop payload to the control API

### Requirement: Standard Incus client setup

The client SHALL provide client setup for the standard incus executable. It SHALL use an absolute --incus override when given, otherwise an executable named incus on PATH, and otherwise brew install incus from the official Homebrew formula when an existing Homebrew installation can be found. It SHALL discover the installed executable through Homebrew's prefix even if that bin directory is not on PATH. It SHALL NOT install Homebrew, use a shell installer, sudo, another package manager, a custom tap, or upgrade unrelated formulae. Status, doctor and lifecycle commands MUST NOT run brew or mutate Incus client configuration. An existing functioning incus executable SHALL be reused without an upgrade. Installation progress SHALL be reported on stderr.

#### Scenario: Missing client with Homebrew

- **WHEN** tim client setup is requested, incus is not on PATH, and Homebrew is already installed
- **THEN** the client installs the official incus formula and uses the resulting executable

#### Scenario: Homebrew absent

- **WHEN** tim client setup is requested, incus is not on PATH, and Homebrew cannot be found
- **THEN** the command fails with installation guidance and does not attempt to install Homebrew

### Requirement: Unix remote registration

Setup SHALL read the selected ready runtime status and register its incus socket with standard incus remote commands under INCUS_CONF. The default remote name SHALL be tama-mac when --remote is omitted. It MUST NOT boot an absent or stopped runtime, write client configuration by hand, or translate workload APIs. Repeating setup for the same remote name and socket SHALL be idempotent. A remote name already configured for a different address MUST fail with conflict and MUST NOT be overwritten. The default remote SHALL change only when --set-default is explicit. Unrelated remotes, projects, aliases and TLS material SHALL be preserved. Setup SHALL verify connectivity by asking the standard incus client to list that remote.

#### Scenario: Ready socket registration

- **WHEN** tim client setup is requested for a ready runtime
- **THEN** the named remote points at that runtime's unix socket and incus list can address the remote

#### Scenario: Conflicting remote

- **WHEN** the requested remote name already points at a different address
- **THEN** setup exits with a conflict error and leaves that remote unchanged

#### Scenario: Stopped runtime

- **WHEN** client setup is requested while the outer runtime is not ready
- **THEN** it fails without booting the runtime, installing packages, or changing Incus client configuration

### Requirement: Endpoint discovery and safety

The client SHALL select an absolute state directory from --state-dir, then TIM_STATE_DIR, then ~/.tama/incus-mac. It SHALL reject symlink endpoint ancestry and foreign endpoint/peer ownership, bound responses and enforce total request deadlines. Read-only commands MUST NOT create state directories, install software, or start the daemon. Setup SHALL validate arguments and cheap readiness preconditions before package installation or client-configuration changes. Subprocesses SHALL use fixed argument arrays, preserve the relevant environment, drain bounded output without deadlock, and be reaped on failure, deadline or cancellation.

#### Scenario: Missing daemon

- **WHEN** the selected control socket is absent
- **THEN** the command fails with an actionable error without creating files, installing packages, or starting services

### Requirement: Output and failures

The client SHALL provide human-readable output and --json results/errors. Exit status SHALL be 0 on success, 1 on operational failure and 2 on invalid arguments. Invalid command/flag combinations, including list, show and workload aliases, SHALL fail before networking or installation. A conflicting remote, missing tool, failed installation, connectivity failure or deadline SHALL retain a useful stable error code. Secrets and full client configuration MUST NOT be written to the output.

#### Scenario: Unknown workload command

- **WHEN** tim list or tim show is requested
- **THEN** it exits 2 with a usage error and does not contact a socket or run brew

#### Scenario: Machine-readable conflict

- **WHEN** tim client setup --json requests a remote name that points elsewhere
- **THEN** it exits 1 and emits a JSON error with conflict code

### Requirement: Read-only doctor

Doctor SHALL report runtime status, host/workload capabilities and live guest health through read-only control requests. It SHALL exit successfully only when the runtime is ready, host virtualization is supported and guest health protocol is compatible.

#### Scenario: Stopped runtime diagnosis

- **WHEN** tim doctor inspects a stopped runtime
- **THEN** it reports the observed status and an actionable readiness failure without starting the VM or running brew

### Requirement: CLI acceptance

Tests SHALL cover socket response framing, deadlines, lifecycle requests, setup command sequences, installer failures and remote conflicts with fixture processes. Separate acceptance SHALL run the actual tim executable and the standard incus client with an isolated INCUS_CONF, proving registered connectivity. Mocked installation evidence MUST NOT be reported as an actual Homebrew install. Prior lifecycle or list/show evidence MUST NOT establish the setup gate.

#### Scenario: Executable validation

- **WHEN** setup acceptance is recorded
- **THEN** it proves the installed tim executable registered a remote that the standard incus list command can use, separately from historical lifecycle evidence
