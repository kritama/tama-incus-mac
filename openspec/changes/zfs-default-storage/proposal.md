# Proposal

## Why

Fresh tama-incus-mac appliances currently initialize an ext4 data disk and an Incus `dir` pool. Select ZFS as the out-of-the-box storage backend, qualifying snapshot recovery and appliance compatibility before enabling the default, so users do not need to configure a second pool to use upstream snapshots and clones.

## What Changes

- Record the selected ZFS default and its documented rollback constraints. Add a blocking ZFS compatibility proof covering older-snapshot recovery with newer snapshots and clones present, containers and nested VM storage, quotas, resources, boot/recovery, growth and sparse host-disk behavior before production implementation.
- Once qualified, fresh appliances provision an Incus `default` pool using `zfs` automatically, with the default profile pointing to it. Missing support must fail clearly before destructive provisioning; there is no silent fallback to `dir` or Btrfs.
- Establish a reproducible, signature-verified Alpine stable-branch kernel/OpenZFS package combination and prove module loading across reboots before enabling the default.
- Keep persistent Incus metadata and workload storage on the separate data disk, with explicit appliance and Incus dataset ownership boundaries, safe pool import/mount/export ordering, and resumable first-boot initialization.
- Preserve existing ext4/`dir` installations and their pools, profiles and data. Automatic conversion, root-image replacement and migration of existing workloads are outside this change.
- Extend stopped-state disk growth to ZFS without shrinking or recreating pools, and report storage failures without advertising runtime readiness.
- Require isolated hardware evidence for first boot, upstream Incus storage operations, reboot/crash recovery, growth and data preservation. Current ext4 acceptance is not ZFS acceptance.

## Capabilities

### New Capabilities

None. Storage provisioning belongs to the existing Linux appliance capability.

### Modified Capabilities

- `linux-appliance`: Define ZFS qualification and default provisioning, compatible guest dependencies, persistent storage ownership and failure handling, backend-specific growth, legacy ext4 compatibility and the acceptance gate.

## Impact

Implementation is expected to touch `Integration/guest/bootstrap.sh`, `storage.sh`, `tama-storage.initd`, appliance preparation/verification and isolated acceptance tooling, plus focused provisioning tests and storage documentation. A guest storage-layout version and identity record are required; any host manifest/configuration change must be justified by the compatibility investigation rather than assumed necessary.

The host continues to use Apple Virtualization.framework directly. `tim` remains responsible for runtime lifecycle, health and standard Incus client setup; workload, volume, snapshot and clone operations remain upstream Incus operations. Homebrew distribution, ZFS root boot, host-side ZFS, RAID, replication policy and automatic appliance upgrades are separate work.

ZFS selection is confirmed. Isolated qualification and the production path now record the matching kernel/module pair, sibling layout, filesystem creation-time reservations, and the failure-preservation cases in `docs/zfs-qualification.md`. Zvol `refreservation` remains none, so a full pool must not be described as able to grow a sparse VM disk. Btrfs implementation and comparative hardware testing are outside this selected scope; no second production backend or user-facing selector is added. This change is not a release or merge by itself.
