# Acceptance evidence

Host validation: 2026-10-03 UTC (2026-10-04 Asia/Bangkok). Apple M4 Max, 64 GiB, macOS 27.0.1 and Apple Swift 6.4; minimum deployment target remains macOS 15.

## Native checks and CI

Debug/release builds with warnings-as-errors, 26 Swift Testing tests plus four guest-helper tests, strict Swift formatting, guest shell/Python syntax and strict OpenSpec validation passed locally. Tests cover lifecycle concurrency/cancellation, failure retention, configuration/path/manifest safety, HTTP framing and binary duplex/half-close behavior.

GitHub Actions runs these checks on the macOS ARM64 `xcode-27` runner with pinned checkout/setup-node actions and OpenSpec 1.14.0. [The Alpine implementation workflow run passed](https://github.com/kritama/tama-incus-mac/actions/runs/37146208220). CI does not boot VZ or establish hardware acceptance; final PR-head checks are recorded on GitHub.

## Alpine appliance

The signed native Swift process boots the verified Alpine ARM64 raw image through Apple VZ EFI, provisions signed stable-branch APK packages, starts OpenRC services and exposes Incus through Unix-to-vsock sockets. No SSH or Mac VM CLI is used. The host reports nested virtualization support, and the Linux guest exposes usable KVM.

[Image provenance](testing/alpine-image.json) records the official Alpine 3.24.2 cloud-init metal r0 archive, SHA-512, pinned cloud signing fingerprint and raw SHA-256. Both checksum corruption and a checksum-matching archive with an invalid signature were rejected before extraction. [Resolved package versions](testing/alpine-package-versions.txt) record the acceptance appliance's signed v3.24 main/community packages: Incus LTS 7.0.1-r1, LXC 7.0.0-r0, QEMU 11.0.3-r0 and Linux 6.18.52-lts. No edge repository or unsigned-package exception is used.

Hardware testing corrected several Alpine-specific provisioning gaps: wait for IPv4 DHCP across reboots, start D-Bus and nftables, force an offline ext4 check before resize, load TUN/vsock modules on every boot and install QEMU's split audio/GPU/device modules. Incus startup readiness now waits for its internal startup tasks, beyond a successful `/1.0` response. The selected ARM64 AAVMF firmware lacks the Secure Boot pair; the nested test explicitly sets `security.secureboot=false`, consistent with the v1 boundary.

## Hardware results

Isolated Alpine appliances have passed real standard Incus system-container and OCI boot/exec, outbound networking, outer restart persistence and stopped-state data growth from 8 to 9 GiB. The guest directory-pool capacity grew from 8,350,298,112 to 9,407,197,184 bytes while the container's marker remained intact.

The final freshly provisioned appliance (`alpine-3.24.2-incus-a14`) passed the entire acceptance runner, including read-only write rejection, writable share propagation, cached OCI reuse after both restarts and growth, and nested Debian 13 ARM64 guest-agent `uname -m`. [The hardware report](testing/alpine-hardware-acceptance.json) records command results, capabilities, selected server environment and all 17 successful checks. Successful test workloads/remotes were removed by the runner.

Earlier runs exposed missing OCI cached files after restart while the image metadata remained present. Both `alpine:latest` and `alpine:3.23` reproduced it on fresh fixtures; a later diagnostic image survived reuse. The selected Incus 7.0.1 source contains a background-download cancellation path that can remove cache files; this is a suspected cause of the observed loss. New appliances set `images.auto_update_interval=0` and keep image updates explicit. Cached reuse passed in the complete final fixture under that default. Automatic background image updates remain unverified. A transient native EFI configuration failure also motivated releasing stopped VZ attachments before reopening them; the final immediate restart and growth/start cycle both passed. Failed fixtures and their Incus data are retained in ignored `.integration/`.

## Review and scope

CodeRabbit completed five reviews during this Alpine acceptance work. Its minor DHCP configuration idempotency finding was corrected; four subsequent reviews completed with zero findings. The last review covered the final VZ cleanup and explicit-image-update changes. Earlier native implementation findings were also addressed. Checks affected by the final Swift change were rerun successfully.

All 23 implementation/acceptance tasks in the archived OpenSpec checklist are complete. PR publication, head CI and review-thread resolution are tracked on GitHub. This records the supported initial implementation and acceptance fixture. Production signed/notarized distribution, a published appliance, Homebrew formula, automatic image/root upgrades, forwarding and custom DNS remain outside this initial implementation. No image, runtime disk, downloaded executable or client credential is committed.

The standard native Incus CLI used for acceptance is 7.5.1 from the verified official Homebrew ARM64 bottle, SHA-256 `864f707022778302ef3be6f11746f7aea15e659613c768ed63ab56f349eff2da`.

## PR review verification — 2026-10-04 UTC

The review fixes revalidate cached readiness inside start, replace blocking host relay pumps with bounded nonblocking Dispatch sources, supervise both guest listeners as one process and persist confirmed reset intent across daemon restart. The complete JSON configuration contract is explicit: initializer/template defaults do not imply omitted required fields. Regression tests verify incomplete JSON returns 400, custom values survive decoding, dead/unhealthy guests are not returned as ready, reset interruptions before/after configuration removal recover, invalid intent preserves data, and fatal listener failure exits even with a blocked worker.

The updated signed native process and newly provisioned Alpine appliance `alpine-3.24.2-incus-review-v1` passed [all 17 hardware checks](testing/pr-review-hardware-acceptance.json). The [idle-stream regression](testing/pr-review-relay-stress.json) held 80 real Incus connections open; all 60 control/health/Incus probes succeeded, with a maximum response time under 7 ms on this fixture. Swift regressions also verify 2 MB bidirectional transfers with forced backpressure, half-close and cancellation. These timings describe this local fixture, not a production performance guarantee.

CodeRabbit CLI completed an uncommitted review of the 16 implementation/planning/test files with zero findings. The standalone hardware stress runner was added afterward and separately passed syntax and real-hardware validation. The GitHub PR review remains the record for the published commit. The docstring coverage warning in the original PR review analyzed zero supported files (29 were unsupported); it does not establish Swift documentation coverage. API and recovery contracts are maintained in the project documentation.

## tim client acceptance — 2026-10-04 UTC

This gate is separate from the 17-check runtime acceptance above. Unit success does not establish it.

Canonical `Integration/scripts/check.sh` passed for both executables: warnings-as-errors debug and release builds, 41 Swift tests, strict formatting, guest shell/Python syntax, four guest-helper tests, and an isolated-prefix install. The install placed signed `tama-incus-mac` and `tim` in one prefix, applied the virtualization entitlement only to the daemon, and did not create runtime state or a launch agent. `mise run spec:validate` passed all 6 OpenSpec items.

CodeRabbit CLI 0.8.2 completed an authenticated review of the branch plus untracked client, test, packaging, and OpenSpec files (`review_completed`, 3 minor findings). Two findings were pre-existing and outside this slice: historical absolute paths in the prior runtime report, and guest preseed-marker behavior. They were not rewritten here. The restart-timeout finding conflicts with the validated 650-second lifecycle default; the CLI documents that restart includes shutdown plus boot and that a longer `--timeout` is required when those configured deadlines exceed 650 seconds. No finding required a product-code change.

The actual installed `tim` binary was then run against the existing stopped isolated appliance `<workspace>/.integration/a15`, using the appliance files in `<workspace>/.integration/alpine-a15`. It was not pointed at `~/.tama/incus-mac` or `~/.local`. The standard Incus 7.5.1 CLI created fixtures only. Installed tim proved status/start/doctor, JSON list, running virtual-machine filtering, show metadata plus live state, a `not_found` JSON error, restart, stop, and stopped doctor/list failures that did not boot the guest. Data and root disk sizes stayed 9,663,676,416 and 12,884,901,888 bytes. The guest and daemon were stopped afterward. [The redacted report](testing/tim-client-hardware-acceptance.json) records the checks. Earlier fixture-script mistakes left owned instances in that stopped appliance; they were retained rather than cleaned by another boot. That list/show scope is superseded. The lifecycle results remain historical only.

## tim client setup — 2026-10-04 UTC

`tim list` and `tim show` are not part of this client. Setup acceptance is separate from both the 17-check runtime gate and the historical lifecycle run above.

Swift tests drove fixture `brew` and `incus` processes for installation, prefix discovery, install failure, timeout reaping, remote conflict, idempotent registration, optional default switching and unrelated-remote preservation. No host `brew install` ran. `Integration/scripts/check.sh` and strict OpenSpec validation passed after the revision.

CodeRabbit CLI 0.8.2 completed an authenticated review of the revised uncommitted slice (`review_completed`, 1 minor finding). The finding was that the acceptance script recorded an unchanged default without failing the run; the script now requires `incus remote get-default` to succeed and to differ from the new remote. The observed run had already kept the default at `local`.

A newly installed `tim` in `<workspace>/.integration/tim-setup-prefix`, not the in-use prefix, registered `tama-mac` against the ready `<workspace>/.integration/a15` socket using the cached Incus 7.5.1 CLI and a fresh `INCUS_CONF`. `incus list tama-mac:` exited 0. Setup was idempotent and did not change the default remote. The appliance was not stopped, restarted or reconfigured. [The redacted setup report](testing/tim-client-setup-acceptance.json) records that this was not a lifecycle gate and not an actual Homebrew install.

Before PR publication, direct review corrected subprocess cancellation cleanup, removed EOF waits on pipes inherited by descendants, and made an unreadable default remote fail before registration. Regression tests exercise cancellation/reaping, inherited writers, simultaneous stdout/stderr, output overflow and failed default discovery. Canonical checks passed with 50 Swift tests and 4 guest Python tests, release builds, strict formatting and isolated installation; strict OpenSpec validation passed all 6 items. Installed setup acceptance passed again from a new `<workspace>/.integration/tim-pr-prefix` using a fresh client configuration and the same ready appliance, without lifecycle or host package changes. A full CodeRabbit review found one minor issue in the installer test's fixed temporary output path; it now uses the test's isolated directory and cleanup trap.

A second full CodeRabbit review completed with one minor finding: the Homebrew timeout test's log-based assertion did not establish that its child exited. The fixture now records its PID, and the test confirms that PID no longer exists when the timed-out command returns. That strengthened test and strict formatting passed.

The final committed implementation review completed with zero findings. The first PR CI run exposed short fixture deadlines while synchronous subprocess waits occupied Swift's cooperative executor. Executable fixtures now await the bounded subprocess runner, and successful-response tests allow cold process startup without changing the deliberate one-second timeout tests. Canonical checks passed again with all 50 Swift tests; hardware acceptance and production timeout behavior are unchanged by this fixture correction.

The focused review of that fixture correction completed with zero findings. The Homebrew timeout fixture records its PID in a shell before executing a sleeping install, avoiding Python startup as part of the measured failure. Its test verifies the actual `brew install incus` arguments and that the child PID is gone on return.

## PR #2 review follow-up — 2026-10-05

The installer now refuses symlinked bin directories, symlinked executable destinations (including dangling links), and non-file executable destinations before copying either tool. Isolated regressions verify that outside targets and existing sibling binaries retain their contents. The setup acceptance runner records the default before setup and requires the post-setup default to match it exactly; fixture checks prove that switching to an unrelated remote fails acceptance and an unreadable initial default prevents setup. The canonical SwiftPM delivery requirement now names both executables.

Canonical checks passed with 50 Swift tests and 7 Python tests (4 guest bridge checks and 3 acceptance-runner regressions), strict formatting, release builds and isolated installation. All 6 strict OpenSpec items passed. Read-only real-client acceptance against the already-ready isolated appliance also passed: the default was `local` both before and after setup, registration and connectivity succeeded, and repeated setup was idempotent. The appliance and existing installation were untouched; no host Homebrew installation or new lifecycle gate ran.

CodeRabbit CLI completed an uncommitted review of all five implementation/spec/test changes with zero findings. This follow-up addresses the three current GitHub review comments; the added documentation records the independently checked evidence.

## Macus rename — 2026-10-06

`macus` now combines foreground serving, host capabilities and the former tim client commands in one executable; the Swift library is `Macus`. Earlier dual-executable descriptions and reports above record historical runs and are superseded for current installation instructions. Existing default state paths and persistent reset/guest identifiers remain compatible.

Canonical `Integration/scripts/check.sh` passed: warnings-as-errors debug/release builds, 51 Swift tests, strict formatting, guest shell/Python syntax, 46 Python tests and an isolated signed single-binary install. Strict OpenSpec validation passed all 8 items. A separately signed debug `macus serve` was run against a disposable `/private/tmp` state directory: the control socket returned API version 1 and absent state, selected `MACUS_STATE_DIR` over legacy `TIM_STATE_DIR`, created no guest disks and terminated gracefully. No VM was booted and no hardware acceptance of the renamed binary is claimed.

Local diff review verified that runtime/configuration fields and the persisted reset marker remain compatible, and current command/module/installer names agree. CodeRabbit authentication succeeded, but automatic approval review rejected uploading the source diff without explicit user authorization; no remote review result is claimed.

## Rename review and CI fixes — 2026-10-07

Greptile CLI reviewed PR #4 at `84049ac` with 4/5 confidence and one P2 finding: host capability output bypassed the public CLI runner's custom streams. Daemon output now uses the supplied `MacusStreams`, including capabilities and help, and the CLI forwards those streams. A capture regression failed before the fix and passes afterward.

The first rename CI run failed in `chunkedFramingSurvivesByteSizedReads` with `Local socket connection failed`. Its raw HTTP fixture responded and closed without first reading the POST request, racing the client's write. The HTTP transport fixtures now consume complete requests before responding and retain descriptor ownership through the handler. The chunked test verifies received method, path and body for both 2-byte and 256 KiB requests; the larger case reproduced the failure before the fix. Production transport behavior and deadlines were preserved.

Canonical checks passed with 52 Swift tests (including both chunked request sizes), 46 Python tests, debug/release builds, strict formatting and an isolated signed install. Both regressions passed 20 consecutive repeated runs. Strict OpenSpec validation passed all 8 items, and diff whitespace checks passed. No guest was booted; hardware acceptance remains separate.

The next hosted CI run passed both chunked request sizes but exposed concurrent subprocess-startup timeouts and a deadline fixture reporting a client's early disconnect. Canonical Swift checks now explicitly use `--no-parallel`; all internal concurrency, cancellation and deadline assertions remain in place. Only the two deadline HTTP fixtures tolerate incomplete requests on disconnect; other fixture read errors still fail validation. The final canonical run again passed 52 Swift tests, 46 Python tests, builds, formatting, isolated signed installation and all 8 OpenSpec items. Hosted Greptile reviewed `163f993` with 5/5 confidence and no actionable findings; that review precedes this scheduling follow-up.

Native CI passed at `4feb7e8`. Hosted Greptile also passed with 5/5 confidence but left a P2 observation that the disconnect opt-out could let deadline tests pass without executing their response handlers. The follow-up removes that opt-out: all HTTP fixture read errors are reported, and both delayed/trickled tests explicitly assert a thread-safe handler-start observation. The original deadline bounds remain intact. Canonical validation of this stricter follow-up passed all 52 Swift tests, 46 Python tests, builds, formatting, isolated signed installation and strict OpenSpec validation.

## Start experience — 2026-10-07

This is a separate hardware gate from the earlier Alpine and client reports. Unit success does not establish it.

An installed `macus` at `/private/tmp/ms7e/install/bin/macus` was started from `/private/tmp`, with state `/private/tmp/ms7e/st`, client config `/private/tmp/ms7e/client`, and remote `macus-acc`. The checkout was not on `PATH`. `~/.tama/incus-mac`, the default Incus remote, and any persistent `com.upmaru.macus` agent were not used. The session agent was `com.upmaru.macus.42ae29138d65`; its parent was launchd after `macus start` returned.

The successful run verified a cache copied from an earlier isolated download of the 626,889,284-byte archive. It did not download again. Progress showed the expected kernel reboot, the reboot allowance was consumed, and live health reported Incus 7.0.1 with KVM. Official Homebrew installed Incus 7.5.1 during that start; it had been absent. Repeat start finished in about one second, skipped acquisition, and reused the client.

A Debian 13 container resolved `deb.debian.org` and kept a `macus-ok` marker across a successful runtime restart and across bootout/bootstrap of the isolated agent. The first runtime restart after the initial boot failed with an invalid boot loader; disks were kept and a following start recovered. The first bootstrap immediately after bootout returned an I/O error; the retry succeeded. Live capabilities reported `vm` and nested virtualization, and Incus reported `lxc | qemu`. No nested guest was booted in this run.

The smoke container was deleted, the owned runtime was stopped, and the session agents were unloaded. Failure directories under `/private/tmp/ms7acc`, `ms7b`, `ms7c`, and `ms7d` were retained. [The report](testing/start-experience-acceptance.json) records the versions and results. That run is not completion of the unavailable-checkout or restart gates: the checkout remained on disk, acquisition reused a copied cache, the first runtime restart failed with an invalid boot loader, and a manual bootstrap returned I/O error 5 after the binary was replaced under a live job.

## Start experience follow-up — 2026-10-07

A later installed binary was built from an owned `/private/tmp/ms7src` copy. That copy was removed before `macus start`. The shared checkout was not renamed or deleted. From `/private/tmp`, with isolated state and `INCUS_CONF`, start downloaded and verified the 626,889,284-byte archive, observed the expected reboot, and connected to the already installed Incus client. It did not install Homebrew again and did not boot a nested guest. Live capabilities reported VM and nested virtualization support.

Two immediate `macus runtime restart` commands returned ready. The workload marker survived, and the EFI store and data disk inodes were unchanged. An owned PTY session listed the remote and was closed; the launchd daemon and guest stayed ready. Booting out only the session agent and then running `macus start` after that job left the domain restored the marker. An overlapping start while the previous daemon was still stopping conflicted and preserved disks. [The follow-up report](testing/start-experience-follow-up.json) records this separately from the earlier failures.

## Homebrew candidate packaging

The local candidate at source revision `7e071e383d630ffe0a72c019dc8a28af02446dde`, version `0.0.0-dev.20261008123735.7e071e383d63`, passed Homebrew source compilation, formula style/audit/test, bottle generation and a subsequent poured-bottle install on ARM64 macOS 27.0.1. Its installed signature and virtualization entitlement verified, help/capabilities ran outside the checkout, and the install left ordinary runtime/client/service state unchanged. [Package evidence](testing/homebrew-package-acceptance.json) records the measured bottle digest and receipt. This verifies only the `arm64_golden_gate` bottle; macOS 15/26 bottle coverage and remote tap installation are not claimed. Development signing is ad hoc, without notarization.

The separately opted-in installed-bottle hardware run booted a fresh isolated Alpine appliance and consumed its single expected kernel restart, but live Incus readiness did not arrive after the second boot; the retained serial log showed `tama-bootstrap` stopped. The test VM was force-stopped and its owned launchd job unloaded. Its disks/logs were preserved. [Hardware evidence](testing/homebrew-hardware-acceptance.json) explicitly records unsuccessful acceptance. First/repeated ready startup, package-upgrade marker persistence and uninstall retention remain unverified; passing package checks does not complete them. Guest bootstrap repair and artifact publication are pending user scope/authorization decisions.

Readable CLI presentation acceptance is recorded in
[testing/readable-cli-output-acceptance.json](testing/readable-cli-output-acceptance.json).
These 21 transcripts come from the signed release executable with isolated Unix
socket and Incus-client fixtures, under a pseudo-terminal and redirected streams.
They cover help, host capabilities (both JSON placements), runtime status, doctor,
startup reuse, JSON, error, timeout, SIGINT exit 130 and foreground serve notices.
The checks preserve fixture disks/configuration, assert read-only requests for
inspection, and never boot a VM. They are presentation evidence, separate from
guest/hardware qualification. The canonical isolated-prefix install check reruns
`Integration/scripts/presentation-acceptance.py --binary <signed-macus>`.
On a CI host that reports Apple virtualization unavailable, the signed runner
verifies startup's unsupported-host rejection and records that mode explicitly;
it does not bypass production preflight or claim the startup success/timeout
matrix ran there. Supported-host runs exercise that full matrix. Runtime-wait
failure, timeout and interruption cases must observe an actual fixture start
request; preflight failures cannot satisfy their assertions.
