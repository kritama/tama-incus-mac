# Proposal

## Why

Incus does not run on Darwin. Tama needs a local Incus substrate on Apple Silicon while retaining the same standard Incus API and portable workloads used on Linux.

## What Changes

- Add a headless Swift service using Virtualization.framework directly to manage one ARM64 Linux appliance.
- Expose a versioned runtime control API and a separate transparent Incus stream endpoint over owner-only Unix sockets.
- Bootstrap a minimal Alpine Linux ARM64 appliance using OpenRC and signed APK packages, persist Incus on a separate disk, and report verified readiness and nested VM support.
- Provide explicit VirtioFS shares, safe stopped-state resource configuration, launchd packaging, and repeatable acceptance tests.
- Record root-image upgrade and service exposure as future features with explicit boundaries.

## Capabilities

### New Capabilities

- `runtime-lifecycle`: Outer VM states, concurrency, recovery, health, resource configuration and deletion.
- `linux-appliance`: Image trust and format, boot, initial provisioning, persistent disks and upgrade boundaries.
- `incus-transport`: Transparent Unix/vsock transport, runtime control API and tama-machine contract.
- `host-integration`: Apple VZ device configuration, networking, capability detection, nesting and explicit filesystem shares.
- `service-delivery`: Installation, security, observability, testing and future-feature acceptance gates.

### Modified Capabilities

None: this is a new project with no existing specifications.

## Impact

One SwiftPM library and executable; Apple Virtualization, Foundation, Darwin and os frameworks. No third-party Swift dependencies. Guest uses Alpine Linux, OpenRC, Incus and its own LXC/QEMU dependencies, plus a small host-only vsock helper. Use Alpine's signed main/community APK repositories from one pinned stable release branch. The host never executes a VM CLI. Control API is new and local; Incus API bytes are preserved. Existing guest provisioning and image preparation must be migrated to Alpine and hardware acceptance repeated; earlier prototype boot evidence does not establish Alpine readiness.
