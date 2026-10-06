# ZFS compatibility qualification

Recorded 2026-10-05 on physical Apple Silicon, using Apple
Virtualization.framework directly. Sections through "Startup-headroom root cause"
are the historical qualification prototype, including direct dataset reservations
that are not the shipping operation. The "Production path, 2026-10-06" section is
the current production-path record. **Filesystem reservations and the recorded
failure-preservation cases are proven. Zvol refreservation remains none.** This
report does not establish a release or merge, and it does not claim a second
backend or automatic fallback.

The repository [evidence summary](testing/zfs-qualification.json) records measured
results. Complete private command transcripts, serial logs, disks and failed
fixtures are retained under ignored `.integration/`. The [runbook](../Integration/qualification/README.md)
describes explicit opt-in reproduction.

**a15 was not untouched.** During fixture cleanup the agent used a broad process
filter and reported stopping the pre-existing `.integration/a15` daemon, then
restarted the same `serve` command. The user subsequently clarified, "I stoped
the a15 daemon". The parent verified runtime state `stopped`, then stopped only
that agent-restored process (PID 70353), confirming its exit. No VM restart or
disk/config change was requested. The intended stopped state is restored and no
restoration question remains. The earlier cleanup deviation remains recorded;
this does not establish historical disk-hash preservation for a15.

## Hardware and package provenance

Historical 2026-10-05 prototype record. It is not the current production-task status.

| Component | Tested value |
| --- | --- |
| Host | Mac16,5; Apple M4 Max; 64 GiB RAM |
| OS | macOS 27.0.1, build 26A434 |
| Virtualization | Native VZ; nesting and VirtioFS supported |
| Base | Alpine 3.24.2 aarch64 cloud-init metal r0 |
| Repositories | Signed Alpine v3.24 main/community; no edge |
| Booted kernel | `6.18.55-0-lts` |
| Kernel/module APKs | `linux-lts-6.18.55-r0`, `zfs-lts-6.18.55-r0` |
| ZFS APKs | `zfs`, `zfs-libs`, `zfs-openrc`: `2.4.4-r0` |
| Loaded userspace/module | `zfs-2.4.4-1`, `zfs-kmod-2.4.4-1` |
| Incus server/client | `7.0.1-r1` / native client `7.5.1` |
| Incus supported ZFS driver | `2.4.4-1` |

The base archive was reverified with its detached signature, SHA-512 and pinned
cloud signer `F26ADFADBAE702EF7AF637459DA7EF23BFFCDF22`. The raw SHA-256 is
`47c0b69be2a3458c2a1ff11519e8f4b3f6565a73e89a2fe2294ed0ca3e496516`.
Full archive provenance and six signed APK SHA-256 values are in the evidence
summary. `apk verify` reported OK for all six retained packages.

## Production path, 2026-10-06

Disposable state `.integration/za` booted the production seed, not the qualification splice. The first boot installed the pinned packages, registered `tama-bootstrap`, and powered off with `TAMA_ZFS_KERNEL_REBOOT_REQUIRED` before Incus was ready. The second boot continued on `6.18.55-0-lts`. `findmnt` is not in the qualified `util-linux-misc` package; the first storage start refused an empty mount source. Replacing that check with `/proc/mounts` imported pool GUID `18341841560738065233` without recreating it.

Incus 7.0.1 reported `volume.zfs.reserve_space=true`, source `tama-data/workloads`, and a 2 GiB default root. `zfs list` after ordinary creates showed filesystem `refreservation` values of 1G metadata, 2G `za-c`, 2G `za-recovered`, 128M `za-vol`, 500M `za-vm`, and 128M `za-oci`. `za-vm.block` had volsize 4G and `refreservation=none`. The cached image zvol had volsize 10G and `refreservation=none`. A later 2 GiB create failed with `size is greater than available space` instead of creating an unreserved dataset.

After an 860 MiB incompressible fill, pool used was 6.60 GiB of 6.73 GiB. The autostart reboot became ready in 27 seconds. `za-c` still contained `marker-za-c-2`, the `s1` copy still contained `marker-za-c`, and `za-vm` exec returned `aarch64`. No `BLOCK_IO_ERROR` appeared on that reboot. This does not show that a later zvol write can grow into a full pool.

Stopped growth from 8 to 9 GiB raised pool total from 6725787648 to 7766024192 bytes and preserved those markers. Graceful stop logged `TAMA_ZFS_EXPORT_OK`. A forced stop also preserved the markers, VM agent and grown capacity on the next import. OCI `alpine` exec returned `Linux`. A writable VirtioFS share round-tripped a host token and a guest write after the share mount retried; a single early mount attempt had failed with the wrong filesystem type.

Failure preservation on 2026-10-06 used the production `storage.sh` and `bootstrap.sh`. A missing `zfs.ko.gz`/`spl.ko.gz` refused with `ZFS module is unavailable; disk left blank` and left the blank disk at `8479e43911dc45e89f934fe48d01297e16f51d17aa561d4d1c216b1ae0fcddca`. Foreign ext4 and an unknown nonblank disk were refused and kept their SHA-256. `intent-blank` without a recorded GUID refused before import and did not rewrite a foreign layout. Import of GUID `999` failed with `cannot import owned pool 999 from /dev/vdb1` and the disk hash stayed `9f81281442fa341fd1ba6137d566fe96cd903ac5427dc1bea0bdfa867f29fa7e`. A tmpfs already mounted at the metadata path was refused before import, with that same hash unchanged. Interrupted preseed invoked `tama-bootstrap` and logged `Interrupted initialization; preserve data for explicit recovery/reset` with no `incus admin init`. Phase stayed `preseed-pending`, GUID stayed `18341841560738065233`, and both pending/started markers were still on the dataset after export/import. The container marker remained `marker-za-c-2` (`6ba0ca411a4b418f6833caeff36571ac6243b149693c99a69b433d4c4d88b0c4`).

Recognized legacy ext4 `.integration/a8` was cloned, not modified. Its original SHA-256 stayed `18f45d67fa488e2085b0ced5b0defc6fbaf52fbc7b3e41ed080aef095d9cc266`. The clone logged `TAMA_STORAGE_EXT4_READY`, kept `driver: dir`, did not reseed a 2 GiB root, and the container file hash stayed `5db56381b34a41afa05b8527085f8eadc34c6f2e1c6e77debf4ac375c90fc926`.

On `.integration/za`, nested virtualization was enabled and the attached data file was 10737418240 bytes, later grown to 11811160064. Incus had set `volatile.vm.rtc_adjustment` to `17674211790`, and QEMU used `-rtc base=2002-04-14`, so the agent did not listen. Clearing that instance key once, on this fixture only, was enough. Later graceful restart, forced stop and growth kept `rtc_adjustment` at `0` without another manual clear. A 480 MiB write was only pressure, not exhaustion. The exhaustion case created custom volume `za-fill3` with `zfs.reserve_space=false`, `zfs.use_refquota=false` and `size=3GiB`, then `dd` failed with `No space left on device` after 2327707648 bytes. The volume's own `df` available fell from 2318401536 to 0, and Incus pool used equalled total `9856069632`. While that volume remained, `za-vm` was in `ERROR` and could not be started. After the appliance reboot, standard Incus exec showed `/root/tama-vm-data` still `c744ba8e2d9c8b30a8d09a5b525ff6eb279db524b31c8bbe7c81012f7d27b4dd`. The uniquely named filler was then deleted only after `used_by` was empty. Zvol `refreservation` remains none.

The cloud base boots kernel `6.18.52-0-lts`; available modules require a newer
kernel. An initial `.54` package candidate disappeared as the repository advanced
to `.55` during qualification. The prototype retains the resolved signed APKs,
installs a matching pair into a disposable writable root, and powers off before
creating ZFS storage. The second EFI boot loads the matched module. This is a
qualification bootstrap, **not** a released, prebuilt and fully pinned appliance.
Repository resolution alone cannot promise repeatable future package revisions.

The 157.5 MiB EFI partition initially lacked kernel-update staging space. Removing
unused DTBs only from the disposable writable root allowed the update; afterward
`/boot` used about 114 MiB. Production image preparation must handle this explicitly
and preserve its verified source image.

## Proven layout and operations

One virtual data disk backs `tama-data`, with whole-disk ZFS creation producing
the actual vdev `/dev/vdb1`. `tama-data/metadata` mounts at `/var/lib/incus`;
Incus receives only sibling `tama-data/workloads`. Standard preseed sets
`default.driver=zfs`, `source=tama-data/workloads`, `zfs.export=false`, and maps
the default profile's root device to `default`.

The fixture uses identifier `qualification-v1`. Production must introduce its own
versioned durable ownership/phase records; the prototype's root-side GUID is not
the complete production identity contract.

| Check | Result |
| --- | --- |
| EFI, virtio block/network, vsock relay, ZFS reload | Passed across repeated boots |
| Read-only/writable VirtioFS | Standard Incus disk devices verified host/guest content and write rejection |
| Containers and custom volumes | Launch/exec, random-data writes, 128 MiB quota, snapshots and checksums passed |
| Older snapshot `s1` with newer `s2`/`s3` and clone | Direct restore refused; all descendants retained |
| Copy older `s1` into a new instance | Passed, retaining newer snapshots and clone content |
| Nested Debian 13 VM | Guest-agent exec, random-data overwrite and snapshot/restore passed |
| VM custom block volume | 128 MiB boundary rejected beyond-device write; original data retained |
| Graceful shutdown | Incus stopped before parent-pool export; explicit successful-export marker verified |
| Forced stop | Same GUID and custom-volume checksum recovered without recreation |
| Stopped growth | Same GUID, metadata, snapshots/clones and custom-volume data retained; usable capacity increased |
| Guest workload-space exhaustion | Metadata-only reservation blocked autostart readiness; measured dataset/zvol refreservations restored it |
| Host filesystem exhaustion | Not exercised |

The actual refusal was: `Snapshot "s1" cannot be restored due to subsequent
snapshot(s). Set zfs.remove_snapshots to override`. No destructive rollback
options were enabled. Copy-to-new-instance is the verified recovery path; the
report does not claim unrestricted rollback or test destructive clone removal.
This agrees with the [upstream ZFS recovery constraints](https://linuxcontainers.org/incus/docs/main/reference/storage_zfs/).

Graceful export uses appliance-owned `zpool export` after Incus stops, which
unmounts the pool's datasets. Import scans the actual partition and selects the
expected GUID. `zpool online -e tama-data /dev/vdb` made stopped-state backing-file
growth usable without changing identity. Production still needs stronger device
identity and interrupted-phase checks than this disposable prototype.

## Memory, capacity and failure recovery

The baseline fixture used the existing 4 GiB RAM/32 GiB data defaults and grew to
33 GiB. Its Incus workload capacity increased from 32,397,938,688 to
33,453,965,312 bytes. Default ARC `c_max` was 3,030,818,816 bytes; observed ARC use
was much smaller. An explicit cap is preferable to leaving cache growth implicit.

A smaller fixture began at 2 GiB RAM/4 GiB data with a 512 MiB ARC cap and a
1 GiB metadata refreservation. It passed container/VM storage operations and grew
4 → 5 → 6 GiB over two runs. The 4 → 5 GiB run increased workload capacity from
2,816,393,216 to 3,864,883,200 bytes. These are workload-subtree capacities,
which exclude reserved metadata headroom, not virtual disk sizes.

During a repeat run, the 2 GiB stress fixture sampled 152,120 KiB `MemAvailable`
with nested VMs active and ARC capped. Retained VM fixtures make this unsuitable
as a clean single-VM minimum-memory benchmark. A later repeat run accumulated
three retained 1 GiB VMs that restarted according to their previous power state
in the 2 GiB guest. Incus crashed during
startup and readiness timed out, although the pool remained ONLINE with free
space. Temporarily raising RAM to 8 GiB recovered the same pool; all three VMs
were confirmed running and then stopped through Incus without deleting data.
Resource overcommit is the likely cause; retained kernel logs did not prove an
OOM kill. The runner now explicitly checks one VM through lifecycle/growth and
stops/disables its autostart after success, preventing cross-run accumulation.

The existing 512 MiB RAM / 1 GiB disk API minima remain **unqualified for ZFS**. Shipping resource limits and
any manifest/API validation changes must be resolved before production work.

An initial full-pool test used a 128 MiB metadata refreservation. Metadata already
used about 348 MiB because it includes cached image archives, so that reservation
provided no free headroom. After writing 3,914,203,136 filler bytes, workload space
ran out, the Incus relay failed, and reboot withheld readiness. The ONLINE pool
and its data were retained. While stopped, an offline APFS clone preserved this
full-pool state. Growing the same disk from 5 to 6 GiB restored readiness; GUID,
custom-volume SHA-256, all three snapshots and recovery markers matched. Only the
test filler was then removed through standard Incus operations.

With the revised 1 GiB reservation, the 5 GiB test reached workload ENOSPC while
Incus and original data remained available. The host file allocated 4,347,666,432
bytes under pressure; deleting the filler and completing `zpool trim` reduced
allocation to 1,088,159,744 bytes. Guest workload capacity was reclaimed too.
This proves sparse backing and trim through VZ on this host; it is not a general
host free-space guarantee. These are per-file allocated blocks; preserved APFS
clones can retain physical space independently.

Rebooting the 6 GiB fixture while workload space was exhausted returned Incus
but left containers stopped. Explicit start reported a credentials-directory
error. Standard filler detach reported ENOSPC writing the instance backup file,
but its database update had persisted: the filler volume showed `used_by: []`.
After verifying it was unused, deleting only that filler through Incus restored
container startup, the same GUID and the original custom-volume checksum. No
disk growth or direct workload-dataset deletion was needed. The failed full-pool
state was preserved in a second offline APFS clone before recovery. The runner
records these limitations and verifies actual detachment before filler deletion.

A fixed reservation protects free headroom only while metadata use stays below
it. Larger image caches can consume that protection. Production needs a measured
metadata-cache/headroom policy and checks for resource rejection before formatting;
simply copying the prototype's `refreservation=1G` is insufficient. A single vdev
also cannot repair loss of the host backing file; snapshots are not independent
backups.

The final 4 GiB run checked one explicit autostart VM. Its root checksum survived
graceful restart, forced stop and growth from 6 to 7 GiB; the memory sample had
2,301,628 KiB available. With workload space then exhausted, the full-space reboot
timed out on readiness despite about 672 MiB available to metadata. A separate
offline APFS clone preserved this failure. Stopped growth from 7 to 8 GiB restored
readiness and the same pool GUID; VM/custom-volume checksums, all three snapshots
and clone/recovery markers matched. The known filler was removed through Incus.

## Startup-headroom root cause

Historical diagnostic. Direct `zfs set` reservations on this clone are evidence
only. They are not the shipping appliance operation.

A later boot of an APFS clone of that preserved failure, not the original clone,
showed the cause. Memory was not exhausted: about 3.7 GiB remained available, ARC
stayed capped at 512 MiB, and there was no OOM message. `incusd` was running.
`tama-bridge` waited on `incusd waitready`, and Incus 7.0.1 does not report ready
until synchronous autostart finishes. The VM config dataset had a 500 MiB quota
but no refreservation, so its available space was 0. Autostart failed with
`symlink incus-agent .../config/lxd-agent: no space left on device`. Fifteen
retained `boot.autostart=true` containers then failed credentials creation. Each
failure is retried three times with a 5 second delay, which exceeded both the
180 second and a 420 second readiness wait.

Upstream `zfs.reserve_space=true` was accepted on the pool and VM volume but did
not set the companion refreservation. Reserving the zvol's full 10 GiB volsize
is not viable. The measured policy is appliance-owned refreservation: 128 MiB
for a VM config dataset, 32 MiB for a container root, and 256 MiB for a VM root
zvol, plus metadata refreservation that stays above referenced use. Without the
zvol reservation, QEMU stops on `BLOCK_IO_ERROR` with `nospace=true`.

Those reservations were applied on the diagnostic clone after stopped growth
from 7 to 8 GiB, without deleting the filler or modifying the preserved clone.
Metadata reservation was 768 MiB while referenced metadata was 370 MiB, leaving
420 MiB actually available. Incus still reported the workload pool exhausted.
The next restart was ready in 27 seconds. The autostart VM was running, GUID
`12013223106127235492` was unchanged, and both the VM root checksum
`08a57d0f6925478b2b918ec4fdfc18683cd55f9288100dd8c70d3908a76b8288` and custom
volume checksum `19d8f8018a75f88fde206a602706e533d41abb1d0421682579503517dbc9dc02`
matched. A full pool still cannot grow a sparse zvol beyond its reservation.
Those direct reservations mutated Incus-owned datasets. They explain the failure;
they are not the shipping operation. Production asks Incus to reserve a volume's
own size at creation time and does not itself modify workload datasets. The
2026-10-06 production boot measured that Incus applies this to filesystem
datasets and not to VM or image zvols.

## Acceptance boundary

The broad existing runtime runner reached Linux/Incus readiness, Alpine detection
and standard Unix/vsock client access, then timed out after 600 seconds downloading
the Debian system-container image. That run failed and its workloads were retained.
The focused ZFS runner independently proves container networking, VirtioFS and
nested VM storage; it does not complete the broad OCI cache-reuse suite.

The kernel, layout, filesystem-reservation and failure-preservation gates recorded
below are proven on disposable state. Historical sections above remain the
qualification record and are not rewritten as if they were the production path.
There is no automatic backend fallback, migration or root-image replacement.
A 4 GiB data disk is only the guest floor before formatting. Mixed container/VM
work was measured on 8–11 GiB disks, not qualified as a 4 GiB minimum.
The guest rejects formatting only when MemTotal is below 3670016 KiB. That is
not a check of the host's 4096 MiB configuration.

The 14-file CodeRabbit result below is historical. It is not the current review.
That historical review found two minor help-text findings, then a verification
review of the same 14 files reported zero findings.

Current reviews covered 27 files. One completed with `outcome=completed` and one
major qualification-guard finding, which was fixed by counting the exact install
and reboot lines. A later 27-file run finished with
`outcome=completed_with_warnings` and `Review completed with unverified findings`.
That warning-bearing run is not a clean review. Its minor completed-marker finding
was fixed with an explicit refusal when a completed appliance lacks its qualified
kernel record, and independently verified without package, storage or preseed work.
Final parent canonical checks passed with 50 Swift tests, 46 Python tests and the
isolated install; strict OpenSpec passed 7/7 and `git diff --check` passed. Task 5.4
is complete. Task 5.3 is closed after the user's clarification and restoration
of a15's intended stopped daemon state; the cleanup incident remains documented.
Development remains on
`feature/zfs-storage`; no release, merge or publication is established by this report.

Useful primary references: [Incus ownership and storage behavior](https://linuxcontainers.org/incus/docs/main/reference/storage_zfs/),
[OpenZFS Alpine packages and module loading](https://openzfs.github.io/openzfs-docs/Getting%20Started/Alpine%20Linux/index.html),
and [OpenZFS device expansion](https://openzfs.github.io/openzfs-docs/Basic%20Concepts/Pool%20Structure/Changing%20Pool%20Layout.html).

## Pre-publication verification, 2026-10-06

A fresh 27-file CodeRabbit review found a major qualification-seed indentation defect introduced during refactoring. It was corrected with dedented init and cloud-config literals and an emitted-seed regression. The parent independently ran preparation with mocked image/ISO operations, parsed the generated cloud-config, verified top-level bootcmd/runcmd and six write_files entries, and checked init-script shell syntax and the first-line shebang. Canonical checks passed with 50 Swift and 46 Python tests; strict OpenSpec passed 7/7. The verification CodeRabbit review completed normally with two minor documentation findings concerning task status and counts. Those records now match the independent checks; task 5.4 is complete. This is not a claim of a zero-findings review.
