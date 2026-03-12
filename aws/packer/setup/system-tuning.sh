#!/usr/bin/env bash
set -euo pipefail

# System tuning for E2B nodes running Firecracker microVMs
# Covers: KVM access, sysctl networking/memory, hugepages, file limits

echo "==> Applying system tuning"

# ---------------------------------------------------------------------------
# KVM access
# ---------------------------------------------------------------------------
# Ensure /dev/kvm has correct permissions (on metal instances)
# Create udev rule for persistent KVM permissions
sudo tee /etc/udev/rules.d/99-kvm.rules > /dev/null <<'UDEV'
KERNEL=="kvm", GROUP="kvm", MODE="0660"
UDEV

# Create kvm group if it doesn't exist, add ubuntu and nomad users
sudo groupadd -f kvm
sudo usermod -aG kvm ubuntu
# Ensure the nomad user (which runs Firecracker via raw_exec) has KVM access
id -u nomad &>/dev/null && sudo usermod -aG kvm nomad || true

# ---------------------------------------------------------------------------
# Sysctl tuning
# ---------------------------------------------------------------------------
sudo tee /etc/sysctl.d/99-e2b-tuning.conf > /dev/null <<'SYSCTL'
# ---- Network tuning ----
# Allow IP forwarding (required for Firecracker VM networking)
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# Increase connection tracking table size for many VMs
net.netfilter.nf_conntrack_max = 1048576
net.nf_conntrack_max = 1048576

# Increase ARP cache for many TAP interfaces
net.ipv4.neigh.default.gc_thresh1 = 4096
net.ipv4.neigh.default.gc_thresh2 = 8192
net.ipv4.neigh.default.gc_thresh3 = 16384

# Increase socket buffer sizes
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 1048576 16777216
net.ipv4.tcp_wmem = 4096 1048576 16777216

# Increase listen backlog
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 16384

# Increase max number of open ports
net.ipv4.ip_local_port_range = 1024 65535

# TCP keepalive tuning
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6

# Reduce TIME_WAIT sockets
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15

# ---- Memory tuning ----
# Reduce swappiness (prefer keeping things in RAM)
vm.swappiness = 10

# Allow overcommit for Firecracker balloon memory management
vm.overcommit_memory = 1

# Increase max memory map areas (needed for many VMs)
vm.max_map_count = 1048576

# ---- File descriptor tuning ----
# Increase system-wide file descriptor limit
fs.file-max = 2097152

# Increase inotify limits for file watchers inside VMs
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288

# ---- IPC tuning ----
# Increase max queued signals
kernel.pid_max = 4194304
SYSCTL

# Apply sysctl settings
sudo sysctl --system

# ---------------------------------------------------------------------------
# Hugepages (optional, for better VM memory performance)
# ---------------------------------------------------------------------------
# Reserve 2MB hugepages — 1024 pages = 2GB
# On metal instances with more RAM, the user-data script can increase this
sudo tee /etc/sysctl.d/99-hugepages.conf > /dev/null <<'HUGEPAGES'
vm.nr_hugepages = 1024
HUGEPAGES
sudo sysctl -p /etc/sysctl.d/99-hugepages.conf || true

# Create hugepage mount point
sudo mkdir -p /dev/hugepages
if ! mountpoint -q /dev/hugepages 2>/dev/null; then
    echo "hugetlbfs /dev/hugepages hugetlbfs defaults 0 0" | sudo tee -a /etc/fstab > /dev/null
fi

# ---------------------------------------------------------------------------
# File limits
# ---------------------------------------------------------------------------
sudo tee /etc/security/limits.d/99-e2b.conf > /dev/null <<'LIMITS'
# E2B service limits
*               soft    nofile          1048576
*               hard    nofile          1048576
root            soft    nofile          1048576
root            hard    nofile          1048576
root            soft    nproc           unlimited
root            hard    nproc           unlimited
root            soft    memlock         unlimited
root            hard    memlock         unlimited
nomad           soft    nproc           unlimited
nomad           hard    nproc           unlimited
nomad           soft    memlock         unlimited
nomad           hard    memlock         unlimited
LIMITS

# Ensure PAM applies limits
if ! grep -q 'pam_limits.so' /etc/pam.d/common-session 2>/dev/null; then
    echo "session required pam_limits.so" | sudo tee -a /etc/pam.d/common-session > /dev/null
fi

# ---------------------------------------------------------------------------
# Systemd service limits
# ---------------------------------------------------------------------------
sudo mkdir -p /etc/systemd/system.conf.d
sudo tee /etc/systemd/system.conf.d/99-e2b-limits.conf > /dev/null <<'SYSTEMD'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=infinity
DefaultLimitMEMLOCK=infinity
SYSTEMD

sudo systemctl daemon-reload

# ---------------------------------------------------------------------------
# Firecracker VM networking (iptables at boot)
# ---------------------------------------------------------------------------
# iptables rules cannot be applied at AMI build time because the network
# interfaces don't exist yet.  Instead we install a oneshot systemd service
# that configures forwarding + NAT on every boot.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sudo mkdir -p /opt/e2b
sudo install -m 0755 "${SCRIPT_DIR}/setup-firecracker-networking.sh" /opt/e2b/setup-firecracker-networking.sh
sudo install -m 0644 "${SCRIPT_DIR}/e2b-network.service" /etc/systemd/system/e2b-network.service
sudo systemctl daemon-reload
sudo systemctl enable e2b-network.service

echo "==> System tuning applied successfully"
