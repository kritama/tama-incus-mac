# Spec Delta

## MODIFIED Requirements

### Requirement: Truthful progress

Start SHALL identify preflight, acquisition, verification, preparation, service activation, runtime creation, guest provisioning, readiness, and client setup as pending, active, complete, failed, or skipped, using readable stage names. It SHALL show byte progress only when measurable, elapsed waiting time otherwise, and distinguish the expected reboot. It MUST NOT show success based only on process launch, progress markers, or cached readiness.

#### Scenario: Download with unknown length

- **WHEN** the server does not supply a trustworthy content length
- **THEN** progress shows downloaded bytes and activity without inventing a percentage or completion estimate

#### Scenario: Slow guest provisioning

- **WHEN** guest packages are still being installed
- **THEN** progress shows the observed provisioning stage and elapsed time while runtime readiness remains false

### Requirement: Terminal and machine output

Start SHALL support --progress auto|plain|none. Auto SHALL animate a stage progress bar only on a capable interactive stderr terminal; plain output SHALL preserve readable stage transitions without cursor escapes. --json SHALL disable animation and write one final result object to stdout, keeping progress on stderr. Renderers SHALL restore terminal state and finish the progress line before final results or errors after success, error, timeout and interruption.

#### Scenario: Redirected output

- **WHEN** start runs with stderr redirected or TERM=dumb
- **THEN** it emits plain progress without ANSI animation or raw guest/subprocess output

#### Scenario: Machine-readable result

- **WHEN** macus start --json --progress none succeeds
- **THEN** stdout contains one JSON result with runtime readiness, live capabilities, selected state, remote, and resolved client path

#### Scenario: Progress disabled

- **WHEN** start is run with --progress none
- **THEN** progress is absent while final results or errors remain available

## ADDED Requirements

### Requirement: Stage-based startup bar

The interactive bar SHALL identify resolved stages out of nine, counting complete and skipped stages once each. It MUST NOT imply elapsed-time percentage or ETA. Unmeasured active stages SHALL show activity and elapsed time. Overall completion SHALL require a successful live-ready, connected result. A known-length acquisition SHALL additionally show bounded measured byte progress; unknown-length acquisition SHALL omit percentage.

#### Scenario: Reused runtime

- **WHEN** acquisition, verification, preparation or runtime creation is skipped for an existing runtime
- **THEN** skipped stages advance the resolved-stage count without appearing to perform downloads or recreate disks

#### Scenario: Overlapping readiness and provisioning

- **WHEN** readiness begins and later provisioning updates are observed
- **THEN** the bar preserves stage states without double counting or treating event order as percentage of work done

#### Scenario: Download progress

- **WHEN** acquisition reports a positive trusted total byte count
- **THEN** the display includes human-readable completed/total sizes and a measured bar/percentage bounded from zero to one hundred, whose completion does not mark overall startup ready

#### Scenario: Expected kernel reboot

- **WHEN** the expected provisioning reboot is observed
- **THEN** the active display names that reboot as an ongoing wait, retaining elapsed time and the unresolved readiness stage

### Requirement: Ordered progress finalization

Progress writes SHALL be serialized. Before final result/error emission, refresh activity SHALL stop, the active line SHALL be cleared or terminated, and cursor state SHALL be restored. Cleanup SHALL be idempotent. Completed/skipped stages SHALL leave readable scrollback; failures SHALL preserve their stage and recovery guidance. Cancellation SHALL retain the existing runtime/data preservation behavior and exit status 130.

#### Scenario: Successful stream ordering

- **WHEN** animated startup finishes and stdout and stderr share a terminal
- **THEN** the final summary begins on a fresh line after progress finalization, without concatenated progress text or subsequent redraw

#### Scenario: Interrupted startup

- **WHEN** startup is interrupted or times out while an animated wait is visible
- **THEN** the terminal is restored before the failure message, progress stops, and the report states retained runtime status and available explicit stop guidance

### Requirement: Width-aware and restrained progress

Interactive progress SHALL fit the current terminal width using shorter labels or a compact fallback, and SHALL adapt to resize. Plain progress SHALL report state/detail transitions promptly while throttling repetitive byte/elapsed updates. NO_COLOR SHALL suppress color without suppressing useful progress. Output SHALL remain understandable using text alone.

#### Scenario: Narrow or resized terminal

- **WHEN** a terminal shrinks during startup or its width is unavailable
- **THEN** progress uses a safe compact display without wrapping stale animated rows or overwriting unrelated output

#### Scenario: Long redirected wait

- **WHEN** a stage emits many equivalent waiting or byte updates with plain progress selected
- **THEN** the log preserves important transitions and periodic progress without printing every animation refresh

### Requirement: Native Noora step presentation

Startup stages SHALL use Noora progress-step components for activity, completion and failure. The adapter SHALL preserve native step markers and elapsed-time presentation while keeping skipped-stage meaning, stage accounting, stream selection and terminal cleanup explicit.

#### Scenario: Native step completion

- **WHEN** an observed startup stage completes or fails
- **THEN** it leaves one intact native Noora completion or failure row rather than a raw bracketed state string

#### Scenario: Terminal without automatic carriage return

- **WHEN** stdout and stderr share a terminal whose linefeed does not return to column zero
- **THEN** completed steps and the final report start at the left margin, without joined rows or clipped prefixes

#### Scenario: Late native callback

- **WHEN** a component or refresh callback arrives after its stage resolves or after finalization
- **THEN** it cannot redraw an obsolete active row or overwrite completed scrollback or the final report
