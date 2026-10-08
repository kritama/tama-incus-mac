# Tasks

## 1. Formula and candidate artifacts

- [x] 1.1 Add the canonical Macus source formula/template under `Packaging/homebrew`, with ARM64/macOS 15+ restrictions, build-only Swift 6.4 prerequisite, installed entitlement verification, passive install and no service stanza; verify Ruby/Homebrew style and audit checks and a source build on the selected toolchain.
- [x] 1.2 Add candidate generation from a clean committed revision, with measured source SHA-256 and a manifest containing package version, commit, toolchain, platform and signing mode; verify guards reject dirty/unidentified inputs, placeholder digests and conflicting artifact reuse without publishing an installable incomplete formula.
- [x] 1.3 Add the Homebrew build-bottle and bottle-JSON merge workflow; verify the generated formula metadata matches the actual bottle bytes and signatures/entitlements before and after pouring on the build platform.
- [x] 1.4 Add pure packaging integrity/guard regressions to ordinary checks and document local artifact generation, development signing and source fallback in `Packaging/homebrew/README.md`; verify these checks do not install packages, publish assets or boot VMs.

## 2. Homebrew service paths and package transitions

- [x] 2.1 Resolve a validated stable Homebrew opt executable for new registrations while retaining ordinary source-install behavior; verify linked invocation resolves to the current installed executable and arbitrary PATH/environment targets cannot select a service binary.
- [x] 2.2 Support verified stable/physical executable equivalence in service checks while retaining exact state/other argument checks; verify focused Swift regressions for current-keg equivalence, removed/old keg rejection, foreign executable conflicts, significant whitespace and default/isolated labels.
- [x] 2.3 Document concrete stop/status/unload/upgrade/start and stop/unload/uninstall commands, including explicit transition of old versioned plists and retained data; verify command paths/labels against generated registrations and confirm `runtime stop` is not presented as unloading launchd.
- [x] 2.4 Run the affected Swift regressions and native swift-format check after the service changes; verify the default registration is not replaced by isolated startup and existing legacy conflict checks still pass.

## 3. Local tap and package acceptance

- [x] 3.1 Add opt-in local Git tap generation and installation commands using actual local source/bottle URLs and a distinct local tap identity; verify conflicting Macus installations are refused without unlink/overwrite and generated shared-tap output rejects local URLs.
- [x] 3.2 Add an installed-package acceptance command that records keg, revision, formula, digest, host and bottle receipt; verify installed help/capabilities, signature, virtualization entitlement, source independence and absence of runtime/service creation, and fail if installation built from source.
- [x] 3.3 Add fixture checks for corruption rejection, package conflicts, protected report paths and retained failure artifacts; verify these tests do not mutate host Homebrew and their invocation is included in canonical checks.
- [x] 3.4 Document and execute the opt-in local tap bottle rehearsal in a dedicated supported package environment; verify no tester Swift invocation occurred and save a package-only report with hardware acceptance explicitly incomplete.

## 4. Installed hardware acceptance

- [x] 4.1 Extend/reuse acceptance runners for the Homebrew-installed executable with separate package/hardware flags, short isolated state, isolated `INCUS_CONF` and unique remote; verify refusal without opt-in and unsafe-path rejection using fixtures before running hardware.
- [ ] 4.2 When explicitly authorized, run first-use and repeated-start hardware acceptance from the installed bottle; verify live Incus readiness, expected kernel continuation, standard client connectivity, service isolation and no checkout binary substitution, retaining state/logs on failure.
- [ ] 4.3 When explicitly authorized, use two verified candidate package revisions for stop/unload/upgrade/start and standard Incus marker persistence, then stop/unload/uninstall; verify the marker survives upgrade and runtime/client data survives removal, with no automatic disk reset or guest image upgrade.
- [ ] 4.4 Update `docs/acceptance.md` with separate package and hardware evidence, exact candidate identities, exercised OS coverage and limitations; verify unexecuted hardware/compatibility checks remain visibly incomplete and initial ad-hoc bottles make no notarization claim.

## 5. Shared tap preparation and publication

- [ ] 5.1 Prepare a local export for `upmaru/homebrew-tap` containing `Formula/macus.rb`, README and ARM64 formula/bottle checks, plus Macus CI candidate artifact generation; verify exported formula logic matches the canonical definition and uses complete real metadata with no runtime disks/build outputs committed.
- [ ] 5.2 Qualify the bottle-platform matrix for the advertised toolchain-free install coverage, including macOS 15 where advertised; verify poured binaries actually run on each target and record gaps/source requirements rather than inferring compatibility from the deployment target.
- [ ] 5.3 With publication authorization, use the existing public `upmaru/homebrew-tap` at `git@github.com:upmaru/homebrew-tap.git`, inspect its latest contents and initialize its first branch only if still empty, then publish immutable development candidate assets and the verified formula; verify downloaded source/bottle digests and commit provenance before pushing the completed tap payload, preserve any existing remote contents, and do not finish source Git Flow branches or create a stable release.
- [ ] 5.4 With package-test authorization, verify `brew install upmaru/tap/macus` from a fresh tap fetch uses the published bottle and passes package acceptance; update the project/tap READMEs with tested commands, supported platforms and development-signature limitations, keeping remote-package evidence distinct from local-tap evidence.

## 6. Integration validation

- [ ] 6.1 Run `Integration/scripts/check.sh` and `mise exec -- openspec validate --all --strict --no-interactive`; verify canonical checks pass and generator outputs, bottles, runtime data and `.integration/` artifacts remain excluded from commits.
- [ ] 6.2 Review the source and exported tap diffs against the delivery delta and recorded acceptance evidence; verify every completed task has its stated evidence and package-only success does not complete hardware, remote-publication or untested platform tasks.
