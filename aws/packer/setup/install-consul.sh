#!/usr/bin/env bash
set -euo pipefail

# Install HashiCorp Consul from official repository
# Pinned to Consul 1.17.x

CONSUL_VERSION="1.17.3-1"

echo "==> Installing Consul ${CONSUL_VERSION}"

# Add HashiCorp GPG key (idempotent — may already exist from Nomad install)
if [ ! -f /usr/share/keyrings/hashicorp-archive-keyring.gpg ]; then
    curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
fi

# Add HashiCorp repository (idempotent — may already exist from Nomad install)
if [ ! -f /etc/apt/sources.list.d/hashicorp.list ]; then
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
        | sudo tee /etc/apt/sources.list.d/hashicorp.list > /dev/null
fi

sudo apt-get update -y
sudo apt-get install -y consul="${CONSUL_VERSION}"
sudo apt-mark hold consul

# Create directories for Consul
sudo mkdir -p /opt/consul/data
sudo mkdir -p /etc/consul.d
sudo chmod 700 /opt/consul/data

# Do NOT write any config files here — user-data is the single source of truth
# for all Consul configuration. Writing config here would cause duplicate/conflicting
# blocks when Consul loads all .hcl files from /etc/consul.d/.

# Enable Consul service (but don't start — user-data will configure and start)
sudo systemctl enable consul

# Disable systemd-resolved stub listener to free port 53 for dnsmasq
# On Ubuntu 22.04, systemd-resolved binds to 127.0.0.53:53 by default,
# which conflicts with dnsmasq. We configure it here so it takes effect on next boot.
sudo mkdir -p /etc/systemd/resolved.conf.d
cat <<RESOLVED | sudo tee /etc/systemd/resolved.conf.d/no-stub.conf
[Resolve]
DNSStubListener=no
RESOLVED
sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf

# Install dnsmasq for Consul DNS forwarding
sudo apt-get install -y dnsmasq

sudo tee /etc/dnsmasq.d/10-consul > /dev/null <<'DNSMASQ'
# Forward .consul domain to Consul's DNS
server=/consul/127.0.0.1#8600
DNSMASQ

sudo systemctl enable dnsmasq

echo "==> Consul installed successfully"
consul version
