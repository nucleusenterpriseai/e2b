#!/usr/bin/env bash
# =============================================================================
# E2B Integration Test Runner for EC2
# =============================================================================
# Runs the orchestrator integration tests on an EC2 instance against a running
# orchestrator and sandbox proxy.
#
# Prerequisites:
#   - Orchestrator running on localhost:5008 (gRPC)
#   - Sandbox proxy running on localhost:5007 (HTTP)
#   - A template build available (see build-template.sh)
#   - KVM access (/dev/kvm)
#   - Go toolchain available
#
# Usage:
#   ./scripts/run-integration-tests.sh
#   ./scripts/run-integration-tests.sh --build-id <uuid>
#   ./scripts/run-integration-tests.sh --kernel vmlinux-6.1.158 --firecracker v1.12.1_a41d3fb
#
# Environment variables (alternative to flags):
#   TEST_BUILD_ID             - Build ID to test against
#   TEST_TEMPLATE_ID          - Template ID (default: base)
#   TEST_KERNEL_VERSION       - Kernel version
#   TEST_FIRECRACKER_VERSION  - Firecracker version
#   ORCHESTRATOR_ADDR         - Orchestrator gRPC address (default: localhost:5008)
#   PROXY_ADDR                - Sandbox proxy address (default: localhost:5007)
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TESTS_DIR="$PROJECT_ROOT/tests/orchestrator"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
# These can be overridden by flags or environment variables.
# Flag values take precedence over env vars, which take precedence over defaults.
BUILD_ID="${TEST_BUILD_ID:-}"
TEMPLATE_ID="${TEST_TEMPLATE_ID:-}"
KERNEL_VERSION="${TEST_KERNEL_VERSION:-}"
FIRECRACKER_VERSION="${TEST_FIRECRACKER_VERSION:-}"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Run E2B orchestrator integration tests on an EC2 instance.

Options:
  --build-id ID           Build ID to test against (env: TEST_BUILD_ID)
  --template-id ID        Template ID (env: TEST_TEMPLATE_ID)
  --kernel VERSION        Kernel version (env: TEST_KERNEL_VERSION)
  --firecracker VERSION   Firecracker version (env: TEST_FIRECRACKER_VERSION)
  -h, --help              Show this help message

Examples:
  $(basename "$0") --build-id abc123
  TEST_BUILD_ID=abc123 $(basename "$0")

Notes:
  - TestSandboxPauseResume is excluded by default due to a known template
    corruption issue where pause/resume can corrupt the snapshot, causing
    subsequent test runs to fail.
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-id)
            BUILD_ID="$2"
            shift 2
            ;;
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
# Validate test directory
# ---------------------------------------------------------------------------
if [[ ! -d "$TESTS_DIR" ]]; then
    echo "ERROR: Test directory not found: $TESTS_DIR" >&2
    echo "Expected orchestrator integration tests at tests/orchestrator/" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Set environment variables for the test suite
# ---------------------------------------------------------------------------
# The test code reads these env vars to configure sandbox creation:
#   TEST_BUILD_ID             -> buildID()
#   TEST_TEMPLATE_ID          -> templateID()
#   TEST_KERNEL_VERSION       -> kernelVersion()
#   TEST_FIRECRACKER_VERSION  -> firecrackerVersion()
#   ORCHESTRATOR_ADDR         -> orchestratorAddr()
#   PROXY_ADDR                -> proxyAddr()

if [[ -n "$BUILD_ID" ]]; then
    export TEST_BUILD_ID="$BUILD_ID"
fi

if [[ -n "$TEMPLATE_ID" ]]; then
    export TEST_TEMPLATE_ID="$TEMPLATE_ID"
fi

if [[ -n "$KERNEL_VERSION" ]]; then
    export TEST_KERNEL_VERSION="$KERNEL_VERSION"
fi

if [[ -n "$FIRECRACKER_VERSION" ]]; then
    export TEST_FIRECRACKER_VERSION="$FIRECRACKER_VERSION"
fi

# ---------------------------------------------------------------------------
# Print configuration
# ---------------------------------------------------------------------------
echo "=============================================="
echo "E2B Integration Tests"
echo "=============================================="
echo "Test directory:    $TESTS_DIR"
echo "Build ID:          ${TEST_BUILD_ID:-<default: base-build>}"
echo "Template ID:       ${TEST_TEMPLATE_ID:-<default: base>}"
echo "Kernel:            ${TEST_KERNEL_VERSION:-<default from test code>}"
echo "Firecracker:       ${TEST_FIRECRACKER_VERSION:-<default from test code>}"
echo "Orchestrator:      ${ORCHESTRATOR_ADDR:-localhost:5008}"
echo "Proxy:             ${PROXY_ADDR:-localhost:5007}"
echo "=============================================="
echo ""

# ---------------------------------------------------------------------------
# Run the tests
# ---------------------------------------------------------------------------
# We exclude TestSandboxPauseResume because pause/resume has a known issue
# where it can corrupt the template snapshot. When the snapshot is corrupted,
# all subsequent sandbox creations from that template fail. This makes the
# test destructive to the test environment -- it poisons the build artifacts
# for any tests that run after it.
#
# We use Go's -skip flag (Go 1.23+) which accepts a regex of tests to skip.
# This is cleaner than trying to enumerate all other tests in -run.
#
# Flags:
#   -tags integration    Build constraint required by the test files
#   -v                   Verbose output (print each test name and result)
#   -count=1             Disable test caching (always run fresh)
#   -timeout 300s        5-minute timeout for the entire test suite
#   -skip <regex>        Skip tests matching this pattern

echo "Running tests (excluding TestSandboxPauseResume)..."
echo ""

cd "$TESTS_DIR"

TEST_START=$(date +%s)

# Run go test, capturing the exit code without exiting immediately (set +e).
# This lets us print the summary even if tests fail.
set +e
go test \
    -tags integration \
    -v \
    -count=1 \
    -timeout 300s \
    -skip "^TestSandboxPauseResume$" \
    ./...
TEST_EXIT=$?
set -e

TEST_END=$(date +%s)
TEST_DURATION=$((TEST_END - TEST_START))

cd "$PROJECT_ROOT"

# ---------------------------------------------------------------------------
# Print results summary
# ---------------------------------------------------------------------------
echo ""
echo "=============================================="
if [[ $TEST_EXIT -eq 0 ]]; then
    echo "RESULT: PASS"
else
    echo "RESULT: FAIL (exit code: $TEST_EXIT)"
fi
echo "Duration: ${TEST_DURATION}s"
echo "Excluded: TestSandboxPauseResume (known template corruption issue)"
echo "=============================================="

exit $TEST_EXIT
