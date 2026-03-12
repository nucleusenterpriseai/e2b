# Phase 3: API Server + Client-Proxy + Database

**Duration**: 5 days
**Depends on**: Phase 0, Phase 2 (partially)
**Status**: Not Started

---

## Objective

Get the API server, client-proxy, and database running. Keep the full upstream schema (90 migrations). Use API key auth only. Configure env vars to disable SaaS dependencies.

## PRD (Phase 3)

### What the API Server Does
- REST API (Gin, port 50001) for sandbox/template CRUD
- gRPC server (port 5009) for proxy-initiated operations (auto-resume)
- Auth: 5 authenticators in upstream, we use API key only (`X-API-Key` header)
- Discovers orchestrator nodes via Nomad API (cluster pool)
- Stores sandbox/template metadata in PostgreSQL
- Tracks running sandboxes in Redis (sandbox catalog)

### What the Client-Proxy Does
- Routes SDK traffic to correct orchestrator node
- Parses hostname: `{sandboxID}-{clientID}.{domain}` or `{port}-{sandboxID}.{domain}`
- Looks up `sandboxID -> orchestratorIP` in Redis catalog
- Proxies HTTP to `orchestratorIP:5007` (orchestrator's sandbox proxy)
- Health check on port 3003, proxy on port 3002

### Database
- Keep full upstream schema (90 goose migrations)
- Tables we actively use: `teams`, `team_api_keys`, `envs` (templates), `env_builds`, `env_aliases`, `team_limits`, `clusters`
- API keys use SHA-256 hashing (`packages/shared/pkg/keys/`)
- Separate auth DB connection supported (we point both at same RDS)

### What We're Delivering
- API server starts with correct env vars (no Supabase, no ClickHouse, no Loki)
- Database initialized with all 90 migrations
- Seed data: 1 team + 1 API key (properly hashed)
- Client-proxy running and routing correctly
- Full chain: REST API -> orchestrator gRPC -> sandbox created

### What We're NOT Changing
- Auth package stays intact (just don't set Supabase env vars)
- OpenAPI spec unchanged
- sqlc-generated queries unchanged
- Schema unchanged (run all 90 migrations)

### Key Config Env Vars (API Server)
```bash
POSTGRES_CONNECTION_STRING=postgresql://user:pass@rds-host:5432/e2b
# AUTH_DB_CONNECTION_STRING defaults to POSTGRES_CONNECTION_STRING
REDIS_URL=redis://redis-host:6379
DOMAIN_NAME=e2b.example.com
DEFAULT_KERNEL_VERSION=vmlinux-6.1.102
SANDBOX_STORAGE_BACKEND=redis  # or "memory" for single-node dev
API_GRPC_PORT=5009
# Don't set (graceful fallbacks):
# LOKI_URL (made optional in Phase 0)
# CLICKHOUSE_CONNECTION_STRING
# POSTHOG_API_KEY
# SUPABASE_JWT_SECRETS
```

### Key Config Env Vars (Client-Proxy)
```bash
PROXY_PORT=3002
HEALTH_PORT=3003
REDIS_URL=redis://redis-host:6379
API_GRPC_ADDRESS=localhost:5009  # For auto-resume
```

### Success Criteria
- API server starts without errors
- `GET /health` returns 200
- Database migrations complete (all 90)
- API key auth works (valid key -> 200, invalid -> 401)
- `POST /sandboxes` creates sandbox via orchestrator
- Client-proxy routes `{sandboxID}.domain` to correct orchestrator
- `DELETE /sandboxes/{id}` destroys sandbox

## Dev Plan

### 3.1 Database Setup (Day 1, 4 hours)

**Create seed data scripts:**

`aws/db/init.sh`:
```bash
#!/bin/bash
# Run all 90 upstream migrations
cd /path/to/infra/packages/db
goose -dir migrations postgres "$DATABASE_URL" up

# Seed initial data
psql "$DATABASE_URL" -f /path/to/aws/db/seed.sql
```

`aws/db/seed.sql`:
```sql
-- Create a team
INSERT INTO teams (id, name, tier, is_default)
VALUES ('00000000-0000-0000-0000-000000000001', 'internal', 'base_v1', true);

-- Create API key (must use SHA-256 hash format)
-- The key package uses: sha256(raw_key) stored as hex
-- Raw key: e2b_<40-hex-chars>
-- We'll generate this programmatically
```

**Important**: API keys must be generated using the `packages/shared/pkg/keys/` package to get correct format and hash. Write a small Go program:

```go
// cmd/seed-key/main.go
package main

import (
    "fmt"
    "github.com/e2b-dev/infra/packages/shared/pkg/keys"
)

func main() {
    key, hash := keys.GenerateAPIKey()
    fmt.Printf("API_KEY=%s\nHASH=%s\n", key, hash)
    fmt.Printf("INSERT INTO team_api_keys (team_id, api_key_hash) VALUES ('00000000-...', '%s');\n", hash)
}
```

### 3.2 Test Database Locally (Day 1, 2 hours)

```bash
# Start local PostgreSQL
docker run -d --name e2b-pg -p 5432:5432 \
  -e POSTGRES_DB=e2b -e POSTGRES_USER=e2b -e POSTGRES_PASSWORD=dev \
  postgres:15

# Run migrations
export DATABASE_URL="postgresql://e2b:dev@localhost:5432/e2b?sslmode=disable"
cd infra/packages/db
go install github.com/pressly/goose/v3/cmd/goose@latest
goose -dir migrations postgres "$DATABASE_URL" up

# Verify tables
psql "$DATABASE_URL" -c "\dt"
```

### 3.3 Test API Server Locally (Day 2, 4 hours)

```bash
# Start Redis
docker run -d --name e2b-redis -p 6379:6379 redis:7

# Start API server
cd infra/packages/api
export POSTGRES_CONNECTION_STRING="postgresql://e2b:dev@localhost:5432/e2b?sslmode=disable"
export REDIS_URL="redis://localhost:6379"
export DOMAIN_NAME="localhost"
export DEFAULT_KERNEL_VERSION="vmlinux-6.1.102"
export SANDBOX_STORAGE_BACKEND="memory"
# Volume token config (made optional in Phase 0)
# LOKI_URL (made optional in Phase 0)

go run .
```

Test endpoints:
```bash
curl http://localhost/health
curl -H "X-API-Key: e2b_<generated-key>" http://localhost:50001/sandboxes
```

### 3.4 Understand Cluster Discovery (Day 2, 2 hours)

The API discovers orchestrators via Nomad API:
- `packages/api/internal/clusters/discovery/local.go` uses `nomadapi.Client`
- Queries Nomad for allocations with `orchestrator` service
- Builds a node pool with health checks

For local dev without Nomad, may need to configure static discovery or mock.

### 3.5 Test Client-Proxy (Day 3, 4 hours)

```bash
cd infra/packages/client-proxy
export PROXY_PORT=3002
export HEALTH_PORT=3003
export REDIS_URL="redis://localhost:6379"

go run .
```

Test routing:
```bash
# Health check
curl http://localhost:3003/health

# Sandbox routing (requires sandbox in Redis catalog)
curl -H "Host: test-sandbox-id.localhost" http://localhost:3002/
```

### 3.6 Integration: API + Orchestrator (Day 3-4, 8 hours)

On a machine with both API and orchestrator running:
1. Start orchestrator (port 5008)
2. Start API with Nomad pointed at orchestrator
3. Create sandbox via REST API
4. Verify sandbox reachable via client-proxy
5. Delete sandbox via REST API

### 3.7 Docker-Reverse-Proxy (Day 4, 2 hours)

```bash
cd infra/packages/docker-reverse-proxy
go run .
```

Configure for ECR:
- Needs AWS credentials (IAM role or env vars)
- Proxies Docker pull requests to ECR

### 3.8 Adapt Upstream Tests (Day 4-5, 4 hours)

Check which integration tests work:
```bash
cd infra/tests/integration
export TESTS_API_SERVER_URL=http://localhost:50001
export TESTS_E2B_API_KEY=<generated-key>
go test ./internal/tests/api/auth/ -v
go test ./internal/tests/api/sandbox/ -v -run TestSandboxCreate
```

## Test Cases (Phase 3)

### P0 (Must Pass)

| ID | Test | Expected |
|---|---|---|
| A3-01 | Database migrations run (all 90) | No errors, all tables created |
| A3-02 | Seed data inserted | Team + API key exist |
| A3-03 | API server starts | No panics, listens on :50001 |
| A3-04 | `GET /health` | 200 OK |
| A3-05 | Valid API key -> auth passes | 200 response |
| A3-06 | Invalid API key -> auth fails | 401 Unauthorized |
| A3-07 | Missing API key -> auth fails | 401 Unauthorized |
| A3-08 | `POST /sandboxes` | Sandbox created (requires orchestrator) |
| A3-09 | `GET /sandboxes` | Lists sandboxes |
| A3-10 | `DELETE /sandboxes/{id}` | Sandbox destroyed |
| A3-11 | Client-proxy health check | 200 on :3003 |

### P1 (Should Pass)

| ID | Test | Expected |
|---|---|---|
| A3-12 | `GET /sandboxes/{id}` | Returns sandbox details |
| A3-13 | `PATCH /sandboxes/{id}` timeout | Timeout extended |
| A3-14 | `POST /templates` | Template build started |
| A3-15 | `GET /templates/{id}` | Returns template status |
| A3-16 | Client-proxy routes to correct sandbox | gRPC reaches envd |
| A3-17 | Port proxy `{port}-{sandbox}.domain` | Forwards to VM port |
| A3-18 | API gRPC server (port 5009) | Responds to proxy RPCs |
| A3-19 | Upstream auth tests pass | API key flow works |
| A3-20 | Team scoping | Team A can't see Team B's sandboxes |

## Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Migration fails on newer PostgreSQL | Medium | Use PostgreSQL 15 (same as upstream) |
| sqlc generated code needs regeneration | High | Don't change schema, use upstream as-is |
| Nomad discovery not available in dev | Medium | Test with static orchestrator address |
| Redis catalog population | Medium | Verify orchestrator writes to Redis on sandbox create |

## Deliverables
- [ ] Database migrations running (all 90)
- [ ] Seed data script with proper key hashing
- [ ] API server starts with correct env vars
- [ ] Auth flow verified (API key)
- [ ] Client-proxy routing verified
- [ ] API -> orchestrator -> sandbox flow working
- [ ] Upstream integration tests adapted
