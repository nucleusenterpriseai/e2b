# Phase 7: Upstream Test Inventory for Self-Hosted

This document classifies all 47 upstream integration test files from `infra/tests/integration/`
for self-hosted E2B deployments. Each test is categorized based on its dependencies and
whether it can run without modification.

## Classification Key

| Category | Meaning |
|---|---|
| **Run As-Is** | Works with self-hosted using API key/access token auth. No database or SaaS dependencies. |
| **Needs DB** | Requires `POSTGRES_CONNECTION_STRING` to create test users/teams/keys via direct DB access. Some sub-tests also need `TESTS_SUPABASE_JWT_SECRET` but gracefully skip when it is absent. |
| **Skip** | Requires SaaS-only features (Supabase auth, ClickHouse analytics) that are not available in self-hosted deployments. |

## Environment Variables

All tests read configuration from environment variables defined in
`infra/tests/integration/internal/setup/constants.go`:

| Variable | Required | Description |
|---|---|---|
| `TESTS_API_SERVER_URL` | Yes | API server URL (e.g. `http://localhost:3000`) |
| `TESTS_E2B_API_KEY` | Yes | Team API key (`e2b_...`) seeded in the database |
| `TESTS_E2B_ACCESS_TOKEN` | Yes | Access token (`sk_e2b_...`) seeded in the database |
| `TESTS_SANDBOX_TEMPLATE_ID` | Yes | Template ID for sandbox creation (default: `base`) |
| `TESTS_ENVD_PROXY` | Yes | Client-proxy / envd proxy URL (e.g. `http://localhost:3002`) |
| `TESTS_ORCHESTRATOR_HOST` | No | Orchestrator gRPC address (e.g. `localhost:5008`) |
| `POSTGRES_CONNECTION_STRING` | No | PostgreSQL connection string (for DB-dependent tests) |
| `TESTS_SUPABASE_JWT_SECRET` | No | Supabase JWT secret (leave empty to auto-skip Supabase sub-tests) |
| `TESTS_SANDBOX_TEAM_ID` | No | Team ID for team-scoped tests |
| `TESTS_SANDBOX_USER_ID` | No | User ID for user-scoped tests |

See `infra/tests/integration/.env.self-hosted` for a ready-to-use template.

---

## Run As-Is (33 test files)

These tests work with a self-hosted deployment using only `TESTS_E2B_API_KEY` and
`TESTS_E2B_ACCESS_TOKEN` authentication. No database connection or SaaS features needed.

Some of these files contain sub-tests that use `WithSupabaseToken()` or `GetTestDBClient()`.
Those sub-tests will **auto-skip** when the corresponding env vars are empty, thanks to the
framework's built-in `t.Skip()` behavior. The remaining sub-tests in the file still run.

### API Tests

| File | Tests | Notes |
|---|---|---|
| `api/health_test.go` | `TestHealth` | Simple `GET /health` check |
| `api/sandboxes/sandbox_test.go` | `TestSandboxCreate`, `TestSandboxResumeUnknown`, `TestSandboxResumeWithSecuredEnvd`, `TestSandboxPauseNotFound` | Core sandbox lifecycle |
| `api/sandboxes/sandbox_kill_test.go` | `TestKillNonExistingSandbox`, `TestKillSandbox`, `TestKillPausedSandbox`, `TestKillSubsequentlyPausedSandbox` | Sandbox termination |
| `api/sandboxes/sandbox_list_test.go` | `TestSandboxList`, `TestSandboxListWithFilter`, `TestSandboxListRunning`, `TestSandboxListPaused`, `TestSandboxListPausing`, and pagination sub-tests | Sandbox listing and filtering |
| `api/sandboxes/sandbox_detail_test.go` | `TestSandboxDetailRunning`, `TestSandboxDetailPaused`, `TestSandboxDetailPausingSandbox` | Sandbox detail view |
| `api/sandboxes/sandbox_pause_test.go` | `TestSandboxPause`, `TestSandboxConcurrentPauses`, `TestSandboxPauseKilledSandbox`, `TestSandboxPauseAlreadyPaused` | Sandbox pause |
| `api/sandboxes/sandbox_resume_test.go` | `TestSandboxResume`, `TestSandboxConcurrentResumes`, `TestSandboxResumeKilledSandbox` | Sandbox resume; cross-team sub-tests auto-skip without DB |
| `api/sandboxes/sandbox_timeout_test.go` | `TestSandboxTimeoutExtend`, `TestSandboxTimeoutShorten`, `TestSandboxTimeoutNotFound` | Timeout manipulation; cross-team sub-tests auto-skip |
| `api/sandboxes/sandbox_refresh_test.go` | `TestSandboxRefreshExtend`, `TestSandboxRefreshShorten`, `TestSandboxRefreshNotFound` | Refresh endpoint; cross-team sub-tests auto-skip |
| `api/sandboxes/sandbox_connect_test.go` | `TestSandboxConnectPaused`, `TestSandboxConnectRunning`, `TestSandboxConnectNotExisting` | Connect to sandboxes; cross-team sub-tests auto-skip |
| `api/sandboxes/sandbox_internet_test.go` | `TestSandboxAllowInternet`, `TestSandboxDenyInternet`, `TestResumedSandboxInternet` | Internet access control |
| `api/sandboxes/sandbox_secure_test.go` | `TestSandboxCreateWithSecuredEnvd`, `TestSandboxDisabledPublicTraffic` | Secured envd and traffic control |
| `api/sandboxes/sandbox_auto_pause_test.go` | `TestSandboxAutoPause`, `TestResumePersisted`, `TestSandboxNotAutoPause` | Auto-pause behavior |
| `api/sandboxes/sandbox_network_out_test.go` | Network egress tests | Builds a custom template; may need template build support |
| `api/sandboxes/snapshot_template_test.go` | Snapshot create/list/delete/create-from-snapshot | Concurrent sub-tests need DB (auto-skip) |
| `api/metrics/sandbox_metrics_test.go` | Per-sandbox metrics | Calls metrics API endpoint |
| `api/metrics/sandbox_list_metrics_test.go` | Multi-sandbox metrics | Calls metrics API endpoint |
| `api/volumes/crud_test.go` | Volume create/get/list/mount/read/write/delete | Full volume lifecycle |

### Envd Tests

| File | Tests | Notes |
|---|---|---|
| `envd/filesystem_test.go` | `TestListDir`, `TestFilePermissions`, `TestStat`, entries, relative paths | In-VM filesystem operations |
| `envd/process_test.go` | `TestKillNextApp`, `TestKillWith&&`, workdir deletion, workdir permission denied, stdin | In-VM process management |
| `envd/auth_test.go` | Access token auth, init calls, change token, resume with/without token | Envd authentication |
| `envd/watcher_test.go` | Filesystem watcher create/events/remove | File system change notifications |
| `envd/signatures_test.go` | File download with/without signing, expired tokens | Signed URL file access |
| `envd/hyperloop_test.go` | Hyperloop server via IP, domain, with blocked internet | Hyperloop networking |
| `envd/localhost_bind_test.go` | Bind to 0.0.0.0, ::, 127.0.0.1, localhost, ::1 | Network binding tests |

### Orchestrator Tests

| File | Tests | Notes |
|---|---|---|
| `orchestrator/sandbox_test.go` | `TestList` | Simple orchestrator list |
| `orchestrator/sandbox_entropy_test.go` | Hardware entropy device | Validates `/dev/hwrng` availability |
| `orchestrator/sandbox_memory_integrity_test.go` | tmpfs hash, write-after-read, stress-ng | Memory integrity after pause/resume |
| `orchestrator/sandbox_object_not_found_test.go` | Create with nonexistent template | Error handling |

### Proxy Tests

| File | Tests | Notes |
|---|---|---|
| `proxies/closed_port_test.go` | Working port, closed port (JSON + HTML) | Error response format |
| `proxies/sandbox_not_found_test.go` | Non-existent sandbox (JSON + HTML) | Error response format |
| `proxies/auto_resume_test.go` | Auto-resume via exec, via proxy, no auto-resume without flag | Paused sandbox auto-resume |
| `proxies/mask_request_host_test.go` | Mask request host, incorrect URL | Request host manipulation |
| `proxies/traffic_access_token_test.go` | Missing/invalid/valid token, envd port not affected | Traffic auth |

---

## Needs DB (5 test files)

These tests require `POSTGRES_CONNECTION_STRING` to create test users, teams, and API keys
via direct database access. Some sub-tests also use `WithSupabaseToken()` (which auto-skips
when `TESTS_SUPABASE_JWT_SECRET` is empty).

If `POSTGRES_CONNECTION_STRING` is not set, the test runner skips these entirely.

| File | Tests | Dependencies | Notes |
|---|---|---|---|
| `api/apikey_test.go` | Create/Delete/List/Patch API keys, cross-team tests | DB + Supabase JWT | Creates teams via DB; uses `WithSupabaseToken` for auth; Supabase sub-tests auto-skip |
| `api/access_token_test.go` | Create/Delete access tokens | DB + Supabase JWT | Uses `WithSupabaseToken`; auto-skips without JWT secret |
| `team_test.go` | Banned team, blocked team | DB | Uses `GetTestDBClient` to manipulate team state |
| `api/metrics/team_metrics_test.go` | Team metrics, time range, empty, invalid date | Team ID + ClickHouse (server-side) | Uses `TESTS_SANDBOX_TEAM_ID`; ClickHouse is called server-side by the API |
| `api/metrics/team_metrics_max_test.go` | Max concurrent sandboxes, max start rate, empty | DB + Team ID | Uses `GetTestDBClient` and `TESTS_SANDBOX_TEAM_ID` |

---

## Skip (1 test file)

These tests require SaaS-only infrastructure that is not available in self-hosted deployments.

| File | Tests | Reason |
|---|---|---|
| `api/auth/supabase_test.go` | Supabase token authentication | Requires `TESTS_SUPABASE_JWT_SECRET` for Supabase-based auth flows. Self-hosted uses API key auth only. The framework auto-skips when the JWT secret is empty, but the tests provide no value for self-hosted validation. |

---

## Graceful Degradation

The upstream test framework has built-in graceful degradation for self-hosted environments:

1. **`WithSupabaseToken()`** in `setup/api_client.go` calls `t.Skip()` when
   `TESTS_SUPABASE_JWT_SECRET` is empty. This means sub-tests that test Supabase-specific
   auth flows will skip automatically without failing.

2. **`WithSupabaseTeam()`** calls `t.Skip()` when `TESTS_SANDBOX_TEAM_ID` is empty.

3. **`GetTestDBClient()`** requires `POSTGRES_CONNECTION_STRING`. Tests calling this
   function will fail if the variable is not set, so the test runner skips the entire
   file when the DB connection string is absent.

This means you can safely run files from the "Run As-Is" category even if they contain
some Supabase/DB-dependent sub-tests -- those sub-tests will be skipped, and the
remaining sub-tests will execute normally.

---

## Coverage Summary

| Category | Count | Percentage |
|---|---|---|
| Run As-Is | 33 | 85% |
| Needs DB | 5 | 13% |
| Skip | 1 | 2% |
| **Total** | **39** | **100%** |

Note: The 47 test files mentioned in PHASE_7_INTEGRATION.md includes support files
(`main_test.go`, `seed.go`, setup helpers) that are not test suites themselves.
The 39 files above are the actual test suites containing test functions.

---

## Running Tests

### Quick start (all eligible tests)

```bash
# 1. Copy and fill in the environment template
cp infra/tests/integration/.env.self-hosted infra/tests/integration/.env.self-hosted.local
# Edit with your deployment values

# 2. Run all tests
./scripts/run-e2e-tests.sh --env infra/tests/integration/.env.self-hosted.local
```

### Run specific categories

```bash
# Orchestrator tests only (18 tests, all passing as baseline)
./scripts/run-e2e-tests.sh --suite orchestrator

# Upstream API sandbox tests
./scripts/run-e2e-tests.sh --suite upstream --category api/sandboxes

# Upstream envd tests
./scripts/run-e2e-tests.sh --suite upstream --category envd

# Upstream proxy tests
./scripts/run-e2e-tests.sh --suite upstream --category proxies

# Dry run (show what would execute)
./scripts/run-e2e-tests.sh --dry-run
```

### Generate a test report

```bash
./scripts/run-e2e-tests.sh --env .env.self-hosted.local --report
# Report saved to test-reports/e2e-report-YYYYMMDD-HHMMSS.txt
```

### With DB-dependent tests

```bash
# Set the DB connection string to enable DB-dependent tests
export POSTGRES_CONNECTION_STRING="postgres://user:pass@host:5432/e2b?sslmode=require"
./scripts/run-e2e-tests.sh --env .env.self-hosted.local
```
