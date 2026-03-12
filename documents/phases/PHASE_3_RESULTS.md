# Phase 3 Results: API Server + Client-Proxy + Database

## Database Schema Findings

### Migration Count
- **90 migration files** (confirmed), numbered from `20000101000000` to `20260309120000`.

### Key Tables (after all 90 migrations)

| Table | Primary Key | Key Columns | Notes |
|---|---|---|---|
| `auth.users` | `id (uuid)` | `email` | Created by migration 0; used by triggers and FK constraints |
| `tiers` | `id (text)` | `name, disk_mb, concurrent_instances, max_length_hours, max_vcpu, max_ram_mb, concurrent_template_builds` | Defines resource limits per tier |
| `teams` | `id (uuid)` | `name, tier (FK->tiers), email, is_blocked, is_banned, blocked_reason, cluster_id, slug, sandbox_scheduling_labels` | `is_default` was removed in migration `20250106`. `slug` added in `20260121`. |
| `team_api_keys` | `id (uuid)` | `team_id, api_key_hash, api_key_prefix, api_key_length, api_key_mask_prefix, api_key_mask_suffix, name, created_at, updated_at, last_used, created_by` | Raw `api_key` column was removed in migration `20250910124212`. Only hash is stored. |
| `envs` | `id (text)` | `team_id, build_count, spawn_count, public, created_by, cluster_id, source` | Templates |
| `env_builds` | `id (uuid)` | `env_id, status, dockerfile, vcpu, ram_mb, kernel_version, firecracker_version, status_group, team_id` | Template builds |
| `env_aliases` | `id (uuid)` | `alias, env_id, is_renamable, namespace` | PK changed from `alias` to `id (uuid)` in migration `20260127`. |
| `env_build_assignments` | `id (uuid)` | `env_id, build_id, tag, source` | M:N builds with tags (migration `20251218160000`) |
| `clusters` | `id (uuid)` | `endpoint, endpoint_tls, token, sandbox_proxy_domain` | Edge deployment clusters |
| `addons` | `id (uuid)` | `team_id, name, extra_concurrent_sandboxes, ...` | Temporary resource boosts |
| `snapshots` | `id (uuid)` | `env_id, sandbox_id, base_env_id, team_id, origin_node_id, config` | Paused sandbox state |
| `snapshot_templates` | `(env_id, sandbox_id)` | `origin_node_id, build_id` | Snapshot template metadata |
| `volumes` | `id (uuid)` | `team_id, name, volume_type` | Persistent volumes |
| `access_tokens` | `id (uuid)` | `user_id, access_token_hash, name, access_token_prefix, ...` | CLI access tokens (raw column removed) |
| `users_teams` | `id (bigint)` | `user_id, team_id, is_default, added_by` | User-team membership |
| `active_template_builds` | (view) | `build_id, team_id, template_id, tags, created_at` | Materialized view for active builds |

### Key View

| View | Columns | Notes |
|---|---|---|
| `team_limits` | `id, max_length_hours, concurrent_sandboxes, concurrent_template_builds, max_vcpu, max_ram_mb, disk_mb` | Joins `teams -> tiers` and sums active `addons`. Used by all auth queries. |

### API Key Format (packages/shared/pkg/keys/)

- **Raw key**: `e2b_` + 40 hex characters (20 random bytes, hex-encoded)
- **Hash**: `$sha256$` + base64(SHA-256(raw_bytes)) -- base64 uses raw standard encoding (no padding)
- **Verification flow**: Strip prefix -> hex decode -> SHA-256 -> base64 -> prepend `$sha256$` -> DB lookup on `api_key_hash`
- The `team_api_keys` table no longer stores the raw key (removed in migration `20250910124212`)

### Auth Flow (packages/auth/pkg/auth/)

1. Request header `X-API-Key` is checked for `e2b_` prefix
2. Key bytes are hashed via `keys.VerifyKey(keys.ApiKeyPrefix, apiKey)` -> produces `$sha256$...`
3. Hash is looked up in `team_api_keys` table via `GetTeamWithTierByAPIKey` query
4. Query JOINs `team_api_keys -> teams -> team_limits(view)` to return team + limits
5. Result is cached in an in-memory `AuthCache`
6. Team info is set on the Gin context for downstream handlers

## Scripts Created

| File | Purpose |
|---|---|
| `aws/db/init.sh` | Installs goose, runs all 90 migrations, seeds tier+team, verifies tables |
| `aws/db/seed.sql` | Inserts `base_v1` tier and `self-hosted` team; documents API key insertion format |
| `aws/db/generate_api_key.go` | Go program that uses `packages/shared/pkg/keys` to generate a key + hash + SQL INSERT |
| `aws/db/go.mod` | Go module with `replace` directive pointing to `../../infra/packages/shared` |
| `tests/api_test.sh` | Shell test suite covering health, valid/invalid/missing API key, list sandboxes, client-proxy health |
| `aws/config/api.env.example` | Complete env var reference for the API server |
| `aws/config/client-proxy.env.example` | Complete env var reference for the client-proxy |

## Config Requirements

### API Server (Required to start)

| Variable | Required | Notes |
|---|---|---|
| `POSTGRES_CONNECTION_STRING` | Yes | `env:"required,notEmpty"` |
| `REDIS_URL` or `REDIS_CLUSTER_URL` | Yes | Fatal if neither set (in `NewAPIStore`) |
| `NODE_ID` | Yes | Panics if missing (`env.GetNodeID()`) |
| `SANDBOX_ACCESS_TOKEN_HASH_SEED` | Yes | Fatal if empty (`NewAccessTokenGenerator` returns error) |
| `DOMAIN_NAME` | Recommended | Default: `""` |
| `AUTH_DB_CONNECTION_STRING` | No | Defaults to `POSTGRES_CONNECTION_STRING` |
| `SANDBOX_STORAGE_BACKEND` | No | Default: `"memory"` |
| `DEFAULT_KERNEL_VERSION` | No | Default: `"vmlinux-6.1.158"` (from feature flags) |
| `API_GRPC_PORT` | No | Default: `5009` |
| `NOMAD_ADDRESS` | No | Default: `"http://localhost:4646"` |
| `CLICKHOUSE_CONNECTION_STRING` | No | Uses noop client if empty |
| `POSTHOG_API_KEY` | No | Silences logs if empty |
| `LOKI_URL` | No | Creates provider with empty address (queries will fail but server starts) |
| `SUPABASE_JWT_SECRETS` | No | Supabase auth simply won't work (fine for API-key-only mode) |

### Client-Proxy (Required to start)

| Variable | Required | Notes |
|---|---|---|
| `NODE_ID` | Yes | Panics if missing |
| `REDIS_URL` or `REDIS_CLUSTER_URL` | Recommended | Falls back to in-memory catalog if neither set |
| `PROXY_PORT` | No | Default: `3002` |
| `HEALTH_PORT` | No | Default: `3003` |
| `API_GRPC_ADDRESS` | No | If empty, paused sandbox auto-resume is disabled |

## Issues and Discrepancies with Phase Doc

### 1. Phase doc mentions `is_default` column on `teams` -- it was removed
The phase doc's seed SQL uses `INSERT INTO teams (id, name, tier, is_default)`. The `is_default` column was removed in migration `20250106142106_remove_team_is_default.sql`. The seed SQL has been corrected.

### 2. Phase doc says API key hash is "sha256(raw_key) stored as hex" -- it is base64
The actual format is `$sha256$` + base64-raw-std-encoding of SHA-256(raw_bytes). Not hex. This is implemented in `packages/shared/pkg/keys/sha256.go`.

### 3. `team_limits` is a VIEW, not a TABLE
The phase doc lists `team_limits` as a table. It is actually a VIEW (created in migration `20251011200438`) that joins `teams -> tiers` with aggregated `addons`. This means the `tiers` table must have data for queries to work.

### 4. `SANDBOX_ACCESS_TOKEN_HASH_SEED` is required
Not mentioned in the phase doc's env var list, but the API server will fatal if this is empty. It is used to generate per-sandbox HMAC tokens.

### 5. `NODE_ID` is required
Not mentioned in the phase doc, but `env.GetNodeID()` panics if `NODE_ID` is not set. Both API and client-proxy need it.

### 6. Loki provider does not gracefully handle empty URL
`NewLokiQueryProvider("")` succeeds (returns a provider with empty address), but queries against it will fail at runtime. The API server calls Fatal if this returns an error, but since it doesn't error on empty URL, the server starts fine. Log queries will simply fail.

### 7. Team `slug` column is required (NOT NULL)
Added in migration `20260121175429`. A trigger auto-generates it from the team name, but our seed SQL provides it explicitly for determinism.

### 8. Team `email` column is required (NOT NULL)
Added in migration `20240103104619`. Must be included in the seed INSERT.

### 9. `active_template_builds` is a materialized view
Created in migration `20260305130000`. Will be empty but exists after migrations.

### 10. Feature flags client (`LaunchDarkly`) -- non-fatal
The `featureflags.NewClient()` call will create a client even without LaunchDarkly configuration. It logs an error but does not cause a fatal crash (confirmed by the client-proxy code which handles the error and continues).
