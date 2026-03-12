#!/usr/bin/env bash
# =============================================================================
# E2B Local Test Runner (Phase 3)
# =============================================================================
# Runs the API test suite against the local development stack.
#
# Prerequisites:
#   1. ./scripts/local-setup.sh   (database + API key)
#   2. ./scripts/local-api.sh     (API server running in another terminal)
#
# Usage:
#   ./scripts/local-test.sh                       # run all tests
#   ./scripts/local-test.sh --api-url http://localhost:8080  # custom URL
#   ./scripts/local-test.sh --skip-health          # skip health-check gate
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ENV_LOCAL="$PROJECT_ROOT/.env.local"
COMPOSE_FILE="$PROJECT_ROOT/docker-compose.local.yml"
TESTS_DIR="$PROJECT_ROOT/tests"

# Defaults
API_URL="${API_URL:-http://localhost:3000}"
SKIP_HEALTH=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --api-url)
            API_URL="$2"
            shift 2
            ;;
        --skip-health)
            SKIP_HEALTH=true
            shift
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 [--api-url URL] [--skip-health]" >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { printf "\033[0;34m[INFO]\033[0m  %s\n" "$*"; }
ok()    { printf "\033[0;32m[OK]\033[0m    %s\n" "$*"; }
warn()  { printf "\033[1;33m[WARN]\033[0m  %s\n" "$*"; }
die()   { printf "\033[0;31m[ERROR]\033[0m %s\n" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Pre-flight: check .env.local
# ---------------------------------------------------------------------------
if [ ! -f "$ENV_LOCAL" ]; then
    die ".env.local not found. Run ./scripts/local-setup.sh first."
fi

# shellcheck disable=SC1090
source "$ENV_LOCAL"

if [ -z "${E2B_API_KEY:-}" ]; then
    die "E2B_API_KEY not set in .env.local. Run ./scripts/local-setup.sh to generate one."
fi

# ---------------------------------------------------------------------------
# Pre-flight: check PostgreSQL
# ---------------------------------------------------------------------------
info "Checking PostgreSQL..."
if docker compose -f "$COMPOSE_FILE" exec -T postgres pg_isready -U e2b -d e2b &>/dev/null; then
    ok "PostgreSQL is running."
else
    die "PostgreSQL is not running. Start it with: docker compose -f docker-compose.local.yml up -d"
fi

# ---------------------------------------------------------------------------
# Pre-flight: check Redis
# ---------------------------------------------------------------------------
info "Checking Redis..."
if docker compose -f "$COMPOSE_FILE" exec -T redis redis-cli ping 2>/dev/null | grep -q PONG; then
    ok "Redis is running."
else
    die "Redis is not running. Start it with: docker compose -f docker-compose.local.yml up -d"
fi

# ---------------------------------------------------------------------------
# Pre-flight: check API server
# ---------------------------------------------------------------------------
info "Checking API server at ${API_URL}..."
if [ "$SKIP_HEALTH" = true ]; then
    warn "Skipping health check gate (--skip-health)."
else
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${API_URL}/health" 2>/dev/null) || HTTP_STATUS="000"
    case "$HTTP_STATUS" in
        200)
            ok "API server is healthy (200)."
            ;;
        503)
            warn "API server returned 503 (no orchestrator node). Auth and DB tests will still work."
            ;;
        000)
            die "API server is not reachable at ${API_URL}. Start it with: ./scripts/local-api.sh"
            ;;
        *)
            warn "API server returned unexpected status: ${HTTP_STATUS}. Proceeding anyway."
            ;;
    esac
fi

# ---------------------------------------------------------------------------
# Export env vars for tests
# ---------------------------------------------------------------------------
export API_URL
export API_KEY="${E2B_API_KEY}"
export E2B_API_KEY
export DATABASE_URL="${POSTGRES_CONNECTION_STRING:-postgresql://postgres:e2b_local_dev@localhost:5433/e2b?sslmode=disable}"
export POSTGRES_CONNECTION_STRING="${DATABASE_URL}"
export REDIS_URL="${REDIS_URL:-localhost:6380}"

# Also export as API_BASE_URL for tests that use that convention
export API_BASE_URL="${API_URL}"

TEST_FAILED=0

echo ""
info "Running tests..."
info "  API_URL          = ${API_URL}"
info "  API_KEY          = ${E2B_API_KEY:0:10}..."
info "  DATABASE_URL     = postgresql://e2b:****@localhost:5433/e2b"
echo ""

# ---------------------------------------------------------------------------
# Run the shell-based test suite (tests/api_test.sh)
# ---------------------------------------------------------------------------
if [ -f "$TESTS_DIR/api_test.sh" ]; then
    info "Running api_test.sh..."
    bash "$TESTS_DIR/api_test.sh"
    echo ""
fi

# ---------------------------------------------------------------------------
# Run Go integration tests if they exist
# ---------------------------------------------------------------------------
if [ -f "$TESTS_DIR/go.mod" ]; then
    GO_TEST_DIRS=$(find "$TESTS_DIR" -name '*_test.go' -not -path '*/vendor/*' 2>/dev/null | head -1 || true)
    if [ -n "$GO_TEST_DIRS" ]; then
        info "Running Go integration tests..."
        cd "$TESTS_DIR"
        go test -tags integration -v -run TestAPI ./... || {
            warn "Go integration tests exited with non-zero status (some tests may have been skipped or failed)."
            TEST_FAILED=1
        }
    else
        info "No Go test files found in $TESTS_DIR, skipping Go tests."
    fi
fi

echo ""
if [ "$TEST_FAILED" -ne 0 ]; then
    warn "One or more test suites failed."
fi
ok "Test run complete."
exit $TEST_FAILED
