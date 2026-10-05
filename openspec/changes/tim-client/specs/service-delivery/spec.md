# Spec Delta

## MODIFIED Requirements

### Requirement: SwiftPM delivery

The project SHALL build and test with SwiftPM and strict Swift 6 concurrency, with one library, a minimal tama-incus-mac daemon and a minimal tim client executable in the same package. Debug/release builds, formatting and warnings-as-errors SHALL be canonical commands.

#### Scenario: Clean toolchain build

- **WHEN** the documented build and test commands run on the supported toolchain
- **THEN** both executables build without concurrency diagnostics

## ADDED Requirements

### Requirement: Single installation

One tama-incus-mac installation SHALL provide both tama-incus-mac and tim executables together without a separate client install. Local development installation SHALL apply the daemon's VZ entitlement and verify both installed binaries. Installation SHALL preserve runtime data and MUST NOT install/start a launch agent, install Homebrew, or bundle the Incus CLI. Release packaging SHALL bundle both tools when released. Installing the standard Incus CLI SHALL remain the explicit tim client setup step.

#### Scenario: Bundled client

- **WHEN** a user installs tama-incus-mac into a selected prefix
- **THEN** both the daemon and tim are available in that prefix's bin directory, existing state is preserved, and the Incus CLI is not installed by that command
