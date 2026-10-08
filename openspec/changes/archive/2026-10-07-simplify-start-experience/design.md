# Design

## Context

See proposal.md for the first-use problem. The implementation already has a native VZ daemon, a private Unix control API, atomic staged runtime creation with manifest verification, live guest health checks, and standard Incus client setup. It does not have an appliance downloader, seed preparation in the installed distribution, service activation, or a startup coordinator.

Relevant existing surfaces:

- `MacusCLI` resolves state, parses flags, and performs client setup; its setup helper currently cannot be reused independently.
- `GuestImageManager` verifies a local manifest/root digest and copies the image into owned runtime storage.
- `RuntimeService.startLocked` currently fails on every guest exit before readiness, including the expected first kernel shutdown.
- `verify-appliance.py` verifies an Alpine OpenPGP signature with a pinned signer; `prepare-appliance.py` generates a NoCloud ISO through macOS hdiutil.
- `Integration/guest/bootstrap.sh` installs Incus and the qualified kernel/ZFS pair, registers continuation, then may emit `TAMA_ZFS_KERNEL_REBOOT_REQUIRED` and power off.
- Packaging installs an entitled executable without activating a service; the current template uses `com.kritama.macus`.
- Completed changes `tim-client`, `zfs-default-storage`, and `rename-to-macus` have not been archived/synced into all main specs. The implementation and those completed deltas must be considered when reconciling this plan; their historical artifacts are not edited by this proposal.

All new repository links, metadata, and any future Macus-hosted assets belong to [upmaru/macus](https://github.com/upmaru/macus). Official Alpine image/package origins and the official Incus formula remain upstream sources.

## Goals / Non-Goals

**Goals:** An installed executable can safely bring one selected runtime and named Incus client remote to usable readiness, return control to the shell, and show meaningful progress. Use the existing runtime/Incus contracts and preserve data through every retry.

**Non-Goals:** Installing/upgrading the Macus executable itself, installing Homebrew, a release/Homebrew publishing pipeline, automatic root-image replacement, backend migration, a full-screen dashboard, workload wrappers, management HTTPS/TCP, or a GUI application. These do not block this first-run improvement.

## Decisions

### 1. Make start an explicit high-level coordinator

Add `macus start [--remote NAME] [--set-default] [--incus ABSOLUTE_PATH]`, using existing global state, timeout, and JSON options plus `--progress auto|plain|none`. Fresh creation uses the current CPU, memory, disk and share defaults, with nesting enabled only where supported; an existing runtime always retains its saved settings. The fresh readiness limit is 1800 seconds to cover initial provisioning, while existing saved limits remain unchanged. Resource customization continues through the existing stopped-state configuration API in this change.

Place orchestration in library-owned `Sources/Macus/Bootstrap`; keep argument dispatch small and VZ calls behind existing library interfaces. Extract the client resolver/registration logic into a reusable service instead of running a recursive Macus subprocess or duplicating Incus configuration logic. No wholesale argument-parser migration is needed.

A startup context contains a monotonic overall deadline, cancellation token, operation ID, selected paths, and typed progress sink. Proposed start default: 1800 seconds, with the existing integer timeout range 1...3600. Existing command defaults stay unchanged. Every network request, subprocess, API call, readiness wait, and retry receives the remaining budget. The high-level command supplies remaining seconds in an optional POST start body; the daemon bounds the entire boot, including driver startup and the expected reboot, by the smaller of this budget and its saved readiness limit. Empty start bodies keep the existing contract. Timeout never silently forces a running guest off; it revokes readiness and reports observed state.

The coordinator performs preflight, takes a distinct bootstrap lock, queries existing service/runtime state, prepares an appliance only for absent state, ensures service availability, creates if absent, starts and checks live readiness, then runs standard client setup/connectivity. Cheap client/remote checks happen during preflight when a client already exists so known conflicts fail early. Final success requires both runtime and client readiness.

Alternative considered: making `runtime start` create everything implicitly. Keeping its explicit API role preserves script contracts and provides a clear debug path.

### 2. Ship a trusted catalog and seed payload; download the existing Alpine base

Use a versioned catalog compiled into the Macus library. Each supported entry records the exact upstream archive URL and name, archive SHA-512, raw SHA-256, expected archive member and size bounds, architecture, catalog/manifest/helper versions, guest payload revision, qualified package/kernel revisions, and upstream signer fingerprint/provenance.

Initially retain the existing qualified ARM64 EFI Alpine cloud-init metal base and current stable-branch bootstrap. Populate real digests only after running the existing upstream signature verification with the pinned signer in maintainer tooling; keep that provenance reviewable in `upmaru/macus`. Do not trust freshly downloaded sidecar checksums, use a mutable latest URL, or invent digest values. Catalog updates are reviewed code changes paired with acceptance evidence.

The installed command verifies pinned digests using CryptoKit. It does not need a host OpenPGP implementation because the shipped catalog binds bytes already authenticated during catalog preparation. This preserves the existing trusted upstream-signature chain while removing GnuPG from the user's first-run prerequisites. Development/source installs trust their built catalog in the same way they trust the built bootstrap code; signed/notarized binary distribution remains separate work.

Embed the versioned guest scripts and seed templates into the library so a copied installed executable does not depend on a checkout or an uninstalled SwiftPM resource bundle. A checked generator/synchronization check can derive these embedded resources from `Integration/guest`, preventing two independently maintained bootstrap implementations. Use Foundation and the native `/usr/bin/hdiutil` utility to generate the ISO, with fixed arguments and private paths.

Use Foundation download APIs with streaming file writes and real byte callbacks. Stage under the selected private state, cap download/extraction sizes, validate exactly one regular `disk.raw` member with no links/traversal, and use macOS archive tooling with fixed arguments or a bounded native reader. Publish completed image, manifest, seed and provenance atomically. Existing `GuestImageManager` remains the final root digest/copy boundary. A complete cache is rehashed before reuse; partial downloads are discarded/retried rather than relying on unproven HTTP range resumption.

Alternative considered: immediately publishing a custom preprovisioned Macus disk. It can reduce startup time and dependency on guest package repositories, but introduces an image build/signing/release pipeline. This change automates the current qualified base and provisioning first; a compatible prebuilt artifact can later use the same catalog contract.

### 3. Use per-user launchd and keep service ownership explicit

For a default selected state, generate a private `~/Library/LaunchAgents/com.upmaru.macus.plist` with an absolute installed binary path and explicit state directory. Bootstrap it in the current user's launchd session. It may start the control daemon at login, but must not automatically boot Linux on login. No sudo or GUI application is required.

For an explicit nondefault state, derive a deterministic `com.upmaru.macus.<state-hash>` label and keep its plist/logs beneath that isolated state. Bootstrap that service for the current session without installing a login-persistent default LaunchAgent. Validate labels, paths, ownership, plist escaping, and endpoint length before activation. Surface session-policy or launchctl failures with actionable diagnostics.

Probe an existing endpoint through the existing same-UID checks and validate its API/bootstrap capability before reuse. A compatible foreground daemon is reusable and is reported as foreground-owned: closing its terminal will still stop it. Do not seize its lock or install another daemon. An outdated daemon must be stopped by the owner and restarted with the compatible binary.

Inspect existing new and legacy service registrations and validate their executable/state arguments. Reuse compatible services serving this state; reject foreign/conflicting registrations and dormant legacy agents that could race startup. Never silently unload a user-owned service, replace a conflicting plist, or start both old and new labels for one state. Historical `com.kritama.*` and older names are migration detection inputs only; new labels and current branding use Upmaru.

Alternative considered: detach `serve` directly. launchd provides known supervision and log ownership without ad-hoc process management. The existing foreground mode remains available for development.

### 4. Keep bootstrap ownership separate from daemon ownership

A private advisory `bootstrap.lock` protects the coordinator's catalog/cache/seed/service preparation and prevents two high-level starts from racing. The existing daemon lock continues to protect the runtime and sockets. The CLI does not instantiate StateStore or take the daemon lock while preparing images.

A small versioned bootstrap journal records selected catalog/payload identity, completed preparation, operation observations and the one-time kernel-transition allowance. Completed artifacts are checked against disk and hashes rather than trusted solely because a journal says complete. The daemon owns runtime configuration and the expected-reboot allowance; the coordinator never edits data/root disks after creation.

Failure before creation can remove only coordinator-owned temporary files. Failure after creation retains all runtime files. Incomplete configuration commits remain an explicit recovery error, matching `GuestImageManager`'s data-preserving behavior. A cancelled start releases its lock and terminates its direct download/subprocess work; it does not force-stop a VM. If a dispatched daemon boot is still running, the result names that state and gives the explicit `runtime stop` command. A repeated start observes an active daemon mutation and returns conflict rather than dispatching another boot.

### 5. Handle the expected reboot inside the runtime mutation gate

Extend RuntimeService's boot loop to recognize a versioned expected-kernel-transition observation emitted by the trusted packaged bootstrap. Track the current boot's serial offset/generation so historical lines cannot authorize a restart. Accept the signal only for a fresh catalogued bootstrap, wait for actual guest stop, durably consume its one-time allowance, then restart the same runtime within the remaining readiness/start deadline.

The boot generation, cancellation checks, explicit force-stop behavior, and mutation gate must cover both boots. Unexpected exit without a current signal, a second signal, failed durable bookkeeping, or an expired deadline remains failure. A lost daemon cannot reuse persisted ready evidence or replenish the allowance.

Guest markers are advisory progress and narrowly bounded reboot evidence, never live authentication or Incus readiness. Do not parse arbitrary log text into commands, resources, or package substitutions. Preserve the current qualified-package failure and existing-filesystem refusal semantics.

Alternative considered: catch every exit in the CLI and retry. That would conceal crashes, race another mutation, and let old serial output trigger loops.

### 6. Render typed progress events without a TUI framework initially

A typed Sendable progress event records operation/stage, stage state, elapsed time, optional completed/total bytes, safe detail, and optional error code. The coordinator emits host stages; the daemon exposes guest phase through an additive private progress/status response while a start request is pending. Prefer a small `GET /v1/runtime/progress` snapshot with a versioned response; poll concurrently with the long start request through independent control connections. Keep the existing readiness state model and socket authentication.

Guest scripts emit a small versioned allowlist of serial observations for provisioning stages. Consume current-boot observations incrementally with bounded buffers; omit arbitrary serial contents and raw package output from user progress. Existing private serial logs remain the detailed debugging channel. Unknown marker versions do not create false precision; show the generic provisioning wait instead.

Use a compact stage display on interactive stderr with a spinner, actual download bytes/percentage only when total length is known, elapsed time for indefinite stages, and clear skipped/failed states. Do not produce a single invented overall percentage. `TERM=dumb`, redirected stderr, `--progress plain`, and JSON mode use stable plain stage lines without cursor controls; `--progress none` suppresses progress. Stdout is reserved for the final human summary or one JSON result.

Keep rendering behind a sink so orchestration can be tested without a terminal. Use bounded refresh frequency and restore any hidden cursor/terminal attributes in all exit paths. Errors and installation output are sanitized and bounded.

[SwiftTUI](https://github.com/rensbreur/SwiftTUI) offers SwiftUI-like layout, state, scrolling, buttons and input controls. Those suit a future interactive dashboard; first-use progress requires no selection or form input. A small renderer keeps this change compatible with strict Swift 6, scripts, existing stream capture, and the minimal dependency footprint. Introducing SwiftTUI now would still require the plain/JSON renderers and a concurrency/terminal-cleanup compatibility qualification.

### 7. Complete the client contract without hijacking shell configuration

Reuse Incus from an explicit absolute override or PATH; otherwise use the existing official Homebrew formula path and bounded runner. Start's explicit request authorizes this installation. Preflight reports missing Homebrew; it never installs Homebrew, runs a shell installer, invokes sudo, or changes unrelated formulae.

Register remote `macus` unless overridden, honor `INCUS_CONF`, preserve conflicting/unrelated remotes, and change the user's default only with `--set-default`. Ask the real Incus client to verify connectivity after live readiness. The result includes the resolved executable path and a copyable `incus list macus:` command. If Homebrew's bin directory is not on PATH, show the actual executable command and PATH guidance; do not rewrite shell profiles.

A client failure leaves a ready runtime intact and start unsuccessful. A retry reuses that runtime. `client setup` remains independently callable and retains its readiness-before-install behavior.

## Risks / Trade-offs

- [First boot depends on Alpine package availability and networking] → Keep fixed qualified revisions, bounded waits, stage diagnostics, and data preservation. Never silently substitute another kernel/backend; unavailable pins require a reviewed catalog/bootstrap update.
- [Compiled trust pins can age] → Store exact provenance, validate catalog/resource synchronization, and qualify every changed image/payload revision before enabling it.
- [Serial observations can be stale or noisy] → Use versioned allowlisted markers, per-boot offsets/generations, a durable one-time allowance, actual stopped-state checks, and live helper/API readiness.
- [launchd and terminal behavior differ from fixture behavior] → Record explicit isolated hardware acceptance separately, including terminal close, service restart, and observed progress.
- [Old daemons and unsynced completed spec changes can conflict] → Require bootstrap feature compatibility before reuse and reconcile the existing completed deltas during spec synchronization; retain only explicit compatibility references to legacy branding.
- [Incus installation can be slow or unavailable] → Use the shared deadline, show active installation/wait stages, and distinguish client failure from runtime readiness.
- [Cancellation races with a daemon-owned boot] → Report observed runtime state, preserve data, retain the force-stop mutation gate, and do not claim the guest stopped merely because the CLI exited.

## Migration Plan

1. Implement additively on `feature/start-experience`; canonical build/unit/fixture/install and strict OpenSpec checks must pass before hardware acceptance.
2. Keep existing state-path precedence (`--state-dir`, MACUS_STATE_DIR, TIM_STATE_DIR, legacy default) and persisted runtime formats. Do not rename/move data, storage identifiers, or existing remotes.
3. Update the current launchd template/logging identity to Upmaru as part of implementation; document explicit transitions for legacy agents. Reconcile completed Macus/client/storage deltas with the new plan when syncing/archiving specifications, without rewriting historical evidence.
4. Validate the installed binary from an arbitrary directory with the checkout unavailable, then run opt-in actual first-use acceptance in fresh isolated state/prefix/client configuration and a session-only isolated agent.
5. Replace the README's primary manual first-run instructions with `macus start` once implemented and accepted; keep the existing prepared-appliance/API route as an advanced debug procedure.
6. Rollback means returning to the previous executable and manual commands after explicitly unloading only the newly owned agent if needed. Do not roll back by deleting disks, replacing root images, or changing Incus schemas. No publication or merge is part of this planning request.
