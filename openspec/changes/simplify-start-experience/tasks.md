# Tasks

## 1. Shared startup contracts and client integration

- [x] 1.1 Extract reusable Incus executable discovery, installation and remote-registration services from MacusCLI without changing client setup behavior; verify existing setup, deadline, conflict and command-runner tests still pass.
- [x] 1.2 Add typed startup context/progress/result models and a remaining-budget abstraction in the Macus library; verify deterministic tests demonstrate one deadline across multiple stages and cancellation without resetting the budget.
- [x] 1.3 Add start argument parsing and preflight for state safety, remote/override validation, host support, executable entitlement and Incus/Homebrew availability; verify invalid/missing prerequisites cause no download, service mutation or runtime creation.
- [x] 1.4 Document the proposed high-level/low-level command distinction, prerequisite contract, 1800-second start default and new flags in CLI documentation; verify help/argument fixtures match the documented interface.

## 2. Trusted catalog and installed guest preparation

- [x] 2.1 Add a versioned catalog with real archive/raw digests, sizes, source URL, pinned upstream signer provenance and qualified guest revisions; verify catalog inputs through the existing signature-verification tooling and commit reviewable provenance without fabricated checksums.
- [x] 2.2 Embed generated guest scripts/templates in the Macus library and add a synchronization check against Integration/guest; verify installed resource access from an arbitrary working directory without depending on a checkout or SwiftPM resource bundle.
- [x] 2.3 Implement streamed acquisition with byte events, size/deadline bounds, safe private extraction and atomic verified cache publication; verify fixtures reject mismatched digests, truncation, extra members, traversal, links, oversize inputs and corrupt caches.
- [x] 2.4 Implement native manifest/NoCloud seed preparation using embedded payloads and bounded hdiutil invocation; verify manifest/seed contents, permissions, failure cleanup and repeated preparation against the existing guest contract.
- [x] 2.5 Document catalog refresh/provenance and cache/preparation recovery in development/appliance documentation; verify synchronization/provenance commands run as written without creating or booting a VM.

## 3. Background service ownership and bootstrap persistence

- [x] 3.1 Add private bootstrap locking, staged-preparation journal and validated recovery paths separate from StateStore's daemon lock; verify concurrent starts, interrupted preparation, unsafe ownership/symlinks and incomplete runtime configuration cannot replace disks or active sockets.
- [x] 3.2 Implement launchd service discovery and validated plist generation/activation with com.upmaru.macus identities and per-state isolation; verify fixture launchctl calls, XML escaping, stable executable/state paths, endpoint readiness waits and timeout failures.
- [x] 3.3 Implement compatible daemon reuse and legacy/conflicting service detection without implicitly unloading user services; verify foreground reuse, old-daemon incompatibility, dormant legacy conflicts and foreign ownership through fixtures.
- [x] 3.4 Update current launchd template, service logging identity and packaging documentation to Upmaru while retaining explicit legacy transition instructions; verify existing source installation remains inert and isolated-start registration cannot overwrite the default agent.

## 4. Guest progress and bounded kernel-transition recovery

- [x] 4.1 Add versioned provisioning stage/failure/reboot observations to the existing bootstrap scripts while preserving qualified packages, APK verification and storage guards; verify bootstrap continuation/storage fixture tests and marker payloads.
- [x] 4.2 Implement bounded incremental current-boot observation parsing and private GET runtime progress reporting; verify old/unknown/malformed markers, control requests during boot and progress/readiness separation through transport/runtime tests.
- [x] 4.3 Add optional validated remaining-time input to POST runtime start and bound driver startup, readiness and reboot by one daemon deadline; verify empty-body compatibility, malformed budget rejection and no saved configuration changes.
- [x] 4.4 Implement daemon-owned durable one-time expected-kernel-reboot recovery within the existing mutation gate; verify current marker plus actual guest stop triggers one restart, while stale markers, unexpected exits, second requests and bookkeeping failures do not.
- [x] 4.5 Verify force stop, caller timeout, daemon restart and cancellation around both boot attempts cannot replenish the reboot allowance or race an automatic restart; add regression fixtures that observe driver calls and preserve disk sentinels.
- [x] 4.6 Document progress API semantics, marker versioning, expected-reboot allowance and manual failure recovery; verify examples match the API and explicitly distinguish progress from live readiness.

## 5. End-to-end start coordinator

- [x] 5.1 Connect preflight, bootstrap ownership, existing-state discovery, absent-only acquisition/preparation, service activation and runtime creation; verify fixtures cover fresh, stopped, already-ready, legacy ext4/dir and partial-creation states with unchanged existing disk/config sentinels.
- [x] 5.2 Connect budgeted boot/live health and standard client setup/connectivity; verify first-use success, remote conflicts, official Homebrew installation path, explicit Incus override, isolated INCUS_CONF and a ready-runtime/client-failure retry without reboot.
- [x] 5.3 Add signal/deadline cancellation cleanup and observed-state diagnostics; verify download/direct-child termination and lock release without force-stopping existing workloads or claiming a daemon-owned boot has stopped.
- [x] 5.4 Emit final human/JSON results with live capabilities, service ownership, selected state/remote, resolved client executable and copyable next commands; verify success/usage/operational output and off-PATH client guidance through captured streams.
- [x] 5.5 Update README's primary starting experience and CLI/packaging docs after behavior exists, retaining advanced manual preparation and explicit runtime commands; verify examples use upmaru/macus and describe client conflicts, retries, prerequisites and foreground ownership truthfully.

## 6. Terminal progress presentation

- [x] 6.1 Implement a renderer independent of bootstrap logic for stage states, byte progress, elapsed time and bounded refresh; verify captured event tests never invent percentages or mark ready on process launch.
- [x] 6.2 Add auto/plain/none selection, stderr TTY/TERM detection, JSON animation suppression, terminal-safe details and cleanup; verify redirected/TERM=dumb output contains no escape sequences, JSON stdout is one object, and failure/timeout/interruption restore terminal state.
- [x] 6.3 Document and capture representative fresh-start, cache reuse, expected reboot and failed-stage output; verify a pseudo-terminal fixture exercises animation and cleanup without booting hardware.

## 7. Integrated validation and explicit hardware acceptance

- [ ] 7.1 Run Integration/scripts/check.sh and `mise exec -- openspec validate --all --strict --no-interactive`; record build/format/unit/fixture/install results separately from hardware acceptance and resolve regressions before proceeding.
- [x] 7.2 Extend the opt-in acceptance runner for actual macus start using fresh short state/prefix paths, isolated INCUS_CONF and a session-only per-state agent; verify the runner refuses ordinary user state and preserves all failure artifacts.
- [ ] 7.3 With explicit hardware opt-in, run an installed binary outside an unavailable checkout, proving verified acquisition, actual guest provisioning, observed progress, expected kernel transition, live Incus readiness and real standard-client connectivity; record actual tool versions and observations rather than mock evidence.
- [ ] 7.4 With explicit hardware opt-in, prove workload/container DNS, data persistence through runtime/service restart, terminal-close independence, repeated start/cache reuse and truthful nested capability; verify only owned smoke workloads and isolated agents are cleaned up, with all data/logs retained on failures.
- [ ] 7.5 Record a real official Homebrew client installation separately when explicitly authorized, or mark that acceptance case unrun when only a preinstalled client/fixture was used; verify the report does not claim mocked installation as hardware evidence.
- [ ] 7.6 Review the final diff and reconcile startup specs with the completed Macus/client/storage deltas during the later sync/archive workflow; verify current namespaces use Upmaru, existing compatibility/data contracts survive, and no release, merge or publication is inferred from passing unit checks.

## Review corrections

These correct defects found after the initial 7.1/7.2 checks. Hardware tasks 7.3-7.5 remain unrun.

- [x] R1 Reject unsafe acceptance report destinations before any filesystem mutation. Regressions must keep runtime sentinel bytes unchanged and must not run the executable, both without hardware opt-in and on the fixture-only hardware path.
- [x] R2 Share the original start deadline across Incus discovery, Homebrew prefix/install, registration and connectivity. Standalone client setup keeps its per-command timeout. Regressions must fail a client stage whose individually fast subprocesses together exceed the deadline, including nested Homebrew discovery.
- [x] R3 Refuse to replace a same-label service plist that names another state or executable, including from the writer itself. Matching registrations stay byte-identical and conflicts must not call bootstrap.

## Independent review checkpoint

The three initial review defects are resolved and independently reproduced as fixed. Four focused Swift regressions, four acceptance-runner tests and strict OpenSpec validation (9/9) passed after the corrections. The latest independent canonical run did not finish: commandRunnerCancellationReapsTheChild hung for more than four minutes in ProcessCommandRunner cleanup at Process.waitUntilExit, with no remaining direct child observed. Only the independently launched test helper was terminated. Task 7.1 is reopened until the cancellation hang is fixed and the full gate passes. Hardware tasks 7.3-7.5 and spec reconciliation 7.6 remain pending at this commit checkpoint.
