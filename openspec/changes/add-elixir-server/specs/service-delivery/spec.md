# Spec Delta

## MODIFIED Requirements

### Requirement: Installation

One Macus installation SHALL provide the entitled Swift executable and the matching self-contained Elixir release including its pinned shared dependency. Both SHALL support per-user launchd operation without a GUI or root privileges. The high-level start command SHALL activate both missing compatible services. Installation alone MUST NOT activate services, initialize credentials/runtime state, boot Linux or install the Incus CLI. Prebuilt packages MUST NOT require host Swift, Elixir or Erlang toolchains. The same two services SHALL remain sufficient; no Opsmaru service SHALL be installed.

#### Scenario: Local installation

- **WHEN** the owner explicitly starts the complete installed package
- **THEN** the authenticated public server and owner-private backend endpoints become available without SSH or a VM CLI

#### Scenario: First high-level start

- **WHEN** start finds no compatible daemon for the selected state
- **THEN** it registers and activates both independently supervised per-user services using stable installed paths and waits for authenticated server availability within the original deadline

#### Scenario: Existing foreground service

- **WHEN** a compatible same-user foreground daemon already serves the selected state
- **THEN** start reuses it without installing a competing Swift agent, activates or reuses the matching gateway, and reports each service ownership

### Requirement: Security

Private directories SHALL be mode 0700 and sockets, authentication files and durable host state mode 0600. Swift SHALL remain the single owner of the VM state lock; the server SHALL independently protect its credential/task state. Symlinks and foreign ownership MUST be rejected. Runtime configuration MUST NOT contain API secrets; dedicated credential stores SHALL be private and excluded from packages, ordinary status responses and logs.

#### Scenario: Second daemon

- **WHEN** another daemon uses the same state directory
- **THEN** it fails without unlinking the active sockets

### Requirement: Macus source installation

Source installation SHALL build and verify the entitled Swift macus executable and matching bundled-ERTS release in one prefix. Service labels SHALL retain com.upmaru.macus for Swift and use com.upmaru.macus.server for Elixir. Legacy registrations MUST NOT be implicitly unloaded. Installation SHALL preserve data and reject unsafe destinations. It MUST NOT activate agents or install the Incus CLI. Client setup SHALL retain the macus default name and existing conflict/default-switch rules.

#### Scenario: Isolated installation

- **WHEN** macus is installed into an isolated prefix
- **THEN** the entitled Swift executable and complete Elixir release are installed at distinct paths, verify their build identity, and remain passive without runtime state or service activation

### Requirement: Service identity and isolation

New startup-managed registrations SHALL use the com.upmaru.macus namespace and bind stable paths for the Swift executable and Elixir release to one absolute state directory, with independent identities and logs for both services. Isolated state directories SHALL receive distinct service identities without replacing the default user's agent. Existing compatible daemons SHALL be reused. Server recovery MUST NOT stop or restart the VM. Each job SHALL validate its actual executable, arguments, selected state and package identity; gateway listeners SHALL not be reused solely because a port responds. Foreign or conflicting registrations and legacy agents targeting the same state SHALL be detected before activating another service.

#### Scenario: Isolated startup service

- **WHEN** start targets a nondefault isolated state directory
- **THEN** its service and logs are isolated, the default registration remains unchanged, and the isolated service is not automatically registered for future logins

#### Scenario: Loaded matching job

- **WHEN** the selected label is already running or starting and launchctl reports the same executable and state while its control endpoint is not yet open
- **THEN** start waits for that endpoint within the original deadline and does not bootstrap, kickstart, or replace the plist

#### Scenario: Stopped matching job

- **WHEN** the selected label is registered but not running and launchctl reports the same executable and arguments
- **THEN** start kickstarts only that job without forcing, bootstrapping again, or replacing its plist, then waits for the endpoint within the original deadline

#### Scenario: Significant argument whitespace

- **WHEN** a registered service targets a state-directory path ending in a space
- **THEN** start preserves the literal argument value while removing only launchctl indentation, so the matching service can be reused or recovered

#### Scenario: Actual executable conflict

- **WHEN** launchctl reports a different executable even though its argument vector and the current plist match the requested service
- **THEN** start rejects the registration before activation and preserves the existing plist and runtime data

#### Scenario: Legacy service conflict

- **WHEN** an incompatible legacy agent is registered against the selected state
- **THEN** start preserves that registration and data, reports how to transition it explicitly, and does not create a second daemon

#### Scenario: Independent server restart

- **WHEN** the gateway process exits or is explicitly restarted
- **THEN** only its job is recovered and the Swift daemon retains the running VM and Incus data

#### Scenario: Isolated service pair

- **WHEN** start targets a nondefault state directory
- **THEN** both jobs, public endpoint, credentials, task state and logs are isolated from the default installation and neither job is registered for future logins

### Requirement: Acceptance evidence

Native and Elixir unit/protocol checks SHALL run without booting a VM. Package evidence SHALL verify both installed artifacts, bundled runtime and passive installation. Explicit isolated hardware acceptance SHALL separately prove Linux/Incus boot, system-container and OCI-container boot, public runtime control, native Incus HTTP/WebSockets, MCP mutations, service recovery and restart persistence. Nested VM acceptance SHALL prove actual VM boot where supported or record an explicit unsupported skip. LAN/remote acceptance SHALL use an actual authenticated remote client and remain separate from loopback evidence.

#### Scenario: No false completion

- **WHEN** only unit tests have passed
- **THEN** hardware acceptance tasks remain incomplete

#### Scenario: Container and OCI workload boot

- **WHEN** installed-package hardware acceptance runs against the isolated guest Incus backend
- **THEN** system-container and OCI-container workloads boot and pass their fixture-defined readiness checks through the public gateway; API responses or capability reports alone cannot complete these checks

#### Scenario: Nested VM boot or unsupported skip

- **WHEN** installed-package hardware acceptance evaluates nested VM support
- **THEN** a supported nested VM boots and passes its guest readiness check, or a genuinely unsupported platform records the reason and explicit skip without claiming successful VM boot

## ADDED Requirements

### Requirement: Versioned combined release

Swift and the Macus release SHALL share immutable Macus package/source identity. The release SHALL record its distinct pinned shared dependency identity, include ERTS and run foreground under launchd. Upgrades/removal SHALL preserve runtime, credential and task state. Missing/mismatched payloads MUST fail without fetching a startup replacement.

#### Scenario: Combined prebuilt installation

- **WHEN** a user installs an advertised verified prebuilt Macus package
- **THEN** both components are installed automatically from that package and can run without separately installed Erlang or Elixir

#### Scenario: Mismatched component revision

- **WHEN** server and Swift component metadata identify different source revisions
- **THEN** startup rejects the mismatch before guest mutation and reports package recovery guidance

### Requirement: Embedded dependency payload and provenance

The complete pinned shared application SHALL ship inside the existing Macus release in embedded mode. Its source identity SHALL be recorded separately from the matched Macus components. A sibling checkout or standalone shared-service installation MUST NOT be required at build or runtime.

#### Scenario: Installed embedded payload

- **WHEN** the verified package starts on a Mac without Elixir/Erlang or an Opsmaru checkout
- **THEN** shared compute services run inside the existing Macus server without another endpoint or launchd job

#### Scenario: Missing shared payload

- **WHEN** the installed shared dependency is absent or conflicts with recorded build identity
- **THEN** startup fails before guest mutation without downloading a replacement

### Requirement: Embedded connector delivery and preservation

The existing Macus release SHALL include the pinned shared connector without another daemon/job or database requirement. Installation SHALL not enroll or start it. Upgrades/removal SHALL preserve selected-state device identity, disabled/pending revocation state and receipts; incompatible recovery MUST NOT reset or replay execution.

#### Scenario: Package upgraded after disconnect

- **WHEN** an installation with a disabled connector is upgraded
- **THEN** the connector remains disabled and its receipt/revocation state survives without reconnecting or changing workloads
