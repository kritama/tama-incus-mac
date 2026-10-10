# Spec Delta

## MODIFIED Requirements

### Requirement: Runtime controls

The client SHALL provide runtime status, start, stop and restart through the authenticated public /runtime API. Forced stop SHALL require an explicit --force flag on stop. It SHALL distinguish the outer runtime from Incus instances and MUST NOT implement workload commands or silently bypass an unavailable server through private sockets.

#### Scenario: Explicit force

- **WHEN** macus runtime stop --force is requested
- **THEN** the client sends the existing forced-stop payload to the control API

### Requirement: Endpoint discovery and safety

The client SHALL select an absolute state directory from --state-dir, then MACUS_STATE_DIR, then legacy TIM_STATE_DIR, then ~/.tama/incus-mac. It SHALL validate owner-private endpoint metadata and credentials, reject unsafe path ancestry, verify HTTPS server identity, bound responses and enforce total deadlines. Read-only commands MUST NOT create state, install software or activate services. Setup SHALL check arguments and readiness before mutation. Fixed-argument subprocesses SHALL retain bounded output and be reaped on failure, deadline or cancellation.

#### Scenario: Missing daemon

- **WHEN** the selected public server endpoint is absent or unavailable
- **THEN** the command fails with an actionable error without creating files, installing packages, starting services or falling back to private sockets

### Requirement: CLI acceptance

Tests SHALL cover HTTPS identity, authorization, response framing, deadlines, lifecycle routes, setup sequences, installer failures and remote conflicts with fixture processes. Separate acceptance SHALL run actual installed macus and standard incus clients with isolated INCUS_CONF through the server, including native WebSocket operations. Mocked installation MUST NOT count as actual Homebrew installation. Historical direct-socket evidence MUST NOT establish the new server gate.

#### Scenario: Executable validation

- **WHEN** setup acceptance is recorded
- **THEN** it proves the installed macus executable registered a remote that the standard incus list command can use, separately from historical lifecycle evidence

## REMOVED Requirements

### Requirement: Unix remote registration

**Reason**: Normal client access now goes through the authenticated public server.

**Migration**: Use Server remote registration; explicitly select a new remote name or transition the owner-selected legacy remote. Never overwrite unrelated configuration.

## ADDED Requirements

### Requirement: Server remote registration

Setup SHALL read readiness through the server and register its HTTPS Incus endpoint using standard remote commands under INCUS_CONF. The default name SHALL be macus. It MUST NOT boot an absent/stopped runtime, hand-write remote configuration or translate workloads. Setup SHALL explicitly enroll the selected certificate, verify server identity, remain idempotent for the same endpoint/identity, and prove connectivity with standard incus list.

#### Scenario: Ready server registration

- **WHEN** macus client setup is requested for a ready runtime
- **THEN** the named remote points at its public HTTPS server endpoint, the selected certificate is trusted by the gateway, and incus list can address it

#### Scenario: Stopped runtime

- **WHEN** client setup is requested while the outer runtime is not ready
- **THEN** it fails without booting the runtime, installing packages, or changing Incus client configuration

### Requirement: Client setup state preservation

Existing remotes, including legacy unix remotes, MUST NOT be overwritten. The default remote SHALL change only with explicit --set-default. Unrelated remotes, projects, aliases and TLS material SHALL be preserved. Legacy transition SHALL require an explicit owner action or a different remote name.

#### Scenario: Conflicting remote

- **WHEN** the requested remote name already points at a different address
- **THEN** setup exits with a conflict error and leaves that remote unchanged

#### Scenario: Existing direct socket remote

- **WHEN** the selected remote already names a legacy unix endpoint
- **THEN** setup reports the explicit transition or alternate remote-name choice and preserves that registration until the owner changes it

### Requirement: Owner-local server administration

The macus CLI SHALL provide owner-local gateway endpoint configuration, certificate trust and bearer issuance/revocation. These actions SHALL validate private state ownership and preserve runtime disks and unrelated credentials. Secret output SHALL require explicit issuance to a private destination; ordinary help/status/doctor MUST NOT issue credentials or activate services.

#### Scenario: Explicit credential issuance

- **WHEN** the owner requests a scoped bearer credential with a private output destination
- **THEN** the CLI issues only the requested credential, protects its destination and leaves VM/workload state unchanged

### Requirement: One embedded service connection

Normal CLI startup/setup SHALL use the existing Macus gateway and its embedded compute dependency. It MUST NOT install or activate a separate Opsmaru server or configure another MCP endpoint as a prerequisite.

#### Scenario: Complete package setup

- **WHEN** client setup operates against the complete ready Macus package
- **THEN** the same public gateway provides native Incus and composed MCP connectivity without another service setup

### Requirement: Explicit central connect

`macus connect [url]` SHALL enroll this installation and enable its outbound connector. First use SHALL require a valid trusted HTTPS service URL; later use SHALL resume the saved registration idempotently. Enrollment SHALL require authorized external-provider browser authentication and device key proof. Switching service MUST NOT overwrite an active registration implicitly.

#### Scenario: First connect

- **WHEN** the owner connects to an approved central URL and completes enrollment
- **THEN** the selected installation stores its private device identity and verified target/generation and enables the connector in the existing Elixir server

#### Scenario: Different central service

- **WHEN** connect names a different service while an active registration exists
- **THEN** it reports an explicit disconnect/enrollment conflict and preserves the existing identity, receipts and pending work

### Requirement: Connect side effects and failure bounds

Connect SHALL enforce safe state, installed service identity, trusted metadata and one bounded enrollment deadline. It may explicitly recover only the matching Elixir job. It MUST NOT provision/start the VM, change host shares/native remotes, open inbound ports or persist user OAuth credentials. Failure SHALL preserve workloads and report uncertain registration outcomes.

#### Scenario: Guest absent during enrollment

- **WHEN** connect enrolls a Mac whose guest is absent or stopped
- **THEN** the target can be registered with truthful readiness without acquiring an appliance, booting VZ or changing shares

#### Scenario: Lost enrollment response

- **WHEN** central commits enrollment but the client loses its response
- **THEN** reconnect recovers the same key-bound enrollment receipt without creating another device grant or target

### Requirement: Passive connection status

`macus connection status` SHALL report saved enrollment, transport connectivity and backend readiness separately, with JSON support and sanitized errors. It MUST NOT create files, issue credentials, enroll, activate services or disclose secrets.

#### Scenario: No registration

- **WHEN** connection status inspects an unregistered installation
- **THEN** it reports disconnected without mutating state or starting the server

### Requirement: Safe disconnect

`macus disconnect` SHALL durably disable reconnect and new central dispatch before closing sessions and attempting central revocation. It SHALL be idempotent and report remote-revocation-pending when confirmation is unavailable. Local access, workloads, credentials unrelated to central and execution receipts SHALL remain intact.

#### Scenario: Central unavailable during disconnect

- **WHEN** disconnect cannot reach central
- **THEN** local remote access is disabled immediately and pending revocation is reported without claiming global revocation or deleting VM/task state
