#!/bin/bash
# E2B Self-Hosted — EC2 Instance Setup Script
# Brings a fresh c6g.metal (ARM64 Ubuntu 22.04) to full testing state.
#
# Usage:
#   1. Launch c6g.metal spot instance (Ubuntu 22.04, 200GB+ gp3, SG: 22,80,5007,5008)
#   2. scp this script + the infra repo to the instance
#   3. sudo bash ec2-setup.sh
#
# After setup:
#   - Orchestrator on :5008, proxy on :5007
#   - API on :80
#   - Templates: base (1024MB), playwright384 (384MB)
#   - SDK: pip install e2b, connect via localhost

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
E2B_DIR="${E2B_HOME:-/home/ubuntu/e2b}"
DATA_DIR="/data/e2b"

echo "=== E2B Self-Hosted EC2 Setup ==="
echo "E2B source: $E2B_DIR"
echo "Data dir:   $DATA_DIR"
echo

# ── Phase 1: System packages ─────────────────────────────────────────────────
echo "── Phase 1: System packages ──"

apt-get update -qq
apt-get install -y -qq \
  build-essential git curl wget unzip jq \
  docker.io containerd \
  python3 python3-pip \
  linux-modules-extra-$(uname -r) 2>/dev/null || true

# Go 1.25.4
if ! /usr/local/go/bin/go version 2>/dev/null | grep -q '1.25'; then
  echo "Installing Go 1.25.4..."
  wget -q https://go.dev/dl/go1.25.4.linux-arm64.tar.gz -O /tmp/go.tar.gz
  rm -rf /usr/local/go
  tar -C /usr/local -xzf /tmp/go.tar.gz
  rm /tmp/go.tar.gz
fi
export PATH=/usr/local/go/bin:$PATH
go version

# Nomad 1.7.7
if ! /usr/local/bin/nomad version 2>/dev/null | grep -q '1.7.7'; then
  echo "Installing Nomad 1.7.7..."
  wget -q https://releases.hashicorp.com/nomad/1.7.7/nomad_1.7.7_linux_arm64.zip -O /tmp/nomad.zip
  cd /tmp && unzip -o nomad.zip && mv nomad /usr/local/bin/ && chmod +x /usr/local/bin/nomad
fi
nomad version

# Python SDK
pip3 install -q e2b

# Docker service
systemctl enable docker
systemctl start docker

echo "Phase 1 done."

# ── Phase 2: Kernel modules & sysctl tuning ──────────────────────────────────
echo "── Phase 2: System tuning ──"

# Load nbd with high max
modprobe nbd nbds_max=1024 max_part=15 2>/dev/null || true
echo "nbd" > /etc/modules-load.d/nbd.conf
echo "options nbd nbds_max=1024 max_part=15" > /etc/modprobe.d/nbd.conf

# Sysctl
sysctl -w vm.max_map_count=1048576
echo "vm.max_map_count=1048576" > /etc/sysctl.d/99-e2b.conf

# Verify KVM
test -c /dev/kvm && echo "KVM: OK" || echo "WARNING: /dev/kvm not found — need bare metal instance"

echo "Phase 2 done."

# ── Phase 3: Data directories ─────────────────────────────────────────────────
echo "── Phase 3: Data directories ──"

mkdir -p $DATA_DIR/{fc-versions,kernels,orchestrator,sandbox,snapshot-cache,templates/snapshot-cache}

echo "Phase 3 done."

# ── Phase 4: Firecracker + Kernel ─────────────────────────────────────────────
echo "── Phase 4: Firecracker + Kernel ──"

FC_VERSION="v1.12.1_a41d3fb"
FC_DIR="$DATA_DIR/fc-versions/$FC_VERSION"
if [ ! -f "$FC_DIR/firecracker" ]; then
  echo "Downloading Firecracker v1.12.1..."
  mkdir -p "$FC_DIR"
  wget -q "https://github.com/firecracker-microvm/firecracker/releases/download/v1.12.1/firecracker-v1.12.1-aarch64.tgz" -O /tmp/fc.tgz
  tar -xzf /tmp/fc.tgz -C /tmp/
  cp /tmp/release-v1.12.1-aarch64/firecracker-v1.12.1-aarch64 "$FC_DIR/firecracker"
  chmod +x "$FC_DIR/firecracker"
  rm -rf /tmp/fc.tgz /tmp/release-v1.12.1-aarch64
fi
echo "Firecracker: $($FC_DIR/firecracker --version 2>&1 | head -1)"

KERNEL_DIR="$DATA_DIR/kernels"
if [ ! -f "$KERNEL_DIR/vmlinux-6.1.158" ]; then
  echo "Downloading kernel vmlinux-6.1.158..."
  # Build from e2b fc-kernels or download pre-built
  if [ -d "$E2B_DIR/packages/fc-kernels" ]; then
    echo "Building kernel from source (this takes a while)..."
    cd "$E2B_DIR/packages/fc-kernels" && make build-arm64 2>/dev/null || {
      echo "Kernel build failed — please provide vmlinux-6.1.158 manually at $KERNEL_DIR/"
      echo "You can scp it from a previous instance."
    }
  else
    echo "WARNING: No kernel found. Please copy vmlinux-6.1.158 to $KERNEL_DIR/"
  fi
fi
ls -la "$KERNEL_DIR/" 2>/dev/null

echo "Phase 4 done."

# ── Phase 5: PostgreSQL + Redis (Docker) ──────────────────────────────────────
echo "── Phase 5: PostgreSQL + Redis ──"

# PostgreSQL
if ! docker ps | grep -q e2b-postgres; then
  docker rm -f e2b-postgres 2>/dev/null || true
  docker run -d --name e2b-postgres --restart unless-stopped \
    -e POSTGRES_USER=e2b \
    -e POSTGRES_PASSWORD=e2b_local \
    -e POSTGRES_DB=e2b \
    -p 5432:5432 \
    postgres:15-alpine
  echo "Waiting for PostgreSQL..."
  sleep 5
fi

# Redis
if ! docker ps | grep -q e2b-redis; then
  docker rm -f e2b-redis 2>/dev/null || true
  docker run -d --name e2b-redis --restart unless-stopped \
    -p 6379:6379 \
    redis:7-alpine
fi

echo "Phase 5 done."

# ── Phase 6: Database migrations + seed ───────────────────────────────────────
echo "── Phase 6: Database migrations + seed ──"

# Wait for postgres
for i in $(seq 1 30); do
  docker exec e2b-postgres pg_isready -U e2b 2>/dev/null && break
  sleep 1
done

# Create postgres role (needed by Supabase migration)
docker exec e2b-postgres psql -U e2b -d e2b -c "CREATE ROLE postgres WITH LOGIN SUPERUSER PASSWORD 'postgres';" 2>/dev/null || true

# Run goose migrations
if [ -d "$E2B_DIR/packages/db/migrations" ]; then
  echo "Running goose migrations..."
  go install github.com/pressly/goose/v3/cmd/goose@latest 2>/dev/null || true
  export GOOSE_DRIVER=postgres
  export GOOSE_DBSTRING="postgresql://e2b:e2b_local@localhost:5432/e2b?sslmode=disable"
  export GOOSE_MIGRATION_DIR="$E2B_DIR/packages/db/migrations"
  $(go env GOPATH)/bin/goose up 2>/dev/null || /root/go/bin/goose up 2>/dev/null || {
    echo "goose not found, trying direct psql..."
    for f in $(ls $E2B_DIR/packages/db/migrations/*.sql | sort); do
      docker exec -i e2b-postgres psql -U e2b -d e2b < "$f" 2>/dev/null || true
    done
  }
fi

# Seed data — use the canonical seed.sql from aws/db/ if available, otherwise
# fall back to inline SQL that matches the canonical team/tier IDs.
echo "Seeding data..."
SEED_SQL_FILE="$SCRIPT_DIR/../aws/db/seed.sql"
if [ -f "$SEED_SQL_FILE" ]; then
  echo "  Using canonical seed file: $SEED_SQL_FILE"
  docker exec -i e2b-postgres psql -U e2b -d e2b < "$SEED_SQL_FILE"
else
  echo "  seed.sql not found, using inline seed..."
fi

# Always ensure tier, team, and base template exist (idempotent).
# Uses the canonical team ID '00000000-0000-0000-0000-000000000001' from seed.sql.
docker exec e2b-postgres psql -U e2b -d e2b <<'SEED_SQL'
-- Tier
INSERT INTO tiers (id, name, disk_mb, concurrent_instances, max_length_hours, max_vcpu, max_ram_mb, concurrent_template_builds)
VALUES ('base_v1', 'Base', 512, 500, 24, 8, 8192, 20)
ON CONFLICT (id) DO NOTHING;

-- Team (canonical ID matches aws/db/seed.sql)
INSERT INTO teams (id, name, tier, email, slug)
VALUES ('00000000-0000-0000-0000-000000000001', 'self-hosted', 'base_v1', 'admin@e2b.local', 'self-hosted')
ON CONFLICT (id) DO NOTHING;

-- Base template
INSERT INTO envs (id, team_id, public, build_count, source)
VALUES ('base', '00000000-0000-0000-0000-000000000001', true, 1, 'template')
ON CONFLICT (id) DO NOTHING;
SEED_SQL

echo ""
echo "  NOTE: Use 'cd aws/db && go run generate_api_key.go' to generate an API key."
echo "        Do NOT hard-code API key hashes in setup scripts."

echo "Phase 6 done."

# ── Phase 7: Build base template ──────────────────────────────────────────────
echo "── Phase 7: Build base template ──"

# Check if base template already exists in snapshot-cache
BASE_BUILD_EXISTS=$(find $DATA_DIR/templates/snapshot-cache -name 'snapfile.mem' 2>/dev/null | head -1)
if [ -z "$BASE_BUILD_EXISTS" ]; then
  echo "No templates found. You need to build them."
  echo ""
  echo "To build base template:"
  echo "  cd $E2B_DIR/packages/orchestrator"
  echo "  sudo go run ./cmd/create-build -template base -to-build <uuid> \\"
  echo "    -memory 1024 -disk 1024 -vcpu 2 \\"
  echo "    -storage $DATA_DIR/templates -hugepages=false"
  echo ""
  echo "To build playwright384 template:"
  echo "  docker build -t playwright384:prebuilt -f /path/to/Dockerfile.playwright ."
  echo "  sudo go run ./cmd/create-build -template playwright384 -to-build <uuid> \\"
  echo "    -memory 384 -disk 8530 -vcpu 2 -from-image '' \\"
  echo "    -storage $DATA_DIR/templates -hugepages=false"
else
  echo "Templates found in snapshot-cache."
fi

echo "Phase 7 done."

# ── Phase 8: Nomad + Services ─────────────────────────────────────────────────
echo "── Phase 8: Starting services ──"

# Nomad (dev mode for service discovery)
if ! pgrep -x nomad > /dev/null; then
  nohup /usr/local/bin/nomad agent -dev -bind=0.0.0.0 > /tmp/nomad_dev.log 2>&1 &
  sleep 3
fi

# Install systemd unit files for E2B services
mkdir -p /opt/e2b

E2B_DIR="${E2B_HOME:-/home/ubuntu/e2b}"
DATA_DIR="/data/e2b"

# Write orchestrator env file
cat > /opt/e2b/orchestrator.env <<ENV_EOF
ENVIRONMENT=local
NODE_ID=local
SANDBOX_DIR=$DATA_DIR/sandbox
LOCAL_TEMPLATE_STORAGE_BASE_PATH=$DATA_DIR/templates
STORAGE_PROVIDER=Local
TEMPLATE_BUCKET_NAME=unused
BUILD_CACHE_BUCKET_NAME=unused
DOCKER_REGISTRY=localhost:5000
FIRECRACKER_VERSIONS_DIR=$DATA_DIR/fc-versions
KERNEL_VERSIONS_DIR=$DATA_DIR/kernels
ENV_EOF

# Write API env file
cat > /opt/e2b/api.env <<ENV_EOF
ENVIRONMENT=local
NODE_ID=local
POSTGRES_CONNECTION_STRING=postgresql://e2b:e2b_local@localhost:5432/e2b?sslmode=disable
REDIS_URL=localhost:6379
ORCHESTRATOR_PORT=5008
PORT=80
API_SECRET=test-secret
TEMPLATE_MANAGER_ADDRESS=localhost:5009
SANDBOX_ACCESS_TOKEN_HASH_SEED=test-seed-key-for-dev-12345678
ENV_EOF
chmod 600 /opt/e2b/orchestrator.env /opt/e2b/api.env

# Install systemd units for legacy path.
# NOTE: The repo-shipped units (aws/packer/setup/*.service) expect pre-built
# binaries at /usr/local/bin/{orchestrator,e2b-api} and are designed for the
# single-node Terraform/AMI path. The legacy script uses `go run .` instead.
E2B_DIR_RESOLVED="${E2B_HOME:-/home/ubuntu/e2b}"

cat > /etc/systemd/system/e2b-orchestrator.service <<UNIT
[Unit]
Description=E2B Orchestrator
After=network-online.target docker.service
Requires=docker.service
[Service]
Type=simple
EnvironmentFile=/opt/e2b/orchestrator.env
ExecStart=/usr/local/go/bin/go run .
WorkingDirectory=${E2B_DIR_RESOLVED}/packages/orchestrator
Restart=on-failure
RestartSec=5
StandardOutput=append:/var/log/orchestrator.log
StandardError=append:/var/log/orchestrator.log
[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/e2b-api.service <<UNIT
[Unit]
Description=E2B API Server
After=network-online.target docker.service e2b-orchestrator.service
Requires=docker.service
[Service]
Type=simple
EnvironmentFile=/opt/e2b/api.env
ExecStart=/usr/local/go/bin/go run .
WorkingDirectory=${E2B_DIR_RESOLVED}/packages/api
Restart=on-failure
RestartSec=5
StandardOutput=append:/var/log/api.log
StandardError=append:/var/log/api.log
[Install]
WantedBy=multi-user.target
UNIT

# Install the Firecracker networking helper + systemd unit (normally done by packer AMI build).
# The legacy script runs on stock Ubuntu, so we must install these ourselves.
NETWORKING_SCRIPT="$SCRIPT_DIR/../aws/packer/setup/setup-firecracker-networking.sh"
NETWORKING_SERVICE="$SCRIPT_DIR/../aws/packer/setup/e2b-network.service"
if [ -f "$NETWORKING_SCRIPT" ]; then
  install -m 0755 "$NETWORKING_SCRIPT" /opt/e2b/setup-firecracker-networking.sh
else
  # Inline fallback if repo layout is missing
  cat > /opt/e2b/setup-firecracker-networking.sh <<'NETSCRIPT'
#!/usr/bin/env bash
set -euo pipefail
FC_SUBNET="10.11.0.0/16"
DEFAULT_IF=$(ip route show default | awk '{print $5}' | head -1)
[ -z "$DEFAULT_IF" ] && { echo "e2b-network: no default route" | logger -t e2b-network; exit 1; }
iptables -N E2B-FORWARD 2>/dev/null || true
iptables -t nat -N E2B-POSTROUTING 2>/dev/null || true
iptables -F E2B-FORWARD
iptables -t nat -F E2B-POSTROUTING
iptables -C FORWARD -j E2B-FORWARD 2>/dev/null || iptables -I FORWARD 1 -j E2B-FORWARD
iptables -t nat -C POSTROUTING -j E2B-POSTROUTING 2>/dev/null || iptables -t nat -I POSTROUTING 1 -j E2B-POSTROUTING
iptables -A E2B-FORWARD -s "$FC_SUBNET" -j ACCEPT
iptables -A E2B-FORWARD -d "$FC_SUBNET" -j ACCEPT
iptables -t nat -A E2B-POSTROUTING -s "$FC_SUBNET" -o "$DEFAULT_IF" -j MASQUERADE
echo "e2b-network: rules applied (subnet=$FC_SUBNET, iface=$DEFAULT_IF)" | logger -t e2b-network
NETSCRIPT
  chmod +x /opt/e2b/setup-firecracker-networking.sh
fi

if [ -f "$NETWORKING_SERVICE" ]; then
  install -m 0644 "$NETWORKING_SERVICE" /etc/systemd/system/e2b-network.service
else
  cat > /etc/systemd/system/e2b-network.service <<'NETSVC'
[Unit]
Description=E2B Firecracker VM networking (iptables rules)
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/opt/e2b/setup-firecracker-networking.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
NETSVC
fi

systemctl daemon-reload
systemctl enable e2b-network.service
# Apply network rules now
/opt/e2b/setup-firecracker-networking.sh

# Write restart convenience script (uses systemd)
cat > /opt/e2b/restart-services.sh <<'SERVICES_EOF'
#!/bin/bash
set -e

# --- Clean all E2B network state ---
for ns in $(ip netns list 2>/dev/null | awk '{print $1}'); do
    ip netns delete $ns 2>/dev/null || true
done
for veth in $(ip link show 2>/dev/null | grep 'veth-' | awk -F': ' '{print $2}' | cut -d'@' -f1); do
    ip link delete $veth 2>/dev/null || true
done
# Purge stale per-sandbox iptables rules from built-in chains.
# FORWARD/PREROUTING rules reference veth-*; POSTROUTING MASQUERADE rules
# use -s 10.11.0.X/32 (sandbox host subnet, no veth token).
FC_HOST_PREFIX="10.11"
for chain_spec in "filter FORWARD veth-" "nat PREROUTING veth-" "nat POSTROUTING veth-" "nat POSTROUTING ${FC_HOST_PREFIX}."; do
    table=$(echo "$chain_spec" | awk '{print $1}')
    chain=$(echo "$chain_spec" | awk '{print $2}')
    pattern=$(echo "$chain_spec" | awk '{print $3}')
    iptables -t "$table" -S "$chain" 2>/dev/null | grep -n "$pattern" | sort -t: -k1 -rn | while IFS=: read -r _ rule; do
        iptables -t "$table" $(echo "$rule" | sed "s/^-A/-D/") 2>/dev/null || true
    done
done

# Flush E2B static chains and repopulate
iptables -F E2B-FORWARD 2>/dev/null || true
iptables -t nat -F E2B-POSTROUTING 2>/dev/null || true
/opt/e2b/setup-firecracker-networking.sh

# Restart services via systemd
systemctl restart e2b-orchestrator
echo "Orchestrator started"
sleep 5
systemctl restart e2b-api
echo "API started"
sleep 15
curl -s http://localhost:80/health && echo " OK" || echo " NOT READY"
SERVICES_EOF
chmod +x /opt/e2b/restart-services.sh

# Start services
bash /opt/e2b/restart-services.sh

echo "Phase 8 done."

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  E2B Self-Hosted Setup Complete"
echo "============================================================"
echo ""
echo "Services:"
echo "  Orchestrator: :5008 (gRPC), :5007 (sandbox proxy)"
echo "  API:          :80 (REST)"
echo "  PostgreSQL:   :5432 (Docker)"
echo "  Redis:        :6379 (Docker)"
echo "  Nomad:        :4646 (dev mode)"
echo ""
echo "API Key: Generate with 'cd aws/db && go run generate_api_key.go'"
echo ""
echo "Test (replace <YOUR_API_KEY> with output from generate_api_key.go):"
echo "  python3 -c '"
echo "  import os"
echo "  os.environ[\"E2B_API_KEY\"]=\"<YOUR_API_KEY>\""
echo "  os.environ[\"E2B_API_URL\"]=\"http://localhost:80\""
echo "  os.environ[\"E2B_SANDBOX_URL\"]=\"http://localhost:5007\""
echo "  from e2b import Sandbox"
echo "  sbx = Sandbox.create(\"base\", timeout=30)"
echo "  print(sbx.commands.run(\"echo hello\").stdout)"
echo "  sbx.kill()"
echo "  '"
echo ""
echo "Restart services: sudo bash /opt/e2b/restart-services.sh"
echo "Build template:   See Phase 7 output above"
