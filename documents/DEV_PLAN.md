# Development Plan: E2B Self-Hosted Sandbox Platform

**Version**: 1.0
**Date**: 2026-03-12
**Estimated Duration**: 16 working days

---

## Overview

Fork [e2b-dev/infra](https://github.com/e2b-dev/infra) (Apache 2.0) and modify for self-hosted AWS deployment. Bottom-up build order ensures each layer is verified before building the next.

**Build Order**: envd -> orchestrator -> API -> infra -> templates -> SDK -> integration

---

## Phase 0: Fork & Environment Setup (Day 1)

### 0.1 Clone Repository
- [x] Clone `e2b-dev/infra` to `/Users/mingli/projects/e2b/infra/`
- [x] Verify Go workspace (`go.work`) and module structure
- [x] Verify envd, API, client-proxy, docker-reverse-proxy compile on macOS

### 0.2 Project Structure
- [x] Create `aws/` directory for AWS-specific code
- [x] Create `aws/terraform/` with module structure
- [ ] Create `documents/` for PRD, dev plan, test cases

### 0.3 Dependencies Audit
- Identify all third-party SaaS dependencies to remove:
  - Supabase (auth) -> simple API key lookup
  - PostHog (analytics) -> remove
  - ClickHouse (metrics) -> remove
  - LaunchDarkly (feature flags) -> remove
  - GCS/GCR (storage) -> S3/ECR (already supported: `STORAGE_PROVIDER=AWSBucket`)

### Deliverables
- Cloned repo with working Go builds
- `aws/` directory structure
- Dependency audit document

---

## Phase 1: envd - In-VM Agent (Days 2-4)

### 1.1 Code Review & Understand
- [ ] Read `packages/envd/main.go` — ConnectRPC server setup, MMDS polling, cgroup init
- [ ] Read `packages/envd/internal/process/` — Exec, PTY, signal handling
- [ ] Read `packages/envd/internal/filesystem/` — Read, Write, List, Watch, MakeDir, Remove
- [ ] Read `packages/envd/internal/host/mmds.go` — MMDS metadata polling
- [ ] Read proto definitions in `packages/shared/pkg/grpc/envd/`
- [ ] Map all external dependencies in `go.mod`

### 1.2 Simplify for Internal Use
- [ ] Remove analytics hooks (if any — envd is already minimal)
- [ ] Verify auth interceptor works standalone (Bearer token from MMDS)
- [ ] Verify cgroup v2 manager works in Firecracker context
- [ ] Test MMDS polling behavior (metadata available at `169.254.169.254`)

### 1.3 Build & Unit Test
- [ ] Cross-compile: `GOOS=linux GOARCH=amd64 go build -o envd .`
- [ ] Run locally (macOS) with `ENVD_ACCESS_TOKEN=test` for basic smoke test
- [ ] Write test client (Go or Python) to verify:
  - Process exec: `echo hello` -> stdout "hello\n" + exit code 0
  - Filesystem write + read roundtrip
  - Directory listing
  - File watch events

### 1.4 Validation
- [ ] envd binary builds without errors
- [ ] ConnectRPC server starts and accepts connections
- [ ] All process/filesystem gRPC methods respond correctly
- [ ] Auth interceptor rejects unauthenticated calls

### Deliverables
- Working envd Linux binary
- Smoke test script/client
- List of any modifications made

---

## Phase 2: Orchestrator - Firecracker VM Manager (Days 4-7)

### 2.1 Code Review
- [ ] Read `packages/orchestrator/main.go` — gRPC server, cmux, pool init
- [ ] Read `packages/orchestrator/internal/sandbox/` — VM create/delete/pause/resume
- [ ] Read `packages/orchestrator/internal/sandbox/firecracker.go` — firecracker-go-sdk usage
- [ ] Read `packages/orchestrator/internal/sandbox/snapshot.go` — UFFD snapshot restore
- [ ] Read `packages/orchestrator/internal/network/` — TAP device + IP pool
- [ ] Read `packages/orchestrator/internal/rootfs/` — OverlayFS setup
- [ ] Read `packages/orchestrator/internal/template/` — template cache (S3)
- [ ] Identify all GCS, ClickHouse, PostHog, LaunchDarkly references

### 2.2 Modify for AWS
- [ ] Replace GCS storage calls with S3 (check if `STORAGE_PROVIDER=AWSBucket` covers this)
- [ ] Remove ClickHouse metric collectors
- [ ] Remove PostHog analytics calls
- [ ] Remove LaunchDarkly feature flag conditionals
- [ ] Verify `firecracker-go-sdk` usage is cloud-agnostic (it is)
- [ ] Verify network pool code is cloud-agnostic (TAP devices are Linux-only, not cloud-specific)

### 2.3 Build (Linux Only)
- [ ] Build must happen on Linux (uses `userfaultfd` syscalls)
- [ ] Set up build on EC2 instance or CI pipeline
- [ ] `GOOS=linux GOARCH=amd64 go build -o orchestrator .`

### 2.4 Test on EC2
- [ ] Launch KVM-capable EC2 instance (c5.metal or c8i with nested virt)
- [ ] Install Firecracker + jailer
- [ ] Download vmlinux kernel
- [ ] Build base rootfs (minimal ext4 with envd)
- [ ] Boot Firecracker VM with envd -> connect via vsock -> exec command
- [ ] Test TAP networking: VM can reach internet
- [ ] Test snapshot create + restore cycle
- [ ] Verify snapshot restore < 200ms

### Deliverables
- Working orchestrator binary (Linux)
- Verified Firecracker VM boot with envd
- TAP networking functional
- Snapshot create/restore verified

---

## Phase 3: API Server + Client-Proxy (Days 7-9)

### 3.1 Database Schema
- [ ] Create simplified migration.sql (teams, team_api_keys, templates, sandboxes)
- [ ] Create seed.sql (initial team + API key for testing)
- [ ] Create init.sh script for RDS initialization
- [ ] Test migration against local PostgreSQL

### 3.2 API Server Modifications
- [ ] Read `packages/api/` — Gin router, handlers, middleware
- [ ] Remove Supabase auth -> implement simple API key lookup middleware
  - Query `team_api_keys` table by `X-API-Key` header
  - Set team context on request
- [ ] Remove PostHog analytics calls
- [ ] Remove ClickHouse logging
- [ ] Remove complex tier/quota enforcement -> simple concurrent sandbox limit
- [ ] Keep OpenAPI schema validation middleware
- [ ] Verify all CRUD endpoints work:
  - `POST /sandboxes` — calls orchestrator gRPC Create
  - `GET /sandboxes` — queries PostgreSQL
  - `DELETE /sandboxes/:id` — calls orchestrator gRPC Delete
  - `POST /templates` — calls template-manager gRPC Build
  - `GET /templates/:id` — queries PostgreSQL

### 3.3 Client-Proxy
- [ ] Read `packages/client-proxy/` — hostname parsing, vsock proxy
- [ ] Verify works with Consul DNS for service discovery
- [ ] Minimal changes expected (already cloud-agnostic)
- [ ] Test hostname routing: `{sandboxID}-{clientID}.{domain}` -> correct VM

### 3.4 Docker-Reverse-Proxy
- [ ] Read `packages/docker-reverse-proxy/` — ECR proxy
- [ ] Modify for ECR authentication (AWS SDK)
- [ ] Test Docker pull through proxy

### 3.5 Validation
- [ ] API server starts, `/health` returns 200
- [ ] API key auth works (valid key -> 200, invalid -> 401)
- [ ] Create sandbox via REST -> orchestrator creates VM
- [ ] Client-proxy routes connections correctly
- [ ] Full chain: SDK -> API -> orchestrator -> Firecracker -> envd

### Deliverables
- Simplified database schema + seed data
- Modified API server (no Supabase/PostHog/ClickHouse)
- Working client-proxy
- End-to-end sandbox create/use/delete via REST

---

## Phase 4: Template System (Days 9-11)

### 4.1 Template-Manager Modifications
- [ ] Read `packages/template-manager/` — build pipeline
- [ ] Replace GCR -> ECR for Docker registry
- [ ] Replace GCS -> S3 for template storage
- [ ] Verify build pipeline:
  1. Pull Docker image from ECR
  2. Extract layers -> ext4 rootfs
  3. Inject envd + init script
  4. Boot Firecracker VM
  5. Run setup commands
  6. Create snapshot (memory + disk)
  7. Upload to S3
  8. Update template status in DB

### 4.2 Template Dockerfiles
- [ ] Create `templates/base.Dockerfile` — Ubuntu 22.04 + Python3 + Node.js + git
- [ ] Create `templates/code-interpreter.Dockerfile` — base + Jupyter + numpy/pandas/matplotlib
- [ ] Create `templates/desktop.Dockerfile` — Ubuntu + Xvfb + XFCE + VNC + noVNC + browser
- [ ] Create `templates/browser-use.Dockerfile` — base + headless Chrome + Playwright

### 4.3 Kernel
- [ ] Download Firecracker-compatible vmlinux kernel (6.1.x)
- [ ] Upload to S3 bucket (`fc-kernels`)
- [ ] Verify kernel boot with base rootfs

### 4.4 Validation
- [ ] Template build pipeline: Dockerfile -> rootfs -> boot -> snapshot -> S3
- [ ] Snapshot restore: S3 -> restore VM in < 200ms
- [ ] All template types boot and pass health check
- [ ] Desktop template: VNC accessible after restore

### Deliverables
- Modified template-manager (ECR + S3)
- 4 template Dockerfiles
- Firecracker kernel in S3
- Verified template build and restore pipeline

---

## Phase 5: SDK Integration (Days 11-12)

### 5.1 SDK Strategy Decision
- [ ] Option A (Recommended): Use existing `e2b` Python/JS SDKs with `E2B_DOMAIN` env var
- [ ] Option B: Build minimal internal Python SDK if customization needed

### 5.2 SDK Configuration
- [ ] Set `E2B_API_KEY` and `E2B_DOMAIN` environment variables
- [ ] Verify SDK connects to our API server
- [ ] Verify SDK creates sandboxes, executes code, reads/writes files

### 5.3 SDK Testing
- [ ] `Sandbox.create("base")` -> returns sandbox object
- [ ] `sandbox.run_code('print("hello")')` -> stdout "hello\n"
- [ ] `sandbox.files.write("/tmp/test.txt", "data")` -> success
- [ ] `sandbox.files.read("/tmp/test.txt")` -> "data"
- [ ] `sandbox.files.list("/tmp")` -> includes "test.txt"
- [ ] `sandbox.kill()` -> sandbox destroyed
- [ ] Desktop: `Sandbox.create("desktop")` -> VNC URL accessible

### Deliverables
- SDK configuration documented
- SDK smoke tests passing
- Desktop sandbox accessible via VNC

---

## Phase 6: AWS Infrastructure (Days 12-15)

### 6.1 Packer AMI
- [ ] Create `aws/packer/e2b-node.pkr.hcl`:
  - Ubuntu 22.04 LTS base
  - Install Nomad 1.7+
  - Install Consul 1.17+
  - Install Docker CE
  - Install Firecracker + jailer (from GitHub releases)
  - Install CNI plugins
  - Configure system (hugepages, KVM access, sysctl tuning)
  - Download Firecracker kernel to `/opt/fc/`
- [ ] Build AMI: `packer build e2b-node.pkr.hcl`
- [ ] Test AMI: launch EC2, verify all tools installed

### 6.2 Terraform Modules (Completed)
- [x] `modules/vpc/` — VPC, subnets, IGW, NAT gateways
- [x] `modules/security/` — Security groups, IAM role + instance profile
- [x] `modules/database/` — RDS PostgreSQL, ElastiCache Redis
- [x] `modules/storage/` — S3 buckets, ECR repositories
- [x] `modules/secrets/` — Secrets Manager entries
- [x] `modules/alb/` — ACM cert, ALB, target groups, routing rules
- [x] `modules/compute/` — Launch templates, ASGs, bastion, user-data scripts
- [x] Root `main.tf`, `variables.tf`, `outputs.tf`, `providers.tf`

### 6.3 Terraform Validation
- [ ] `terraform init` — providers download
- [ ] `terraform validate` — syntax check
- [ ] `terraform plan` — review resources
- [ ] `terraform apply` — deploy infrastructure

### 6.4 Nomad Jobs
- [ ] Create `aws/nomad/jobs/api.hcl` — API server Docker job
- [ ] Create `aws/nomad/jobs/orchestrator.hcl` — orchestrator raw_exec job
- [ ] Create `aws/nomad/jobs/client-proxy.hcl` — client-proxy Docker job
- [ ] Create `aws/nomad/jobs/template-manager.hcl` — template-manager raw_exec job
- [ ] Create `aws/nomad/jobs/docker-reverse-proxy.hcl` — Docker reverse proxy job
- [ ] Create `aws/nomad/prepare.sh` — pre-deployment setup
- [ ] Create `aws/nomad/deploy.sh` — deploy all jobs

### 6.5 Database Init
- [ ] Create `aws/db/migration.sql` — simplified schema
- [ ] Create `aws/db/seed.sql` — initial team + API key
- [ ] Create `aws/db/init.sh` — connect to RDS + run migration + seed

### 6.6 Validation
- [ ] All AWS resources created successfully
- [ ] Nomad cluster healthy (3 servers, N clients)
- [ ] Consul cluster healthy
- [ ] RDS accessible from private subnets
- [ ] Redis accessible from private subnets
- [ ] ALB serving HTTPS with valid cert
- [ ] All Nomad jobs running

### Deliverables
- Packer AMI definition + built AMI
- Terraform applied with all resources
- Nomad jobs deployed and healthy
- Database initialized

---

## Phase 7: Desktop & Integration Testing (Days 14-16)

### 7.1 Desktop Template
- [ ] Build desktop template (Xvfb + XFCE + VNC + browser)
- [ ] Verify VNC accessible via noVNC WebSocket
- [ ] Test screenshot capture
- [ ] Test mouse/keyboard input via SDK
- [ ] Test browser launch inside desktop

### 7.2 End-to-End Tests
- [ ] Base template: create -> exec -> filesystem -> destroy
- [ ] Code interpreter: create -> run_code -> check output -> destroy
- [ ] Desktop: create -> screenshot -> mouse/keyboard -> destroy
- [ ] Browser-use: create -> launch browser -> navigate -> destroy
- [ ] Concurrent sandboxes: create 10+ simultaneously
- [ ] Timeout: create with short timeout -> verify auto-cleanup
- [ ] Snapshot: create -> pause -> resume -> verify state preserved

### 7.3 Performance Benchmarks
- [ ] Cold boot time (no snapshot)
- [ ] Snapshot restore time
- [ ] Process exec latency (simple command)
- [ ] Filesystem read/write latency
- [ ] Max concurrent sandboxes before degradation
- [ ] Memory usage per sandbox

### 7.4 Security Validation
- [ ] VM-to-VM isolation (sandbox A cannot reach sandbox B)
- [ ] envd auth (unauthenticated requests rejected)
- [ ] API key auth (invalid key returns 401)
- [ ] Network isolation (`allow_internet=false` blocks outbound)
- [ ] Jailer restrictions (seccomp, cgroups, namespaces)

### Deliverables
- All templates working
- End-to-end test suite passing
- Performance benchmark results
- Security validation report

---

## Makefile Targets

```makefile
# Build
make build-envd          # Cross-compile envd for linux/amd64
make build-api           # Cross-compile API server
make build-client-proxy  # Cross-compile client-proxy
make build-all           # Build all services

# Infrastructure
make packer              # Build AMI
make terraform-plan      # Plan Terraform changes
make terraform-apply     # Apply Terraform
make db-init             # Initialize database

# Deploy
make nomad-deploy        # Deploy all Nomad jobs
make nomad-status        # Check job status

# Templates
make template-base       # Build base template
make template-desktop    # Build desktop template
make template-all        # Build all templates

# Test
make test-unit           # Run unit tests
make test-integration    # Run integration tests
make test-e2e            # Run end-to-end tests
make test-all            # Run all tests
```

---

## Risk Register

| Risk | Impact | Mitigation |
|------|--------|------------|
| KVM not available on chosen instance type | High | Verify c5.metal or c8i nested virt support before provisioning |
| Firecracker version incompatibility with kernel | High | Pin versions (FC 1.7.0 + vmlinux 6.1.102), test in Phase 2 |
| E2B upstream code changes break our fork | Medium | Pin to specific commit, merge selectively |
| UFFD (userfaultfd) not supported on kernel | High | Verify kernel config, use kernel from Firecracker releases |
| ECR auth for template builds | Medium | Test Docker pull through ECR early in Phase 4 |
| Nomad raw_exec security concerns | Medium | Restrict to client nodes only, security group isolation |
| DNS wildcard routing edge cases | Low | Test with multiple sandbox IDs, verify ALB rules |

---

## Dependencies Between Phases

```
Phase 0 (Setup)
  |
  v
Phase 1 (envd) --------+
  |                     |
  v                     |
Phase 2 (Orchestrator) -+---> Phase 4 (Templates)
  |                     |         |
  v                     |         v
Phase 3 (API + Proxy) --+    Phase 5 (SDK)
  |                               |
  v                               v
Phase 6 (AWS Infra) ----------> Phase 7 (Integration)
```

Phase 1-2 can partially overlap (envd standalone testing while reading orchestrator code).
Phase 6 can start in parallel with Phase 3-4 (Terraform is independent of code changes).
