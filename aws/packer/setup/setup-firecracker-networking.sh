#!/usr/bin/env bash
set -euo pipefail

# Setup iptables rules for Firecracker VM networking.
# Runs at boot via the e2b-network.service systemd unit.
#
# Uses dedicated E2B chains (E2B-FORWARD, E2B-POSTROUTING) so that
# flushing E2B rules on restart does not destroy Docker or other
# system iptables rules.
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

# --- Create E2B-specific chains (idempotent) ---
iptables -N E2B-FORWARD 2>/dev/null || true
iptables -t nat -N E2B-POSTROUTING 2>/dev/null || true

# Flush only the E2B chains (safe — does not touch Docker or system rules)
iptables -F E2B-FORWARD
iptables -t nat -F E2B-POSTROUTING

# Jump into E2B chains from the built-in chains (skip if already present)
iptables -C FORWARD -j E2B-FORWARD 2>/dev/null || iptables -I FORWARD 1 -j E2B-FORWARD
iptables -t nat -C POSTROUTING -j E2B-POSTROUTING 2>/dev/null || iptables -t nat -I POSTROUTING 1 -j E2B-POSTROUTING

# --- FORWARD rules ---
# Allow traffic from and to the Firecracker VM subnet
iptables -A E2B-FORWARD -s "$FC_SUBNET" -j ACCEPT
iptables -A E2B-FORWARD -d "$FC_SUBNET" -j ACCEPT

# --- NAT (MASQUERADE) ---
# Outbound traffic from VMs is NATed through the host's default interface
iptables -t nat -A E2B-POSTROUTING -s "$FC_SUBNET" -o "$DEFAULT_IF" -j MASQUERADE

echo "e2b-network: iptables rules applied (subnet=${FC_SUBNET}, iface=${DEFAULT_IF})" | logger -t e2b-network
