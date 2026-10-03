#!/bin/sh
set -eu
disk=/dev/vdb
kind=$(blkid -s TYPE -o value "$disk" || true)
if [ "$kind" = ext4 ]; then
    :
elif [ -z "$kind" ]; then
    size=$(blockdev --getsize64 "$disk")
    # Check the whole device, not just its first sector. Unknown data must survive.
    if ! cmp -s -n "$size" "$disk" /dev/zero; then
        echo 'Refusing to format nonblank Incus data disk' >&2
        exit 1
    fi
    mkfs.ext4 -q -L tama-incus-data "$disk"
else
    echo "Refusing unknown data filesystem: $kind" >&2
    exit 1
fi
if ! mountpoint -q /var/lib/incus; then
    e2fsck -p "$disk" || [ "$?" -eq 1 ]
    resize2fs "$disk"
    mkdir -p /var/lib/incus
    mount -o defaults "$disk" /var/lib/incus
fi
mkdir -p /mnt/tama-shares
# No configured share device is a normal case; never fall back to sharing home.
if grep -q 'virtiofs' /proc/filesystems || modprobe virtiofs; then
    mountpoint -q /mnt/tama-shares || mount -t virtiofs tama-shares /mnt/tama-shares || true
fi
