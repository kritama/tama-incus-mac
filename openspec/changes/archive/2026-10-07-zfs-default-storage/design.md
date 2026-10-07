# Design

## Context

See `proposal.md` for motivation. The current guest uses Alpine 3.24.2, provisions packages from the signature-verified v3.24 main/community repositories, formats an all-zero `/dev/vdb` as ext4, mounts it at `/var/lib/incus`, and seeds Incus `default` with `driver: dir`. `tama-storage` runs before `incusd` and `tama-bridge`. Initialization intent is durable, and an interrupted preseed is preserved for recovery rather than repeated blindly.

The host already supplies one separate sparse data disk, grows it only while stopped, and preserves failed state. Defaults are 4 GiB RAM and 32 GiB data. Recorded ext4 acceptance used Linux 6.18.52-0-lts and Incus 7.0.1; that does not establish ZFS support. Production provisioning has no ZFS packages or module-loading checks. The isolated qualification prototype and recorded results are in `docs/zfs-qualification.md`. This change affects the guest data layout, not the EFI/root boot filesystem.

## Goals / Non-Goals

**Goals:** Qualify ZFS as the selected automatic fresh-install default; storage identity, Incus metadata and workloads survive boot failures and disk growth; legacy disks remain usable through their existing path. Prove these properties on new isolated appliances before claiming support.

**Non-Goals:** Host ZFS, ZFS root boot, extra host disks, RAID, deduplication, encryption/key management, automated replication, existing-workload migration, automatic root-image upgrades, Homebrew publication or new `tim` workload commands.

## Decisions

### 1. ZFS is selected; compatibility remains a blocking gate

The user selected ZFS after reviewing the mixed container/VM requirements and upstream recovery tradeoffs. Btrfs's older-snapshot restore advantage does not outweigh its documented VM disk-file and quota limitations for this appliance. No comparative Btrfs hardware fixture, second production backend or automatic fallback is required in this change.

Before production provisioning, use disposable isolated Alpine appliances to prove ZFS support in the booted kernel, signature-verified stable-branch packages, the actual Incus driver, persistent metadata outside the Incus-controlled workload dataset, reboot behavior and disk growth. This proof does not touch existing appliance data. Copying an older snapshot into a new instance is the non-destructive recovery workflow when rollback is blocked by newer snapshots or clones; direct rollback must not promise preservation of those descendants.

The report must include:

| Criterion | Required evidence |
| --- | --- |
| Older-snapshot recovery | Create `s1`, change data and create `s2`/`s3`, retain a clone from a newer snapshot, then attempt standard Incus restore to `s1`. Verify restored checksums and survival of newer snapshots and clone data, or record refusal and required deletion. Separately test copying `s1` into a new instance; it is a different workflow. Use a disposable duplicate to test any destructive ZFS restore option. |
| Workload coverage | Container and custom-volume operations on ZFS; VM disk I/O and snapshot/restore with usable nested KVM. Without nesting, record the VM evidence as pending/unsupported rather than predicting success. |
| Quotas and space accounting | Configured limits, random overwrite, snapshot/clone retention, full-pool behavior and reclaimed capacity after deletion; include ZFS dataset/zvol accounting. |
| Resources and storage growth | Memory/cache usage, usable capacity, sparse host-file allocation, stopped-state growth and relevant timing measurements under the same workload. |
| Persistence and recovery | Graceful restart, forced-stop recovery, safe ownership checks, failed mount/import and preservation of metadata and workload checksums. |
| Maintenance | Stable-branch package/kernel availability, boot ordering, image versioning and recovery complexity for the appliance. |

Upstream Incus documents ZFS rollback restrictions involving newer snapshots and clone dependencies. Record version-specific outcomes and distinguish direct restore from copy-to-new-instance. Expected refusal is a recovery limitation to verify, not a failed promise of unrestricted rollback.

Use Alpine's stable-branch ZFS userspace and kernel module packages with a matching booted LTS kernel. OpenZFS documents `zfs` and `zfs-lts` for Alpine, and the spike verified Alpine v3.24 aarch64 `linux-lts`/`zfs-lts` 6.18.55-r0 with ZFS 2.4.4-r0 and Incus 7.0.1-r1. The base kernel 6.18.52-0-lts must be replaced in a new versioned image; the retained signed APKs and digests are recorded in `docs/testing/zfs-qualification.json`. That package investigation is recorded. The production path uses the same signed Alpine v3.24 pair and is covered in `docs/zfs-qualification.md`.

If the existing cloud-image kernel does not match available modules, prepare a new versioned image with a matched stable-branch kernel/module pair and verify EFI, virtio, vsock and nested capability again. Do not mix edge packages, compile modules during ordinary user boot, bypass APK signatures or patch a running user's appliance. If no supported combination passes, report the blocker and revise the plan; do not substitute `dir` while describing the default as ZFS.

An optional ZFS toggle was considered but does not meet the requested out-of-the-box experience. Switching distribution solely to obtain ZFS is outside the Alpine scope. The remaining decisions describe the proposed ZFS path and become implementation-ready only after the compatibility gate passes.

### 2. Use one data-disk pool with separate ownership domains

The selected layout is one ZFS pool backed directly by the existing virtual data disk, with an appliance-owned metadata dataset mounted at `/var/lib/incus` and a sibling dataset handed exclusively to Incus as the source of its `default` storage pool. The proven names are parent `tama-data`, metadata `tama-data/metadata` and Incus source `tama-data/workloads`, with actual vdev `/dev/vdb1`. The disposable layout marker is `qualification-v1`; production needs a distinct durable versioned identity/phase contract rather than adopting that prototype marker.

Incus owns all descendants of the workload dataset. Appliance metadata, layout records and provisioning intent live outside that subtree. Do not hand Incus the whole parent pool, because it assumes full control of the pool/dataset supplied to it. Avoid loop-backed ZFS inside ext4 and an extra virtual disk: the former adds a filesystem/space-accounting layer, and the latter changes host attachment, persistence and growth contracts unnecessarily.

The spike demonstrated sibling coexistence with `zfs.export=false` on the Incus pool and appliance-owned parent export after Incus stops. Successful export, GUID-scoped re-import and stopped growth were measured. Production still needs device/phase preservation tests before this layout can ship. Preserve the root image's existing boot layout.

### 3. Classify disks before provisioning and persist identity before initialization

Distinguish an entirely zero-filled disk, known legacy ext4, a recognized owned ZFS layout, and unknown/nonblank/ambiguous data. Lack of a `blkid` result is not evidence of blankness. Initial ZFS creation is allowed only after verifying the complete attached disk is blank and persisting initialization intent outside the disk being initialized. Record the expected disk identity, layout version and pool GUID as they become available, then durable metadata and preseed phase within the metadata dataset.

On subsequent boots, import only the expected pool from the attached data device and verify dataset identity and mount targets. Name matches alone do not prove ownership. Do not use general import-all discovery, automatic forced imports, `source.wipe`, blind forced pool creation or feature upgrades to repair errors. Resume only a provably owned safe phase; uncertain or interrupted destructive/preseed phases retain data and provide an actionable diagnostic. Preserve the existing preseed interruption boundary.

The old ext4 path retains its checking/growth behavior and existing Incus configuration. A recognized ext4 disk without a complete known legacy layout is preserved and rejected rather than reseeded or converted. No fresh-install backend selector is added in this slice.

### 4. Order storage around Incus and gate readiness on the selected backend

On boot, load the matched module, import the expected pool, mount persistent metadata, validate storage ownership, then start Incus and initialize the workload dataset only for a fresh owned layout. For new ZFS layouts, verify the `default` driver's actual value and default profile mapping before helper readiness. Legacy layouts verify their recorded configuration without overwriting user-managed pools or profiles.

Own explicit OpenRC dependency ordering rather than enabling conflicting broad import/mount services alongside `tama-storage`. At shutdown, stop the helper and Incus before exporting the parent pool; the proven `zpool export` unmounts its datasets, including metadata. Configure upstream Incus dataset export behavior as necessary for the sibling layout and prove it in the spike. Forced VM stops may bypass export; recovery must re-import the same pool without recreating it. Failed storage preparation blocks readiness and retains private diagnostic logs.

### 5. Grow the existing backing device and establish measured resource limits

Keep host growth stopped-only and byte-preserving. On boot, extend the identified ZFS vdev to consume added capacity, including safe handling of any whole-disk partition table created by ZFS; do not recreate the pool or add a second vdev. Validate that usable capacity increases and instance checksums, metadata and snapshots remain intact. Preserve the ext4 `e2fsck`/`resize2fs` path.

Begin with the existing 4 GiB/32 GiB defaults, compression enabled through documented upstream settings and deduplication disabled. The hardware-qualified fresh-ZFS host configuration is 4096 MiB RAM. The guest formatting floor is MemTotal of at least 3670016 KiB and a data disk of at least 4 GiB. That guest check does not reject every host configuration below 4096 MiB. Mixed container/VM workloads were measured on 8–11 GiB data disks, not at a 4 GiB mixed-workload minimum. The host API minima of 512 MiB and 1 GiB remain valid only for recognized legacy ext4; they are not ZFS-qualified. Cap ARC at 512 MiB. A 2 GiB guest with retained VMs is not a qualified minimum.

Protect metadata with an initial 1 GiB refreservation. Available space inside that reservation is the only metadata headroom; a consumed reservation is not free capacity. Readiness fails, without reformatting, if metadata available space is below 256 MiB.

Incus 7.0.1 starts `boot.autostart` instances synchronously before it reports ready. On the exhausted pool, the autostart VM failed with `symlink incus-agent .../config/lxd-agent: no space left on device` because its config dataset had a quota but no refreservation, and retained autostart containers then failed credentials creation. Three retries and a 5 second delay per instance exceeded the 180 second readiness timeout. This was not an OOM: about 3.7 GiB remained available and ARC stayed capped. A diagnostic clone showed that reservations present before exhaustion let that pool become ready in 27 seconds. Applying those reservations with `zfs set` mutated Incus-owned workload descendants. That violates the ownership boundary and is not a shipping operation. Upstream `zfs.reserve_space=true` on an existing volume did not set the companion refreservation.

The ownership-safe request is pool configuration `volume.zfs.reserve_space=true` and `volume.zfs.use_refquota=true`, plus a sized default-profile root, so Incus reserves a volume's own size when it creates the volume. The 2026-10-06 production boot measured that Incus 7.0.1 does this for filesystem datasets: container root `refreservation=2G`, custom volume `128M`, and the VM config dataset `500M`. It does not set `refreservation` on the VM or image zvol (`za-vm.block` volsize 4G, refreservation none; image zvol volsize 10G, refreservation none). A new 2 GiB filesystem create correctly fails when the pool cannot reserve that size. A bounded full-pool autostart reboot reached readiness in 27 seconds and retained the container marker, snapshot copy and nested VM agent, because the previously failing config dataset now has a reservation. That does not protect later zvol writes. A zvol without a reservation can still stop QEMU with `BLOCK_IO_ERROR`/`nospace`. Do not claim a full pool can grow sparse VM disks, and do not set zvol properties from the appliance. A single virtual disk provides no redundancy against loss of its host backing file.

### 6. Separate compatibility proof, implementation checks and acceptance

First record the selected ZFS rationale plus package/kernel, ownership-layout and growth proofs on disposable isolated state. Focused tests then cover classification, ordering, ownership, interrupted phases and errors. Final hardware acceptance uses standard Incus commands for container launch, custom volumes, snapshot/restore and clones, including documented older-snapshot recovery semantics; VM volumes and operations additionally require guest KVM and supported nesting. An unsupported nested VM is reported as such, never counted as passed acceptance.

Acceptance also covers graceful restart, explicit forced-stop recovery, increased disk size, full-pool failure, wrong/missing module, foreign/unknown disk rejection and legacy ext4 preservation. Existing `.integration/a15`, `.integration/tim-client-prefix`, global packages and normal Incus configuration are excluded; use fresh directories and isolated `INCUS_CONF`. Hardware execution remains an explicit opt-in step. Unit success and earlier ext4 evidence cannot close these tasks.

## Risks / Trade-offs

- Kernel/module drift → pin and record a tested image/package combination; reject incompatibility before provisioning; revalidate any image change.
- Incus export of a shared parent pool or ownership of metadata → give Incus only its sibling dataset and prove lifecycle behavior before production changes.
- Partial first boot or pool identity ambiguity → persist versioned intent and GUIDs, verify attached device ownership, preserve uncertain state.
- Sparse backing-file exhaustion → test guest and host space failures, expose actionable errors and document required host headroom; snapshots are not independent backups.
- ARC pressure at small memory sizes → measure at defaults and boundaries, bound ARC and reconcile supported resource requirements before shipping.
- Single-disk damage → checksums detect corruption but do not supply redundant repair data; document backups through standard Incus tools.
- Reverting to a kernel or image unable to read the new pool → retain the compatible image/kernel; do not use automatic `zpool upgrade` or downgrade assumptions.
- ZFS direct older-snapshot restore can require deleting newer snapshots or dependent clones → verify and document the constraints and copy-to-new-instance recovery.

## Migration Plan

1. Deliver this planning change on `feature/zfs-storage`; leave completed client planning housekeeping and Homebrew distribution separate.
2. Run the explicitly authorized isolated ZFS compatibility spike. Record results and qualify the selected layout before production implementation. A failed compatibility gate blocks implementation and requires revisiting the plan; it never authorizes a backend fallback.
3. Implement and validate fresh ZFS initialization and recognized legacy ext4 compatibility without touching active user state.
4. Run canonical checks, strict OpenSpec validation, CodeRabbit review and new opt-in ZFS acceptance. Pending hardware work stays unchecked.
5. Publish development work through a PR into `develop`. A release still follows the project's Git Flow release process and explicit authorization.

Existing appliances keep their current images and pools. Roll back code before creating ZFS state if needed; after creation, retain the compatible ZFS appliance and data. Moving data to another backend requires a separate explicit backup/restore or Incus migration plan, not reformatting or image replacement.

## Remaining blocking qualification

Package/module compatibility, the sibling layout and Incus creation-time filesystem reservations are proven on the production path. Appliance mutation of workload datasets remains forbidden. Incus 7.0.1 does not reserve VM or image zvols; that limit is measured, not repaired by an appliance `zfs set`. There is no second backend or fallback. Legacy ext4 and foreign-disk hardware acceptance remain separate from the production ZFS boot. OCI launch and a writable VirtioFS share were exercised on the same disposable appliance. Legacy preservation and no silent fallback apply throughout.

## References

- [Incus ZFS driver and ownership boundary](https://linuxcontainers.org/incus/docs/main/reference/storage_zfs/)
- [Incus storage feature comparison](https://linuxcontainers.org/incus/docs/main/reference/storage_drivers/#feature-comparison)
- [Incus Btrfs driver, snapshots and VM/quota considerations](https://linuxcontainers.org/incus/docs/main/reference/storage_btrfs/)
- [OpenZFS on Alpine: packages, module loading and boot services](https://openzfs.github.io/openzfs-docs/Getting%20Started/Alpine%20Linux/index.html)
- [OpenZFS device expansion](https://openzfs.github.io/openzfs-docs/Basic%20Concepts/Pool%20Structure/Changing%20Pool%20Layout.html)

These establish upstream mechanisms, not successful validation of this project's appliance.
