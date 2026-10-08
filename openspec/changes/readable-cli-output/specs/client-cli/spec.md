# Spec Delta

## MODIFIED Requirements

### Requirement: Output and failures

The client SHALL provide human-readable output by default and explicit --json results/errors. Exit status SHALL remain 0 on success, 1 on operational failure and 2 on invalid arguments. Invalid command/flag combinations, including list, show and workload aliases, SHALL fail before networking or installation. A conflicting remote, missing tool, failed installation, connectivity failure or deadline SHALL retain a useful stable error code. Secrets and full client configuration MUST NOT be written to the output.

#### Scenario: Unknown workload command

- **WHEN** macus list or macus show is requested
- **THEN** it exits 2 with a usage error and does not contact a socket or run brew

#### Scenario: Machine-readable conflict

- **WHEN** macus client setup --json requests a remote name that points elsewhere
- **THEN** it exits 1 and emits a JSON error with conflict code

## ADDED Requirements

### Requirement: Consistent human command results

Startup, runtime status/start/stop/restart, doctor, client setup and host capabilities SHALL present a clear outcome followed by grouped, readable labels. Human output MUST NOT dump nested JSON or expose snake_case field names. Booleans SHALL use contextual words; missing observations SHALL be unknown or unavailable. Reports SHALL preserve material diagnostic details and separate copyable next commands from results.

#### Scenario: Successful startup summary

- **WHEN** macus start succeeds with a connected remote and observed workload capabilities
- **THEN** the summary states that Macus is ready, groups runtime/client/service details, names supported workload features, and puts each suggested command on its own line

#### Scenario: Runtime lifecycle result

- **WHEN** status, start, stop or restart returns an observed runtime state
- **THEN** the report identifies that state, displays available uptime in human units, preserves the selected socket and last failure, and does not imply readiness from request success alone

#### Scenario: Incomplete diagnosis

- **WHEN** doctor has runtime status but no live capability or health response
- **THEN** it groups runtime, host/workload and guest-health observations, labels absent data unavailable, preserves useful error details and retains its existing unsuccessful exit

#### Scenario: Client setup result

- **WHEN** client setup completes
- **THEN** it reports connectivity, remote, endpoint, client executable, installation/reuse and default selection with readable labels and a copyable Incus next command

### Requirement: Explicit host capability JSON

macus capabilities SHALL report human-readable host support by default. Both macus capabilities --json and macus --json capabilities SHALL emit the existing host-capability JSON object and trailing newline without human decoration. Host capabilities SHALL remain read-only and distinguish host support from observed guest/workload readiness. Existing JSON result/error schemas for other commands SHALL remain compatible.

#### Scenario: Host-only capability display

- **WHEN** macus capabilities is run without JSON selection
- **THEN** it reports platform, architecture, Apple virtualization support, host nesting and file-sharing support without claiming that any guest or workload is ready

#### Scenario: Capability machine consumer

- **WHEN** capabilities is requested with --json before or after the command
- **THEN** stdout contains exactly the existing parseable host-capability object with no ANSI escapes, progress or human summary

#### Scenario: Existing JSON commands

- **WHEN** runtime, doctor, client setup or start is requested with --json
- **THEN** existing result fields, JSON error destinations and exit statuses remain unchanged and styling is excluded

### Requirement: Readable help and foreground notice

Help SHALL group commands and options with copyable common examples and concise descriptions. Foreground serve SHALL emit a concise listening notice identifying its control endpoint and foreground ownership, while keeping diagnostic logging and signal behavior. Neither help nor presentation SHALL add runtime mutations or change supported workload boundaries.

#### Scenario: Foreground serving

- **WHEN** serve has successfully bound its control API
- **THEN** a readable notice identifies the endpoint and explains that the terminal owns the daemon without claiming the guest is ready

#### Scenario: First-use help

- **WHEN** macus --help is requested
- **THEN** it shows startup, inspection, lifecycle and client commands with JSON/progress usage and the existing state-selection, timeout and exit-status information

### Requirement: Safe human terminal text

Human errors SHALL clearly identify the failure and separate available recovery commands. Human results, diagnostics and progress SHALL escape untrusted control characters. Styling SHALL be optional, terminal-aware and disabled with NO_COLOR; redirected output SHALL remain readable without ANSI escapes. Status meaning MUST NOT depend on color or decorative glyphs. Complete paths and copyable commands SHALL not be truncated in final reports.

#### Scenario: Unsafe diagnostic string

- **WHEN** a runtime detail, path or subprocess message contains terminal control characters
- **THEN** the text is escaped and cannot move the cursor, clear the screen or impersonate another output line

#### Scenario: Redirected or color-free result

- **WHEN** stdout is redirected or NO_COLOR is set
- **THEN** results use readable text without color sequences and retain explicit status words
