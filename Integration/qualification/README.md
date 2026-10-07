# Opt-in ZFS compatibility qualification

This prototype is separate from production appliance preparation. It changes only
new disposable appliances under this checkout's ignored `.integration/` directory.
It does not qualify production disk classification, interrupted provisioning or
legacy preservation. See [the recorded results](../../docs/zfs-qualification.md).

Use an Apple Silicon Mac with native Virtualization.framework support. Nested VM
checks additionally require supported/enabled nesting and usable guest KVM. Start
with the signed, verified Alpine raw image from [development setup](../../docs/development.md).
Use a verified standard Incus client; no host VM CLI is involved.

Build, copy and sign a dedicated daemon, then prepare a **new** fixture:

```sh
swift build -Xswiftc -warnings-as-errors
mkdir -p .integration/zfs-bin
cp .build/debug/macus .integration/zfs-bin/macus
codesign --force --sign - --entitlements Packaging/virtualization.entitlements \
  .integration/zfs-bin/macus
codesign --verify --strict .integration/zfs-bin/macus
python3 Integration/qualification/prepare-zfs.py \
  --root-disk .integration/cache/verified-alpine/disk.raw \
  --output .integration/zfs-appliance --memory-mib 4096 --data-disk-gib 4
.integration/zfs-bin/macus serve --state-dir "$PWD/.integration/zfs-state"
```

The default preparation settings are 4096 MiB RAM and 32 GiB data. The smaller data-disk
fixture above is required for the bounded space-exhaustion check. Preparation
rejects less than 2048 MiB or 4 GiB and refuses an existing output directory.
The generated configuration includes dedicated read-only/writable share fixtures;
their 0777 permissions apply only to disposable test directories.

In another terminal, create the runtime and boot:

```sh
curl --fail --silent --show-error --unix-socket .integration/zfs-state/runtime.sock \
  -X POST -H 'Content-Type: application/json' \
  --data-binary @.integration/zfs-appliance/config.json \
  http://localhost/v1/runtime/create
curl --fail --silent --show-error --unix-socket .integration/zfs-state/runtime.sock \
  -X POST http://localhost/v1/runtime/start
```

The first boot resolves signed packages from Alpine v3.24 main/community and
retains the kernel/ZFS APK snapshot. It replaces the disposable writable root's
kernel, removes unused EFI-partition DTBs to provide staging space, then powers
off when the running kernel differs. This first start returns HTTP 503. Inspect
`serial.log` for `TAMA_ZFS_KERNEL_REBOOT_REQUIRED` and the expected kernel before
starting again. An unrelated 503 is a failure to investigate, not a retry signal.
No pool is created until the matching kernel has booted and its module loads.

```sh
curl --fail --silent --show-error --unix-socket .integration/zfs-state/runtime.sock \
  -X POST http://localhost/v1/runtime/start
python3 Integration/qualification/run-zfs.py --hardware-opt-in --space-exhaustion \
  --state-dir .integration/zfs-state --incus /absolute/path/to/incus \
  --report .integration/zfs-report.json
```

The runner checks the fixture marker, actual ZFS default and root profile before
launching workloads. It uses a private `INCUS_CONF` and unique names, standard
Incus operations, controlled outer restarts/forced stop, and stopped disk growth
by 1 GiB. Container DHCP can lag exec readiness; the network check waits up to
roughly 150 seconds. It retains workloads and the JSON command transcript on
both success and failure. Successful VM fixtures are stopped with autostart
disabled; failed fixtures are retained for diagnosis. Before rerunning a failed
fixture, account for its existing VM memory and previous-power-state autostart
behavior. The 2 GiB setting is a stress boundary, not a qualified arbitrary-VM
memory minimum; use 4 GiB for the full default-memory run.

`--space-exhaustion` requires at most a 7 GiB configured data disk before growth
and at least 12 GiB of free host space. It writes incompressible data until guest
workload space is exhausted, checks access and attempts reboot recovery, then
removes only its verified unused filler volume if those checks succeed. The
recorded autostart-VM full-space reboot failed until measured refreservations
were applied. Failures still preserve the filler and disks for recovery.
Omit the flag to run normal lifecycle/storage checks separately. This does **not** fill the
host filesystem. Omitting the flag still exercises a bounded custom-volume quota.

The candidate policy is a 512 MiB ARC cap and a 1 GiB metadata refreservation.
The reservation protects capacity only while metadata use remains below it;
cached images count against metadata. Production must protect actual free
headroom as metadata grows. These are measured prototype settings, not new
production configuration guarantees.

Preserve failed disks and reports. Even with metadata headroom, containers can fail to start at zero
workload space. Detach can report an ENOSPC backup-file error after persisting
the database update; verify the filler volume is actually unused before deleting
it. A full-pool recovery may require stopping the
fixture, preserving an offline clone, increasing its data size through the
control API, and importing the same pool. Never format, reset or replace failed
state to obtain a passing result. Stop the disposable runtime after testing:

```sh
curl --fail --silent --show-error --unix-socket .integration/zfs-state/runtime.sock \
  -X POST http://localhost/v1/runtime/stop
```

Repository checks perform no hardware execution:

```sh
Integration/scripts/check.sh
mise exec -- openspec validate --all --strict --no-interactive
```
