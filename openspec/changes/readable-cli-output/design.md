# Design

## Context

See `proposal.md` for motivation and the two delta specs for the behavior contract. `MacusCLI.swift` currently formats runtime fields with raw keys, renders client results generically, and renders doctor nested dictionaries as JSON values. `Daemon.run` special-cases the exact unflagged `capabilities` invocation and always encodes JSON. `MacusStart.swift` writes its human/JSON result while the progress sink is still active; its deferred cleanup runs afterwards. `TerminalProgressSink` protects renderer state with a lock but writes outside it, allowing concurrent progress events to reorder. The progress model already supplies nine stages, state, byte counters, elapsed time and expected-reboot observations. Existing tests cover renderer cleanup through a pseudo-terminal but do not check the combined progress/result ordering.

## Goals / Non-Goals

**Goals:** Keep all presentation inside the Macus library; give commands a shared readable vocabulary; preserve machine schemas and operational behavior; make progress truthful and compatible with scrollback, redirection, interruption and narrow terminals.

**Non-Goals:** Full-screen navigation, keyboard focus/input, GUI surfaces, changes to Incus operations or guest provisioning, automatic repairs, new package publication, and VM/hardware acceptance as a prerequisite for presentation changes.

## Decisions

### 1. Small shared presentation helpers

Introduce internal helpers under `Sources/Macus/Client` or `Support` for headings, aligned label/value sections, contextual support/connection states, human durations and byte sizes, and next-command blocks. Use dedicated report builders for startup, runtime, doctor, client and host capabilities so labels and omission rules remain deliberate. Preserve full paths and failure details, escape untrusted terminal controls using the existing safety boundary, and quote arguments when constructing copyable shell commands. Never convert missing capability data to unsupported or invent readiness from host support. Unknown optional fields can be omitted from human summaries while required missing observations are labelled unavailable; JSON retains its fields.

Optional subtle heading/status styling is selected per output stream, only for capable TTYs and with no `NO_COLOR` key present. Text statuses convey the meaning when styling is absent. Use an ASCII-compatible fallback for bars/status markers; decorative glyphs are unnecessary. Final reports wrap long values naturally rather than truncating paths or commands.

An expanded generic dictionary renderer was considered. It cannot reliably choose meaningful labels or distinguish host capabilities from live workload capabilities. A full TUI framework was also considered: [SwiftTUI](https://github.com/SwiftTUI/swift-tui) owns view layout, input, focus and terminal drawing, which this short-lived command does not need. Reuse Foundation/Darwin and the current renderer; keep `Package.swift` dependency-free and `MacusCommand` minimal.

### 2. Outcome-first doctor report

Doctor retains its read-only requests and readiness/exit rules. Report an outcome computed from those existing checks, then Runtime, Host support, Workload support and Guest health sections. Show state, selected endpoint, formatted uptime and last error; host architecture/virtualization; observed container/OCI/VM/nesting/sharing support; Incus version, KVM and guest health protocol. Keep host-supported nesting distinct from enabled workload VM capability. Do not print an enormous API-extension list in human mode; expose its relevant interpreted capabilities and retain the full list through JSON. A missing health/capability response appears as Unavailable, never as a pass or a false boolean.

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

Use a compact single live line, with completed/skipped stage messages preserved in scrollback. Representative forms:

```text
Starting Macus
  [done] Checking host
  [done] Preparing appliance

  [#####----] 5/9 stages | Booting Linux (1m 12s)
```

During acquisition, add or substitute a measured byte bar (`128 MiB / 256 MiB, 50%`) when a positive trusted total is available. Unknown-length downloads show transferred size and activity only. Validate/clamp display arithmetic for invalid or over-total counters without changing underlying measurements. Waiting stages use readable labels and human elapsed time; guest details map known phase names to readable wording and escape unknown details. The expected kernel reboot is explicitly named as an ongoing wait.

Sample elapsed/animation refreshes at a bounded cadence (no more than ten redraws per second), with immediate important transitions. A cancellable sink-owned refresh task can animate during stages with sparse events; it reads the most recent observation and elapsed duration, never synthesizing readiness or guest phases. Refreshing does not extend startup's deadline. Stop and await that task before final output.

### 5. Serialized stream finalization

Serialize renderer state and the actual stderr write together. A finalization method stops refresh, clears/terminates the active line, restores the cursor and disables further events. Invoke it before writing the success object/summary; retain an idempotent deferred cleanup for exceptions. Error rendering happens only after cleanup has completed. Do not share mutable presentation state outside its concurrency boundary. Keep writes ordered when sink callbacks come from download, runtime polling and client installation concurrently.

A normal return must leave the success summary on a new line; a failure leaves the failed stage/recovery information. Cancellation continues to preserve disks and any still-running runtime, with exit 130. Unify client-install progress presentation and ensure the bounded subprocess diagnostic output already forwarded by `IncusClientService` is readable text with deliberate newline handling; never mingle subprocess output with a live animated row.

### 6. Terminal width and plain logs

Read stderr width via Darwin terminal sizing, allow an injected width in tests, and re-evaluate on refresh so resize does not require global signal ownership. Bound live text to the available cell width with a conservative margin; prioritize the stage/status, remove detail or shrink the bar before falling back to a compact line. Use a conservative default when sizing fails; if a safe single line cannot be established, fall back to plain output. Account for display width rather than byte length for dynamic non-ASCII strings. Do not erase unrelated rows after resize.

In plain mode, emit state/detail transitions immediately and otherwise report at most one repetitive byte/elapsed update every five seconds. Preserve distinct expected-reboot changes and final/failure events. `--json` still selects plain stderr progress unless `--progress none` is supplied. JSON disables all styling; redirected stderr and `TERM=dumb` disable cursor operations. `NO_COLOR` affects styling, not animation capability or explicit text status.

## Risks / Trade-offs

- Stage sizes differ greatly → label the bar as stages, use measured bytes only for acquisition and never advertise a time-based percentage or ETA.
- stdout/stderr capture can interleave independently → flush/finalize stderr before the single stdout summary; test merged streams through an actual pseudo-terminal.
- Concurrent callbacks or timer shutdown could redraw after summary → serialize writes and close the sink before final emission; cover late events and idempotent cleanup.
- Width/Unicode may cause wrapped stale rows → use display-cell budgeting, narrow fallback and resize tests; leave final paths untruncated.
- Changing default capabilities affects scripts → mark the presentation break explicitly, migrate repository JSON consumers and document both accepted `--json` placements.
- Fixtures could be mistaken for VM acceptance → label examples and terminal checks as presentation evidence, retain separate opt-in hardware gates.

## Migration Plan

Implement on `feature/readable-cli-output` from develop after planning review. Update machine consumers before relying on new default capabilities output. Run presentation tests, pseudo-terminal/redirected executable acceptance, canonical native checks and strict OpenSpec validation. Preserve current service, disks, clients and package install while testing terminal fixtures. Present the implementation for review without merging or publishing packages. Rollback reverts presentation code/docs and JSON consumer invocation changes together; runtime schemas and data require no migration.
