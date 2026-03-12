# TDD Methodology & Code Quality Review Report

**Date**: 2026-03-12
**Reviewers**: Tech Lead, QA Engineer, DevOps Engineer, Go Engineer
**Scope**: All deliverables from Phases 1, 3, and 6

---

## Executive Summary

**Verdict: TDD was NOT practiced.** All four reviewers independently reached the same conclusion. The team produced verification tests written *after* implementation, not specification tests written *before*. The tests themselves are competently written, but the methodology is traditional "test-after" — not Test-Driven Development.

Additionally, reviewers found **4 critical bugs**, **8 infrastructure blockers** that will prevent deployment, **6 security concerns**, and numerous quality issues.

| Reviewer | TDD Compliance | Code Quality | Key Finding |
|----------|---------------|--------------|-------------|
| Tech Lead | **No** | Mixed | `go 1.25.4` doesn't exist; test that always passes |
| QA | **No** | Good tests, wrong methodology | 51% coverage of planned test cases |
| DevOps | N/A (infra review) | Individual components good, integration broken | **Will not deploy** — 8 fatal issues |
| Go Engineer | N/A (code review) | Solid patterns, critical nil panic | `VolumesTokenConfig` nil dereference will crash API |

---

## Part 1: TDD Methodology Assessment

### Why This Is NOT TDD

Both the Tech Lead and QA independently identified the same evidence:

1. **Phase plans prescribe build-first**: Phase 1 plan says "Step 1.2: Build → Step 1.3: Write smoke tests." TDD requires tests before implementation.

2. **Tests verify pre-existing code**: The team explicitly states envd required "zero code changes" and the phase is "verification only." You cannot do TDD against code you did not write.

3. **Tests are named "smoke tests"**: A TDD term would be "specification tests" or "acceptance tests." "Smoke test" is inherently a post-hoc verification concept.

4. **No Red-Green-Refactor artifacts**: No commits where tests were added before implementation. No evidence of failing tests driving design decisions.

5. **No git history**: The project directory is not a git repository, making commit-ordering verification impossible.

### What It Actually Is

The team practiced **integration verification testing** — a valid methodology, but not TDD. The tests confirm that existing upstream code works as expected in the self-hosted context.

### TDD Compliance Scorecard

| Phase | TDD Practiced? | What Actually Happened |
|-------|---------------|----------------------|
| Phase 1 (envd) | No | Post-hoc smoke tests for pre-existing code |
| Phase 3 (API) | No | Bash verification script written after configuration |
| Phase 6 (Infra) | No | Zero tests written for any deliverable |

### Test Coverage vs Plan

| Source | Specified | Implemented | Coverage |
|--------|-----------|-------------|----------|
| Phase 1 P0 (E1-01 to E1-10) | 10 | 9 | 90% |
| Phase 1 P1 (E1-11 to E1-19) | 9 | 5 | 56% |
| Phase 3 P0 (A3-01 to A3-11) | 11 | 6 | 55% |
| Phase 3 P1 (A3-12 to A3-20) | 9 | 0 | 0% |
| Phase 6 (all) | 0 specified | 0 | N/A |
| **Total** | **39** | **20** | **51%** |

---

## Part 2: Critical Bugs (Must Fix)

### BUG-1 (CRITICAL): VolumesTokenConfig nil dereference will crash API server
**File**: `infra/packages/api/internal/cfg/model.go` (lines 81-84)
**Found by**: Go Engineer

Removing `required` tags from volume token fields means `SigningMethod` and `SigningKey` will be `nil` when env vars are unset. Any request to volume endpoints will call `jwt.NewWithClaims(config.SigningMethod, claims)` → **nil pointer panic → API server crash**.

**Fix**: Add nil guard at top of `generateVolumeContentToken()` that returns a clear error, or enforce all-or-nothing validation in `Parse()`.

### BUG-2 (CRITICAL): `go 1.25.4` does not exist
**Files**: `tests/go.mod`, `aws/db/go.mod`
**Found by**: Tech Lead

Go 1.25.4 is not a released Go version. These modules will not build. Fix to actual Go version (e.g., `go 1.21`).

### BUG-3 (CRITICAL): `aws/db` module has no `go.sum`
**File**: `aws/db/go.mod`
**Found by**: Go Engineer

`go run generate_api_key.go` will refuse to execute without verified checksums. Run `go mod tidy`.

### BUG-4 (MEDIUM): `seed.sql` sets `max_ram_mb` to 8096
**File**: `aws/db/seed.sql` (line 29)
**Found by**: Tech Lead

Almost certainly a typo for 8192 (8 GB). 8096 is not a standard memory size.

### BUG-5 (MEDIUM): `TestEnvdAuthAccessTokenRejection` asserts nothing
**File**: `tests/envd_smoke_test.go` (lines 535-536)
**Found by**: Tech Lead + Go Engineer (independently)

Accepts status codes 200, 401, 400, and 404. This test **always passes** regardless of server behavior. Worse than no test — creates false confidence.

### BUG-6 (LOW): SQL injection risk in `generate_api_key.go`
**File**: `aws/db/generate_api_key.go` (lines 52-58)
**Found by**: Tech Lead

Printf-based SQL generation does not escape single quotes. If a generated value contains a quote, SQL breaks or allows injection.

---

## Part 3: Infrastructure Blockers (Will Prevent Deployment)

All found by DevOps Engineer. These are independently fatal — **any one of them will prevent jobs from running**.

### INFRA-1: Datacenter mismatch — no jobs will be scheduled
All Nomad jobs specify `datacenters = ["dc1"]`, but user-data configures `datacenter = "${environment}"` (defaults to `"dev"`). **Every job placement will fail with zero eligible nodes.**

### INFRA-2: `node.class` never set — all job constraints fail
Jobs constrain on `${node.class}` = `"client"` or `"api"`, but user-data sets `meta { "node_type" = "client" }` instead of `node_class = "client"` inside the `client {}` block. These are different Nomad concepts.

### INFRA-3: ECR image references use undefined variables
`"${ECR_REGISTRY}/e2b-orchestration/api:latest"` — `${ECR_REGISTRY}` is not a valid Nomad runtime variable. Will cause parse error or empty string.

### INFRA-4: Orchestrator artifact block contradicts itself
`destination = "/opt/e2b/"` with `mode = "file"` — these are contradictory. Also, empty AWS credentials override IAM instance profile auth.

### INFRA-5: Packer and user-data write conflicting config files
Both write Nomad/Consul configs to the same directories. Duplicate plugin blocks may cause parse errors.

### INFRA-6: `NOMAD_UPSTREAM_ADDR_e2b-api-grpc` will be empty
Requires Consul Connect `sidecar_service` block, which is not configured. Client-proxy cannot reach API gRPC endpoint.

### INFRA-7: dnsmasq conflicts with systemd-resolved
Ubuntu 22.04's `systemd-resolved` binds to port 53. Installing dnsmasq without disabling resolved causes port conflict.

### INFRA-8: `deploy.sh` uses GNU-only `grep -oP`
Won't work on macOS or minimal Linux without GNU grep.

---

## Part 4: Security Concerns

| ID | Issue | Severity | Found By |
|----|-------|----------|----------|
| SEC-1 | VNC without authentication (`-nopw -listen 0.0.0.0`) | High | DevOps |
| SEC-2 | `/dev/kvm` world-writable (`MODE="0666"`) | Medium | DevOps |
| SEC-3 | `raw_exec` + `allow_privileged` enabled globally | Medium | DevOps |
| SEC-4 | Secrets written to disk in plaintext config files | Medium | DevOps |
| SEC-5 | Chromium sandbox disabled (`--no-sandbox`) | Low | DevOps |
| SEC-6 | Unlimited `nproc` and `memlock` for all users | Low | DevOps |

---

## Part 5: Code Quality (Go)

### Anti-Patterns Found (Go Engineer)

1. **Resource cleanup not guarded by `t.Cleanup()`** — if assertions fail before cleanup, resources leak
2. **Repeated boilerplate** — every test creates its own context + clients instead of shared helper
3. **Tests should be table-driven** — 4 process tests are structurally identical, differing only in inputs
4. **`http.DefaultClient` used without timeout** in file upload/download helpers
5. **`*testing.T` passed into goroutines** — fragile if any future refactor adds `require` calls

### What's Good (Go Engineer)

- ConnectRPC client usage is correct (HTTP/1.1 POST, not native gRPC)
- `require` vs `assert` usage follows Go best practice
- `execCommand` helper is well-structured with proper stream handling
- Key generator correctly delegates to upstream `keys` package
- `LokiURL` change is safe (runtime-graceful degradation)
- Test coverage is comprehensive for a smoke test suite

---

## Part 6: What's Good Overall

Despite the TDD methodology gap and deployment blockers, reviewers noted significant strengths:

- **Terraform bootstrap is production-grade**: KMS encryption, versioning, PITR, public access blocks, lifecycle rules
- **Packer scripts are idempotent**: check-before-create guards, version-pinned with `apt-mark hold`
- **System tuning is comprehensive**: conntrack, ARP cache, socket buffers, fd limits, hugepages
- **Nomad update strategies well-configured**: `auto_revert = true`, staggered rolling, health deadlines
- **Phase 3 results document is thorough**: 10 discrepancies identified between plan and reality
- **Makefile is well-structured**: 40+ targets, self-documenting, proper `.PHONY`
- **Shell scripts use `set -euo pipefail`**: strict error handling throughout

---

## Part 7: Consolidated Action Items

### Priority 1 — Blocking (Must fix before any deployment)

| # | Issue | Source |
|---|-------|--------|
| 1 | Fix `VolumesTokenConfig` nil dereference (add nil guard or all-or-nothing validation) | BUG-1 |
| 2 | Fix `go 1.25.4` → actual Go version in both `go.mod` files | BUG-2 |
| 3 | Run `go mod tidy` for `aws/db` module | BUG-3 |
| 4 | Align datacenter names (user-data vs Nomad jobs) | INFRA-1 |
| 5 | Set `node_class` in Nomad client config (not just `meta`) | INFRA-2 |
| 6 | Fix ECR image references (use envsubst or Consul KV template) | INFRA-3 |
| 7 | Fix orchestrator artifact (file path + remove empty AWS creds) | INFRA-4 |
| 8 | Resolve Packer/user-data config file conflicts | INFRA-5 |
| 9 | Fix client-proxy → API gRPC address (use Consul DNS) | INFRA-6 |
| 10 | Fix dnsmasq/systemd-resolved conflict | INFRA-7 |

### Priority 2 — High (Should fix before production)

| # | Issue | Source |
|---|-------|--------|
| 11 | Fix `max_ram_mb` typo (8096 → 8192) | BUG-4 |
| 12 | Delete or rewrite auth rejection test | BUG-5 |
| 13 | Add VNC authentication or restrict to localhost | SEC-1 |
| 14 | Tighten `/dev/kvm` permissions to 0660 | SEC-2 |
| 15 | Add SHA256 checksum verification for binary downloads | DevOps |
| 16 | Pin Docker base images by digest | DevOps |
| 17 | Fix `deploy.sh` GNU grep dependency | INFRA-8 |

### Priority 3 — Improvement (Should address)

| # | Issue | Source |
|---|-------|--------|
| 18 | Implement 4 missing Phase 1 tests (PTY, signals, WatchDir, upstream) | QA |
| 19 | Implement Phase 3 P1 tests (0% coverage) | QA |
| 20 | Add infrastructure tests (Terratest, packer validate, nomad validate) | Tech Lead |
| 21 | Refactor Go tests: `t.Cleanup()`, table-driven, shared setup helper | Go Engineer |
| 22 | Fix SQL injection in `generate_api_key.go` | BUG-6 |
| 23 | Harmonize module paths (`e2b-selfhost` vs `infra`) | Go Engineer |
| 24 | Template Dockerfiles should extend base instead of duplicating | DevOps |

---

## Conclusion

**The team produced solid engineering artifacts but did not follow TDD.** The tests are competent verification tests written after implementation — not specification tests that drove design. If TDD is a project requirement, the workflow must be restructured: write a failing test, commit it, then write minimal passing code, commit that, then refactor.

**The infrastructure will not deploy** in its current state due to 8 independently fatal integration issues at the boundaries between Packer, user-data, and Nomad job definitions. Individual components are well-crafted; the failures are at the seams.

**Recommended next steps**:
1. Fix all 10 Priority 1 blockers before attempting any deployment
2. Initialize a git repository and enforce commit discipline going forward
3. If TDD is desired, restructure the workflow per the reviewers' guidance
4. Add integration testing for infrastructure (Terratest, `nomad job validate`)
