# Design

## Context

See `proposal.md` for motivation and the `service-delivery` delta for observable requirements. The checkout has one SwiftPM executable, Swift tools version 6.4, deployment target macOS 15 and no third-party Swift dependencies. `Packaging/install-local.sh` already builds, ad-hoc signs and verifies the virtualization entitlement. It accepts an isolated prefix and rejects symlink destinations; it should remain a source-install tool rather than being called against Homebrew's symlinked opt prefix.

`Packaging/homebrew/README.md` currently defers all formula publication. Some of its prerequisite wording predates the now-embedded, verified Alpine catalog and guest payload. `Sources/Macus/Bootstrap/ApplianceCatalog.swift` and `EmbeddedGuestPayload.swift` allow the installed executable to run outside the checkout; there is no need to ship a prepared VM disk.

`macus start` owns the launchd registration. `currentExecutablePath()` in `Sources/Macus/Client/MacusStart.swift` calls `realpath`, so an invocation through Homebrew's bin/opt links becomes a versioned Cellar path. Startup currently compares launchctl executable and argument strings exactly. Removing an old keg can leave a registration pointing at a missing executable. Existing conflict, ownership and isolated-service rules must survive the fix.

The native CI uses the `xcode-27` runner and does not build bottles. There are no local release tags. The user has created `upmaru/homebrew-tap` at `git@github.com:upmaru/homebrew-tap.git`. The public tap scaffold is now merged into main through tap PR #1. Use this existing repository; repository creation is no longer required.

## Goals / Non-Goals

**Goals:**

- Make a locally generated candidate installable through real Homebrew, with evidence that a bottle was poured and no Swift build ran on the tester's machine.
- Reuse that formula and artifact contract for a shared tap after local qualification.
- Qualify installation separately from guest behavior and preserve state through package changes.

**Non-Goals:**

- Developer ID signing, notarization, core/cask submission, automatic guest upgrades, or an automatic daemon restart during package upgrade.
- A second service supervisor or new workload operations.
- Bundling Incus, Homebrew, a Linux root/data disk, or the previously discussed Elixir/Docker work.

## Decisions

### 1. Source formula with Homebrew bottles

Maintain the Ruby `Macus` formula template in `Packaging/homebrew/Formula/macus.rb.in` as the canonical definition. Candidate generation pins its bytes to the clean source revision and emits an installable `Formula/macus.rb` with measured metadata. Export the completed formula to the tap without separately maintained install logic. It builds one release executable using SwiftPM, installs it into its keg, applies `Packaging/virtualization.entitlements` after build-time modification, and verifies signature and entitlement. Declare macOS 15+ and ARM64 constraints and the build-only Swift/Xcode prerequisite; fail early with the required compiler version if the selected toolchain cannot parse the package.

Build bottles through Homebrew's standard `brew install --build-bottle` and `brew bottle --json` flow. Use the resulting metadata and actual digests rather than hand-constructing archives or hashes. Verify signatures both before packaging and after pouring: any relocation/re-signing behavior must preserve the entitlement. Keep `brew test` limited to installed help, host capabilities and signature checks; it must not start a service or VM. No `service do` stanza in this milestone: caveats point users to `macus start`.

A source-only tap would not meet the user's confirmed toolchain-free install preference. A custom binary-only formula would duplicate Homebrew's bottle handling. A cask is unnecessary for the existing command-line source project. Source installation remains available to contributors and is explicitly distinguished from bottle acceptance.

### 2. Pinned development candidates before stable releases

Generate each candidate from a clean, committed source revision. The artifact manifest records the full commit SHA, development package version, source archive SHA-256, bottle SHA-256, architecture, bottle OS tag, toolchain, deployment target and signing mode. A development version derived from the candidate identity must sort predictably for upgrade rehearsal and must not be presented as a stable version. Formula checksum fields are populated only from artifacts already generated and verified; a non-installable template must never be exported as a published formula.

Use local generated source archives and bottle URLs for rehearsal. The shared tap uses immutable HTTPS source/bottle assets with a revision-specific candidate identifier, for example a clearly labelled GitHub prerelease. A formula update references the uploaded bytes, is checked against downloaded assets, and is reviewed before tap publication. Do not use moving `develop` archive URLs, mutable `latest` downloads, `--HEAD` as the normal install, or replacement assets under an existing version. This workflow guarantees traceable inputs and verification, not bit-for-bit reproducibility of signatures.

Local ad-hoc development signing is sufficient for the first opt-in test milestone, subject to actual installed-binary acceptance. Do not strip quarantine, disable Gatekeeper or claim notarization. If remote distribution is blocked by macOS security policy, record the failure and retain local acceptance; production signing remains a separate change rather than silently bypassing policy.

### 3. Local and shared taps use the same artifact contract

Provide packaging commands that generate an output Git tap under ignored `.integration/` or an explicit disposable output root. Register that local repository with an explicit local tap identity/URL, generate the formula's local source and bottle URLs, then install the fully qualified formula through Homebrew. The tap rehearsal must confirm installation receipt/bottle metadata and installed keg path. Homebrew mutations require explicit rehearsal opt-in and must not be added to the default native check script.

The local tap uses a distinct name such as `upmaru/macus-local`; it must not shadow an installed shared `macus`. Both formulae install the same command and rack name, so do not promise side-by-side installation. Refuse conflicts instead of automatically unlinking, uninstalling or overwriting an existing package. A clean account separates runtime and user services but shares a machine-wide Homebrew installation; if Macus is already installed there, use a dedicated test Homebrew environment or a clean test Mac. Custom Homebrew prefixes and bottle relocation must themselves pass validation before use.

The existing remote repository is `upmaru/homebrew-tap` (`git@github.com:upmaru/homebrew-tap.git`), with formula to be added at `Formula/macus.rb`, tap README and native ARM64 formula checks. Users eventually run `brew install upmaru/tap/macus`; direct installation also adds the tap. Keep local artifact URLs out of the exported shared formula. Prepare the tap payload locally before any authorized push, checking for new remote contents before initializing its first branch. Source development stays on `feature/*`; candidate publication does not finish a Git Flow feature or release.

### 4. Validated stable service path with explicit transitions

For a Homebrew-installed process, derive the corresponding absolute `opt/macus/bin/macus` path from the verified installed keg/prefix relationship, not from an arbitrary PATH entry or environment override. Use it only when it resolves to the current entitled executable. For ordinary source installs, retain the existing physical executable path.

Separate the stable path recorded in arguments from physical executable identity used for checks. Accept launchctl's resolved executable only when it equals the verified current target; keep the recorded state path and all other arguments exact, including significant whitespace. Reject foreign executable targets, incompatible state, old removed keg registrations and legacy service labels as before. Add focused regressions for both linked/physical representations and unrelated executable conflicts.

Document the upgrade sequence: stop the runtime gracefully, confirm stopped state, unload only its owned launchd job, upgrade the formula, then run `macus start` for the same state. `runtime stop` alone leaves the service registered and is not sufficient. A registered stable-path plist can be reused; an old versioned-path plist needs an explicit, reviewed transition after unload. Do not silently rewrite it. Document removal similarly: stop, unload and remove only the owned service registration, then `brew uninstall`; retain the runtime directory and Incus configuration. No post-install hook boots or restarts anything.

### 5. Two acceptance layers

Package acceptance records source revision, formula identity, installed keg, bottle digest, host platform, signature/entitlement result and `poured_from_bottle` evidence. Check installed help/capabilities, source independence, passive installation and corruption rejection. The source formula also receives syntax/style/audit checks and a build-bottle test on a build host. Add pure generator/guard regressions to ordinary checks without mutating Homebrew.

Hardware acceptance is separately invoked and uses short fresh paths such as `/private/tmp/macus-brew.XXXXXX`, a separate `INCUS_CONF`, unique remote and report outside runtime/install directories. Extend or reuse the existing startup/Incus acceptance runners, but pass the actual installed executable and record that no `Packaging/install-local.sh` or checkout binary supplied it. Cover first startup and the expected kernel continuation, live Incus connectivity, repeated start, a standard Incus workload marker, stop/unload/upgrade/start and marker persistence, then stop/unload/uninstall with state retained. A second checksummed development package revision supplies a real upgrade candidate; changing the package revision need not change the guest image. Failures retain disks, workloads and logs.

Build/validate bottles on explicitly recorded ARM64 OS targets. Start with the available local platform, then qualify compatible bottle coverage for advertised macOS 15+ versions before claiming a toolchain-free installation there. A macOS 15 deployment target alone is not evidence that a newer-host bottle is installable or runnable on 15. Never use a platform-independent bottle tag for this Mach-O executable. Record coverage gaps and source fallback prerequisites.

## Risks / Trade-offs

- [Swift 6.4 and the SDK used by the existing runner may limit older build hosts or bottle compatibility] → Test installed artifacts on advertised targets, provision suitable native build runners/toolchains, and publish only verified bottle tags.
- [Homebrew relocation or signing changes the signature/entitlements] → Verify the poured binary and fail promotion on lost entitlement; avoid false relocatability declarations.
- [A stable link changes while an old daemon is running] → Require the documented stop/unload sequence, compare physical identity and state, and do not restart during package operations.
- [Machine-wide package installation can affect an existing user] → Refuse conflicting package installation and use a dedicated test environment where needed; runtime isolation alone does not isolate Homebrew.
- [Ad-hoc test bottles encounter Gatekeeper restrictions when fetched remotely] → Keep development limitations visible, verify actual remote installation separately and preserve production signing as future work.
- [Failed hardware runs leave services or disks] → Record owned service identity and recovery instructions; preserve data and stop only explicitly owned test services when appropriate.
- [Tap update references unqualified or changed assets] → Produce a concrete formula diff after asset checks, require matching revision/digest metadata, and publish only with the applicable user authorization.

## Migration Plan

1. Implement and validate the generator, source formula, installed-signature checks and service-path handling on `feature/homebrew-tap`.
2. Generate a committed development candidate and install it from a local tap on a dedicated supported test environment. Record package-only results first.
3. When hardware testing is explicitly authorized, run installed first-use, persistence, upgrade and removal acceptance. Keep failures and any unfinished hardware tasks visible.
4. Prepare the shared tap repository payload and immutable candidate artifact workflow for the existing `upmaru/homebrew-tap`. With publication authorization, initialize its first branch if still empty, publish verified candidate assets and formula, then verify installation from the remote tap. Preserve any contents added in the meantime. Do not merge/finish source branches or label a production release as part of this test milestone.
5. Roll back packaging by stopping/unloading the owned service and reinstalling a retained prior verified candidate. Keep root/data disks untouched. Package rollback does not imply guest schema rollback or restore an automatically changed appliance.

## References

- [Homebrew tap structure, local repositories and installation](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap)
- [Homebrew bottle creation, tags and relocation](https://docs.brew.sh/Bottles)
- [Formula build, test and service behavior](https://docs.brew.sh/Formula-Cookbook)
