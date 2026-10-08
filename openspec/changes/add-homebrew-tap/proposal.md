# Proposal

## Why

The current isolated source installer cannot prove the experience of a user installing Macus through Homebrew. A tap with prebuilt bottles will let testers exercise installation, first startup, upgrades and removal without a Swift toolchain, while keeping development distribution distinct from a production release.

## What Changes

- Add a Macus formula and reproducible ARM64 bottle workflow, with macOS 15+ restrictions, actual checksums and source-commit provenance. Contributors can still build from source with Swift 6.4.
- Provide a local Git tap rehearsal before publication, then populate the existing public Upmaru tap repository and prepare an immutable development artifact publication path. Shared identity is `upmaru/tap`, backed by `upmaru/homebrew-tap` (`git@github.com:upmaru/homebrew-tap.git`), created by the user.
- Preserve the virtualization entitlement through bottle creation and installation; verify the installed executable. Initial test bottles use clearly documented ad-hoc development signing. Developer ID signing and notarization remain future production work.
- Keep installation passive and `macus start` responsible for the per-user service. Use a verified stable Homebrew executable path for new registrations and document an explicit stop/unload/start sequence for upgrades and removal.
- Add packaging checks and separately opted-in hardware acceptance using the actual Homebrew-installed binary, isolated runtime state and Incus configuration. Preserve data and diagnostics on failure and uninstall.
- Document the commands for local rehearsal and eventual `brew install upmaru/tap/macus`, plus supported bottle coverage, dependency behavior and distribution limitations.

## Capabilities

### New Capabilities

None; delivery belongs to the existing `service-delivery` capability.

### Modified Capabilities

- `service-delivery`: Homebrew formula/bottle delivery, artifact integrity, local install rehearsal and acceptance; stable service paths across Homebrew upgrades.

## Impact

- `Packaging/homebrew`, packaging automation, README and packaging/development/acceptance documentation.
- `Sources/Macus/Client/MacusStart.swift` and service identity checks where Homebrew's stable opt path and versioned Cellar path differ; relevant Swift regressions.
- `Integration/scripts` and packaging/acceptance fixtures; retain the canonical native checks and strict OpenSpec validation.
- Macus artifact CI and a separate tap repository with formula checks and bottle metadata. No tap repository or release is created by this proposal.
- Testers need Homebrew on a supported Apple Silicon Mac, network access for the existing pinned Alpine appliance and the standard Incus client. The bottle install has no Swift build requirement. Incus remains optional at package-install time and is installed/configured explicitly by existing startup behavior.
- No guest image changes, workload API changes, Elixir server, Docker compatibility layer, automatic appliance upgrade or GUI are included.
