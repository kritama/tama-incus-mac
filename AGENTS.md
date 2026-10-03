# Project instructions

Use SwiftPM with strict Swift 6 concurrency and native swift-format. Keep the executable small and VZ code inside Sources/TamaIncusMac/Virtualization. Use OpenSpec for substantial behavior changes; validate planning before implementation and keep hardware acceptance distinct from unit test success. Never implement workload operations Incus already provides, wrap a host VM CLI, or introduce cross-platform/GUI requirements.

Canonical checks: Integration/scripts/check.sh and `openspec validate --all --strict --no-interactive`. Hardware acceptance is explicit and opt-in; use only isolated state directories. Preserve Incus data on failures. Use feature/ branches, exclude .integration/build artifacts from commits, and do not publish a formula with fake checksums.
