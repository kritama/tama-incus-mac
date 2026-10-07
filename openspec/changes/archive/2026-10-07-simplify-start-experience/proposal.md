# Proposal

## Why

Trying Macus currently requires downloading and verifying an image, preparing a seed, running a foreground daemon, calling the create API with curl, starting the guest, and separately configuring Incus. A user should be able to run `macus start` and watch those steps complete until the standard Incus client is usable.

## What Changes

- Add a high-level, idempotent `macus start` that performs host preflight, verified appliance acquisition, per-user background service setup, first-time runtime creation, guest provisioning, live readiness checks, and standard Incus client installation/remote registration.
- Package the guest bootstrap payload and trusted, versioned Alpine image catalog with Macus so first use does not require a source checkout, host Python, GnuPG, Swift, hand-written JSON, curl, or a second terminal.
- Show real stage progress, download byte counts when available, and elapsed waiting time. Provide terminal, plain-text, and quiet rendering with a clean final JSON result.
- Recognize the expected first-provisioning kernel shutdown and perform one bounded, recorded restart automatically; fail visibly on unexpected exits or unavailable qualified packages.
- Resume verified preparation after interruption, preserve all runtime/data disks on failure, and reject competing starts without weakening daemon ownership.
- Reuse existing runtimes and matching Incus remotes without changing resources, storage backends, default remotes, or root images.
- Use `upmaru/macus` as the repository and artifact/documentation identity and `com.upmaru.macus` for new startup-managed service registrations. Detect legacy service registrations rather than activating competing agents.
- Keep `serve`, `runtime start/stop/restart`, `doctor`, and `client setup` as explicit lower-level tools. Installing the Macus executable remains a separate prerequisite; automatic appliance upgrades and signed/notarized release delivery remain future work.

## Capabilities

### New Capabilities

- `startup-bootstrap`: The end-to-end first-use and repeat-start contract, standard Incus client readiness, bounded recovery, and truthful terminal progress.

### Modified Capabilities

- `linux-appliance`: Authenticated acquisition using a shipped trusted catalog, packaged seed resources, and boot-scoped provisioning progress.
- `runtime-lifecycle`: Bounded recovery of the expected first-provisioning kernel shutdown while retaining live readiness and existing mutation semantics.
- `incus-transport`: Read-only boot progress and a bounded optional start-request time budget.
- `service-delivery`: Automatic per-user background service activation through the high-level start command, service identity/isolation, and bootstrap observability.

## Impact

Implementation will primarily affect `Sources/Macus/Client`, new library-owned bootstrap and progress components, `Sources/Macus/Guest`, runtime lifecycle/API status reporting, persistence, packaged guest resources, and launchd packaging. Apple VZ code remains in `Sources/Macus/Virtualization`; the executable remains minimal. Relevant tests, integration acceptance tooling, README, CLI and packaging documentation will change.

First use may download the pinned Alpine base and signature-verified guest packages, install the official Incus Homebrew formula when Homebrew already exists, and register a per-user service and named Incus remote. It will not install Homebrew, require sudo, expose a management TCP listener, share host directories by default, or implement Incus workload commands. The proposed initial renderer has no new SwiftTUI dependency.
