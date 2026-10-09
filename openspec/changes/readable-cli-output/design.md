# Design

## Context

See `proposal.md` for motivation and the two delta specs for the behavior contract. `MacusCLI.swift` currently formats runtime fields with raw keys, renders client results generically, and renders doctor nested dictionaries as JSON values. `Daemon.run` special-cases the exact unflagged `capabilities` invocation and always encodes JSON. `MacusStart.swift` writes its human/JSON result while the progress sink is still active; its deferred cleanup runs afterwards. `TerminalProgressSink` protects renderer state with a lock but writes outside it, allowing concurrent progress events to reorder. The progress model already supplies nine stages, state, byte counters, elapsed time and expected-reboot observations. Existing tests cover renderer cleanup through a pseudo-terminal but do not check the combined progress/result ordering.

## Goals / Non-Goals

**Goals:** Keep all presentation inside the Macus library; give commands a shared readable vocabulary; preserve machine schemas and operational behavior; make progress truthful and compatible with scrollback, redirection, interruption and narrow terminals.

**Non-Goals:** Full-screen navigation, keyboard focus/input, GUI surfaces, changes to Incus operations or guest provisioning, automatic repairs, new package publication, and VM/hardware acceptance as a prerequisite for presentation changes.

## Decisions

### 1. Noora-backed presentation adapter

Introduce a library-level Noora adapter under `Sources/Macus/Client` or `Support`. Use Noora's semantic text, alerts, static tables and progress components for human presentation; retain small Macus helpers for contextual support/connection states, human durations and byte sizes, and next-command blocks. Use dedicated report builders for startup, runtime, doctor, client and host capabilities so labels and omission rules remain deliberate. Preserve full paths and failure details, escape untrusted terminal controls before constructing Noora text, and quote arguments when constructing copyable shell commands. Never convert missing capability data to unsupported or invent readiness from host support. Unknown optional fields can be omitted from human summaries while required missing observations are labelled unavailable; JSON retains its fields.

Use an exact SwiftPM Noora pin, initially the verified released tag [0.57.5](https://github.com/tuist/Noora/releases/tag/0.57.5), and commit `Package.resolved` for reproducible builds. Its manifest declares macOS 13+, below Macus's macOS 15 minimum, and its library depends on Rainbow, SwiftLog and Path; ArgumentParser is declared for Noora's example target, not for replacing Macus's parser. Inspect the resolved graph and compile against Macus's strict Swift 6 toolchain before marking dependency integration complete. Do not add ConsoleKit or SwiftTUI alongside Noora or change the existing command grammar. Keep Noora implementation details behind the adapter and `MacusCommand` minimal.

Inject Noora `StandardPipelining` implementations backed by `MacusStreams` instead of accepting global stdout defaults. Use separate configured presentation instances for final stdout reports, stderr diagnostics and stderr progress. For progress, both Noora output and error pipelines route to the serialized stderr sink. A custom `Terminaling` adapter uses the selected stream's TTY capability/width, `TERM` and `NO_COLOR`; it performs cursor operations on that stream and does not install signal handlers. Never instantiate Noora's default `Terminal`, whose default signal behavior restores the cursor and exits with status zero. Macus remains responsible for cancellation and exit 130. JSON bypasses Noora's human formatting and JSON convenience encoder, preserving the existing serialization, schema and trailing newline.

Optional subtle heading/status styling is selected per output stream, only for capable TTYs and with no `NO_COLOR` key present. Text statuses convey the meaning when styling is absent. Use an ASCII-compatible fallback for bars/status markers when required. Final reports wrap long values naturally rather than truncating paths or commands. Use Noora tables for bounded status/support rows; keep paths, diagnostics and next commands outside cells that might truncate them.

An expanded generic dictionary renderer was considered, but cannot reliably distinguish host capabilities from live workload capabilities. A dependency-free renderer was the initial plan; the user's explicit selection of Noora replaces it to share a consistent visual design across commands. ConsoleKit offers lower-level primitives but leaves more layout work to Macus. A full TUI framework such as SwiftTUI adds input/focus handling this short-lived command does not need. Noora is the chosen presentation dependency; the adapter addresses Macus-specific output contracts.

### 2. Outcome-first doctor report

Doctor retains its read-only requests and readiness/exit rules. Use a Noora success/warning/error alert for the existing checks' outcome, then static report sections/tables for Runtime, Host support, Workload support and Guest health. Show state, selected endpoint, formatted uptime and last error; host architecture/virtualization; observed container/OCI/VM/nesting/sharing support; Incus version, KVM and guest health protocol. Keep host-supported nesting distinct from enabled workload VM capability. Do not print an enormous API-extension list in human mode; expose its relevant interpreted capabilities and retain the full list through JSON. A missing health/capability response appears as Unavailable, never as a pass or a false boolean.

Representative human report, with values based on fixtures rather than actual hardware evidence:

```text
Macus needs attention

Runtime
  Status       Stopped
  Uptime       0s
  Incus socket /tmp/macus-test/state/incus.sock

Host support
  Status       Unavailable

Workload support
  Status       Unavailable

Guest health
  Status       Unavailable

Next steps
  macus --state-dir /tmp/macus-test/state runtime start
```

A successful report starts with `Macus is healthy`. Error recovery must use the selected state and observed failure: it must not blindly suggest runtime start for every error (for example an absent setup or unsupported host). Human doctor can integrate the readiness diagnosis into one cohesive report while JSON retains its current stdout report and stderr error behavior. Update presentation assertions without weakening readiness tests.

### 3. Explicit capabilities machine mode

Route capabilities through the CLI's existing global-flag handling, accepting `--json` before or after it. Reuse host detection with the existing main-actor isolation. Plain capabilities renders host support; JSON encodes the current `HostCapabilities` schema. Validate irrelevant flags before detection. Update executable tests and all repository scripts/documentation that parse capabilities as JSON. Grep-based `apple-vz` smoke checks can remain human consumers or use explicit JSON consistently. No API schema changes.

Serve retains its existing grammar and os logging, adding its human listening notice only after a successful bind. It does not adopt startup's progress renderer, or acquire/boot an appliance. Help groups common usage first while retaining advanced state selection, deadlines, flags and exit statuses.

### 4. Stage ledger and measurable acquisition

Maintain a per-operation ledger for the nine `StartupStage` values rather than deriving completion from event order. Complete and skipped stages resolve one slot each; pending/active/failed do not. Track overlapping provisioning/readiness observations without double counting. Use resolved-stage counts (e.g. `5/9 stages`) rather than an overall percentage or ETA. Hold the final stage unresolved for display until a successful `StartupResult` confirms ready and connected; then finalize the bar. Failed or interrupted operations never render a success marker.

Use Noora's themed rendering for a compact live progress display, with completed/skipped stage messages preserved in scrollback. The stage ledger is Macus-owned: render the stage-count bar through Noora's text/renderer APIs rather than presenting Noora's built-in numeric percentage as overall startup completion. Representative forms (illustrative text; the actual Noora theme may use different markers):

```text
✔︎ Host checked [0.1s]
✔︎ Appliance prepared [0.2s]
⠋ Provisioning Linux (1m 12s) | [#####----] 5/9 stages
```

During acquisition, use Noora's `progressBarStep` for measured byte progress (`128 MiB / 256 MiB, 50%`) when a positive trusted total is available and the terminal has sufficient width. Unknown-length downloads and boot/client waits use its activity/progress-step presentation without a numerical percentage. Validate/clamp display arithmetic for invalid or over-total counters without changing underlying measurements. Waiting stages use readable labels and human elapsed time; guest details map known phase names to readable wording and escape unknown details. The expected kernel reboot is explicitly named as an ongoing wait. Keep the overall stage-count view and current-stage activity under one serialized renderer; do not run independent indicators that erase each other's rows.

Use the actual Noora `progressStep` API for each observed stage, including its native completion/failure markers and elapsed-time layout. A custom string sent through `passthrough` is not a substitute for a step component. Keep stage accounting as supplementary context on the active step; completed steps remain native Noora scrollback. Skipped stages must explicitly describe reuse/skipping rather than displaying a successful download or disk creation.

Noora 0.57.5's step spinner and mutable message share unsynchronized state. Run its step component with `showSpinner: false`, process message updates on one component task per stage, and let the adapter's synchronized refresh animate the cached native frame. All native renderer/pipeline callbacks pass through the same closed-state/write boundary. Finish and await component tasks before the final report, and reject late events and stale active frames for already resolved stages.

Terminal line handling must explicitly return to column zero after every progress scrollback line, including when `ONLCR` is disabled. Test the screen after interpreting carriage returns, linefeeds, erasure and color controls; raw captures that merely contain completion strings do not prove the displayed prefixes and row boundaries are intact. Human report pipelines must also preserve line starts on such terminals, without changing redirected or JSON bytes.

Sample elapsed/animation refreshes at a bounded cadence (no more than ten redraws per second), with immediate important transitions. Coordinate Noora's indicator callbacks through an injected renderer to enforce that cadence and the sink's closed state. Where the component cannot express the required stage view or width fallback, compose it using Noora `TerminalText` and the same renderer rather than introducing another presentation dependency. A cancellable adapter-owned refresh task can provide elapsed updates during sparse events; it reads the latest observation, never synthesizing readiness or guest phases. Refreshing does not extend startup's deadline. Stop and await all refresh activity before final output.

### 5. Serialized stream finalization

Serialize Macus renderer state and actual Noora pipeline writes together. A finalization method stops refresh, clears/terminates the active line, restores the cursor and disables further events. Invoke it before writing the success object/summary; retain an idempotent deferred cleanup for exceptions. Error rendering happens only after cleanup has completed. Noora component completion text must be emitted after animation shutdown, not allow a late timer redraw to erase the final report. Do not share mutable presentation state outside its concurrency boundary. Keep writes ordered when sink callbacks come from download, runtime polling and client installation concurrently; verify injected renderer/pipeline callbacks are compatible with strict Swift 6 concurrency.

A normal return must leave the success summary on a new line; a failure leaves the failed stage/recovery information. Cancellation continues to preserve disks and any still-running runtime, with exit 130. Unify client-install progress presentation and ensure the bounded subprocess diagnostic output already forwarded by `IncusClientService` is readable text with deliberate newline handling; never mingle subprocess output with a live animated row.

### 6. Terminal width and plain logs

Read stderr width via the custom Noora `Terminaling` adapter's Darwin terminal sizing, allow an injected width in tests, and re-evaluate on refresh so resize does not require global signal ownership. Noora 0.57.5's built-in progress bar uses a fixed 30-cell bar; do not assume it meets the responsive-width contract. Use it only when its message/bar fits, switching to a compact Noora-themed frame or plain mode otherwise. Bound live text to available cell width with a conservative margin; prioritize the stage/status and remove detail before shrinking the bar. Use a conservative default when sizing fails; if a safe single line cannot be established, fall back to plain output. Account for display width rather than byte length for dynamic non-ASCII strings. Do not erase unrelated rows after resize.

In plain mode, emit state/detail transitions immediately and otherwise report at most one repetitive byte/elapsed update every five seconds. Preserve distinct expected-reboot changes and final/failure events. `--json` still selects plain stderr progress unless `--progress none` is supplied. JSON disables all styling; redirected stderr and `TERM=dumb` disable cursor operations. `NO_COLOR` affects styling, not animation capability or explicit text status.

## Risks / Trade-offs

- Stage sizes differ greatly → label the bar as stages, use measured bytes only for acquisition and never advertise a time-based percentage or ETA.
- stdout/stderr capture can interleave independently → flush/finalize stderr before the single stdout summary; test merged streams through an actual pseudo-terminal.
- Concurrent callbacks or timer shutdown could redraw after summary → serialize writes and close the sink before final emission; cover late events and idempotent cleanup.
- Width/Unicode may cause wrapped stale rows → use display-cell budgeting, narrow fallback and resize tests; leave final paths untruncated.
- Changing default capabilities affects scripts → mark the presentation break explicitly, migrate repository JSON consumers and document both accepted `--json` placements.
- Fixtures could be mistaken for VM acceptance → label examples and terminal checks as presentation evidence, retain separate opt-in hardware gates.
- Noora defaults own stdout and signals → always inject stream pipelines and a signal-neutral terminal, bypass human rendering for JSON, and exercise interruption through a real pseudo-terminal.
- Noora's fixed bar width and refresh behavior do not cover every contract → adapt its rendering at the Macus boundary; verify narrow/resize/plain/finalization cases instead of relaxing the specs.
- Additional SwiftPM dependencies affect reproducibility and compiler compatibility → exact Noora pin, committed resolved graph and strict debug/release checks; do not claim compatibility from the manifest alone.

## Migration Plan

Implement on `feature/readable-cli-output` from develop after planning review. First add and verify the Noora dependency and adapter; then update machine consumers before relying on new default capabilities output. Run presentation tests, pseudo-terminal/redirected executable acceptance, canonical native checks and strict OpenSpec validation. Preserve current service, disks, clients and package install while testing terminal fixtures. Present the implementation for review without merging or publishing packages. Rollback reverts presentation code/docs, Noora manifest/lockfile and JSON consumer invocation changes together; runtime schemas and data require no migration.
