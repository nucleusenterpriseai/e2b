#!/usr/bin/env bash
# =============================================================================
# E2B Local Setup Script (Phase 3: API + DB)
# =============================================================================
# This script:
#   1. Starts PostgreSQL and Redis via docker-compose
#   2. Waits for PostgreSQL to be healthy
#   3. Installs goose if not present
#   4. Runs all database migrations
#   5. Runs seed.sql (tier + team)
#   6. Generates an API key and saves it to .env.local
#   7. Prints connection info and the API key
#
# Usage:
#   ./scripts/local-setup.sh
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Paths (resolve relative to this script's location)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

COMPOSE_FILE="$PROJECT_ROOT/docker-compose.local.yml"
MIGRATIONS_DIR="$PROJECT_ROOT/infra/packages/db/migrations"
SEED_FILE="$PROJECT_ROOT/aws/db/seed.sql"
KEYGEN_DIR="$PROJECT_ROOT/aws/db"
ENV_LOCAL="$PROJECT_ROOT/.env.local"

# Database connection settings
DB_USER="postgres"
DB_PASS="e2b_local_dev"
DB_NAME="e2b"
DB_HOST="localhost"
DB_PORT="5433"
DB_URL="postgresql://${DB_USER}:${DB_PASS}@${DB_HOST}:${DB_PORT}/${DB_NAME}?sslmode=disable"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { printf "\033[0;34m[INFO]\033[0m  %s\n" "$*"; }
ok()    { printf "\033[0;32m[OK]\033[0m    %s\n" "$*"; }
warn()  { printf "\033[1;33m[WARN]\033[0m  %s\n" "$*"; }
die()   { printf "\033[0;31m[ERROR]\033[0m %s\n" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Step 1: Start docker-compose
# ---------------------------------------------------------------------------
info "Starting PostgreSQL and Redis..."
if ! command -v docker &>/dev/null; then
    die "docker is not installed. Please install Docker Desktop first."
fi

docker compose -f "$COMPOSE_FILE" up -d

# ---------------------------------------------------------------------------
# Step 2: Wait for PostgreSQL to be healthy
# ---------------------------------------------------------------------------
info "Waiting for PostgreSQL to be healthy..."
MAX_WAIT=60
WAITED=0
while [ "$WAITED" -lt "$MAX_WAIT" ]; do
    if docker compose -f "$COMPOSE_FILE" exec -T postgres pg_isready -U "$DB_USER" -d "$DB_NAME" &>/dev/null; then
        ok "PostgreSQL is ready."
        break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done
if [ "$WAITED" -ge "$MAX_WAIT" ]; then
    die "PostgreSQL did not become ready within ${MAX_WAIT}s."
fi

# Also verify Redis
info "Verifying Redis is healthy..."
WAITED=0
while [ "$WAITED" -lt 30 ]; do
    if docker compose -f "$COMPOSE_FILE" exec -T redis redis-cli ping 2>/dev/null | grep -q PONG; then
        ok "Redis is ready."
        break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done
if [ "$WAITED" -ge 30 ]; then
    die "Redis did not become ready within 30s."
fi

# ---------------------------------------------------------------------------
# Step 3: Install goose if not present
# ---------------------------------------------------------------------------
GOOSE_BIN="$(command -v goose 2>/dev/null || echo "${GOPATH:-$HOME/go}/bin/goose")"
if [ ! -x "$GOOSE_BIN" ]; then
    info "Installing goose..."
    go install github.com/pressly/goose/v3/cmd/goose@latest
    GOOSE_BIN="${GOPATH:-$HOME/go}/bin/goose"
    ok "goose installed at $GOOSE_BIN"
else
    ok "goose already installed: $GOOSE_BIN"
fi

# ---------------------------------------------------------------------------
# Step 4: Run migrations
# ---------------------------------------------------------------------------
info "Running database migrations from $MIGRATIONS_DIR..."
if [ ! -d "$MIGRATIONS_DIR" ]; then
    die "Migrations directory not found: $MIGRATIONS_DIR"
fi

"$GOOSE_BIN" -dir "$MIGRATIONS_DIR" -table "_migrations" postgres "$DB_URL" up
ok "All migrations applied."

# ---------------------------------------------------------------------------
# Step 5: Run seed.sql (tier + team)
# ---------------------------------------------------------------------------
info "Running seed data..."
if [ ! -f "$SEED_FILE" ]; then
    die "Seed file not found: $SEED_FILE"
fi

# Use docker exec to run psql inside the postgres container so we don't
# require a local psql client.
docker compose -f "$COMPOSE_FILE" exec -T postgres \
    psql -U "$DB_USER" -d "$DB_NAME" < "$SEED_FILE"
ok "Seed data applied."

# ---------------------------------------------------------------------------
# Step 6: Generate API key and save to .env.local
# ---------------------------------------------------------------------------
info "Generating API key..."
if [ ! -f "$KEYGEN_DIR/generate_api_key.go" ]; then
    die "API key generator not found: $KEYGEN_DIR/generate_api_key.go"
fi

# Run the key generator and capture its output
KEYGEN_OUTPUT=$(cd "$KEYGEN_DIR" && go run generate_api_key.go)

# Extract the raw API key (line after "Raw API Key")
RAW_KEY=$(echo "$KEYGEN_OUTPUT" | grep -A1 "Raw API Key" | tail -1 | tr -d '[:space:]')
if [ -z "$RAW_KEY" ]; then
    die "Failed to extract raw API key from generator output."
fi

# Extract the SQL INSERT statement (lines starting with INSERT)
INSERT_SQL=$(echo "$KEYGEN_OUTPUT" | sed -n '/^INSERT INTO/,/;$/p')
if [ -z "$INSERT_SQL" ]; then
    die "Failed to extract INSERT statement from generator output."
fi

# Insert the API key into the database
info "Inserting API key into database..."
echo "$INSERT_SQL" | docker compose -f "$COMPOSE_FILE" exec -T postgres \
    psql -U "$DB_USER" -d "$DB_NAME"
ok "API key inserted."

# Write .env.local
cat > "$ENV_LOCAL" <<EOF
# =============================================================================
# E2B Local Development Environment
# Generated by scripts/local-setup.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# =============================================================================

# API key for SDK / test scripts
E2B_API_KEY=${RAW_KEY}

# Database
POSTGRES_CONNECTION_STRING=postgresql://${DB_USER}:${DB_PASS}@${DB_HOST}:${DB_PORT}/${DB_NAME}?sslmode=disable
DATABASE_URL=postgresql://${DB_USER}:${DB_PASS}@${DB_HOST}:${DB_PORT}/${DB_NAME}?sslmode=disable

# Redis
REDIS_URL=localhost:6380
EOF

ok "Saved environment to $ENV_LOCAL"

# ---------------------------------------------------------------------------
# Step 7: Print summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================="
echo "  E2B Local Development Environment Ready"
echo "============================================="
echo ""
echo "  PostgreSQL:  postgresql://${DB_USER}:****@${DB_HOST}:${DB_PORT}/${DB_NAME}"
echo "  Redis:       localhost:6380"
echo ""
echo "  API Key:     ${RAW_KEY}"
echo "  Saved to:    ${ENV_LOCAL}"
echo ""
echo "  Next steps:"
echo "    1. Start the API server:  ./scripts/local-api.sh"
echo "    2. Run tests:             ./scripts/local-test.sh"
echo ""
echo "  To tear down:"
echo "    docker compose -f docker-compose.local.yml down       # keep data"
echo "    docker compose -f docker-compose.local.yml down -v    # wipe data"
echo "============================================="
