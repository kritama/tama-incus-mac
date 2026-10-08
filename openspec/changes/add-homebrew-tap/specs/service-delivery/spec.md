# Spec Delta

## ADDED Requirements

### Requirement: Homebrew installation

The tap SHALL provide one entitled macus executable for Apple Silicon and macOS 15+. Normal installation on each advertised bottle platform SHALL use a prebuilt bottle without invoking Swift. Installation SHALL NOT start services, create runtime state, boot a guest or configure Incus. Unsupported platforms and missing bottle coverage SHALL have explicit diagnostics and documented source-build prerequisites.

#### Scenario: Bottle installation

- **WHEN** a tester installs the formula on an advertised bottle platform without a Swift toolchain
- **THEN** Homebrew installs the prebuilt executable, its signature and virtualization entitlement verify, and help and host capabilities work without runtime state or service activation

#### Scenario: Unsupported host

- **WHEN** installation is attempted on Intel, Linux or macOS older than 15
- **THEN** the formula rejects the host before installing Macus or changing runtime state

#### Scenario: Missing bottle coverage

- **WHEN** the host satisfies the runtime minimum but has no compatible verified bottle
- **THEN** documentation and installation diagnostics identify the missing coverage and Swift 6.4 source-build requirement rather than claiming a toolchain-free install

#### Scenario: Optional Incus client

- **WHEN** the Macus formula is installed without the standard Incus client
- **THEN** installation does not configure a remote or require the client, and subsequent explicit startup retains the existing client installation and setup behavior

### Requirement: Homebrew artifact integrity

Source archives and bottles SHALL carry measured SHA-256 checksums, an immutable source revision, package version and build-platform provenance. Published URLs SHALL identify immutable artifacts. Generation SHALL refuse missing or placeholder digests. Installed binaries SHALL retain a valid virtualization entitlement. Ad-hoc development signing SHALL be labelled accurately and SHALL NOT be represented as Developer ID signing or notarization.

#### Scenario: Corrupted bottle

- **WHEN** bottle bytes differ from the formula's recorded checksum
- **THEN** Homebrew rejects installation and existing runtime disks and Incus configuration remain unchanged

#### Scenario: Signature lost during packaging

- **WHEN** bottle creation or installation invalidates the executable signature or removes its virtualization entitlement
- **THEN** packaging acceptance fails and the artifact is not promoted as a verified install candidate

#### Scenario: Development candidate

- **WHEN** a candidate is generated from a pinned development commit
- **THEN** it has distinct development provenance and actual digests, and its documentation makes no production signing, notarization or completed hardware acceptance claim

### Requirement: Local tap rehearsal

The project SHALL document and support local Git tap installation using locally generated, checksummed source and bottle artifacts before remote publication. The rehearsal SHALL use real Homebrew installation and the installed executable without substituting the checkout binary. It SHALL refuse replacement of an unrelated existing Macus installation and record the source revision, formula identity, bottle digest and installed path.

#### Scenario: Local prebuilt install

- **WHEN** the local tap rehearsal runs for a generated candidate
- **THEN** Homebrew consumes the candidate bottle, the recorded executable belongs to its installed keg, and no source build is accepted as evidence of prebuilt installation

#### Scenario: Existing package conflict

- **WHEN** an unrelated Macus formula or executable would be replaced or unlinked by the rehearsal
- **THEN** the rehearsal stops before changing that installation and directs the tester to a clean account or dedicated Homebrew test environment

### Requirement: Homebrew acceptance evidence

Package checks SHALL verify installed help, capabilities, signature, entitlement and passive installation without booting a VM. Hardware acceptance SHALL require explicit opt-in and separate evidence using the Homebrew-installed binary, isolated state and Incus configuration. It SHALL cover first start, repeated start, standard Incus connectivity, persistence and the documented package upgrade/removal sequence. Failures SHALL retain state and diagnostics.

#### Scenario: Package-only success

- **WHEN** package checks and canonical native checks pass without hardware opt-in
- **THEN** the report identifies bottle installation success and hardware acceptance remains incomplete

#### Scenario: Installed first use

- **WHEN** a tester explicitly runs hardware acceptance with a fresh isolated state
- **THEN** the installed binary prepares the pinned appliance, activates its isolated service, reaches live Incus readiness, registers a remote only in isolated client configuration, and repeated start reuses the runtime

#### Scenario: Upgrade and removal

- **WHEN** a tester follows the documented stop, unload, upgrade and restart sequence, then stops and unloads before uninstall
- **THEN** the upgraded binary reaches the preserved runtime and workload marker through standard Incus operations, and uninstall retains disks, diagnostic files and client configuration

#### Scenario: Failed first use

- **WHEN** appliance preparation or startup fails
- **THEN** the report distinguishes successful package installation from failed hardware acceptance and preserves runtime data and diagnostic paths

## MODIFIED Requirements

### Requirement: Service identity and isolation

New startup-managed registrations SHALL use the com.upmaru.macus namespace and bind a stable executable path to one absolute state directory. Isolated state directories SHALL receive distinct service identities without replacing the default user's agent. Existing compatible daemons SHALL be reused. Foreign or conflicting registrations and legacy agents targeting the same state SHALL be detected before activating another service. New Homebrew registrations SHALL use a validated stable package path rather than a versioned keg path. Equivalence of that path and its resolved executable SHALL require the same current installed executable; unrelated executables SHALL remain conflicts. Package operations SHALL NOT implicitly start or replace services. Upgrade and removal instructions SHALL stop the runtime and unload its owned service before changing or removing the executable, while preserving runtime and Incus data.

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

#### Scenario: Homebrew executable equivalence

- **WHEN** the job names the stable Homebrew opt path and launchctl reports its resolved current keg executable with otherwise identical arguments and selected state
- **THEN** startup recognizes the verified equivalence and reuses the service without weakening unrelated-executable conflict checks

#### Scenario: Stable path after upgrade

- **WHEN** the owned runtime and service have been stopped and unloaded, Homebrew upgrades the package, and the user explicitly starts it again
- **THEN** the registration retains a valid stable package path, uses the new installed binary and preserves the existing runtime and isolated/default service boundary

#### Scenario: Old versioned registration

- **WHEN** startup finds an existing registration bound to a different or removed versioned keg
- **THEN** it preserves that registration, refuses implicit replacement and provides explicit transition instructions
