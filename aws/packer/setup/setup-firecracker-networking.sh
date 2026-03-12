#!/usr/bin/env bash
set -euo pipefail

# Setup iptables rules for Firecracker build VM networking.
# Runs at boot via the e2b-network.service systemd unit.
#
# The Firecracker VM subnet is 10.11.0.0/16.
# ip_forward is already enabled via sysctl (99-e2b-tuning.conf).

FC_SUBNET="10.11.0.0/16"

# Detect the default-route interface (eth0, ens5, enp3s0, etc.)
DEFAULT_IF=$(ip route show default | awk '{print $5}' | head -1)

if [ -z "$DEFAULT_IF" ]; then
    echo "e2b-network: ERROR - no default route interface found" | logger -t e2b-network
    exit 1
fi

echo "e2b-network: default interface is ${DEFAULT_IF}" | logger -t e2b-network

# --- FORWARD rules ---
# Allow traffic from and to the Firecracker VM subnet
iptables -I FORWARD 1 -s "$FC_SUBNET" -j ACCEPT
iptables -I FORWARD 1 -d "$FC_SUBNET" -j ACCEPT

# --- NAT (MASQUERADE) ---
# Outbound traffic from VMs is NATed through the host's default interface
iptables -t nat -I POSTROUTING 1 -s "$FC_SUBNET" -o "$DEFAULT_IF" -j MASQUERADE

echo "e2b-network: iptables rules applied (subnet=${FC_SUBNET}, iface=${DEFAULT_IF})" | logger -t e2b-network
