# Tasks

## 1. Shared human presentation

- [ ] 1.1 Add library-level section, label, support-state, duration/size and next-command formatting helpers with stream-aware optional styling; verify focused tests cover missing values, NO_COLOR, redirection, safe control escaping and correctly quoted complete commands/paths.
- [ ] 1.2 Replace startup and runtime status/start/stop/restart human reports with dedicated readable layouts; verify CLI fixtures retain observed state, endpoint, last error and selected-state next commands, and unchanged JSON fields/exit statuses.
- [ ] 1.3 Give client setup and its bounded installation diagnostics readable output with deliberate line boundaries; verify success/reuse/install/default-selection and failure fixtures plus existing remote-preservation tests.
- [ ] 1.4 Add presentation examples for startup, runtime and client setup to documentation, labelled as examples; verify they match the fixture output and use valid CLI grammar.

## 2. Doctor, capabilities and command guidance

- [ ] 2.1 Implement doctor outcome plus Runtime, Host support, Workload support and Guest health sections with contextual states and recovery guidance; verify healthy/stopped/failed/unavailable/incompatible fixtures, useful error retention, host-versus-guest capability distinctions and unchanged JSON report/error behavior.
- [ ] 2.2 Route host capabilities through the CLI with human default and --json accepted before/after the command; verify the old HostCapabilities object schema, no-mutation behavior and rejection of irrelevant flags in library and executable tests.
- [ ] 2.3 Update repository consumers that parse capabilities to request JSON explicitly, including acceptance/package checks where appropriate; verify the installed-executable smoke checks and parsed schema tests still pass.
- [ ] 2.4 Group help, add common examples and format human errors/recovery text; add a foreground serve notice after binding while preserving logs and signals; verify help/usage tests and serve fixtures using isolated sockets without a VM.
- [ ] 2.5 Document doctor examples, host-versus-workload capability meaning and the capabilities --json migration; verify all documented invocations against CLI parsing and fixture reports.

## 3. Startup stage progress and terminal lifecycle

- [ ] 3.1 Implement the nine-stage ledger with readable labels, resolved-stage bar, skipped-stage handling and success gated by a ready/connected result; verify reused-runtime, duplicate/overlapping events and failed startup fixtures never invent readiness or time-based percentage.
- [ ] 3.2 Add measured acquisition bars with readable sizes and bounded percentages, unknown-length activity, elapsed waits and expected-reboot labels; verify known/unknown/invalid/over-total byte counters and guest-wait fixtures.
- [ ] 3.3 Add width-aware rendering and bounded refresh activity with five-second plain-update throttling; verify narrow/unknown/resized terminal widths, non-ASCII details, prompt state transitions, NO_COLOR, TERM=dumb and redirected plain output.
- [ ] 3.4 Serialize actual progress writes and stop refresh/finalize before final results or errors with idempotent cleanup; verify shared stdout/stderr pseudo-terminal captures for success, error, timeout, cancellation and late/concurrent events contain no joined summary, stale redraw or hidden cursor.
- [ ] 3.5 Document progress modes, stage-count meaning, measured download percentage and non-animated logging; verify examples against terminal/redirected fixtures and keep hardware evidence explicitly separate.

## 4. Integration verification

- [ ] 4.1 Run the actual signed executable with read-only commands and startup/doctor fixture transports under a pseudo-terminal and with redirected streams, using isolated state only; retain representative presentation transcripts and verify parseable JSON plus unchanged read-only/lifecycle boundaries without booting a VM.
- [ ] 4.2 Run Integration/scripts/check.sh and mise exec -- openspec validate --all --strict --no-interactive; review the final diff for presentation scope, Swift 6 concurrency, no new dependencies, no runtime/client-data changes and no committed .integration/build outputs.
