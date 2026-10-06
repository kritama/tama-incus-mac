#!/bin/sh
# Appliance storage only. Incus remains the only manager of workload datasets.
set -eu
umask 077

action=${1:-start}
root=${TAMA_STORAGE_ROOT:-}
disk=${TAMA_DISK:-/dev/vdb}
pool=tama-data
layout=zfs-v1
metadata_mount=${TAMA_METADATA_MOUNT:-/var/lib/incus}
identity=$root/etc/tama-storage
log=${TAMA_STORAGE_LOG:-$root/var/log/tama-storage.log}
run_dir=$root/run
inspect=$root/mnt/tama-inspect
# Guest-visible gate only. A 4096 MiB VZ configuration reports MemTotal below 4096 MiB.
# This check does not reject every host configuration below 4096 MiB.
min_mem_kib=3670016
min_disk_bytes=4294967296
metadata_min_available=268435456
arc_max=536870912
growth_slack=16777216

mkdir -p "$(dirname "$log")" "$identity" "$run_dir"
exec >>"$log" 2>&1

note() { printf '%s\n' "$*"; }

refuse() {
    note "TAMA_STORAGE_REFUSED: $*"
    exit 1
}

mem_kib() {
    if [ -n "${TAMA_MEMINFO:-}" ]; then
        awk '/MemTotal:/ {print $2}' "$TAMA_MEMINFO"
    else
        awk '/MemTotal:/ {print $2}' /proc/meminfo
    fi
}

disk_bytes() {
    if [ -f "$disk" ]; then
        wc -c <"$disk" | tr -d ' '
    else
        blockdev --getsize64 "$disk"
    fi
}

blank_disk() {
    python3 - "$disk" <<'PY'
import sys
zero = bytes(1024 * 1024)
with open(sys.argv[1], "rb", buffering=0) as disk:
    while chunk := disk.read(len(zero)):
        if chunk != zero[: len(chunk)]:
            raise SystemExit(1)
raise SystemExit(0)
PY
}

write_atomic() {
    target=$1
    value=$2
    temporary=$target.tmp
    printf '%s\n' "$value" >"$temporary"
    sync
    mv "$temporary" "$target"
    sync
}

read_token() {
    if [ ! -f "$1" ]; then
        printf '\n'
        return 0
    fi
    tr -d '\n' <"$1"
}

phase_is_safe() {
    case "$1" in
        intent-blank|pool-created|datasets-ready|preseed-pending|ready) return 0 ;;
        *) return 1 ;;
    esac
}

load_zfs() {
    mkdir -p "$root/etc/modprobe.d"
    printf 'options zfs zfs_arc_max=%s\n' "$arc_max" >"$root/etc/modprobe.d/tama-zfs.conf"
    modprobe zfs || return 1
    if [ -w /sys/module/zfs/parameters/zfs_arc_max ]; then
        printf '%s\n' "$arc_max" >/sys/module/zfs/parameters/zfs_arc_max
    fi
}

backend_file() { write_atomic "$run_dir/tama-storage-backend" "$1"; }

mount_shares() {
    mkdir -p "$root/mnt/tama-shares"
    grep -q virtiofs /proc/filesystems 2>/dev/null || modprobe virtiofs || return 0
    mountpoint -q "$root/mnt/tama-shares" && return 0
    # The virtiofs tag can appear slightly after the guest starts. An empty share
    # set never appears; do not fail storage readiness for that.
    i=0
    while [ "$i" -lt 10 ]; do
        if mount -t virtiofs tama-shares "$root/mnt/tama-shares"; then
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done
    note "TAMA_SHARES_UNAVAILABLE"
}

legacy_markers() {
    mount_point=$1
    [ -e "$mount_point/database" ] || [ -e "$mount_point/.tama-preseed-pending" ] || [ -e "$mount_point/server.crt" ]
}

mounted_source() {
    # /proc/mounts is always present; findmnt is not in the qualified package set.
    mounts=${TAMA_PROC_MOUNTS:-/proc/mounts}
    awk -v target="$1" '$2 == target { print $1; found = 1; exit } END { if (!found) exit 1 }' "$mounts" 2>/dev/null || true
}

mount_owned_metadata() {
    source=$(mounted_source "$metadata_mount")
    if [ -z "$source" ]; then
        zfs mount "$pool/metadata" || refuse "cannot mount owned metadata dataset"
        source=$(mounted_source "$metadata_mount")
    fi
    if [ -z "$source" ] && [ "$(zfs get -H -o value mounted "$pool/metadata")" = yes ]; then
        source=$pool/metadata
    fi
    [ "$source" = "$pool/metadata" ] || refuse "unexpected filesystem mounted at metadata target: ${source:-absent}"
}

exact_vdev() {
    zpool status -P "$pool" | awk -v disk="$disk" '
        $1 == disk || $1 == disk "1" { found = 1 }
        END { exit found ? 0 : 1 }
    '
}

preserve_and_refuse() {
    zpool export "$pool" >/dev/null 2>&1 || true
    refuse "$@"
}

recover_intent_pool() {
    # A root intent does not prove that the attached nonblank pool is ours.
    guid=$(read_token "$identity/pool-guid")
    [ -n "$guid" ] || refuse "intent-blank has no recorded pool GUID; nonblank disk preserved"
    vdev=$disk
    if [ -e "${disk}1" ]; then vdev=${disk}1; fi
    zpool import -N -d "$vdev" "$guid" || refuse "interrupted pool $guid cannot be imported from $vdev; disk preserved"
    actual=$(zpool get -H -o value guid "$pool")
    if [ "$actual" != "$guid" ] || ! exact_vdev; then
        preserve_and_refuse "interrupted pool is not the recorded pool on the attached data disk"
    fi
    if zfs list -H -o name "$pool/metadata" >/dev/null 2>&1; then
        mount_owned_metadata || preserve_and_refuse "cannot inspect interrupted metadata; disk preserved"
        existing=$(read_token "$metadata_mount/.tama-storage-layout")
        if [ -n "$existing" ] && [ "$existing" != "$layout" ]; then
            preserve_and_refuse "foreign metadata layout ${existing}; disk preserved"
        fi
        if [ -e "$metadata_mount/database" ]; then
            preserve_and_refuse "interrupted metadata already has an Incus database; disk preserved"
        fi
    fi
    write_atomic "$identity/phase" pool-created
}

expand_vdev() {
    before=$(zpool get -Hp -o value size "$pool")
    zpool online -e "$pool" "$disk" || refuse "vdev expansion failed; pool preserved"
    after=$(zpool get -Hp -o value size "$pool")
    [ "$after" -ge "$before" ] || refuse "pool size shrank during expansion"
    expandsize=$(zpool get -Hp -o value expandsize "$pool")
    case "$expandsize" in
        ""|"-"|0) ;;
        *) [ "$expandsize" -le "$growth_slack" ] || refuse "vdev expansion is still pending: $expandsize" ;;
    esac
    note "TAMA_STORAGE_GROWTH $before $after"
}

reject_foreign_metadata() {
    zfs list -H -o name "$pool/metadata" >/dev/null 2>&1 || return 0
    mount_owned_metadata || preserve_and_refuse "cannot inspect metadata; disk preserved"
    existing=$(read_token "$metadata_mount/.tama-storage-layout")
    if [ -n "$existing" ] && [ "$existing" != "$layout" ]; then
        preserve_and_refuse "foreign metadata layout ${existing}; disk preserved"
    fi
    if [ -e "$metadata_mount/database" ]; then
        preserve_and_refuse "metadata already has an Incus database; disk preserved"
    fi
}

ensure_datasets() {
    reject_foreign_metadata
    zfs list -H -o name "$pool/metadata" >/dev/null 2>&1 || zfs create -o mountpoint="$metadata_mount" "$pool/metadata"
    mount_owned_metadata
    reject_foreign_metadata
    current=$(zfs get -Hp -o value refreservation "$pool/metadata")
    [ "$current" = "-" ] && current=0
    if [ "$current" -lt 1073741824 ]; then
        zfs set refreservation=1G "$pool/metadata" || refuse "cannot reserve metadata headroom"
    fi
    zfs list -H -o name "$pool/workloads" >/dev/null 2>&1 || zfs create -o mountpoint=none "$pool/workloads"
    printf '%s\n' "$layout" >"$metadata_mount/.tama-storage-layout"
    sync
}

import_owned_pool() {
    recorded_layout=$(read_token "$identity/layout")
    recorded_phase=$(read_token "$identity/phase")
    guid=$(read_token "$identity/pool-guid")
    phase_is_safe "$recorded_phase" || refuse "unknown or interrupted phase: ${recorded_phase:-absent}"
    if [ "$recorded_phase" = pool-created ]; then
        [ -z "$recorded_layout" ] || [ "$recorded_layout" = "$layout" ] || refuse "unknown storage layout version: $recorded_layout"
    else
        [ "$recorded_layout" = "$layout" ] || refuse "unknown storage layout version: ${recorded_layout:-absent}"
    fi
    [ -n "$guid" ] || refuse "owned pool GUID is missing; disk preserved"
    if zpool list -H -o name "$pool" >/dev/null 2>&1; then
        actual=$(zpool get -H -o value guid "$pool")
        [ "$actual" = "$guid" ] || refuse "imported pool GUID $actual does not match owned $guid; not exporting it"
    else
        vdev=$disk
        if [ -e "${disk}1" ]; then vdev=${disk}1; fi
        zpool import -N -d "$vdev" "$guid" || refuse "cannot import owned pool $guid from $vdev"
    fi
    actual=$(zpool get -H -o value guid "$pool")
    [ "$actual" = "$guid" ] || refuse "pool GUID $actual does not match owned $guid"
    exact_vdev || refuse "owned pool is not backed by the attached data disk"
    [ "$recorded_phase" = intent-blank ] && refuse "intent phase cannot own an imported pool"
    if [ "$recorded_phase" = pool-created ] || [ "$recorded_phase" = datasets-ready ]; then
        reject_foreign_metadata
        if [ "$recorded_phase" = pool-created ]; then
            ensure_datasets
            write_atomic "$identity/layout" "$layout"
        else
            mount_owned_metadata
        fi
        if [ -e "$metadata_mount/database" ]; then
            preserve_and_refuse "$recorded_phase phase already has an Incus database; state preserved"
        fi
        touch "$metadata_mount/.tama-preseed-pending"
        sync
        write_atomic "$identity/phase" preseed-pending
        recorded_phase=preseed-pending
    fi
    expand_vdev
    [ "$(zfs get -H -o value mountpoint "$pool/metadata")" = "$metadata_mount" ] || refuse "metadata mountpoint mismatch"
    [ "$(zfs get -H -o value name "$pool/metadata")" = "$pool/metadata" ] || refuse "metadata dataset identity mismatch"
    mount_owned_metadata
    [ "$(read_token "$metadata_mount/.tama-storage-layout")" = "$layout" ] || refuse "on-disk layout version mismatch"
    backend_file zfs
    note "TAMA_STORAGE_ZFS_READY $guid"
}

create_zfs() {
    kib=$(mem_kib)
    bytes=$(disk_bytes)
    [ "$kib" -ge "$min_mem_kib" ] || refuse "ZFS guest MemTotal ${kib} KiB is below ${min_mem_kib} KiB; host configurations below 4096 MiB are not ZFS-qualified"
    [ "$bytes" -ge "$min_disk_bytes" ] || refuse "ZFS requires at least 4 GiB; disk is ${bytes} bytes"
    load_zfs || refuse "ZFS module is unavailable; disk left blank"
    existing=$(read_token "$identity/phase")
    if [ -n "$existing" ] && [ "$existing" != intent-blank ]; then
        refuse "interrupted ZFS phase $existing cannot create a pool"
    fi
    if [ "$existing" = intent-blank ]; then
        blank_disk || refuse "interrupted ZFS intent has a nonblank disk; disk preserved"
        [ ! -f "$identity/pool-guid" ] || refuse "intent phase has a pool GUID; disk preserved"
    else
        write_atomic "$identity/phase" intent-blank
        write_atomic "$identity/intent" blank-verified
    fi
    zpool create -o ashift=12 -O mountpoint=none -O compression=lz4 -O dedup=off "$pool" "$disk" \
        || refuse "pool creation failed; disk preserved"
    write_atomic "$identity/pool-guid" "$(zpool get -H -o value guid "$pool")"
    write_atomic "$identity/phase" pool-created
    ensure_datasets
    write_atomic "$identity/layout" "$layout"
    write_atomic "$identity/phase" datasets-ready
    touch "$metadata_mount/.tama-preseed-pending"
    sync
    write_atomic "$identity/phase" preseed-pending
    backend_file zfs
    note "TAMA_STORAGE_ZFS_CREATED $(read_token "$identity/pool-guid")"
}

inspect_ext4() {
    mkdir -p "$inspect"
    # noload avoids journal replay, so inspection does not change disk bytes.
    mount -o ro,noload "$disk" "$inspect" || refuse "cannot inspect ext4 without modifying it; disk preserved"
    recognized=1
    label=$(blkid -s LABEL -o value "$disk" || true)
    if [ "$label" != tama-incus-data ] || ! legacy_markers "$inspect"; then
        recognized=0
    fi
    umount "$inspect" || refuse "cannot unmount ext4 inspection; disk preserved"
    [ "$recognized" -eq 1 ]
}

start_ext4() {
    inspect_ext4 || refuse "ext4 lacks a complete recognized appliance layout; disk preserved"
    source=$(mounted_source "$metadata_mount")
    if [ -n "$source" ] && [ "$source" != "$disk" ]; then
        refuse "unexpected filesystem mounted at metadata target: $source"
    fi
    if [ "$source" != "$disk" ]; then
        e2fsck -fp "$disk" || [ "$?" -eq 1 ]
        resize2fs "$disk"
        mkdir -p "$metadata_mount"
        mount -o defaults "$disk" "$metadata_mount"
    fi
    legacy_markers "$metadata_mount" || refuse "recognized ext4 markers disappeared after mount"
    backend_file ext4
    note "TAMA_STORAGE_EXT4_READY"
}

refuse_if_metadata_mount_unexpected() {
    source=$(mounted_source "$metadata_mount")
    [ -z "$source" ] && return 0
    if [ "$source" = "$pool/metadata" ] || [ "$source" = "$disk" ]; then
        return 0
    fi
    refuse "unexpected filesystem mounted at metadata target: $source"
}

start_storage() {
    modprobe vmw_vsock_virtio_transport || true
    modprobe virtiofs || true
    modprobe vhost_vsock || true
    modprobe tun || true
    kind=$(blkid -s TYPE -o value "$disk" || true)
    recorded_phase=$(read_token "$identity/phase")
    # Refuse before import or repair so a foreign mount cannot mutate the disk.
    refuse_if_metadata_mount_unexpected
    if [ "$recorded_phase" = intent-blank ]; then
        if blank_disk; then
            create_zfs
        else
            recover_intent_pool
            import_owned_pool
        fi
    elif [ -f "$identity/pool-guid" ] || [ -f "$identity/phase" ] || [ -f "$identity/layout" ]; then
        load_zfs || refuse "owned ZFS pool cannot load its module; disk preserved"
        import_owned_pool
    elif [ "$kind" = ext4 ]; then
        start_ext4
    elif [ -z "$kind" ]; then
        if blank_disk; then
            create_zfs
        else
            refuse "nonblank disk has no recognized signature"
        fi
    elif [ "$kind" = zfs_member ]; then
        refuse "foreign ZFS member has no owned identity"
    else
        refuse "unknown data signature: $kind"
    fi
    mount_shares
}

stop_storage() {
    if [ -f "$identity/pool-guid" ] && zpool list -H -o name "$pool" >/dev/null 2>&1; then
        actual=$(zpool get -H -o value guid "$pool")
        [ "$actual" = "$(read_token "$identity/pool-guid")" ] || refuse "refusing to export a different pool GUID"
        zpool export "$pool" && note "TAMA_ZFS_EXPORT_OK"
    elif mountpoint -q "$metadata_mount"; then
        source=$(mounted_source "$metadata_mount")
        [ "$source" = "$disk" ] || refuse "refusing to unmount unexpected metadata source: ${source:-absent}"
        umount "$metadata_mount"
    fi
}

fresh_contract() {
    config=$(incus query /1.0/storage-pools/default)
    reserve=$(printf '%s' "$config" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("config",{}).get("volume.zfs.reserve_space",""))')
    refquota=$(printf '%s' "$config" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("config",{}).get("volume.zfs.use_refquota",""))')
    profile=$(incus query /1.0/profiles/default)
    profile_pool=$(printf '%s' "$profile" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("devices",{}).get("root",{}).get("pool",""))')
    profile_size=$(printf '%s' "$profile" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("devices",{}).get("root",{}).get("size",""))')
    [ "$reserve" = true ] || refuse "Incus creation-time reservation policy is missing"
    [ "$refquota" = true ] || refuse "Incus refquota reservation policy is missing"
    [ "$profile_pool" = default ] || refuse "default profile root pool is ${profile_pool:-absent}"
    [ -n "$profile_size" ] || refuse "default profile root has no size"
}

mark_ready() {
    [ "$(read_token "$identity/phase")" = preseed-pending ] || refuse "cannot mark ready from phase $(read_token "$identity/phase")"
    [ ! -e "$metadata_mount/.tama-preseed-pending" ] || refuse "preseed marker still exists"
    fresh_contract
    write_atomic "$identity/phase" ready
    note "TAMA_STORAGE_PHASE_READY"
}

ready_storage() {
    backend=$(read_token "$run_dir/tama-storage-backend")
    case "$backend" in
        zfs|ext4) ;;
        *) refuse "storage backend is missing or unknown" ;;
    esac
    if [ "$backend" = ext4 ]; then
        [ "$(mounted_source "$metadata_mount")" = "$disk" ] || refuse "legacy ext4 is not mounted from the attached disk"
        legacy_markers "$metadata_mount" || refuse "legacy ext4 markers are absent at readiness"
        note "TAMA_STORAGE_EXT4_READY_CHECK"
        return 0
    fi
    [ "$(read_token "$identity/phase")" = ready ] || refuse "ZFS phase is not ready: $(read_token "$identity/phase")"
    [ ! -e "$metadata_mount/.tama-preseed-pending" ] || refuse "ZFS preseed is incomplete"
    available=$(zfs get -Hp -o value available "$pool/metadata")
    [ "$available" -ge "$metadata_min_available" ] || refuse "metadata available ${available} is below ${metadata_min_available}"
    driver=$(incus query /1.0/storage-pools/default | python3 -c 'import json,sys; print(json.load(sys.stdin).get("driver",""))')
    config=$(incus query /1.0/storage-pools/default)
    source=$(printf '%s' "$config" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("config",{}).get("source",""))')
    profile_pool=$(incus query /1.0/profiles/default | python3 -c 'import json,sys; print(json.load(sys.stdin).get("devices",{}).get("root",{}).get("pool",""))')
    # Recheck the selected layout every boot. Creation-time size and reservation
    # policy stay in fresh_contract so a later Incus edit is not rejected here.
    [ "$driver" = zfs ] || refuse "unexpected default driver: ${driver:-absent}"
    [ "$source" = "$pool/workloads" ] || refuse "unexpected ZFS source: ${source:-absent}"
    [ "$profile_pool" = default ] || refuse "default profile root pool is ${profile_pool:-absent}"
    note "TAMA_STORAGE_DRIVER_OK"
}

case "$action" in
    start) start_storage ;;
    stop) stop_storage ;;
    ready) ready_storage ;;
    mark-ready) mark_ready ;;
    *) refuse "unknown storage action: $action" ;;
esac
