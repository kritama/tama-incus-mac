# Proposal

## Why

Macus output exposes internal field/stage names, dense nested values and raw booleans. Interactive startup writes its final summary before clearing the active progress line, joining messages and making an otherwise successful first run difficult to read.

## What Changes

- Give every user-facing command a consistent layout: a clear outcome, grouped details with readable labels, explicit supported/unsupported/unknown states, and copyable next commands.
- Format startup, runtime status/start/stop/restart, doctor, client setup, host capabilities, help and errors. Keep foreground serve in normal scrollback with a concise startup notice and its existing diagnostic logging.
- Replace the raw startup spinner with a width-aware stage progress bar and readable active-stage text. Show a measured download bar when byte totals are known; show activity and elapsed time during unmeasured waits and expected reboot.
- Finish progress before writing any final result or error; preserve legible terminal scrollback and serialized writes on success, failure, timeout and interruption.
- Preserve `--progress auto|plain|none`, separate result stdout from progress stderr, and give redirected output readable text without cursor control or color. Honor `NO_COLOR` for optional terminal styling.
- **BREAKING**: `macus capabilities` becomes human-readable by default; `macus capabilities --json` and `macus --json capabilities` provide the existing host-capability JSON schema. Update repository machine consumers to request JSON explicitly. Other JSON schemas, errors and exit statuses stay compatible.

## Capabilities

### New Capabilities

None; presentation belongs to the existing command and startup capabilities.

### Modified Capabilities

- `client-cli`: consistent human presentation across commands, host-capabilities JSON opt-in, readable errors/help, safe terminal text and explicit machine-output compatibility.
- `startup-bootstrap`: stage progress bars, measurable download progress, readable waits, plain-output throttling and ordered terminal finalization.

## Impact

Macus library presentation helpers; `Client/MacusCLI.swift`, `Client/MacusStart.swift`, `Client/IncusClient.swift`, `Bootstrap/ProgressRenderer.swift` and `Application/Daemon.swift`; their CLI/renderer tests and executable fixtures; README and acceptance/package scripts that consume capabilities. `Sources/MacusCommand` remains a thin entry point. Use the existing Foundation/Darwin terminal infrastructure without a new dependency or full-screen TUI. This change does not alter VM provisioning, workload behavior, package publication or runtime data. Terminal acceptance is distinct from opt-in guest/hardware acceptance.
