# Acceptance evidence

Host validation: 2026-10-03 UTC (2026-10-04 Asia/Bangkok). Apple M4 Max, 64 GiB, macOS 27.0.1 and Apple Swift 6.4; minimum deployment target remains macOS 15.

## Native checks and CI

Debug/release builds with warnings-as-errors, 19 Swift Testing tests, strict Swift formatting, guest shell/Python syntax and strict OpenSpec validation passed locally. Tests cover lifecycle concurrency/cancellation, failure retention, configuration/path/manifest safety, HTTP framing and binary duplex/half-close behavior.

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

All 17 tasks in the active OpenSpec checklist are complete. This records the supported initial implementation and acceptance fixture. Production signed/notarized distribution, a published appliance, Homebrew formula, automatic image/root upgrades, forwarding and custom DNS remain outside this initial implementation. No image, runtime disk, downloaded executable or client credential is committed.

The standard native Incus CLI used for acceptance is 7.5.1 from the verified official Homebrew ARM64 bottle, SHA-256 `864f707022778302ef3be6f11746f7aea15e659613c768ed63ab56f349eff2da`.
