#!/usr/bin/env bash
# =============================================================================
# E2B Template Builder for EC2
# =============================================================================
# Automates the full template build process on an EC2 instance. This script:
#
#   1. Builds a Docker image from e2b-base-full.Dockerfile (pre-installs all
#      packages so provision.sh doesn't need internet access).
#   2. Tags the image as <template>:<build-id> for create-build to pick up.
#   3. Stops any running orchestrator (avoids port 5007 conflict with the
#      sandbox proxy that create-build starts internally).
#   4. Runs create-build to produce kernel/rootfs/memfile artifacts.
#   5. Restarts the orchestrator after the build completes.
#
# Prerequisites:
#   - Docker installed and running
#   - Go toolchain available (for building create-build)
#   - Firecracker, KVM, and kernel/envd binaries set up (see local-setup.sh)
#   - Run as root (Firecracker requires root privileges)
#
# Usage:
#   sudo ./scripts/build-template.sh
#   sudo ./scripts/build-template.sh --template-id mytemplate --vcpu 4 --memory 1024
#   sudo ./scripts/build-template.sh --help
#
# The build ID is printed at the end for use in integration tests:
#   export TEST_BUILD_ID=<printed-build-id>
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INFRA_DIR="$PROJECT_ROOT/infra"
ORCHESTRATOR_DIR="$INFRA_DIR/packages/orchestrator"
TEMPLATES_DIR="$PROJECT_ROOT/templates"
DOCKERFILE="$TEMPLATES_DIR/e2b-base-full.Dockerfile"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
# These match the defaults in the orchestrator's feature flags and create-build.
TEMPLATE_ID="base"
KERNEL_VERSION="vmlinux-6.1.158"
FIRECRACKER_VERSION="v1.12.1_a41d3fb"
VCPU=2
MEMORY=512
DISK=512
BUILD_ID=""

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Build an E2B template on an EC2 instance.

Options:
  --template-id ID        Template ID (default: $TEMPLATE_ID)
  --kernel VERSION        Kernel version (default: $KERNEL_VERSION)
  --firecracker VERSION   Firecracker version (default: $FIRECRACKER_VERSION)
  --vcpu N                Number of vCPUs (default: $VCPU)
  --memory MB             Memory in MB (default: $MEMORY)
  --disk MB               Disk size in MB (default: $DISK)
  --build-id ID           Use a specific build ID instead of generating one
  -h, --help              Show this help message

Examples:
  $(basename "$0")
  $(basename "$0") --template-id base --vcpu 4 --memory 1024
  $(basename "$0") --build-id my-custom-build-id

The build ID is printed at the end so you can pass it to integration tests:
  export TEST_BUILD_ID=\$($(basename "$0") | tail -1)
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --template-id)
            TEMPLATE_ID="$2"
            shift 2
            ;;
        --kernel)
            KERNEL_VERSION="$2"
            shift 2
            ;;
        --firecracker)
            FIRECRACKER_VERSION="$2"
            shift 2
            ;;
        --vcpu)
            VCPU="$2"
            shift 2
            ;;
        --memory)
            MEMORY="$2"
            shift 2
            ;;
        --disk)
            DISK="$2"
            shift 2
            ;;
        --build-id)
            BUILD_ID="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            echo "Run '$(basename "$0") --help' for usage." >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Generate build ID if not provided
# ---------------------------------------------------------------------------
if [[ -z "$BUILD_ID" ]]; then
    # Use uuidgen if available, otherwise fall back to /proc/sys/kernel/random
    if command -v uuidgen &>/dev/null; then
        BUILD_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
    elif [[ -f /proc/sys/kernel/random/uuid ]]; then
        BUILD_ID="$(cat /proc/sys/kernel/random/uuid)"
    else
        echo "ERROR: Cannot generate UUID. Install uuidgen or provide --build-id." >&2
        exit 1
    fi
fi

echo "=============================================="
echo "E2B Template Build"
echo "=============================================="
echo "Template ID:   $TEMPLATE_ID"
echo "Build ID:      $BUILD_ID"
echo "Kernel:        $KERNEL_VERSION"
echo "Firecracker:   $FIRECRACKER_VERSION"
echo "vCPUs:         $VCPU"
echo "Memory:        ${MEMORY} MB"
echo "Disk:          ${DISK} MB"
echo "=============================================="

# ---------------------------------------------------------------------------
# Step 1: Build the Docker image with all packages pre-installed
# ---------------------------------------------------------------------------
# This image includes all the packages that provision.sh would normally
# install at runtime. By baking them in, we avoid needing internet access
# during Firecracker VM provisioning.

DOCKER_IMAGE="${TEMPLATE_ID}:${BUILD_ID}"
FULL_IMAGE="e2b-base-full:latest"

echo ""
echo "[1/5] Building Docker image from e2b-base-full.Dockerfile..."

if ! docker image inspect "$FULL_IMAGE" &>/dev/null; then
    echo "  Image '$FULL_IMAGE' not found locally, building..."
    docker build -f "$DOCKERFILE" -t "$FULL_IMAGE" "$TEMPLATES_DIR"
else
    echo "  Image '$FULL_IMAGE' already exists, skipping build."
fi

# Tag the full image with the template:build-id so create-build can find it.
# create-build looks for a local Docker image tagged as <template>:<build> when
# --from-image is not explicitly set to a remote registry image.
echo "  Tagging as $DOCKER_IMAGE"
docker tag "$FULL_IMAGE" "$DOCKER_IMAGE"

# ---------------------------------------------------------------------------
# Step 2: Stop any running orchestrator
# ---------------------------------------------------------------------------
# The orchestrator listens on port 5007 (sandbox proxy) and 5008 (gRPC).
# create-build starts its own sandbox proxy on port 5007, which would conflict.

echo ""
echo "[2/5] Stopping any running orchestrator (port 5007 conflict)..."

if pgrep -f "packages/orchestrator.*main.go" &>/dev/null || pgrep -f "orchestrator" &>/dev/null; then
    # Try graceful shutdown first, then force kill
    pkill -f "packages/orchestrator" 2>/dev/null || true
    sleep 2
    # Force kill if still running
    if pgrep -f "packages/orchestrator" &>/dev/null; then
        pkill -9 -f "packages/orchestrator" 2>/dev/null || true
        sleep 1
    fi
    echo "  Orchestrator stopped."
else
    echo "  No orchestrator process found, continuing."
fi

# Also check if anything else is bound to port 5007 and kill it
if lsof -i :5007 -t &>/dev/null 2>&1; then
    echo "  Killing processes on port 5007..."
    lsof -i :5007 -t 2>/dev/null | xargs kill -9 2>/dev/null || true
    sleep 1
fi

# ---------------------------------------------------------------------------
# Step 3: Run create-build
# ---------------------------------------------------------------------------
# create-build is the orchestrator's CLI tool that:
#   - Pulls (or uses a local) Docker image as the rootfs base
#   - Boots a Firecracker VM to run provision.sh inside it
#   - Snapshots the VM into memfile + rootfs artifacts
#   - Stores artifacts in local storage or GCS

echo ""
echo "[3/5] Running create-build..."

cd "$ORCHESTRATOR_DIR"

# Use the local storage path for EC2-based builds.
# The -storage flag tells create-build to set up a local directory structure
# instead of requiring GCS credentials.
STORAGE_PATH="${STORAGE_PATH:-.local-build}"

sudo -E go run cmd/create-build/main.go \
    -template "$TEMPLATE_ID" \
    -to-build "$BUILD_ID" \
    -kernel "$KERNEL_VERSION" \
    -firecracker "$FIRECRACKER_VERSION" \
    -vcpu "$VCPU" \
    -memory "$MEMORY" \
    -disk "$DISK" \
    -from-image "$DOCKER_IMAGE" \
    -storage "$STORAGE_PATH" \
    -v

BUILD_EXIT=$?

cd "$PROJECT_ROOT"

if [[ $BUILD_EXIT -ne 0 ]]; then
    echo ""
    echo "ERROR: create-build failed with exit code $BUILD_EXIT" >&2
    exit $BUILD_EXIT
fi

# ---------------------------------------------------------------------------
# Step 4: Restart the orchestrator
# ---------------------------------------------------------------------------
# The orchestrator needs to be running for integration tests. Restart it in
# the background so tests can connect to its gRPC endpoint (port 5008).

echo ""
echo "[4/5] Restarting orchestrator..."

if [[ -f "$ORCHESTRATOR_DIR/main.go" ]]; then
    cd "$ORCHESTRATOR_DIR"
    # Start the orchestrator in the background, redirecting output to a log file.
    LOG_DIR="${HOME}/logs"
    mkdir -p "$LOG_DIR"
    sudo -E go run main.go > "$LOG_DIR/orchestrator.log" 2>&1 &
    ORCHESTRATOR_PID=$!
    cd "$PROJECT_ROOT"
    echo "  Orchestrator started (PID: $ORCHESTRATOR_PID), logs: $LOG_DIR/orchestrator.log"

    # Wait briefly for the orchestrator to initialize
    echo "  Waiting for orchestrator to become ready..."
    for i in $(seq 1 30); do
        if curl -sf "http://localhost:5008" &>/dev/null 2>&1 || \
           grpcurl -plaintext localhost:5008 grpc.health.v1.Health/Check &>/dev/null 2>&1; then
            echo "  Orchestrator is ready."
            break
        fi
        if [[ $i -eq 30 ]]; then
            echo "  WARNING: Orchestrator may not be fully ready yet (timed out after 30s)."
            echo "  Check $LOG_DIR/orchestrator.log for details."
        fi
        sleep 1
    done
else
    echo "  WARNING: orchestrator main.go not found at $ORCHESTRATOR_DIR/main.go"
    echo "  Skipping orchestrator restart. Start it manually before running tests."
fi

# ---------------------------------------------------------------------------
# Step 5: Print build ID
# ---------------------------------------------------------------------------
echo ""
echo "[5/5] Build complete!"
echo "=============================================="
echo "Template ID:  $TEMPLATE_ID"
echo "Build ID:     $BUILD_ID"
echo "=============================================="
echo ""
echo "To use this build in integration tests:"
echo "  export TEST_BUILD_ID=$BUILD_ID"
echo "  export TEST_TEMPLATE_ID=$TEMPLATE_ID"
echo "  export TEST_KERNEL_VERSION=$KERNEL_VERSION"
echo "  export TEST_FIRECRACKER_VERSION=$FIRECRACKER_VERSION"
echo ""

# Print the build ID as the last line so it can be captured with:
#   BUILD_ID=$(sudo ./scripts/build-template.sh | tail -1)
echo "$BUILD_ID"
