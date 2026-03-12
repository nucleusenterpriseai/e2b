# Phase 1: envd — In-VM Agent

**Duration**: 2 days
**Depends on**: Phase 0
**Status**: Not Started

---

## Objective

Verify that envd (the in-VM agent) works as-is with no code changes. Build for Linux, run standalone tests for process execution and filesystem operations.

## PRD (Phase 1)

### What envd Does
envd is a Go daemon that runs inside each Firecracker microVM on port 49983. It provides:
- **Process Service**: Execute commands, PTY sessions, signal handling, stdin streaming
- **Filesystem Service**: Read/write files, list/create/remove directories, watch for changes
- **Auth**: Bearer token validation via ConnectRPC interceptor
- **Resource Control**: cgroup v2 management for CPU/memory limits

### What We're Delivering
- Verified envd Linux binary (cross-compiled or native)
- Standalone smoke test proving process and filesystem gRPC services work
- Documentation of envd's runtime requirements and config

### What We're NOT Changing
Per the code review, envd has zero SaaS dependencies. No code changes needed. This phase is verification only.

### Success Criteria
- envd binary builds for linux/amd64
- ConnectRPC server starts and listens on port 49983
- Process exec returns correct stdout, stderr, and exit codes
- Filesystem write/read roundtrip works
- Auth interceptor rejects unauthenticated requests

## Dev Plan

### 1.1 Code Review (Day 1, 2 hours)
Read and understand:
- [ ] `packages/envd/main.go` — Server setup, MMDS polling, cgroup init
- [ ] `packages/envd/internal/services/process/` — Exec, PTY, signals
- [ ] `packages/envd/internal/services/filesystem/` — Read, write, list, watch
- [ ] `packages/envd/internal/host/mmds.go` — Metadata polling (169.254.169.254)
- [ ] `packages/envd/spec/process/process.proto` — Process RPC definitions
- [ ] `packages/envd/spec/filesystem/filesystem.proto` — Filesystem RPC definitions
- [ ] `packages/envd/go.mod` — Dependencies (ConnectRPC, creack/pty, fsnotify)

Key things to note:
- envd uses ConnectRPC (HTTP/2 compatible), not standard gRPC
- Auth via `authorization: Bearer {token}` in metadata
- MMDS polling gets sandbox config (sandboxID, templateID, accessTokenHash)
- When `isNotFC=true` flag is set, MMDS polling is skipped (for local testing)

### 1.2 Build (Day 1, 30 min)
```bash
cd /Users/mingli/projects/e2b/infra/packages/envd
GOOS=linux GOARCH=amd64 go build -o envd -ldflags "-s -w" .
```

For local macOS testing (won't have cgroup/MMDS but API will respond):
```bash
go build -o envd . && ./envd -port 49983 -isnotfc
```

### 1.3 Smoke Test Client (Day 1, 4 hours)

Write a Go test client at `/Users/mingli/projects/e2b/tests/envd_smoke_test.go`:

```go
// Tests to implement:
// 1. Connect to envd ConnectRPC, call Process.Start("echo hello")
//    -> Verify stdout contains "hello\n", exit code 0
// 2. Call Process.Start("exit 42")
//    -> Verify exit code 42
// 3. Call Process.Start("echo err >&2")
//    -> Verify stderr contains "err\n"
// 4. Call Filesystem.Write("/tmp/test.txt", "data")
//    -> Call Filesystem.Read("/tmp/test.txt")
//    -> Verify content matches
// 5. Call Filesystem.MakeDir("/tmp/nested/dir")
//    -> Call Filesystem.ListDir("/tmp/nested")
//    -> Verify "dir" in listing
// 6. Connect without Bearer token
//    -> Verify UNAUTHENTICATED error
```

### 1.4 Run Existing Upstream Tests (Day 2, 2 hours)

The upstream has tests at:
- `packages/envd/internal/services/process/service_test.go`
- `packages/envd/internal/services/filesystem/service_test.go`
- `packages/envd/internal/api/*_test.go`

```bash
cd /Users/mingli/projects/e2b/infra/packages/envd
go test ./... -v -count=1
```

Document which tests pass and which fail (some may need Linux/cgroup).

### 1.5 Document Runtime Requirements (Day 2, 1 hour)

Create a reference doc of envd's runtime needs:
- Linux kernel with cgroup v2
- `/sys/fs/cgroup` mounted
- Port 49983 available
- MMDS at 169.254.169.254 (in Firecracker) or `-isnotfc` flag
- `ENVD_ACCESS_TOKEN` env var or MMDS-provided token hash

## Test Cases (Phase 1)

### P0 (Must Pass)

| ID | Test | Expected |
|---|---|---|
| E1-01 | Build envd for linux/amd64 | Binary produced, no errors |
| E1-02 | Start envd with `-isnotfc` flag | Server listens on :49983 |
| E1-03 | Exec `echo hello` | stdout="hello\n", exit=0 |
| E1-04 | Exec `exit 42` | exit=42 |
| E1-05 | Exec with env var `echo $FOO` | stdout contains FOO value |
| E1-06 | Write file, read it back | Content matches |
| E1-07 | MakeDir recursive | Directory created |
| E1-08 | ListDir | Lists files with metadata |
| E1-09 | Remove file | File gone, subsequent read fails |
| E1-10 | Connect without auth token | UNAUTHENTICATED error |

### P1 (Should Pass)

| ID | Test | Expected |
|---|---|---|
| E1-11 | Exec with stderr output | stderr captured |
| E1-12 | PTY session (Connect) | Interactive shell works |
| E1-13 | Send signal to process | Process terminated |
| E1-14 | WatchDir events | Create/modify/delete events received |
| E1-15 | Stat file | Returns size, type, permissions |
| E1-16 | Concurrent exec (5 processes) | All complete independently |
| E1-17 | Read non-existent file | NOT_FOUND error |
| E1-18 | Large file write/read (1MB) | Content matches |
| E1-19 | Upstream unit tests pass | `go test ./...` passes |

## Risks

| Risk | Impact | Mitigation |
|---|---|---|
| cgroup tests fail on macOS | Low | Expected — test on Linux or skip cgroup tests |
| MMDS tests require Firecracker | Low | Use `-isnotfc` flag for standalone testing |
| ConnectRPC client setup non-trivial | Low | Use `connectrpc.com/connect` Go client library |

## Deliverables
- [ ] envd Linux binary
- [ ] Smoke test client (Go)
- [ ] Upstream test results documented
- [ ] Runtime requirements reference doc
