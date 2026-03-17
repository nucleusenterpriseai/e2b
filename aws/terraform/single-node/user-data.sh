#!/bin/bash
set -euo pipefail

# E2B Single-Node — Fully Automated User Data
# Two modes:
#   1. Pre-built AMI: Just restart services (fast, ~1 min)
#   2. Stock Ubuntu:  Full setup via ec2-setup.sh (~15 min)

# cloud-init may run user-data with HOME unset, which breaks Go module resolution
export HOME="$${HOME:-/root}"
export GOPATH="$${GOPATH:-$HOME/go}"

exec > /var/log/e2b-user-data.log 2>&1
echo "=== E2B Automated Setup — $(date) ==="
echo "Environment: ${environment}"

# --- Kernel tuning (always needed, even on AMI boot) ---
modprobe nbd nbds_max=1024 max_part=15 2>/dev/null || true
echo "nbd" > /etc/modules-load.d/nbd.conf
echo "options nbd nbds_max=1024 max_part=15" > /etc/modprobe.d/nbd.conf
sysctl -w vm.max_map_count=1048576
sysctl -w net.ipv4.ip_forward=1
cat > /etc/sysctl.d/99-e2b.conf <<SYSCTL
vm.max_map_count=1048576
net.ipv4.ip_forward=1
SYSCTL

# KVM
[ -c /dev/kvm ] && chmod 666 /dev/kvm && echo "KVM: OK" || echo "WARNING: no /dev/kvm"

# --- HugePages (reconfigure on each boot) ---
TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_MEM_GB=$((TOTAL_MEM_KB / 1024 / 1024))
HUGEPAGES=$((TOTAL_MEM_GB * 1024 * 80 / 100 / 2))
echo "$HUGEPAGES" > /proc/sys/vm/nr_hugepages
echo "HugePages: $HUGEPAGES ($${TOTAL_MEM_GB}GB total)"

# --- Check if this is a pre-built AMI ---
if [ -f /opt/e2b/restart-services.sh ] && [ -f /usr/local/bin/orchestrator ]; then
    echo "Pre-built AMI detected — restarting services only"

    # Ensure Docker containers are running
    docker start e2b-postgres e2b-redis e2b-registry 2>/dev/null || true
    sleep 5

    # Wait for PostgreSQL
    for i in $(seq 1 30); do
        docker exec e2b-postgres pg_isready -U e2b -d e2b &>/dev/null && break
        sleep 1
    done

    # Restart E2B services
    bash /opt/e2b/restart-services.sh
    echo "=== Pre-built AMI boot complete — $(date) ==="
    exit 0
fi

# --- Full setup mode (stock Ubuntu) ---
echo "Stock Ubuntu detected — running full setup"

# Data directories
DATA_DIR="/data/e2b"
mkdir -p $DATA_DIR/{fc-versions,kernels,orchestrator,sandbox,snapshot-cache}
mkdir -p $DATA_DIR/templates/{templates,snapshot-cache,build-cache,orchestrator,sandbox,fc-versions,kernels}
mkdir -p /home/envd/bin /opt/e2b

# Install git
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git

# Clone infra repo
E2B_HOME="/home/ubuntu/e2b"
mkdir -p "$E2B_HOME"
git clone --depth 1 --branch "${infra_repo_ref}" "${infra_repo_url}" "$E2B_HOME/infra"
chown -R ubuntu:ubuntu "$E2B_HOME"

%{ if e2b_repo_url != "" }
# Clone the user's e2b repo (has ec2-setup.sh, templates, and custom configs)
%{ if e2b_repo_ref != "" }
echo "Cloning e2b repo: ${e2b_repo_url} (ref: ${e2b_repo_ref})"
git clone --depth 1 --branch "${e2b_repo_ref}" "${e2b_repo_url}" "$E2B_HOME/custom"
%{ else }
echo "Cloning e2b repo: ${e2b_repo_url} (default branch)"
git clone --depth 1 "${e2b_repo_url}" "$E2B_HOME/custom"
%{ endif }
if [ ! -f "$E2B_HOME/custom/aws/terraform/single-node/ec2-setup.sh" ]; then
    echo "FATAL: ec2-setup.sh not found in cloned e2b repo"
    exit 1
fi
cp "$E2B_HOME/custom/aws/terraform/single-node/ec2-setup.sh" /opt/e2b/ec2-setup.sh
if [ -f "$E2B_HOME/custom/aws/db/generate_api_key.go" ]; then
    mkdir -p "$E2B_HOME/aws/db"
    cp "$E2B_HOME/custom/aws/db/generate_api_key.go" "$E2B_HOME/aws/db/"
    cp "$E2B_HOME/custom/aws/db/go.mod" "$E2B_HOME/aws/db/" 2>/dev/null || true
    cp "$E2B_HOME/custom/aws/db/go.sum" "$E2B_HOME/aws/db/" 2>/dev/null || true
fi
%{ endif }

# Run setup
export FC_VERSION="${fc_version}"
export FC_COMMIT="${fc_commit}"
export KERNEL_VERSION="${kernel_version}"
export GO_VERSION="${go_version}"
export INFRA_REPO_URL="${infra_repo_url}"
export INFRA_REPO_REF="${infra_repo_ref}"

if [ -f /opt/e2b/ec2-setup.sh ]; then
    chmod +x /opt/e2b/ec2-setup.sh
    bash /opt/e2b/ec2-setup.sh
else
    echo "FATAL: ec2-setup.sh not found at /opt/e2b/ec2-setup.sh — set e2b_repo_url in terraform.tfvars"
    exit 1
fi

echo "=== User data complete — $(date) ==="
