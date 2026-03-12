#!/usr/bin/env bash
# =============================================================================
# E2B Local API Server Runner (Phase 3)
# =============================================================================
# Starts the API server locally with all required environment variables.
#
# Usage:
#   ./scripts/local-api.sh              # default port 3000
#   ./scripts/local-api.sh --port 8080  # custom port
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ENV_LOCAL="$PROJECT_ROOT/.env.local"
API_DIR="$PROJECT_ROOT/infra/packages/api"
COMPOSE_FILE="$PROJECT_ROOT/docker-compose.local.yml"

# Default API port (the Gin server listens on this)
API_PORT="${PORT:-3000}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --port|-p)
            API_PORT="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 [--port PORT]" >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { printf "\033[0;34m[INFO]\033[0m  %s\n" "$*"; }
ok()    { printf "\033[0;32m[OK]\033[0m    %s\n" "$*"; }
die()   { printf "\033[0;31m[ERROR]\033[0m %s\n" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if [ ! -f "$ENV_LOCAL" ]; then
    die ".env.local not found. Run ./scripts/local-setup.sh first."
fi

if [ ! -d "$API_DIR" ]; then
    die "API directory not found: $API_DIR"
fi

# Check that PostgreSQL is reachable
if ! docker compose -f "$COMPOSE_FILE" exec -T postgres pg_isready -U e2b -d e2b &>/dev/null; then
    die "PostgreSQL is not running. Start it with: docker compose -f docker-compose.local.yml up -d"
fi
ok "PostgreSQL is running."

# Check that Redis is reachable
if ! docker compose -f "$COMPOSE_FILE" exec -T redis redis-cli ping 2>/dev/null | grep -q PONG; then
    die "Redis is not running. Start it with: docker compose -f docker-compose.local.yml up -d"
fi
ok "Redis is running."

# ---------------------------------------------------------------------------
# Source .env.local for API key (and any other values stored there)
# ---------------------------------------------------------------------------
# shellcheck disable=SC1090
source "$ENV_LOCAL"

# ---------------------------------------------------------------------------
# Export required environment variables
# ---------------------------------------------------------------------------
# See: infra/packages/api/internal/cfg/model.go for the full Config struct
# See: aws/config/api.env.example for documentation

# --- Required ---
export POSTGRES_CONNECTION_STRING="${POSTGRES_CONNECTION_STRING:-postgresql://postgres:e2b_local_dev@localhost:5433/e2b?sslmode=disable}"
export REDIS_URL="${REDIS_URL:-localhost:6380}"
export NODE_ID="${NODE_ID:-local-dev}"
export SANDBOX_ACCESS_TOKEN_HASH_SEED="${SANDBOX_ACCESS_TOKEN_HASH_SEED:-local-dev-seed}"

# --- Networking ---
export DOMAIN_NAME="${DOMAIN_NAME:-localhost}"
export API_GRPC_PORT="${API_GRPC_PORT:-5009}"

# --- Storage backend ---
# "memory" is fine for single-node local dev
export SANDBOX_STORAGE_BACKEND="${SANDBOX_STORAGE_BACKEND:-memory}"

# --- Local / debug flags ---
export ENVIRONMENT="local"
export E2B_DEBUG="true"

# --- Nomad (not used locally, but set to prevent connection errors) ---
export NOMAD_ADDRESS="${NOMAD_ADDRESS:-http://localhost:4646}"
export NOMAD_TOKEN="${NOMAD_TOKEN:-}"

# --- Optional (leave unset for graceful fallbacks) ---
# ADMIN_TOKEN, LOKI_URL, CLICKHOUSE_CONNECTION_STRING, POSTHOG_API_KEY,
# SUPABASE_JWT_SECRETS, ANALYTICS_COLLECTOR_API_TOKEN, etc.

info "Starting API server on port ${API_PORT}..."
info "  POSTGRES_CONNECTION_STRING = postgresql://e2b:****@localhost:5433/e2b"
info "  REDIS_URL                  = ${REDIS_URL}"
info "  NODE_ID                    = ${NODE_ID}"
info "  DOMAIN_NAME                = ${DOMAIN_NAME}"
info "  SANDBOX_STORAGE_BACKEND    = ${SANDBOX_STORAGE_BACKEND}"
info "  ENVIRONMENT                = ${ENVIRONMENT}"
info "  API_GRPC_PORT              = ${API_GRPC_PORT}"
echo ""
info "Health check will return 503 until an orchestrator node registers."
info "For API-only testing (auth, DB queries), this is expected."
echo ""

# ---------------------------------------------------------------------------
# Build and run the API server
# ---------------------------------------------------------------------------
cd "$API_DIR"
exec go run . -port "$API_PORT" -debug true
