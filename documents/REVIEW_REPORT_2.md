# Review Report #2: Recent Changes (P1 Fixes + TDD Tests + Local Dev)

**Date**: 2026-03-12
**Reviewers**: Tech Lead, QA Engineer, Go Engineer
**Scope**: 21 files — P1 blocker fixes, new TDD test suites, local dev infrastructure

---

## Executive Summary

The P1 blocker fixes are mostly correct, but one fix introduced a **new critical bug**: `envsubst` in deploy.sh will destroy Nomad runtime variables. The TDD test suites are well-structured but have a **build-breaking conflict** on Linux. Local dev scripts are functional but have several issues that will cause failures.

| Reviewer | Score | Top Finding |
|----------|-------|-------------|
| Tech Lead | B+ | `envsubst` clobbers `${node.class}`, `${NOMAD_PORT_*}` — deployment broken |
| QA | 7/10 avg | `TestMain` duplicate on Linux — build failure; 3 missing P0 tests |
| Go Engineer | Good | `TestMain` exits 0 silently — CI false-pass |

---

## Part 1: Critical Issues (P0 — Must Fix)

### CRIT-1: `envsubst` destroys Nomad runtime variables
**File**: `aws/nomad/deploy.sh` line 89
**Found by**: Tech Lead

`envsubst < "${job_file}"` replaces ALL `${}` patterns, including Nomad's own variables like `${node.class}`, `${NOMAD_PORT_grpc}`, `${attr.unique.network.ip-address}`. These get replaced with empty strings, breaking every job constraint and port binding.

**Fix**: Use explicit variable list:
```bash
envsubst '${ECR_REGISTRY} ${E2B_ARTIFACTS_BUCKET}' < "${job_file}" > "${processed_file}"
```

### CRIT-2: goose missing `-table "_migrations"` in local-setup.sh
**File**: `scripts/local-setup.sh` line 109
**Found by**: Tech Lead

The codebase uses `_migrations` as the goose table name (see `packages/db/client/migration.go`). Without `-table "_migrations"`, goose creates `goose_db_version` instead. Then `api_integration_test.go` queries `_migrations` and fails. The API server will also fail.

**Fix**: Change to `goose -table "_migrations" -dir "$MIGRATIONS_DIR" postgres "$DB_URL" up`

### CRIT-3: `TestMain` conflict — build fails on Linux
**Files**: `tests/api_integration_test.go` (defines `TestMain`), `tests/orchestrator_integration_test.go` (same package)
**Found by**: QA + Tech Lead

Both files are in `package tests`. On Linux with `-tags integration`, both compile. Go allows only ONE `TestMain` per package — build fails.

**Fix**: Move orchestrator tests to a subdirectory `tests/orchestrator/` with its own `package orchestrator_test` and `go.mod`, OR add the orchestrator's `TestMain` logic into the existing one with a unified gate.

### CRIT-4: Go version mismatch
**Files**: `tests/go.mod`, `aws/db/go.mod` — use `go 1.25.5`; all other modules use `go 1.25.4`
**Found by**: All 3 reviewers

Version skew could cause build failures in CI if only 1.25.4 is installed.

**Fix**: Align to `go 1.25.4` to match `go.work` and all other modules.

---

## Part 2: High Priority Issues (P1)

### P1-1: `TestMain` exits 0 silently — CI false-pass
**File**: `tests/api_integration_test.go` line 76
**Found by**: Go Engineer + Tech Lead

When API is unreachable, `TestMain` calls `os.Exit(0)`. CI reports green with zero tests run. Also blocks ALL envd tests (same package) when run with `-tags integration`.

**Fix**: Print clear SKIP message and consider env-var gate (`REQUIRE_API=true` to fail instead of skip).

### P1-2: deploy.sh trap leaks temp files in loop
**File**: `aws/nomad/deploy.sh` line 90
**Found by**: Go Engineer + Tech Lead

`trap "rm -f '${processed_file}'" RETURN` inside a loop — each iteration overwrites the previous trap, leaking temp files.

**Fix**: Remove trap, use explicit `rm -f "$processed_file"` after each job submission.

### P1-3: Consul wait loop silently falls through
**Files**: All 3 user-data scripts (server.sh, client.sh, api.sh)
**Found by**: Go Engineer

If Consul never becomes ready in 60s, the loop exits silently and Nomad starts without Consul. Services won't register.

**Fix**: Add post-loop check: `if ! consul members ...; then echo "ERROR: Consul not ready" >&2; fi`

### P1-4: envd smoke tests have no build tag or guard
**File**: `tests/envd_smoke_test.go`
**Found by**: QA

No `//go:build` tag. Running `go test ./...` without envd will produce 15+ connection failures.

**Fix**: Add `//go:build integration` tag, or add `TestMain` guard that skips if envd is unreachable.

### P1-5: local-test.sh swallows test failure exit codes
**File**: `scripts/local-test.sh` line 154
**Found by**: QA

`go test ... || { warn "..."; }` — the `warn` block prevents non-zero exit. Script always exits 0.

**Fix**: Track failure flag, exit non-zero at end.

### P1-6: Port default mismatch (3000 vs 50001)
**Files**: `api_integration_test.go` defaults to `localhost:50001`; `local-api.sh` and `local-test.sh` default to port `3000`
**Found by**: All 3 reviewers

Running Go tests directly (without wrapper script) hits wrong port.

**Fix**: Align `api_integration_test.go` default to `3000`, or document the discrepancy.

### P1-7: Deprecated `grpc.DialContext` usage
**File**: `tests/orchestrator_integration_test.go` lines 113, 133
**Found by**: Go Engineer

Deprecated since gRPC-Go v1.67. Should use `grpc.NewClient`.

---

## Part 3: Test Coverage Gaps

### Missing P0 Tests (Critical Gaps)

| ID | Test | Phase | Status |
|----|------|-------|--------|
| A3-02 | Seed data verification | Phase 3 | **MISSING** |
| A3-08 | POST /sandboxes (create) | Phase 3 | **MISSING** |
| A3-10 | DELETE /sandboxes/{id} | Phase 3 | **MISSING** |
| TC-105 | Long-running process | Phase 1 | **MISSING** |

### Missing P1 Tests

| ID | Test | Phase |
|----|------|-------|
| TC-104 | Command with working directory | Phase 1 |
| TC-108 | Send signal to process | Phase 1 |
| TC-109 | Send input (stdin) | Phase 1 |
| TC-110 | PTY mode | Phase 1 |
| TC-119 | WatchDir | Phase 1 |
| O2-12 | Snapshot restore < 200ms | Phase 2 |
| O2-13 | State preserved after restore | Phase 2 |
| A3-13 | PATCH timeout | Phase 3 |
| A3-16 | Client-proxy routing | Phase 3 |

### Test Quality Scores

| File | Score | Notes |
|------|-------|-------|
| envd_smoke_test.go | 7/10 | Good coverage, missing build tag guard |
| orchestrator_integration_test.go | 7.5/10 | Strong lifecycle coverage, `time.Sleep` fragility |
| api_integration_test.go | 7/10 | Good auth tests, missing write operations |

---

## Part 4: Other Issues (P2-P3)

| # | Issue | Priority | Source |
|---|-------|----------|--------|
| 1 | `TestOrchestratorBuildSucceeds` only checks file exists, doesn't build | P2 | QA |
| 2 | `TestSandboxNoInternet` assertion too permissive (OR logic) | P2 | QA |
| 3 | `volume_token.go` — `config.Duration` unchecked (0 or negative) | P2 | Go Engineer |
| 4 | Duplicate `execResult` / `orchExecResult` types | P2 | Go Engineer |
| 5 | Fragile `grep -A1` key extraction in local-setup.sh | P2 | Go Engineer |
| 6 | Test ID comments don't match phase plan (A3-13, A3-14) | P2 | QA |
| 7 | `/etc/fstab` hugepages entry not idempotent | P2 | Tech Lead |
| 8 | `.env.local` not in `.gitignore` | P2 | Tech Lead |
| 9 | `init()` for test config instead of `TestMain` | P2 | Go Engineer |
| 10 | `time.Sleep` in orchestrator tests — should poll | P2 | QA + Tech Lead |
| 11 | SQL injection in `generate_api_key.go` `--name` flag | P2 | Tech Lead |

---

## Part 5: What's Done Well

All 3 reviewers noted these strengths:

1. **`t.Cleanup()` used properly** — sandbox cleanup runs even on test failure
2. **`require` vs `assert` discipline** — preconditions fail-fast, assertions continue
3. **Context timeouts everywhere** — no unbounded waits
4. **Build tag separation** — `integration` and `integration && linux` properly tier tests
5. **Test ID traceability** — every test references a requirement ID (E1-03, O2-01, A3-04)
6. **volume_token.go nil guard** — clean defensive fix with actionable error messages
7. **Shell scripts use `set -euo pipefail`** — strict error handling throughout
8. **deploy.sh operational features** — dry-run mode, single-job targeting, health checking
9. **Local dev workflow** — complete path from zero to running tests
10. **dnsmasq fix** — correctly disables systemd-resolved stub listener

---

## Part 6: Action Items

### Must Fix (P0 — before any deployment or test run)

| # | Issue | Fix |
|---|-------|-----|
| 1 | `envsubst` clobbers Nomad variables | Use explicit variable list in deploy.sh |
| 2 | goose missing `-table "_migrations"` | Add flag to local-setup.sh |
| 3 | `TestMain` duplicate on Linux | Move orchestrator tests to separate package |
| 4 | Go version 1.25.5 → 1.25.4 | Align both go.mod files |

### Should Fix (P1 — before CI/testing)

| # | Issue | Fix |
|---|-------|-----|
| 5 | TestMain exits 0 silently | Add env-var gate or distinct exit |
| 6 | deploy.sh trap leak | Use explicit cleanup instead of trap |
| 7 | Consul wait loop falls through | Add post-loop failure check |
| 8 | envd tests no build tag | Add `//go:build integration` |
| 9 | local-test.sh swallows failures | Track and propagate exit codes |
| 10 | Port default mismatch | Align to 3000 |
| 11 | Deprecated grpc.DialContext | Migrate to grpc.NewClient |
