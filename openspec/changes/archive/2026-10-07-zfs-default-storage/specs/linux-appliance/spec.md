# Spec Delta

## MODIFIED Requirements

### Requirement: Separate persistent storage

Incus metadata and workloads SHALL reside on a separate persistent data disk prepared before Incus starts. Existing recognizable filesystems and pools MUST NOT be formatted or recreated. Unknown nonblank data MUST fail provisioning. Storage identity and layout version SHALL be verified before reusing initialized storage.

#### Scenario: Restart persistence

- **WHEN** an instance exists and the outer VM restarts
- **THEN** the same Incus instance and data remain available

#### Scenario: Unknown data

- **WHEN** the attached disk contains nonblank data without a recognized owned layout
- **THEN** provisioning fails, preserves disk bytes and does not advertise readiness

#### Scenario: Owned ZFS pool returns

- **WHEN** a previously initialized ZFS appliance restarts
- **THEN** it reuses the same pool identity, persistent metadata and workload storage without recreating the pool or reseeding Incus

### Requirement: Appliance provisioning

Provisioning SHALL be idempotent and use a pinned, maintained Alpine Linux ARM64 base, OpenRC service management and signature-verified APK packages from main/community repositories on the same stable release branch. It SHALL install Incus with its LXC, OCI and ARM64 VM dependencies, the helper, and compatible ZFS userspace and boot-kernel modules for fresh ZFS appliances. It MUST NOT mix edge repositories, bypass package signature verification or include development/desktop/orchestration software.

#### Scenario: Repeated provisioning

- **WHEN** a previously initialized data disk is booted again
- **THEN** storage and profiles remain intact and initialization does not reset workloads

#### Scenario: Alpine service ordering

- **WHEN** OpenRC starts services on first boot or a subsequent boot
- **THEN** cgroup/kernel prerequisites and persistent storage are ready before Incus starts, and helper health reports readiness only after the Incus API responds and the selected storage layout is validated

#### Scenario: Alpine kernel support

- **WHEN** the selected Alpine image is validated on a supported Mac
- **THEN** EFI, virtio storage/networking, vsock, configured VirtioFS, and container kernel prerequisites work, ZFS modules load for the booted kernel on a fresh ZFS appliance, and nested VM capability additionally requires usable guest KVM and ARM64 VM dependencies

### Requirement: Disk growth

Stopped-state disk growth SHALL preserve existing bytes. The guest SHALL make added capacity usable in the recognized backend before starting Incus, by expanding the existing ZFS backing device and pool or growing the legacy ext4 filesystem. Growth MUST NOT recreate storage or change its driver. Shrink SHALL be unsupported.

#### Scenario: Offline growth

- **WHEN** the user increases the disk size and starts the VM
- **THEN** existing Incus data remains intact and new capacity becomes usable

#### Scenario: ZFS growth retains identity

- **WHEN** an initialized ZFS appliance starts after stopped-state disk growth
- **THEN** the same pool exposes increased usable capacity and retains metadata, instances, custom volumes and snapshots

#### Scenario: Growth failure

- **WHEN** the guest cannot safely expand its recognized storage layout
- **THEN** it preserves existing data, reports the failure and does not advertise readiness

## ADDED Requirements

### Requirement: Default storage qualification

ZFS is the selected default. Qualification SHALL include recorded ZFS evidence for older-snapshot recovery, workload support, quotas, resources, persistence and growth before production provisioning is implemented. The report MUST distinguish direct restore from copying a snapshot to a new instance and identify unsupported or pending checks. Btrfs comparative hardware testing and automatic backend fallback are outside this change.

#### Scenario: Older-snapshot recovery

- **WHEN** ZFS recovery behavior is qualified
- **THEN** the report records direct restore to an older snapshot with newer snapshots and clones present, verifies retained data or records required deletion/refusal, and separately records copy-to-new-instance recovery

#### Scenario: Compatibility gate fails

- **WHEN** the selected ZFS image, packages or storage layout fail qualification
- **THEN** production implementation remains blocked until the plan is reconciled and validated; no runtime fallback or backend switch is inferred

#### Scenario: Unavailable VM evidence

- **WHEN** nested KVM is unavailable on the qualification hardware
- **THEN** VM storage evidence remains explicitly unsupported or pending and the qualification report describes that limitation

### Requirement: Out-of-the-box ZFS storage

Once ZFS is qualified as the default, a fresh appliance with a verified blank data disk SHALL automatically initialize Incus's `default` storage pool using `zfs` and point the default profile's root disk to it. It MUST NOT require manual pool setup or a ZFS selection flag. Missing or incompatible ZFS support MUST fail before destructive disk initialization and MUST NOT silently select another driver.

#### Scenario: Fresh default

- **WHEN** a new supported appliance boots with blank persistent storage
- **THEN** standard Incus commands report `default` with driver `zfs`, the default profile selects it and instances use it without manual storage setup

#### Scenario: Missing module

- **WHEN** ZFS userspace or the matching boot-kernel module is unavailable
- **THEN** fresh initialization fails with an actionable error, the blank data disk remains unformatted and readiness is withheld

#### Scenario: Unexpected default driver

- **WHEN** a fresh ZFS layout has an Incus default pool using another driver
- **THEN** readiness is withheld with a configuration error and existing storage is preserved

### Requirement: Legacy storage preservation

Recognized existing ext4 appliances SHALL retain their Incus configuration and `dir` storage without automatic conversion, reseeding or root-image replacement. Existing pools, profiles and workloads MUST be preserved. A filesystem alone without a recognized initialized or safely resumable appliance layout MUST NOT authorize initialization over existing data.

#### Scenario: Existing ext4 appliance

- **WHEN** a recognized legacy appliance is booted or checked
- **THEN** its existing driver, pool configuration, profiles and workload data remain intact

#### Scenario: Foreign ext4 disk

- **WHEN** an ext4 disk lacks a recognized appliance layout or contains uncertain initialization state
- **THEN** provisioning preserves it and requires explicit recovery instead of converting or reseeding it

### Requirement: Storage ownership boundary

Appliance metadata SHALL persist outside the storage subtree controlled by Incus. Incus SHALL exclusively manage the workload subtree it receives. Appliance boot or recovery MUST NOT manage Incus workload datasets, volumes, snapshots or clones directly. Storage reuse MUST verify attached-device and pool identity rather than trusting a pool name alone.

#### Scenario: Incus removes a workload

- **WHEN** the standard Incus client deletes an instance or volume from the default pool
- **THEN** appliance metadata and storage identity remain available across restart

#### Scenario: Pool name collision

- **WHEN** a discovered pool shares the expected name but has a different identity or backing device
- **THEN** it is not adopted, wiped or forcibly imported and readiness is withheld

### Requirement: Non-destructive storage recovery

Storage import, mount and shutdown SHALL be ordered around Incus startup and stop. Interrupted initialization and failed import or mount MUST preserve disk data and durable phase evidence. Recovery SHALL resume only phases proven safe for the recognized layout; uncertain state MUST fail with diagnostics rather than reset storage or force pool adoption.

#### Scenario: Interrupted initialization

- **WHEN** first boot stops after storage creation or during Incus preseed
- **THEN** the next boot verifies identity and durable phase, resumes only proven safe work or reports explicit recovery, and does not format or blindly repeat preseed

#### Scenario: Failed import

- **WHEN** the expected ZFS pool cannot be safely imported or mounted
- **THEN** Incus readiness is withheld and the pool is preserved for recovery

#### Scenario: Forced stop recovery

- **WHEN** the outer VM was explicitly force-stopped after successful initialization
- **THEN** a subsequent boot recovers the same storage identity and retained workload data without recreating the pool

#### Scenario: Graceful shutdown

- **WHEN** the appliance shuts down normally
- **THEN** Incus stops before persistent storage is unmounted and the appliance-owned pool is exported

### Requirement: ZFS acceptance evidence

ZFS default support SHALL require separately recorded opt-in hardware acceptance on isolated state using the tested Alpine image and package versions. Evidence MUST distinguish actual storage checks from mocks and historical ext4 results, and report unsupported nested VM capability explicitly. Unit tests alone MUST NOT establish ZFS acceptance.

#### Scenario: Hardware gate

- **WHEN** ZFS default support is marked accepted
- **THEN** recorded checks demonstrate the actual `zfs` driver, container and custom-volume operations, snapshots and clones, restart and forced-stop persistence, disk growth, failure preservation and legacy compatibility, with VM storage checks passing where nesting is supported

#### Scenario: Hardware checks remain pending

- **WHEN** unit checks pass but hardware acceptance has not run or a required storage check fails
- **THEN** ZFS acceptance remains pending and documentation does not claim validated out-of-the-box support

### Requirement: Qualified ZFS resource and metadata headroom policy

Fresh ZFS provisioning SHALL validate the qualified memory and disk envelope before formatting. The hardware-qualified fresh-ZFS host configuration is 4096 MiB RAM and at least 8 GiB of data for mixed workloads; a 4 GiB data disk is only the guest floor before formatting, not a proven mixed-workload minimum. The guest can see MemTotal, not the host configuration, and SHALL reject formatting when MemTotal is below 3670016 KiB. That guest gate MUST NOT be described as rejecting every host configuration below 4096 MiB. The existing 512 MiB/1 GiB configuration minima MUST NOT be treated as ZFS-qualified. The appliance SHALL set a 512 MiB ARC cap and an initial 1 GiB metadata refreservation on its own metadata dataset. It MUST NOT set properties on Incus-owned workload datasets. Workload space protection SHALL be requested only through upstream Incus pool configuration `volume.zfs.reserve_space` and `volume.zfs.use_refquota`, plus a sized default-profile root, so Incus applies reservations when it creates volumes. Measured Incus 7.0.1 behavior is that this request reserves filesystem datasets at creation and does not set zvol `refreservation`. The appliance MUST NOT compensate by setting properties on Incus-owned zvols. A full pool MUST NOT be described as able to grow a sparse zvol. Metadata headroom is available space inside the metadata reservation; a consumed reservation MUST NOT count as free capacity. If metadata available space is below 256 MiB at readiness, readiness fails without reformatting. Exhaustion MUST preserve pool identity and existing data and expose failures through existing diagnostics and standard Incus operations.

#### Scenario: Unqualified resource boundary

- **WHEN** fresh ZFS formatting sees MemTotal below 3670016 KiB or a data disk below 4 GiB
- **THEN** it rejects provisioning with a resource diagnostic before formatting and preserves the disk
- **AND** the hardware-qualified envelope remains a 4096 MiB host configuration and at least 8 GiB of data for mixed workloads; that envelope is not a stricter guest or host-API rejection, and the 512 MiB/1 GiB host minima stay valid for recognized legacy ext4

#### Scenario: Workload space exhaustion

- **WHEN** workload storage reaches zero free space while protected metadata headroom remains
- **THEN** the same pool and metadata are retained, blocked workload writes or startup are reported through existing diagnostics, and recovery uses standard Incus operations when available or stopped disk growth without pool recreation

#### Scenario: Metadata consumes its reservation

- **WHEN** cached images or other metadata approach the protected capacity
- **THEN** the appliance enforces the qualified headroom policy or reports capacity failure without recreating storage, switching drivers or claiming the consumed reservation is free capacity

#### Scenario: Full-space VM-autostart qualification

- **WHEN** mixed-workload full-space reboot is qualified with an autostart VM
- **THEN** measured startup-headroom policy supports the required Incus readiness or the failed case remains an explicit blocking qualification result with preservation/recovery evidence
