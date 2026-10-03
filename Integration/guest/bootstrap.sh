#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
cat > /etc/apt/apt.conf.d/90-tama-appliance <<'EOF'
Acquire::Languages "none";
Acquire::ForceIPv4 "true";
Acquire::Retries "2";
Acquire::http::Timeout "20";
Acquire::https::Timeout "20";
EOF
# No source package indexes or translation catalogs are needed by an appliance.
sed -i 's/^Types: deb deb-src$/Types: deb/' /etc/apt/sources.list.d/debian.sources
# Private serial diagnostics help distinguish a slow mirror from a guest failure.
(
  while [ ! -e /run/tama-bootstrap-ready ]; do
    printf '\nTAMA_PROVISIONING uptime='
    cat /proc/uptime
    ps -eo pid,stat,wchan:24,args | grep -E 'apt|dpkg|cloud-init|tama-bootstrap' || true
    sleep 20
  done
) >/dev/hvc0 2>&1 &
# Prevent apt from starting Incus before its data disk is mounted.
cat > /usr/sbin/policy-rc.d <<'EOF'
#!/bin/sh
exit 101
EOF
chmod 0755 /usr/sbin/policy-rc.d
trap 'rm -f /usr/sbin/policy-rc.d' EXIT
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl e2fsprogs
mkdir -p /etc/apt/keyrings
curl --fail --silent --show-error --location https://pkgs.zabbly.com/key.asc -o /etc/apt/keyrings/zabbly.asc
chmod 0644 /etc/apt/keyrings/zabbly.asc
cat > /etc/apt/sources.list.d/zabbly-incus.sources <<'EOF'
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/stable
Suites: trixie
Components: main
Architectures: arm64
Signed-By: /etc/apt/keyrings/zabbly.asc
EOF
apt-get update
apt-get install -y --no-install-recommends incus
# Linux host requirements: large subordinate ID ranges for unprivileged workloads.
grep -q '^root:' /etc/subuid || echo 'root:1000000:1000000000' >> /etc/subuid
grep -q '^root:' /etc/subgid || echo 'root:1000000:1000000000' >> /etc/subgid
cat > /etc/sysctl.d/90-tama-incus.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
sysctl --system
mkdir -p /etc/systemd/system/incus.service.d /etc/systemd/system/incus.socket.d
for unit in incus.service incus.socket; do
    cat > "/etc/systemd/system/$unit.d/tama-storage.conf" <<'EOF'
[Unit]
Requires=tama-storage.service
After=tama-storage.service
EOF
done
systemctl daemon-reload
systemctl enable tama-storage.service tama-bridge.service
systemctl start tama-storage.service
rm -f /usr/sbin/policy-rc.d
systemctl enable --now incus.socket
systemctl start incus.service
ready=false
for i in $(seq 1 120); do
    if incus info >/dev/null 2>&1; then ready=true; break; fi
    sleep 1
done
if [ "$ready" != true ]; then
    echo 'Incus failed to become ready; preserving data without running preseed' >&2
    exit 1
fi
# A reused disk may have any pool name or partially applied initialization.
# Keep persistent pending intent until success, but never replay a preseed that
# may already have changed Incus configuration. Explicit recovery/reset is safer.
pending=/var/lib/incus/.tama-preseed-pending
started=/var/lib/incus/.tama-preseed-started
if [ -e "$pending" ]; then
    if [ -e "$started" ]; then
        echo 'Incus initialization was interrupted; preserving state for explicit recovery or reset' >&2
        exit 1
    fi
    touch "$started"
    sync
    incus admin init --preseed <<'EOF'
config: {}
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
systemctl start tama-bridge.service
# Drop SSH; no normal operation should require access to the guest shell.
systemctl disable --now ssh.service ssh.socket 2>/dev/null || true
touch /run/tama-bootstrap-ready
printf 'TAMA_BOOTSTRAP_READY\n' >/dev/hvc0
