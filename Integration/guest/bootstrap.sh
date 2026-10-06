#!/bin/sh
set -eu
umask 077
boot=${TAMA_BOOT_ROOT:-}
storage_script=${TAMA_STORAGE_SCRIPT:-/usr/local/libexec/tama-storage.sh}
echo 'TAMA_ALPINE_PROVISIONING'
# Cloud-init runcmd runs once. Register continuation before any kernel reboot.
if [ -x "$boot/etc/init.d/tama-bootstrap" ]; then
    rc-update add tama-bootstrap default
    sync
fi
if [ -f "$boot/var/lib/tama-bootstrap-complete" ]; then
    kernel_record=$(cat "$boot/etc/tama-zfs-qualified-kernel" 2>/dev/null || true)
    kernel_record=$(printf '%s' "$kernel_record" | tr -d '[:space:]')
    if [ -z "$kernel_record" ]; then
        echo 'TAMA_BOOTSTRAP_KERNEL_RECORD_MISSING: completed marker has no qualified-kernel record; refusing to reprovision' >&2
        exit 1
    fi
    if [ "$(uname -r)" = "$kernel_record" ]; then
        echo TAMA_BOOTSTRAP_ALREADY_COMPLETE
        exit 0
    fi
fi
ip address
ip route
cat "$boot/etc/resolv.conf"
rc-service networking status || rc-service networking start
cat "$boot/etc/network/interfaces"
cat "$boot/etc/dhcpcd.conf"
# Persist IPv4 DHCP selection across reboots; initial cloud-init otherwise
# considers IPv6 RA sufficient for the NAT interface.
if ! grep -q '^# tama-incus IPv4 DHCP$' "$boot/etc/dhcpcd.conf"; then
    cat >> "$boot/etc/dhcpcd.conf" <<'EOF'
# tama-incus IPv4 DHCP
interface eth0
ipv4only
EOF
fi
# IPv6 router advertisements can make OpenRC networking appear ready before
# Apple NAT's IPv4 DHCP lease. Wait for an IPv4 route before fetching packages.
dhcpcd -4 -w -t 45 eth0
network_ready=false
for i in $(seq 1 45); do
    if ip -4 route show default | grep -q '^default '; then network_ready=true; break; fi
    sleep 1
done
[ "$network_ready" = true ] || { echo 'IPv4 DHCP did not become ready' >&2; exit 1; }
ip -4 address
ip -4 route
. "$boot/etc/os-release"
[ "$ID" = alpine ] && [ "${VERSION_ID%.*}" = 3.24 ] || {
    echo 'Expected Alpine Linux 3.24; refusing mixed distribution provisioning' >&2
    exit 1
}
# The minimal cloud base may lack the TLS CA bundle. Bootstrap it using APK's
# trusted Alpine signatures, then use HTTPS for all remaining package operations.
mkdir -p "$boot/run" "$boot/etc/apk" "$boot/etc/modprobe.d" "$boot/var/log" "$boot/var/lib"
cat > "$boot/run/tama-ca-repositories" <<'EOF'
http://dl-cdn.alpinelinux.org/alpine/v3.24/main
EOF
apk --timeout 30 --repositories-file "$boot/run/tama-ca-repositories" update
apk --timeout 30 --repositories-file "$boot/run/tama-ca-repositories" add ca-certificates
rm -f "$boot/run/tama-ca-repositories"
update-ca-certificates
cat > "$boot/etc/apk/repositories" <<'EOF'
https://dl-cdn.alpinelinux.org/alpine/v3.24/main
https://dl-cdn.alpinelinux.org/alpine/v3.24/community
EOF
# APK's normal signature verification stays enabled. No edge or third-party repo.
apk --timeout 30 update
apk --timeout 30 add --no-cache \
    'incus>=7.0.1' 'incus-client>=7.0.1' incus-openrc 'incus-vm>=7.0.1' skopeo \
    qemu-system-aarch64 qemu-audio-spice qemu-hw-display-virtio-gpu-pci qemu-hw-usb-host \
    qemu-chardev-spice qemu-hw-usb-redirect qemu-ui-spice-core aavmf virtiofsd \
    ca-certificates e2fsprogs e2fsprogs-extra util-linux-misc blkid python3 shadow-subids \
    lxcfs lxcfs-openrc nftables acpid acpid-openrc
# Qualified Alpine v3.24 pair. A different revision is a failure, not a silent substitute.
# The cloud image EFI partition needs the unused DTB tree removed before this kernel update.
if [ -d "$boot/boot/dtbs-lts" ]; then rm -rf "$boot/boot/dtbs-lts"; fi
if ! apk --timeout 30 add --no-cache \
    linux-lts=6.18.55-r0 zfs=2.4.4-r0 zfs-libs=2.4.4-r0 zfs-lts=6.18.55-r0 zfs-openrc=2.4.4-r0; then
    echo 'TAMA_ZFS_QUALIFIED_REVISION_UNAVAILABLE: Alpine v3.24 no longer provides linux-lts=6.18.55-r0 zfs=2.4.4-r0; refusing to substitute' >&2
    exit 1
fi
apk info -v | grep '^linux-lts-' | sed 's/^linux-lts-//;s/-r/-/;s/$/-lts/' > "$boot/etc/tama-zfs-qualified-kernel"
if [ "$(uname -r)" != "$(cat "$boot/etc/tama-zfs-qualified-kernel")" ]; then
    echo TAMA_ZFS_KERNEL_REBOOT_REQUIRED
    sync
    poweroff
    exit 0
fi
printf 'options zfs zfs_arc_max=536870912\n' > "$boot/etc/modprobe.d/tama-zfs.conf"
apk info -v > "$boot/var/log/tama-appliance-packages.txt"
cat "$boot/var/log/tama-appliance-packages.txt"
grep -q '^root:' "$boot/etc/subuid" || echo 'root:1000000:1000000000' >> "$boot/etc/subuid"
grep -q '^root:' "$boot/etc/subgid" || echo 'root:1000000:1000000000' >> "$boot/etc/subgid"
mkdir -p "$boot/etc/sysctl.d" "$boot/etc/conf.d"
cat > "$boot/etc/sysctl.d/90-tama-incus.conf" <<'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
sysctl -p "$boot/etc/sysctl.d/90-tama-incus.conf"
grep -v '^rc_cgroup_mode=' "$boot/etc/rc.conf" > "$boot/etc/rc.conf.tmp" || true
mv "$boot/etc/rc.conf.tmp" "$boot/etc/rc.conf"
echo 'rc_cgroup_mode="unified"' >> "$boot/etc/rc.conf"
rc-update add cgroups boot
rc-service cgroups start
test -e "$boot/sys/fs/cgroup/cgroup.controllers"
# Device autoloading normally handles these; ensure the host transport is present.
modprobe vmw_vsock_virtio_transport
modprobe virtiofs
modprobe vhost_vsock
modprobe tun
cat > "$boot/etc/conf.d/incusd" <<'EOF'
INCUSD_OPTIONS="--group incus"
INCUSD_STOP_TIMEOUT=45
rc_need="tama-storage"
EOF
rc-update add tama-storage default
rc-update add incusd default
rc-update add tama-bridge default
rc-update add dbus default
rc-update add acpid default
rc-service acpid start
rc-service tama-storage start || { cat "$boot/var/log/tama-storage.log"; exit 1; }
rc-service dbus start
rc-service incusd start
# /1.0 can respond before startup cleanup/autostart completes.
incusd waitready --timeout 120
pending=$boot/var/lib/incus/.tama-preseed-pending
started=$boot/var/lib/incus/.tama-preseed-started
backend=$(cat "$boot/run/tama-storage-backend" 2>/dev/null || true)
if [ -e "$pending" ]; then
    [ ! -e "$started" ] || {
        echo 'Interrupted initialization; preserve data for explicit recovery/reset' >&2
        exit 1
    }
    touch "$started"
    sync
    if [ "$backend" = zfs ]; then
        pool_yaml='  driver: zfs
  config:
    source: tama-data/workloads
    zfs.export: "false"
    volume.zfs.reserve_space: "true"
    volume.zfs.use_refquota: "true"'
        root_size='      size: 2GiB'
    else
        pool_yaml='  driver: dir
  config: {}'
        root_size=''
    fi
    incus admin init --preseed <<EOF
config:
  # Incus 7.0.1 can unlink cached OCI files if a background image download is
  # cancelled during shutdown. Keep updates explicit until that is resolved.
  images.auto_update_interval: "0"
networks:
- name: incusbr0
  type: bridge
  config:
    ipv4.address: auto
    ipv4.nat: "true"
    ipv6.address: none
storage_pools:
- name: default
$pool_yaml
profiles:
- name: default
  devices:
    root:
      type: disk
      path: /
      pool: default
$root_size
    eth0:
      type: nic
      network: incusbr0
EOF
    rm -f "$pending" "$started"
    sync
fi
if [ "$backend" = zfs ] && [ "$(tr -d '\n' < "$boot/etc/tama-storage/phase" 2>/dev/null || true)" = preseed-pending ] && [ ! -e "$pending" ]; then
    "$storage_script" mark-ready
fi
"$storage_script" ready
# SSH is not part of the appliance's normal control surface.
if [ -x "$boot/etc/init.d/sshd" ]; then
    rc-service sshd stop || true
    rc-update del sshd default || true
fi
rc-service tama-bridge start
mkdir -p "$boot/var/lib"
printf 'complete\n' > "$boot/var/lib/tama-bootstrap-complete"
sync
rc-update del tama-bootstrap default || true
touch "$boot/run/tama-bootstrap-ready"
printf 'TAMA_BOOTSTRAP_READY\n'
