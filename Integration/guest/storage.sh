#!/bin/sh
set -eu
umask 077
exec > /var/log/tama-storage.log 2>&1
# These are runtime prerequisites on every boot, not just cloud-init's first.
modprobe vmw_vsock_virtio_transport
modprobe virtiofs
modprobe vhost_vsock
modprobe tun
disk=/dev/vdb
new_data=false
kind=$(blkid -s TYPE -o value "$disk" || true)
if [ "$kind" = ext4 ]; then
    :
elif [ -z "$kind" ]; then
    # Check the whole device, not just its first sector. Unknown data must survive.
    python3 - "$disk" <<'PY'
import sys
zero = bytes(1024 * 1024)
with open(sys.argv[1], 'rb', buffering=0) as disk:
    while chunk := disk.read(len(zero)):
        if chunk != zero[:len(chunk)]:
            raise SystemExit('Refusing to format nonblank Incus data disk')
PY
    mkfs.ext4 -q -L tama-incus-data "$disk"
    new_data=true
else
    echo "Refusing unknown data filesystem: $kind" >&2
    exit 1
fi
if ! mountpoint -q /var/lib/incus; then
    # Offline resize requires a real check even when ext4's clean bit is set.
    e2fsck -fp "$disk" || [ "$?" -eq 1 ]
    resize2fs "$disk"
    mkdir -p /var/lib/incus
    mount -o defaults "$disk" /var/lib/incus
fi
# Persist the first-boot intent before Incus starts; an early failure can retry.
if [ "$new_data" = true ]; then
    touch /var/lib/incus/.tama-preseed-pending
    sync
fi
mkdir -p /mnt/tama-shares
# No configured share device is a normal case; never fall back to sharing home.
if grep -q 'virtiofs' /proc/filesystems || modprobe virtiofs; then
    mountpoint -q /mnt/tama-shares || mount -t virtiofs tama-shares /mnt/tama-shares || true
fi
