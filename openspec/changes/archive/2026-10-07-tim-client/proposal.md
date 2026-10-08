# Proposal

## Why

The native runtime is validated, but users need a small local client for the outer appliance and a standard Incus CLI pointed at its socket. Add `tim` in this repository for outer-runtime control and explicit Incus CLI setup. Workload operations stay with the standard `incus` client.

## What Changes

- Add `tim` alongside the existing `tama-incus-mac` daemon, retaining the project name, macOS scope and native virtualization boundary.
- Provide `tim runtime status/start/stop/restart`, explicit forced stop and read-only `tim doctor` over the existing control socket.
- Remove `tim list` and `tim show`. tim does not inspect or mutate Incus workloads.
- Add `tim client setup [--remote NAME] [--set-default]`. The default remote name is `tama-mac`. Setup resolves a standard `incus` executable from PATH, or installs the official Homebrew formula `incus` when that executable is missing and Homebrew is already installed. It then registers the ready runtime's `incus.sock` with standard `incus remote` commands.
- Provide a single local tama-incus-mac install command that installs/signs/verifies both daemon and client together, preserving state and leaving launchd opt-in. That install does not install Incus or start the daemon. Future release packages also include both tools.
- Support explicit state-directory discovery, bounded request and subprocess deadlines, readable terminal output, stable exit codes and JSON output/errors.
- Test transport, lifecycle and setup behavior with fixture processes. Real registration acceptance uses the standard Incus CLI and an isolated client configuration; it does not replace historical lifecycle evidence.

## Capabilities

### New Capabilities

- `client-cli`: Local runtime lifecycle, diagnostics, standard Incus CLI setup, output and failure contracts.

### Modified Capabilities

- `service-delivery`: Build and install the separate minimal `tim` client executable alongside the native daemon, without bundling the Incus CLI.

## Impact

SwiftPM adds one executable target, reusing a small client module in the existing library. No third-party Swift dependency, daemon route, guest endpoint or workload command is added. Setup may invoke the existing Homebrew `incus` formula; it does not install Homebrew, wrap a host VM CLI, or translate Incus operations. Canonical checks cover both executables. Automatic daemon installation/start, appliance creation/downloads and signed release distribution remain separate slices.
