#!/bin/sh
# Disposable qualification fixture only; never installed by production preparation.
set -eu
umask 077
action=${1:-start}
case "$action" in
    stop)
        zpool export tama-data > /var/log/tama-zfs-export.log 2>&1 \
            && echo TAMA_ZFS_EXPORT_OK >> /var/log/tama-zfs-export.log
        exit 0
        ;;
    ready|mark-ready)
        exit 0
        ;;
    start) ;;
    *)
        echo "unknown qualification storage action: $action" >&2
        exit 1
        ;;
esac
exec > /var/log/tama-storage.log 2>&1
modprobe vmw_vsock_virtio_transport
modprobe virtiofs
modprobe vhost_vsock
modprobe tun
modprobe zfs
disk=/dev/vdb
pool=tama-data
identity=/etc/tama-zfs-qualification-guid
if [ ! -e "$identity" ]; then
    python3 - "$disk" <<'PY'
import sys
zero = bytes(1024 * 1024)
with open(sys.argv[1], 'rb', buffering=0) as disk:
    while chunk := disk.read(len(zero)):
        if chunk != zero[:len(chunk)]:
            raise SystemExit('Qualification refuses a nonblank data disk')
PY
    test ! -e /etc/tama-zfs-qualification-intent
    echo blank-verified > /etc/tama-zfs-qualification-intent
    sync
    zpool create -o ashift=12 -O mountpoint=none -O compression=lz4 "$pool" "$disk"
    zpool get -H -o value guid "$pool" > "$identity"
    sync
    zfs create -o mountpoint=/var/lib/incus "$pool/metadata"
    zfs set refreservation=1G "$pool/metadata"
    zfs create -o mountpoint=none "$pool/workloads"
    echo qualification-v1 > /var/lib/incus/.tama-zfs-qualification-layout
    touch /var/lib/incus/.tama-preseed-pending
    sync
else
    guid=$(cat "$identity")
    if ! zpool list -H -o guid "$pool" >/dev/null 2>&1; then
        # Whole-disk creation places the ZFS labels on the first GPT partition.
        zpool import -N -d "${disk}1" "$guid"
    fi
    test "$(zpool get -H -o value guid "$pool")" = "$guid"
    zpool status -P "$pool" | grep -q '/dev/vdb'
    test "$(zfs get -H -o value mountpoint "$pool/metadata")" = /var/lib/incus
    if ! mountpoint -q /var/lib/incus; then zfs mount "$pool/metadata"; fi
    test "$(cat /var/lib/incus/.tama-zfs-qualification-layout)" = qualification-v1
    zpool online -e "$pool" "$disk"
fi
mkdir -p /mnt/tama-shares
if grep -q 'virtiofs' /proc/filesystems || modprobe virtiofs; then
    mountpoint -q /mnt/tama-shares || mount -t virtiofs tama-shares /mnt/tama-shares || true
fi
uname -r
zfs version
zpool status -P "$pool"
zfs list -o name,mountpoint,used,available
mkdir -p /run
printf 'zfs\n' > /run/tama-storage-backend
