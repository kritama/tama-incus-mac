# Acceptance evidence

Date: 2026-10-03. Host: Apple M4 Max, 64 GiB, macOS 27.0.1, Apple Swift 6.4. Minimum deployment target remains macOS 15.

## Verified so far

- SwiftPM bootstrap was built/tested before writing OpenSpec or feature code.
- All five specification deltas pass strict OpenSpec validation.
- Debug and release builds succeed with warnings-as-errors and Swift 6 checking; 19 Swift Testing tests, strict format lint and shell/Python syntax checks passed on 2026-10-03.
- Native unit tests cover lifecycle/reentrancy, emergency boot cancellation, failure retention, configuration/path/manifest safety, HTTP framing and binary duplex/half-close behavior.
- Signed native Swift daemon starts and exposes private local status/capability endpoints.
- Apple VZ reports virtualization and nested support on this host.
- Apple's VZ EFI boots the verified Debian 13 ARM64 raw image headlessly; cloud-init runs without SSH or an external VM runtime.
- Real emergency force stop during boot succeeds; daemon crash recovery reconstructs stopped state and preserves disks.
- CodeRabbit completed four reviews: the original five findings, five follow-up findings, two retry/initialization findings, and a final minor marker-durability finding. All actionable findings were addressed and affected checks passed. Changes cover staged-image verification, bootstrap readiness, share defaults, cross-volume input errors, bounded/cancellable vsock connects, guest filesystem growth evidence, explicit runner scope, repeatable OCI remotes, persistent/synchronized first-boot intent and retryable exec timeouts. A persistent started marker deliberately refuses automatic preseed replay after a partial initialization, preserving state for explicit recovery. The last review reported no major findings; its minor durability correction was checked locally, without a further remote review. Guest behavior still requires hardware acceptance.

## Alpine migration and pending hardware acceptance

The active specification now selects Alpine Linux ARM64 with OpenRC and signed APK packages. Guest scripts and preparation currently remain the Debian prototype. Its boot evidence below is historical and does not satisfy Alpine hardware acceptance. Migration tasks 2.2–2.4 and Alpine readiness/workload tasks 5.1–5.4 remain pending. Existing prototype disks are retained; no in-place root replacement is authorized by this OS choice.

Prototype Incus first-boot provisioning stalled during package acquisition in multiple isolated tests. No Incus readiness/workload/persistence/nested-VM success is claimed yet. The opt-in acceptance runner records actual standard Incus operations in a machine-readable JSON report. Linux boot alone does not satisfy the vertical slice.

The active OpenSpec checklist is the source of truth for remaining acceptance. No production appliance release, signed/notarized distribution, Homebrew formula, automatic appliance download catalog or root upgrade has been published.

## Reproduction inputs

Official Debian `debian-13-generic-arm64.tar.xz`, catalog updated 2026-10-01. Published and independently computed SHA-512:

```text
cb80554bf05aa9eb42d0b99a9a395fefad04edc8435514c5387e32f4da83b7827c34809f6249b365dedacd3f0688580f2957fd13b388639c987058bbe127fa8d
```

Native Incus CLI 7.5.1, official Homebrew arm64 bottle, SHA-256:

```text
864f707022778302ef3be6f11746f7aea15e659613c768ed63ab56f349eff2da
```

Artifacts and temporary raw disks remain in ignored `.integration/`; no image, guest state, credentials or downloaded executable is committed.
