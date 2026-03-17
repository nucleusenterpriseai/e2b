#!/bin/bash
# =============================================================================
# E2B Self-Hosted — Full Single-Node Setup
# =============================================================================
# Installs and configures the complete E2B platform on a bare-metal EC2:
#   - Go toolchain + Docker + PostgreSQL + Redis + Docker Registry
#   - Firecracker + ARM64/x86_64 kernel
#   - Builds orchestrator, API, envd from source
#   - Runs DB migrations + seeds data + generates API key
#   - Starts all services
#   - Builds the base template
#
# Prerequisites: Ubuntu 22.04, bare-metal instance (KVM support), 200GB+ disk
#
# Usage:
#   sudo bash /opt/e2b/ec2-setup.sh          # full setup
#   sudo bash /opt/e2b/ec2-setup.sh --skip-build  # skip Go builds (use pre-built binaries)
# =============================================================================
set -euo pipefail

LOGFILE="/var/log/e2b-setup.log"
exec > >(tee -a "$LOGFILE") 2>&1

SECONDS=0
log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "=== E2B Self-Hosted Setup Starting ==="

# ── Ensure HOME/GOPATH are set (cloud-init user-data runs with HOME unset) ──
export HOME="${HOME:-/root}"
export GOPATH="${GOPATH:-$HOME/go}"

# ── Configuration ───────────────────────────────────────────────────────
DATA_DIR="/data/e2b"
E2B_HOME="/home/ubuntu/e2b"
INFRA_DIR="$E2B_HOME/infra"
ENVD_DIR="/home/envd/bin"
FC_VERSION="${FC_VERSION:-v1.12.1}"
FC_COMMIT="${FC_COMMIT:-a41d3fb}"
KERNEL_VERSION="${KERNEL_VERSION:-vmlinux-6.1.158}"
GO_VERSION="${GO_VERSION:-1.25.4}"
INFRA_REPO_URL="${INFRA_REPO_URL:-https://github.com/e2b-dev/infra.git}"
INFRA_REPO_REF="${INFRA_REPO_REF:-main}"
ARCH=$(uname -m)  # aarch64 or x86_64
GOARCH=$( [ "$ARCH" = "aarch64" ] && echo "arm64" || echo "amd64" )
FC_ARCH=$( [ "$ARCH" = "aarch64" ] && echo "aarch64" || echo "x86_64" )
DB_USER="e2b"
DB_PASS="e2b_local"
DB_NAME="e2b"
DB_URL="postgresql://$DB_USER:$DB_PASS@localhost:5432/$DB_NAME?sslmode=disable"
POSTGRES_VERSION="${POSTGRES_VERSION:-15}"
API_KEY_FILE="/opt/e2b/api-key"

# ── 1. System Packages ─────────────────────────────────────────────────
log "Step 1/12: Installing system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    build-essential curl wget git jq unzip \
    iptables iproute2 net-tools \
    ca-certificates gnupg lsb-release \
    postgresql-client acl

# ── 2. Docker ───────────────────────────────────────────────────────────
log "Step 2/12: Installing Docker..."
if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sh
    usermod -aG docker ubuntu
    systemctl enable docker
    systemctl start docker
else
    log "  Docker already installed"
fi

# ── 3. Go Toolchain ────────────────────────────────────────────────────
log "Step 3/12: Installing Go $GO_VERSION..."
if [ ! -f /usr/local/go/bin/go ] || ! /usr/local/go/bin/go version | grep -q "$GO_VERSION"; then
    rm -rf /usr/local/go
    wget -q "https://go.dev/dl/go${GO_VERSION}.linux-${GOARCH}.tar.gz" -O /tmp/go.tar.gz
    tar -C /usr/local -xzf /tmp/go.tar.gz
    rm /tmp/go.tar.gz
fi
export PATH="/usr/local/go/bin:/root/go/bin:$PATH"
echo 'export PATH=/usr/local/go/bin:/root/go/bin:$PATH' > /etc/profile.d/go.sh
log "  Go: $(/usr/local/go/bin/go version)"

# ── 4. Data Directories ────────────────────────────────────────────────
log "Step 4/12: Creating data directories..."
mkdir -p "$DATA_DIR"/{fc-versions,kernels,orchestrator,sandbox,snapshot-cache}
mkdir -p "$DATA_DIR"/templates/{templates,snapshot-cache,build-cache,orchestrator,sandbox}
mkdir -p "$DATA_DIR"/templates/fc-versions
mkdir -p "$DATA_DIR"/templates/kernels
mkdir -p "$ENVD_DIR"
mkdir -p /opt/e2b

# ── 5. HugePages ───────────────────────────────────────────────────────
log "Step 5/12: Configuring HugePages..."
TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_MEM_GB=$((TOTAL_MEM_KB / 1024 / 1024))
# Reserve 80% of memory for hugepages (2MB each)
HUGEPAGES=$((TOTAL_MEM_GB * 1024 * 80 / 100 / 2))
log "  Total memory: ${TOTAL_MEM_GB}GB, allocating $HUGEPAGES hugepages (2MB each)"
echo "$HUGEPAGES" > /proc/sys/vm/nr_hugepages
echo "vm.nr_hugepages=$HUGEPAGES" > /etc/sysctl.d/99-hugepages.conf

# ── 6. Kernel Tuning ───────────────────────────────────────────────────
log "Step 6/12: Kernel tuning..."
modprobe nbd nbds_max=1024 max_part=15 2>/dev/null || true
echo "nbd" > /etc/modules-load.d/nbd.conf
echo "options nbd nbds_max=1024 max_part=15" > /etc/modprobe.d/nbd.conf

sysctl -w vm.max_map_count=1048576
sysctl -w net.ipv4.ip_forward=1
echo "vm.max_map_count=1048576" > /etc/sysctl.d/99-e2b.conf
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.d/99-e2b.conf

# Verify KVM
if [ -c /dev/kvm ]; then
    log "  KVM: OK"
    chmod 666 /dev/kvm
else
    log "  WARNING: /dev/kvm not found — Firecracker will not work"
fi

# Install Firecracker networking helper + systemd unit.
# On AMI-based instances this is done by packer (system-tuning.sh), but the
# stock-Ubuntu full-setup path needs it installed here.
log "  Installing E2B networking helper..."
mkdir -p /opt/e2b
# Check both direct and custom/ paths for repo-shipped files
NETWORKING_SRC="$E2B_HOME/aws/packer/setup/setup-firecracker-networking.sh"
NETWORKING_SVC="$E2B_HOME/aws/packer/setup/e2b-network.service"
[ -f "$NETWORKING_SRC" ] || NETWORKING_SRC="$E2B_HOME/custom/aws/packer/setup/setup-firecracker-networking.sh"
[ -f "$NETWORKING_SVC" ] || NETWORKING_SVC="$E2B_HOME/custom/aws/packer/setup/e2b-network.service"
if [ -f "$NETWORKING_SRC" ]; then
    install -m 0755 "$NETWORKING_SRC" /opt/e2b/setup-firecracker-networking.sh
else
    # Inline fallback
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
if [ -f "$NETWORKING_SVC" ]; then
    install -m 0644 "$NETWORKING_SVC" /etc/systemd/system/e2b-network.service
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
/opt/e2b/setup-firecracker-networking.sh
log "  E2B networking helper installed and active"

# ── 7. Docker Services (PostgreSQL, Redis, Registry) ───────────────────
log "Step 7/12: Starting Docker services..."

# PostgreSQL
if ! docker ps --format '{{.Names}}' | grep -q e2b-postgres; then
    docker run -d \
        --name e2b-postgres \
        --restart unless-stopped \
        -e POSTGRES_USER=$DB_USER \
        -e POSTGRES_PASSWORD=$DB_PASS \
        -e POSTGRES_DB=$DB_NAME \
        -p 5432:5432 \
        -v e2b-pgdata:/var/lib/postgresql/data \
        postgres:${POSTGRES_VERSION}-alpine
    log "  PostgreSQL started"
else
    log "  PostgreSQL already running"
fi

# Redis
if ! docker ps --format '{{.Names}}' | grep -q e2b-redis; then
    docker run -d \
        --name e2b-redis \
        --restart unless-stopped \
        -p 6379:6379 \
        redis:7-alpine
    log "  Redis started"
else
    log "  Redis already running"
fi

# Docker Registry (for template images)
if ! docker ps --format '{{.Names}}' | grep -q e2b-registry; then
    docker run -d \
        --name e2b-registry \
        --restart unless-stopped \
        -p 5000:5000 \
        -v e2b-registry:/var/lib/registry \
        registry:2
    log "  Docker registry started"
else
    log "  Docker registry already running"
fi

# Wait for PostgreSQL to be ready
log "  Waiting for PostgreSQL..."
for i in $(seq 1 30); do
    if docker exec e2b-postgres pg_isready -U $DB_USER -d $DB_NAME &>/dev/null; then
        log "  PostgreSQL ready"
        break
    fi
    sleep 1
done

# ── 8. Clone + Build E2B Infrastructure ─────────────────────────────────
log "Step 8/12: Cloning and building E2B infrastructure..."

if [ ! -d "$INFRA_DIR" ]; then
    log "  Cloning infra from $INFRA_REPO_URL (ref: $INFRA_REPO_REF)..."
    mkdir -p "$E2B_HOME"
    git clone --depth 1 --branch "$INFRA_REPO_REF" "$INFRA_REPO_URL" "$INFRA_DIR"
    chown -R ubuntu:ubuntu "$E2B_HOME"
fi

# Apply the envd init timeout fix (increase from 50ms to 2000ms)
FEATURE_FLAGS="$INFRA_DIR/packages/shared/pkg/feature-flags/flags.go"
if grep -q 'envd-init-request-timeout-milliseconds", 50' "$FEATURE_FLAGS" 2>/dev/null; then
    log "  Applying envd init timeout fix (50ms -> 2000ms)..."
    sed -i 's/envd-init-request-timeout-milliseconds", 50/envd-init-request-timeout-milliseconds", 2000/' "$FEATURE_FLAGS"
fi

# Build orchestrator
log "  Building orchestrator..."
cd "$INFRA_DIR/packages/orchestrator"
CGO_ENABLED=1 GOOS=linux GOARCH=$GOARCH /usr/local/go/bin/go build -buildvcs=false -o /usr/local/bin/orchestrator .
log "  Built: /usr/local/bin/orchestrator"

# Build API
log "  Building API..."
cd "$INFRA_DIR/packages/api"
CGO_ENABLED=0 GOOS=linux GOARCH=$GOARCH /usr/local/go/bin/go build -buildvcs=false -o /usr/local/bin/e2b-api .
log "  Built: /usr/local/bin/e2b-api"

# Build envd
log "  Building envd..."
cd "$INFRA_DIR/packages/envd"
CGO_ENABLED=0 GOOS=linux GOARCH=$GOARCH /usr/local/go/bin/go build -buildvcs=false -o "$ENVD_DIR/envd" .
log "  Built: $ENVD_DIR/envd"

# Build create-build tool
log "  Building create-build..."
cd "$INFRA_DIR/packages/orchestrator"
CGO_ENABLED=1 GOOS=linux GOARCH=$GOARCH /usr/local/go/bin/go build -buildvcs=false -o /usr/local/bin/create-build ./cmd/create-build/
log "  Built: /usr/local/bin/create-build"

# ── 9. Download Firecracker + Kernel ────────────────────────────────────
log "Step 9/12: Downloading Firecracker and kernel..."

FC_DIR="$DATA_DIR/fc-versions/${FC_VERSION}_${FC_COMMIT}"
FC_TEMPLATE_DIR="$DATA_DIR/templates/fc-versions/${FC_VERSION}_${FC_COMMIT}"
mkdir -p "$FC_DIR" "$FC_TEMPLATE_DIR"

if [ ! -f "$FC_DIR/firecracker" ]; then
    log "  Downloading Firecracker ${FC_VERSION} for ${FC_ARCH}..."
    FC_URL="https://github.com/firecracker-microvm/firecracker/releases/download/${FC_VERSION}/firecracker-${FC_VERSION}-${FC_ARCH}.tgz"
    wget -q "$FC_URL" -O /tmp/fc.tgz
    tar -xzf /tmp/fc.tgz -C /tmp/
    cp "/tmp/release-${FC_VERSION}-${FC_ARCH}/firecracker-${FC_VERSION}-${FC_ARCH}" "$FC_DIR/firecracker"
    chmod +x "$FC_DIR/firecracker"
    rm -rf /tmp/fc.tgz "/tmp/release-${FC_VERSION}-${FC_ARCH}"
fi
# Symlink to templates dir
if [ ! -f "$FC_TEMPLATE_DIR/firecracker" ]; then
    ln -sf "$FC_DIR/firecracker" "$FC_TEMPLATE_DIR/firecracker"
fi
log "  Firecracker: $FC_DIR/firecracker"

KERNEL_DIR="$DATA_DIR/kernels/$KERNEL_VERSION"
KERNEL_TEMPLATE_DIR="$DATA_DIR/templates/kernels/$KERNEL_VERSION"
mkdir -p "$KERNEL_DIR" "$KERNEL_TEMPLATE_DIR"

if [ ! -f "$KERNEL_DIR/vmlinux.bin" ] || [ ! -s "$KERNEL_DIR/vmlinux.bin" ]; then
    rm -f "$KERNEL_DIR/vmlinux.bin"  # remove 0-byte stale files
    log "  Downloading kernel $KERNEL_VERSION for $FC_ARCH..."
    KERNEL_DOWNLOADED=false

    # 1. Try explicit kernel_url (HTTPS only — set via Terraform variable or env)
    if [ -n "${KERNEL_URL:-}" ]; then
        log "  Using provided KERNEL_URL: $KERNEL_URL"
        wget -q "$KERNEL_URL" -O "$KERNEL_DIR/vmlinux.bin" 2>/dev/null && KERNEL_DOWNLOADED=true
    fi

    # 2. Fallback: try project GitHub release
    if [ "$KERNEL_DOWNLOADED" = false ]; then
        GH_KERNEL_URL="https://github.com/nucleusenterpriseai/e2b/releases/download/kernels-v1/${KERNEL_VERSION}-${FC_ARCH}.bin"
        log "  Trying project release: $GH_KERNEL_URL"
        wget -q "$GH_KERNEL_URL" -O "$KERNEL_DIR/vmlinux.bin" 2>/dev/null && KERNEL_DOWNLOADED=true
    fi

    # 3. Fallback: try upstream e2b-dev GitHub releases
    if [ "$KERNEL_DOWNLOADED" = false ]; then
        GH_KERNEL_URL="https://github.com/e2b-dev/firecracker-kernels/releases/download/${KERNEL_VERSION}/vmlinux-${FC_ARCH}.bin"
        wget -q "$GH_KERNEL_URL" -O "$KERNEL_DIR/vmlinux.bin" 2>/dev/null && KERNEL_DOWNLOADED=true
    fi

    # Validate — wget -O creates 0-byte files on 404
    if [ ! -s "$KERNEL_DIR/vmlinux.bin" ]; then
        rm -f "$KERNEL_DIR/vmlinux.bin"
        log "  FATAL: Could not download kernel. Set kernel_url in terraform.tfvars or place vmlinux.bin in $KERNEL_DIR/"
        exit 1
    fi
    log "  Kernel downloaded: $(ls -la "$KERNEL_DIR/vmlinux.bin")"
fi
if [ ! -f "$KERNEL_TEMPLATE_DIR/vmlinux.bin" ]; then
    ln -sf "$KERNEL_DIR/vmlinux.bin" "$KERNEL_TEMPLATE_DIR/vmlinux.bin"
fi
log "  Kernel: $KERNEL_DIR/vmlinux.bin"

# ── 10. Database Migrations + Seed ─────────────────────────────────────
log "Step 10/12: Running database migrations..."

# Install goose
if ! command -v goose &>/dev/null; then
    /usr/local/go/bin/go install github.com/pressly/goose/v3/cmd/goose@latest
fi
export PATH="/root/go/bin:$PATH"

# Create postgres role (needed by Supabase auth migration)
PGPASSWORD=$DB_PASS psql -h localhost -U $DB_USER -d $DB_NAME -c \
    "CREATE ROLE postgres WITH LOGIN SUPERUSER PASSWORD 'postgres';" 2>/dev/null || true

MIGRATIONS_DIR="$INFRA_DIR/packages/db/migrations"
log "  Running goose migrations from $MIGRATIONS_DIR..."
goose -dir "$MIGRATIONS_DIR" -table "_migrations" postgres "$DB_URL" up

log "  Seeding tier + team..."
PGPASSWORD=$DB_PASS psql -h localhost -U $DB_USER -d $DB_NAME -c "
INSERT INTO public.tiers (id, name, disk_mb, concurrent_instances, max_length_hours, max_vcpu, max_ram_mb, concurrent_template_builds)
VALUES ('base_v1', 'Base', 512, 500, 24, 8, 8192, 20)
ON CONFLICT (id) DO UPDATE SET concurrent_instances = 500;
" 2>/dev/null || true

PGPASSWORD=$DB_PASS psql -h localhost -U $DB_USER -d $DB_NAME -c "
INSERT INTO public.teams (id, name, tier, email, slug)
VALUES ('00000000-0000-0000-0000-000000000001', 'self-hosted', 'base_v1', 'admin@e2b.local', 'self-hosted')
ON CONFLICT (id) DO NOTHING;
" 2>/dev/null || true

# Generate API key
log "  Generating API key..."
API_KEY_OUTPUT=""
if [ -f "$E2B_HOME/aws/db/generate_api_key.go" ]; then
    cd "$E2B_HOME/aws/db"
    API_KEY_OUTPUT=$(/usr/local/go/bin/go run -buildvcs=false generate_api_key.go 2>&1) || API_KEY_OUTPUT=""
    cd "$E2B_HOME"
fi

if [ -n "$API_KEY_OUTPUT" ]; then
    RAW_KEY=$(echo "$API_KEY_OUTPUT" | grep "^  e2b_" | tr -d ' ')
    SQL_INSERT=$(echo "$API_KEY_OUTPUT" | sed -n '/^INSERT INTO/,/;$/p')
    if [ -n "$RAW_KEY" ] && [ -n "$SQL_INSERT" ]; then
        PGPASSWORD=$DB_PASS psql -h localhost -U $DB_USER -d $DB_NAME -c "$SQL_INSERT" 2>/dev/null || true
        echo "$RAW_KEY" > "$API_KEY_FILE"
        chmod 600 "$API_KEY_FILE"
        log "  API Key generated and saved to $API_KEY_FILE"
        log "  Key: $RAW_KEY"
    fi
fi

if [ ! -f "$API_KEY_FILE" ]; then
    log "  FATAL: API key generation failed. /opt/e2b/api-key does not exist."
    log "  Debug: cd $E2B_HOME/aws/db && go run -buildvcs=false generate_api_key.go"
    exit 1
fi

# Get actual envd version from built binary
ENVD_VERSION=$("$ENVD_DIR/envd" --version 2>/dev/null || echo "0.5.5")
log "  envd version: $ENVD_VERSION"

# Seed base template env entry
log "  Seeding base template in DB..."
PGPASSWORD=$DB_PASS psql -h localhost -U $DB_USER -d $DB_NAME -c "
INSERT INTO envs (id, team_id, public, build_count, source, updated_at)
VALUES ('base', '00000000-0000-0000-0000-000000000001', true, 1, 'template', now())
ON CONFLICT (id) DO NOTHING;

INSERT INTO env_builds (id, env_id, status, status_group, dockerfile, start_cmd, vcpu, ram_mb, free_disk_size_mb, total_disk_size_mb, kernel_version, firecracker_version, envd_version, updated_at)
VALUES (
  'bb000000-0000-0000-0000-000000000001', 'base', 'uploaded', 'ready',
  'FROM e2bdev/base:latest', '', 2, 512, 512, 512,
  '$KERNEL_VERSION', '${FC_VERSION}_${FC_COMMIT}', '$ENVD_VERSION', now()
) ON CONFLICT (id) DO NOTHING;

INSERT INTO env_build_assignments (env_id, build_id, tag)
SELECT 'base', 'bb000000-0000-0000-0000-000000000001', 'default'
WHERE NOT EXISTS (
  SELECT 1 FROM env_build_assignments WHERE env_id = 'base' AND tag = 'default'
);

INSERT INTO env_aliases (env_id, alias, namespace)
VALUES ('base', 'base', NULL)
ON CONFLICT (alias, namespace) DO NOTHING;
"

# ── 11. Write Service Configs + Start Services ─────────────────────────
log "Step 11/12: Starting E2B services..."

# Stop any existing services
systemctl stop e2b-orchestrator 2>/dev/null || true
systemctl stop e2b-api 2>/dev/null || true

# Clean all E2B network state from previous runs
for ns in $(ip netns list 2>/dev/null | awk '{print $1}'); do
    ip netns delete "$ns" 2>/dev/null || true
done
for veth in $(ip link show 2>/dev/null | grep 'veth-' | awk -F': ' '{print $2}' | cut -d'@' -f1); do
    ip link delete "$veth" 2>/dev/null || true
done
# Purge stale per-sandbox iptables rules from built-in chains.
# FORWARD and PREROUTING rules reference veth-* interfaces.
# POSTROUTING MASQUERADE rules use -s 10.11.0.X/32 (no veth token),
# so we match the sandbox subnet separately.
FC_HOST_SUBNET="${SANDBOXES_HOST_NETWORK_CIDR:-10.11.0.0/16}"
FC_HOST_PREFIX=$(echo "$FC_HOST_SUBNET" | cut -d'.' -f1-2)  # e.g. "10.11"
for chain_spec in "filter FORWARD veth-" "nat PREROUTING veth-" "nat POSTROUTING veth-" "nat POSTROUTING ${FC_HOST_PREFIX}."; do
    table=$(echo "$chain_spec" | awk '{print $1}')
    chain=$(echo "$chain_spec" | awk '{print $2}')
    pattern=$(echo "$chain_spec" | awk '{print $3}')
    # grep returns 1 when no matches — use || true to prevent pipefail abort
    iptables -t "$table" -S "$chain" 2>/dev/null | { grep -n "$pattern" || true; } | sort -t: -k1 -rn | while IFS=: read -r _ rule; do
        iptables -t "$table" $(echo "$rule" | sed "s/^-A/-D/") 2>/dev/null || true
    done
done
# Flush E2B static chains and repopulate
iptables -F E2B-FORWARD 2>/dev/null || true
iptables -t nat -F E2B-POSTROUTING 2>/dev/null || true
/opt/e2b/setup-firecracker-networking.sh 2>/dev/null || true

# Write orchestrator env file
cat > /opt/e2b/orchestrator.env <<EOF
NODE_ID=local-ec2
NODE_IP=0.0.0.0
POSTGRES_CONNECTION_STRING=$DB_URL
REDIS_URL=localhost:6379
GRPC_PORT=5008
PROXY_PORT=5007
ORCHESTRATOR_SERVICES=orchestrator,template-manager
ORCHESTRATOR_BASE_PATH=$DATA_DIR/templates/orchestrator
SANDBOX_DIR=$DATA_DIR/templates/sandbox
HOST_ENVD_PATH=$ENVD_DIR/envd
HOST_KERNELS_DIR=$DATA_DIR/templates/kernels
FIRECRACKER_VERSIONS_DIR=$DATA_DIR/templates/fc-versions
TEMPLATE_CACHE_DIR=$DATA_DIR/templates/templates
SNAPSHOT_CACHE_DIR=$DATA_DIR/templates/snapshot-cache
ENVIRONMENT=local
E2B_DEBUG=true
STORAGE_PROVIDER=Local
LOCAL_TEMPLATE_STORAGE_BASE_PATH=$DATA_DIR/templates/templates
LOCAL_BUILD_CACHE_STORAGE_BASE_PATH=$DATA_DIR/templates/build-cache
ARTIFACTS_REGISTRY_PROVIDER=Local
EOF

# Write API env file
cat > /opt/e2b/api.env <<EOF
POSTGRES_CONNECTION_STRING=$DB_URL
REDIS_URL=localhost:6379
ADMIN_TOKEN=local-admin-token
ENVIRONMENT=local
E2B_DEBUG=true
DOMAIN_NAME=localhost
API_PORT=3000
ORCHESTRATOR_ADDRESS=localhost:5008
STORAGE_PROVIDER=Local
LOCAL_TEMPLATE_STORAGE_BASE_PATH=$DATA_DIR/templates/templates
ARTIFACTS_REGISTRY_PROVIDER=Local
DEFAULT_KERNEL_VERSION=$KERNEL_VERSION
NODE_ID=local-ec2
SANDBOX_ACCESS_TOKEN_HASH_SEED=local-dev-seed-key-for-access-tokens-12345
LOKI_URL=http://localhost:3100
VOLUME_TOKEN_ISSUER=e2b-self-hosted
VOLUME_TOKEN_SIGNING_METHOD=HS256
VOLUME_TOKEN_SIGNING_KEY=HMAC:bG9jYWwtZGV2LXNpZ25pbmcta2V5LWZvci12b2x1bWUtdG9rZW5z
VOLUME_TOKEN_SIGNING_KEY_NAME=local-dev-key
EOF

chmod 600 /opt/e2b/orchestrator.env /opt/e2b/api.env

# Install systemd unit files
# Try repo-shipped units first; fall back to inline definitions
if [ -f "$E2B_HOME/aws/packer/setup/e2b-orchestrator.service" ]; then
    cp "$E2B_HOME/aws/packer/setup/e2b-orchestrator.service" /etc/systemd/system/
    cp "$E2B_HOME/aws/packer/setup/e2b-api.service" /etc/systemd/system/
elif [ -f "$E2B_HOME/custom/aws/packer/setup/e2b-orchestrator.service" ]; then
    cp "$E2B_HOME/custom/aws/packer/setup/e2b-orchestrator.service" /etc/systemd/system/
    cp "$E2B_HOME/custom/aws/packer/setup/e2b-api.service" /etc/systemd/system/
else
    cat > /etc/systemd/system/e2b-orchestrator.service <<'UNIT'
[Unit]
Description=E2B Orchestrator — Firecracker VM orchestration
After=network-online.target docker.service e2b-network.service
Wants=network-online.target
Requires=docker.service
[Service]
Type=simple
EnvironmentFile=/opt/e2b/orchestrator.env
ExecStart=/usr/local/bin/orchestrator
Restart=on-failure
RestartSec=5
StandardOutput=append:/var/log/orchestrator.log
StandardError=append:/var/log/orchestrator.log
LimitNOFILE=65536
LimitNPROC=65536
[Install]
WantedBy=multi-user.target
UNIT

    cat > /etc/systemd/system/e2b-api.service <<'UNIT'
[Unit]
Description=E2B API Server — REST API for sandbox management
After=network-online.target docker.service e2b-orchestrator.service
Wants=network-online.target
Requires=docker.service
[Service]
Type=simple
EnvironmentFile=/opt/e2b/api.env
ExecStart=/usr/local/bin/e2b-api
Restart=on-failure
RestartSec=5
StandardOutput=append:/var/log/api.log
StandardError=append:/var/log/api.log
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
UNIT
fi

systemctl daemon-reload

# Start orchestrator
log "  Starting orchestrator..."
systemctl enable --now e2b-orchestrator
sleep 3
if systemctl is-active --quiet e2b-orchestrator; then
    log "  Orchestrator started (PID $(systemctl show -p MainPID --value e2b-orchestrator))"
else
    log "  WARNING: Orchestrator may not have started. Check: journalctl -u e2b-orchestrator"
fi

# Start API
log "  Starting API..."
systemctl enable --now e2b-api
sleep 5
if systemctl is-active --quiet e2b-api; then
    log "  API started (PID $(systemctl show -p MainPID --value e2b-api))"
else
    log "  WARNING: API may not have started. Check: journalctl -u e2b-api"
fi

# Wait for API health
log "  Waiting for API health check..."
for i in $(seq 1 30); do
    if curl -sf http://localhost:80/health >/dev/null 2>&1; then
        log "  API health: OK"
        break
    fi
    sleep 2
done

# Wait for orchestrator node to register (~40s on startup)
log "  Waiting for orchestrator node registration..."
for i in $(seq 1 30); do
    if grep -q '"nodes_count": 1' /var/log/api.log 2>/dev/null || \
       grep -q '"nodes_count":1' /var/log/api.log 2>/dev/null; then
        log "  Orchestrator node: ready"
        break
    fi
    sleep 3
done

# ── 12. Build Templates ───────────────────────────────────────────────
log "Step 12/13: Building templates..."

# Pull base image
docker pull e2bdev/base:latest 2>/dev/null || log "  WARNING: Could not pull e2bdev/base:latest"

# Tag for local artifact registry (create-build uses "templateId:buildId" format)
BASE_BUILD_ID="bb000000-0000-0000-0000-000000000001"
docker tag e2bdev/base:latest "base:${BASE_BUILD_ID}"

# Run create-build for base
log "  Building base template..."
bash -c "set -a; source /opt/e2b/orchestrator.env; set +a; \
    /usr/local/bin/create-build \
    -template base \
    -to-build ${BASE_BUILD_ID} \
    -memory 512 -disk 512 -vcpu 2 \
    -kernel $KERNEL_VERSION \
    -firecracker ${FC_VERSION}_${FC_COMMIT} \
    -v" 2>&1 | tail -20 || {
    log "  WARNING: Base template build may have failed. Check output above."
}

# ── 13. Build Desktop Template (optional) ────────────────────────────
log "Step 13/13: Building desktop template..."

DESKTOP_BUILD_ID=$(python3 -c "import uuid; print(uuid.uuid4())")

# Build desktop Docker image from Dockerfile in user's repo
DESKTOP_DOCKERFILE="$E2B_HOME/custom/templates/desktop.Dockerfile"
if [ -f "$DESKTOP_DOCKERFILE" ]; then
    log "  Building desktop Docker image..."
    docker build -f "$DESKTOP_DOCKERFILE" -t "desktop:${DESKTOP_BUILD_ID}" "$E2B_HOME/custom" 2>&1 | tail -5

    # Seed desktop template in DB
    log "  Seeding desktop template in DB..."
    PGPASSWORD=$DB_PASS psql -h localhost -U $DB_USER -d $DB_NAME -c "
    INSERT INTO envs (id, team_id, public, build_count, source, updated_at)
    VALUES ('desktop', '00000000-0000-0000-0000-000000000001', true, 1, 'template', now())
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO env_builds (id, env_id, status, status_group, dockerfile, start_cmd, vcpu, ram_mb, free_disk_size_mb, total_disk_size_mb, kernel_version, firecracker_version, envd_version, updated_at)
    VALUES (
      '${DESKTOP_BUILD_ID}', 'desktop', 'uploaded', 'ready',
      '', '', 2, 512, 7168, 7168,
      '$KERNEL_VERSION', '${FC_VERSION}_${FC_COMMIT}', '$ENVD_VERSION', now()
    ) ON CONFLICT (id) DO NOTHING;

    INSERT INTO env_build_assignments (env_id, build_id, tag)
    SELECT 'desktop', '${DESKTOP_BUILD_ID}', 'default'
    WHERE NOT EXISTS (
      SELECT 1 FROM env_build_assignments WHERE env_id = 'desktop' AND tag = 'default'
    );

    INSERT INTO env_aliases (env_id, alias, namespace)
    VALUES ('desktop', 'desktop', NULL)
    ON CONFLICT (alias, namespace) DO NOTHING;
    "

    # Run create-build for desktop
    log "  Running create-build for desktop template..."
    bash -c "set -a; source /opt/e2b/orchestrator.env; set +a; \
        /usr/local/bin/create-build \
        -template desktop \
        -to-build ${DESKTOP_BUILD_ID} \
        -memory 512 -disk 7168 -vcpu 2 \
        -kernel $KERNEL_VERSION \
        -firecracker ${FC_VERSION}_${FC_COMMIT} \
        -v" 2>&1 | tail -20 || {
        log "  WARNING: Desktop template build may have failed. Check output above."
    }
else
    log "  Skipping desktop template (no Dockerfile found at $DESKTOP_DOCKERFILE)"
fi

# ── Write convenience scripts ──────────────────────────────────────────

cat > /opt/e2b/restart-services.sh <<'RESTART'
#!/bin/bash
set -e

# --- Clean all E2B network state ---
# Delete sandbox namespaces
for ns in $(ip netns list 2>/dev/null | awk '{print $1}'); do
    ip netns delete "$ns" 2>/dev/null || true
done
# Delete sandbox veth devices
for veth in $(ip link show 2>/dev/null | grep 'veth-' | awk -F': ' '{print $2}' | cut -d'@' -f1); do
    ip link delete "$veth" 2>/dev/null || true
done
# Purge stale per-sandbox iptables rules from built-in chains.
# FORWARD/PREROUTING rules reference veth-*; POSTROUTING MASQUERADE rules
# use -s 10.11.0.X/32 (sandbox host subnet, no veth token).
FC_HOST_PREFIX="10.11"  # first two octets of default sandbox host subnet
for chain_spec in "filter FORWARD veth-" "nat PREROUTING veth-" "nat POSTROUTING veth-" "nat POSTROUTING ${FC_HOST_PREFIX}."; do
    table=$(echo "$chain_spec" | awk '{print $1}')
    chain=$(echo "$chain_spec" | awk '{print $2}')
    pattern=$(echo "$chain_spec" | awk '{print $3}')
    # grep returns 1 when no matches — use || true to prevent pipefail abort
    iptables -t "$table" -S "$chain" 2>/dev/null | { grep -n "$pattern" || true; } | sort -t: -k1 -rn | while IFS=: read -r _ rule; do
        iptables -t "$table" $(echo "$rule" | sed "s/^-A/-D/") 2>/dev/null || true
    done
done

# Flush E2B static chains and repopulate them
iptables -F E2B-FORWARD 2>/dev/null || true
iptables -t nat -F E2B-POSTROUTING 2>/dev/null || true
/opt/e2b/setup-firecracker-networking.sh

# Restart E2B services via systemd
systemctl restart e2b-orchestrator
echo "Orchestrator started"
sleep 5
systemctl restart e2b-api
echo "API started"
sleep 5
curl -sf http://localhost:80/health && echo " Health: OK" || echo " Health: NOT READY"
# Wait for orchestrator node registration (~40s)
echo "Waiting for orchestrator node..."
for i in $(seq 1 30); do
    if grep -q '"nodes_count": 1\|"nodes_count":1' /var/log/api.log 2>/dev/null; then
        echo " Node: ready"
        break
    fi
    sleep 3
done
RESTART
chmod +x /opt/e2b/restart-services.sh

# ── Summary ─────────────────────────────────────────────────────────────
ELAPSED=$SECONDS
API_KEY=$(cat "$API_KEY_FILE" 2>/dev/null || echo "not generated — run: cd $E2B_HOME && go run aws/db/generate_api_key.go")

log ""
log "============================================="
log "  E2B Self-Hosted Setup Complete"
log "  Time: $((ELAPSED/60))m $((ELAPSED%60))s"
log "============================================="
log "  API:          http://localhost:80"
log "  Orchestrator: localhost:5008 (gRPC)"
log "  Sandbox Proxy: localhost:5007"
log "  PostgreSQL:   localhost:5432"
log "  Redis:        localhost:6379"
log "  Registry:     localhost:5000"
log "  API Key:      $API_KEY"
log "  Logs:         /var/log/orchestrator.log, /var/log/api.log"
log "  Setup log:    $LOGFILE"
log "  Restart:      sudo /opt/e2b/restart-services.sh"
log "============================================="
