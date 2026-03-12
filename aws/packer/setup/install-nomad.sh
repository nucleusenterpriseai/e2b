#!/usr/bin/env bash
set -euo pipefail

# Install HashiCorp Nomad from official repository
# Pinned to Nomad 1.7.x

NOMAD_VERSION="1.7.7-1"

echo "==> Installing Nomad ${NOMAD_VERSION}"

# Add HashiCorp GPG key (idempotent)
if [ ! -f /usr/share/keyrings/hashicorp-archive-keyring.gpg ]; then
    curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
fi

# Add HashiCorp repository (idempotent)
if [ ! -f /etc/apt/sources.list.d/hashicorp.list ]; then
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
        | sudo tee /etc/apt/sources.list.d/hashicorp.list > /dev/null
fi

sudo apt-get update -y
sudo apt-get install -y nomad="${NOMAD_VERSION}"
sudo apt-mark hold nomad

# Create directories for Nomad
sudo mkdir -p /opt/nomad/data
sudo mkdir -p /etc/nomad.d
sudo chmod 700 /opt/nomad/data

# Do NOT write any config files here — user-data is the single source of truth
# for all Nomad configuration. Writing config here would cause duplicate/conflicting
# blocks when Nomad loads all .hcl files from /etc/nomad.d/.

# Enable Nomad service (but don't start — user-data will configure and start)
sudo systemctl enable nomad

echo "==> Nomad installed successfully"
nomad version
