#!/bin/bash
# =============================================================================
# E2B Database Initialization Script
# =============================================================================
# Runs all upstream goose migrations and seeds initial data.
#
# Prerequisites:
#   - PostgreSQL running and accessible
#   - DATABASE_URL environment variable set
#   - Go installed (for API key generation)
#
# Usage:
#   export DATABASE_URL="postgresql://e2b:dev@localhost:5432/e2b?sslmode=disable"
#   ./init.sh
#
# Or with explicit migration path:
#   MIGRATIONS_DIR=/path/to/infra/packages/db/migrations ./init.sh
# =============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Configuration ---
DATABASE_URL="${DATABASE_URL:?DATABASE_URL environment variable must be set}"

# Resolve paths relative to this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

MIGRATIONS_DIR="${MIGRATIONS_DIR:-${REPO_ROOT}/infra/packages/db/migrations}"
SEED_SQL="${SEED_SQL:-${SCRIPT_DIR}/seed.sql}"
GENERATE_KEY="${GENERATE_KEY:-${SCRIPT_DIR}/generate_api_key.go}"

# --- Step 1: Install goose if needed ---
log_info "Checking for goose..."
if ! command -v goose &>/dev/null; then
    log_info "Installing goose..."
    go install github.com/pressly/goose/v3/cmd/goose@latest
    if ! command -v goose &>/dev/null; then
        log_error "goose not found in PATH after installation"
        log_error "Make sure \$(go env GOPATH)/bin is in your PATH"
        exit 1
    fi
fi
log_info "goose found: $(which goose)"

# --- Step 2: Validate migration directory ---
if [ ! -d "$MIGRATIONS_DIR" ]; then
    log_error "Migration directory not found: $MIGRATIONS_DIR"
    exit 1
fi

MIGRATION_COUNT=$(ls -1 "$MIGRATIONS_DIR"/*.sql 2>/dev/null | wc -l | tr -d ' ')
log_info "Found $MIGRATION_COUNT migration files in $MIGRATIONS_DIR"

# --- Step 3: Run all upstream migrations ---
log_info "Running goose migrations..."
goose -dir "$MIGRATIONS_DIR" postgres "$DATABASE_URL" up

APPLIED_VERSION=$(goose -dir "$MIGRATIONS_DIR" postgres "$DATABASE_URL" version 2>&1 | tail -1)
log_info "Migration version after run: $APPLIED_VERSION"

# --- Step 4: Verify critical tables exist ---
log_info "Verifying critical tables..."

VERIFY_QUERY="
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN ('teams', 'team_api_keys', 'tiers', 'envs', 'env_builds', 'env_aliases', 'clusters', 'addons', 'snapshots', 'volumes')
ORDER BY table_name;
"

TABLES=$(psql "$DATABASE_URL" -t -A -c "$VERIFY_QUERY" 2>/dev/null) || {
    log_warn "Could not verify tables with psql (psql may not be installed)"
    log_warn "Skipping table verification -- migrations may still have succeeded"
    TABLES=""
}

if [ -n "$TABLES" ]; then
    log_info "Verified tables exist:"
    echo "$TABLES" | while read -r tbl; do
        echo "    - $tbl"
    done

    # Check minimum required tables
    REQUIRED_TABLES="teams team_api_keys tiers"
    for tbl in $REQUIRED_TABLES; do
        if ! echo "$TABLES" | grep -q "^${tbl}$"; then
            log_error "Required table '$tbl' not found!"
            exit 1
        fi
    done
    log_info "All required tables verified."
fi

# Verify team_limits view exists
VIEW_CHECK=$(psql "$DATABASE_URL" -t -A -c "SELECT COUNT(*) FROM information_schema.views WHERE table_schema='public' AND table_name='team_limits';" 2>/dev/null) || VIEW_CHECK=""
if [ "$VIEW_CHECK" = "1" ]; then
    log_info "Verified team_limits view exists."
elif [ -n "$VIEW_CHECK" ]; then
    log_error "team_limits view not found -- auth queries will fail!"
    exit 1
fi

# --- Step 5: Run seed data ---
log_info "Running seed data from $SEED_SQL..."
if [ -f "$SEED_SQL" ]; then
    psql "$DATABASE_URL" -f "$SEED_SQL" || {
        log_error "Failed to run seed SQL"
        exit 1
    }
    log_info "Seed data inserted."
else
    log_warn "Seed file not found at $SEED_SQL -- skipping"
fi

# --- Step 6: Generate API key ---
log_info "Generating API key..."
if [ -f "$GENERATE_KEY" ]; then
    log_info "Run the key generator manually:"
    echo ""
    echo "  cd ${SCRIPT_DIR} && go run generate_api_key.go"
    echo ""
    echo "Then paste the SQL INSERT into psql or append to seed.sql."
else
    log_warn "Key generator not found at $GENERATE_KEY"
fi

# --- Step 7: Summary ---
echo ""
log_info "========================================="
log_info "Database initialization complete."
log_info "  Migrations applied: $MIGRATION_COUNT files"
log_info "  Seed data: inserted (tier + team)"
log_info "  API key: generate with 'go run generate_api_key.go'"
log_info "========================================="
