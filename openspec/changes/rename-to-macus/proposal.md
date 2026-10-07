# Proposal

## Why

The project name `tama-incus-mac` and separate `tim` command require users to remember two names for one runtime. Use Macus consistently for the code package and one command.

## What Changes

- **BREAKING**: Replace the two executable products with `macus`, dispatching foreground `serve` and host `capabilities` alongside existing runtime, doctor and client setup commands.
- **BREAKING**: Rename the SwiftPM package, library and test module to `macus`, `Macus` and `MacusTests`; update source paths, installation, launchd template, logging and current documentation.
- Use `MACUS_STATE_DIR` with `TIM_STATE_DIR` as a compatibility fallback, retain the default `~/.tama/incus-mac` state directory and persisted reset/guest identifiers, and use `macus` as the new default Incus remote name.
- Install and sign one executable with the virtualization entitlement required by its serve mode. Keep historical reports and previous planning artifacts truthful.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `service-delivery`: One named package and executable, unified command dispatch, source installation and state compatibility.

## Impact

SwiftPM entrypoints, library references, installer checks, launchd template, client acceptance tooling, tests, current docs and OpenSpec context. Existing API routes and socket protocols remain compatible. No repository hosting rename, release, launch-agent activation or hardware operation is required by this change. The completed tim-client change is superseded only where it specifies the old names and dual-executable packaging.
