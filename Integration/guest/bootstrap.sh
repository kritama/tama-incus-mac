#!/bin/sh
set -eu
umask 077
echo 'TAMA_ALPINE_PROVISIONING'
ip address
ip route
cat /etc/resolv.conf
rc-service networking status || rc-service networking start
cat /etc/network/interfaces
cat /etc/dhcpcd.conf
# Persist IPv4 DHCP selection across reboots; initial cloud-init otherwise
# considers IPv6 RA sufficient for the NAT interface.
if ! grep -q '^# tama-incus IPv4 DHCP$' /etc/dhcpcd.conf; then
    cat >> /etc/dhcpcd.conf <<'EOF'
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
. /etc/os-release
[ "$ID" = alpine ] && [ "${VERSION_ID%.*}" = 3.24 ] || {
    echo 'Expected Alpine Linux 3.24; refusing mixed distribution provisioning' >&2
    exit 1
}
# The minimal cloud base may lack the TLS CA bundle. Bootstrap it using APK's
# trusted Alpine signatures, then use HTTPS for all remaining package operations.
cat > /run/tama-ca-repositories <<'EOF'
http://dl-cdn.alpinelinux.org/alpine/v3.24/main
EOF
apk --timeout 30 --repositories-file /run/tama-ca-repositories update
apk --timeout 30 --repositories-file /run/tama-ca-repositories add ca-certificates
rm -f /run/tama-ca-repositories
update-ca-certificates
cat > /etc/apk/repositories <<'EOF'
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
apk info -v > /var/log/tama-appliance-packages.txt
cat /var/log/tama-appliance-packages.txt
grep -q '^root:' /etc/subuid || echo 'root:1000000:1000000000' >> /etc/subuid
grep -q '^root:' /etc/subgid || echo 'root:1000000:1000000000' >> /etc/subgid
cat > /etc/sysctl.d/90-tama-incus.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
sysctl -p /etc/sysctl.d/90-tama-incus.conf
sed -i '/^rc_cgroup_mode=/d' /etc/rc.conf
echo 'rc_cgroup_mode="unified"' >> /etc/rc.conf
rc-update add cgroups boot
rc-service cgroups start
test -e /sys/fs/cgroup/cgroup.controllers
# Device autoloading normally handles these; ensure the host transport is present.
modprobe vmw_vsock_virtio_transport
modprobe virtiofs
modprobe vhost_vsock
modprobe tun
cat > /etc/conf.d/incusd <<'EOF'
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
rc-service tama-storage start || { cat /var/log/tama-storage.log; exit 1; }
rc-service dbus start
rc-service incusd start
# /1.0 can respond before startup cleanup/autostart completes.
incusd waitready --timeout 120
pending=/var/lib/incus/.tama-preseed-pending
started=/var/lib/incus/.tama-preseed-started
if [ -e "$pending" ]; then
    [ ! -e "$started" ] || {
        echo 'Interrupted initialization; preserve data for explicit recovery/reset' >&2
        exit 1
    }
    touch "$started"
    sync
    incus admin init --preseed <<'EOF'
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
  driver: dir
  config: {}
profiles:
- name: default
  devices:
    root:
      type: disk
      path: /
      pool: default
    eth0:
      type: nic
      network: incusbr0
EOF
    rm -f "$pending" "$started"
    sync
fi
# SSH is not part of the appliance's normal control surface.
if [ -x /etc/init.d/sshd ]; then
    rc-service sshd stop || true
    rc-update del sshd default || true
fi
rc-service tama-bridge start
touch /run/tama-bootstrap-ready
printf 'TAMA_BOOTSTRAP_READY\n'
