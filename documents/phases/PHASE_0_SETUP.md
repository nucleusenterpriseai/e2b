# Phase 0: Fork & Environment Setup

**Duration**: 1 day
**Status**: Mostly Complete

---

## Objective

Clone the E2B upstream repo, set up the project structure, verify builds, and audit dependencies.

## PRD (Phase 0)

### What We're Delivering
- Cloned `e2b-dev/infra` repository
- `aws/` directory with Terraform module structure
- Verified Go builds for all services (except orchestrator on macOS)
- Dependency audit: what to configure vs. what to change

### Success Criteria
- [x] `e2b-dev/infra` cloned to `/Users/mingli/projects/e2b/infra/`
- [x] Go workspace compiles: envd, api, client-proxy, docker-reverse-proxy
- [x] `aws/terraform/` structure created with all modules
- [x] Documents created: PRD, DEV_PLAN, TEST_CASES
- [ ] Dependency audit complete (see below)

## Dev Plan

### 0.1 Clone Repository (DONE)
```bash
git clone https://github.com/e2b-dev/infra.git
```

### 0.2 Verify Builds (DONE)
- envd: `GOOS=linux GOARCH=amd64 go build -o envd .` -- OK
- api: `GOOS=linux GOARCH=amd64 go build -o api .` -- OK
- client-proxy: OK
- docker-reverse-proxy: OK
- orchestrator: FAILS on macOS (userfaultfd syscalls) -- expected, must build on Linux

### 0.3 Dependency Audit (UPDATED per code review)

**Key finding from code review**: Most SaaS deps have graceful fallbacks. Strategy is config-driven, not code-rewrite.

| Dependency | Disable Method | Code Change? |
|---|---|---|
| ClickHouse | Don't set `CLICKHOUSE_CONNECTION_STRING` | None |
| PostHog | Don't set `POSTHOG_API_KEY` | None |
| LaunchDarkly | Don't set `LAUNCH_DARKLY_API_KEY` | None |
| GCS Storage | Set `STORAGE_PROVIDER=AWSBucket` | None |
| Supabase Auth | Don't use `X-Supabase-*` headers, use API keys only | None |
| Loki | Make `LOKI_URL` not required | ~5 lines |
| Volume Tokens | Make volume token config optional | ~10 lines |
| Database Schema | Keep full upstream schema (90 migrations) | None |

**Total Go code changes needed: ~15 lines**

### 0.4 Project Structure (DONE)
```
/Users/mingli/projects/e2b/
├── infra/           # Forked from e2b-dev/infra (unchanged except ~15 lines)
├── aws/             # AWS-specific Terraform, Packer, Nomad, DB
│   ├── terraform/
│   ├── packer/
│   ├── nomad/
│   └── db/
├── documents/       # PRD, dev plans, test cases, review reports
├── templates/       # Sandbox template Dockerfiles
├── sdk/             # SDK config/wrapper (if needed)
└── tests/           # Integration tests
```

## Test Cases (Phase 0)

| ID | Test | Status |
|---|---|---|
| P0-01 | `go build` succeeds for envd | PASS |
| P0-02 | `go build` succeeds for api | PASS |
| P0-03 | `go build` succeeds for client-proxy | PASS |
| P0-04 | `go build` succeeds for docker-reverse-proxy | PASS |
| P0-05 | `go.work` resolves all modules | PASS |
| P0-06 | Terraform modules validate (`terraform validate`) | TODO |

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Upstream pushes breaking changes | Pin to specific commit hash |
| Go version mismatch | Match upstream's Go version (1.25.4 per go.mod) |

## Phase Completion Checklist
- [x] Repo cloned
- [x] Builds verified
- [x] AWS directory structure created
- [x] Terraform modules created
- [x] Documents written
- [ ] Go code changes applied (LOKI_URL, volume tokens -- in progress)
- [ ] `terraform validate` passes
