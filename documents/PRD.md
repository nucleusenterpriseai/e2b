# Product Requirements Document: E2B Self-Hosted Sandbox Platform

**Version**: 1.0
**Date**: 2026-03-12
**Status**: Draft

---

## 1. Overview

### 1.1 Product Summary

A self-hosted Firecracker-based sandbox platform (forked from [e2b-dev/infra](https://github.com/e2b-dev/infra), Apache 2.0) deployed on AWS EC2 for internal use. The platform provides isolated, ephemeral compute environments (microVMs) accessible via REST API and Python/JS SDKs.

### 1.2 Problem Statement

Internal teams need a secure, fast, isolated code execution environment for:
- AI agent tool-use (code interpreters, shell access, browser automation)
- Untrusted code execution in sandboxed environments
- Desktop environments for CUA (Computer Use Agent) workflows
- Reproducible development and testing environments

### 1.3 Goals

| Goal | Metric |
|------|--------|
| Fast sandbox boot | < 200ms from API call to ready (snapshot restore) |
| Strong isolation | Firecracker microVM + Jailer (cgroups, namespaces, seccomp) |
| Minimal operational overhead | Single Terraform apply, Nomad-managed services |
| SDK compatibility | Compatible with existing `e2b` Python/JS SDKs |
| Cost efficiency | ~$1,100/mo baseline for small deployment |

### 1.4 Non-Goals

- Multi-tenant SaaS platform (this is internal-only)
- Billing, quotas, or tier management
- External analytics (PostHog, ClickHouse)
- Feature flag management (LaunchDarkly)
- GCP/Azure support (AWS-only)

---

## 2. Architecture

### 2.1 System Architecture

```
SDK Client (Python/JS)
  |
  | REST (X-API-Key header)
  v
ALB (HTTPS, *.e2b.example.com)
  |
  +---> API Server (Go/Gin, port 50001)
  |       |
  |       | gRPC
  |       v
  |     Orchestrator (Go, port 5008, on Firecracker host)
  |       |
  |       | firecracker-go-sdk
  |       v
  |     Firecracker VMM --> microVM
  |                           |
  |                           | virtio-vsock
  |                           v
  |                         envd (ConnectRPC, port 49983)
  |
  +---> Client-Proxy (ports 3001/3002)
          |
          | vsock proxy
          v
        envd (inside sandbox VM)
```

### 2.2 Core Components

| Component | Language | Port | Description |
|-----------|----------|------|-------------|
| **envd** | Go | 49983 (in-VM) | In-VM agent: process exec, filesystem ops, PTY, resource control via ConnectRPC |
| **Orchestrator** | Go | 5008 | Firecracker VM lifecycle: create, snapshot, restore, destroy. TAP networking, OverlayFS rootfs |
| **API Server** | Go (Gin) | 50001 | REST API for sandbox/template CRUD. Auth via API key |
| **Client-Proxy** | Go | 3001/3002 | Routes SDK gRPC connections to correct sandbox VM via vsock |
| **Docker-Reverse-Proxy** | Go | 5000 | ECR proxy for template builds |
| **Template-Manager** | Go | 5009 | Template build pipeline: Docker image -> rootfs -> Firecracker snapshot |

### 2.3 Infrastructure Components

| Component | AWS Service | Purpose |
|-----------|------------|---------|
| Compute (Servers) | EC2 t3.xlarge x3 | Nomad/Consul server cluster |
| Compute (Clients) | EC2 c5.2xlarge (variable) | Firecracker host (KVM-capable) |
| Compute (API) | EC2 t3.xlarge x1 | API server + client-proxy |
| Database | RDS PostgreSQL 15 | Sandbox/template metadata |
| Cache | ElastiCache Redis 7.0 | Session state, sandbox tracking |
| Storage | S3 | FC kernels, templates, snapshots, Docker contexts |
| Registry | ECR | Docker images for templates |
| Load Balancer | ALB | HTTPS termination, subdomain routing |
| Secrets | Secrets Manager | Nomad/Consul ACL tokens, gossip key |
| Networking | VPC | 10.0.0.0/16, 2 AZs, public/private subnets |

---

## 3. Functional Requirements

### 3.1 Sandbox Lifecycle

#### FR-1: Create Sandbox
- **Input**: template_id, vcpu (1-16), memory_mb (128-32768), timeout_seconds, env_vars, metadata
- **Process**: API validates API key -> calls orchestrator gRPC -> allocates network (TAP + IP) -> creates rootfs overlay -> boots Firecracker VM or restores snapshot -> waits for envd health check
- **Output**: sandbox_id, client_id, envd_access_token
- **SLA**: < 200ms for snapshot restore, < 2s for cold boot

#### FR-2: Delete Sandbox
- **Input**: sandbox_id
- **Process**: Stop Firecracker VM -> release network (TAP + IP) -> cleanup rootfs overlay -> remove DB record
- **Output**: 200 OK

#### FR-3: List Sandboxes
- **Input**: API key (implicit team scoping)
- **Output**: Array of {sandbox_id, template_id, client_id, status, started_at, end_at, metadata}

#### FR-4: Update Sandbox Timeout
- **Input**: sandbox_id, timeout_seconds
- **Process**: Extend `end_at` timestamp
- **Output**: Updated sandbox record

#### FR-5: Pause/Resume Sandbox (Snapshot)
- **Input**: sandbox_id
- **Process (Pause)**: Pause VM -> create memory + disk snapshot -> upload to S3
- **Process (Resume)**: Download snapshot from S3 -> restore VM via UFFD -> wait for envd
- **Output**: Updated sandbox record

### 3.2 In-VM Operations (envd)

#### FR-6: Process Execution
- **Exec**: Run command with args, env vars, working dir. Returns streaming ProcessEvents (stdout, stderr, exit code)
- **Connect**: Attach to running process (PTY mode)
- **SendInput**: Send stdin data to running process
- **SendSignal**: Send signal (SIGTERM, SIGKILL, etc.) to process
- **List**: List running processes

#### FR-7: Filesystem Operations
- **Read**: Read file contents (binary or text)
- **Write**: Write file contents (create or overwrite)
- **ListDir**: List directory entries with metadata (name, type, size, permissions)
- **MakeDir**: Create directory (recursive)
- **Remove**: Delete file or directory
- **Stat**: Get file metadata
- **WatchDir**: Stream filesystem change events (create, modify, delete, rename)

#### FR-8: Resource Control
- CPU and memory limits via cgroup v2 inside VM
- Configurable per-sandbox at creation time

### 3.3 Template System

#### FR-9: Create Template
- **Input**: Dockerfile (or Docker image reference), vcpu, memory_mb, disk_size_mb, setup commands
- **Process**:
  1. Build Docker image (or pull from ECR)
  2. Extract filesystem layers -> create ext4 rootfs
  3. Inject envd binary + init script
  4. Boot Firecracker VM with rootfs + kernel
  5. Run setup commands (pip install, apt-get, etc.)
  6. Snapshot running VM (memory + disk)
  7. Upload snapshot to S3
  8. Update template status to "ready"
- **Output**: template_id, build_id, status

#### FR-10: Get Template Status
- **Input**: template_id
- **Output**: {template_id, status (building/ready/failed), vcpu, memory_mb, disk_size_mb, created_at}

### 3.4 Networking

#### FR-11: VM Networking
- Each VM gets a TAP device with unique IP from pool (172.16.0.0/16)
- Outbound internet via iptables MASQUERADE + NAT gateway
- Optional: disable internet access per sandbox (`allow_internet` flag)
- Network namespace isolation via Firecracker Jailer

#### FR-12: SDK Connectivity
- Sandbox URL format: `{sandboxID}-{clientID}.{domain}`
- Port proxy: `{port}-{sandboxID}.{domain}` -> forwards to VM port
- HTTPS via ALB with wildcard ACM certificate
- WebSocket support for streaming operations

### 3.5 Authentication

#### FR-13: API Key Auth
- API key format: `e2b_...` (stored in PostgreSQL)
- Passed via `X-API-Key` header on REST calls
- Each key belongs to a team
- Simple concurrent sandbox limit per team (configurable)

#### FR-14: envd Auth
- Bearer token in gRPC metadata (`authorization: Bearer {token}`)
- Token generated per-sandbox at creation time
- Token hash passed to envd via Firecracker MMDS

---

## 4. Non-Functional Requirements

### 4.1 Performance
| Metric | Target |
|--------|--------|
| Snapshot restore time | < 200ms |
| Cold boot time | < 2s |
| Concurrent sandboxes per client node | 50-200 (depends on instance type) |
| envd gRPC latency (process exec) | < 50ms |
| Filesystem read/write latency | < 10ms |

### 4.2 Security
- Firecracker Jailer: seccomp filters, cgroup isolation, chroot
- No shared kernel state between VMs
- Network namespace isolation per VM
- envd runs as non-root inside VM where possible
- API keys stored hashed in PostgreSQL
- Secrets Manager for infrastructure secrets (Nomad/Consul tokens)
- Security groups: least-privilege per component

### 4.3 Reliability
- Nomad server cluster: 3 nodes (quorum-based)
- RDS PostgreSQL: Multi-AZ optional (single-AZ for cost savings initially)
- ElastiCache Redis: single node initially, cluster mode available
- Auto Scaling Group for client nodes (min/max configurable)
- Health checks on all services via Consul

### 4.4 Observability
- CloudWatch logs from all EC2 instances
- Nomad job status monitoring
- Consul service health checks
- ALB access logs to S3
- envd logs to stdout (captured by Nomad)

### 4.5 Scalability
- Client instance type is a Terraform variable (start c5.2xlarge, scale to c5.metal)
- Client ASG: configurable min/max/desired count
- Template snapshots in S3 (unlimited storage)
- Stateless API servers (horizontal scaling via ASG)

---

## 5. Database Schema

### 5.1 Core Tables

```sql
-- Teams (internal groups)
teams (id UUID PK, name TEXT, created_at TIMESTAMPTZ)

-- API keys per team
team_api_keys (id UUID PK, team_id UUID FK, api_key TEXT UNIQUE, created_at TIMESTAMPTZ)

-- Sandbox templates
templates (id TEXT PK, team_id UUID FK, build_id TEXT, status TEXT, vcpu INT, memory_mb INT, disk_size_mb INT, created_at TIMESTAMPTZ)

-- Running/completed sandboxes
sandboxes (id TEXT PK, template_id TEXT FK, team_id UUID FK, client_id TEXT, envd_access_token TEXT, status TEXT, started_at TIMESTAMPTZ, end_at TIMESTAMPTZ, metadata JSONB)
```

### 5.2 Simplified vs. Upstream E2B

Removed from upstream E2B schema:
- `users` / Supabase auth tables
- `tiers` / billing / usage tracking
- `access_tokens` (replaced by simple team_api_keys)
- ClickHouse analytics tables
- Complex RLS policies

---

## 6. API Specification

### 6.1 REST Endpoints

| Method | Path | Auth | Request Body | Response |
|--------|------|------|-------------|----------|
| `POST` | `/sandboxes` | API Key | `{templateID, vcpu?, memoryMB?, timeoutS?, envVars?, metadata?}` | `{sandboxID, clientID, envdAccessToken}` |
| `GET` | `/sandboxes` | API Key | — | `[{sandboxID, templateID, clientID, status, startedAt, endAt}]` |
| `GET` | `/sandboxes/:id` | API Key | — | `{sandboxID, templateID, clientID, status, startedAt, endAt, metadata}` |
| `DELETE` | `/sandboxes/:id` | API Key | — | `204 No Content` |
| `PATCH` | `/sandboxes/:id` | API Key | `{timeoutS}` | Updated sandbox |
| `POST` | `/templates` | API Key | `{dockerfile?, imageRef?, vcpu?, memoryMB?, diskSizeMB?}` | `{templateID, buildID, status}` |
| `GET` | `/templates/:id` | API Key | — | `{templateID, status, vcpu, memoryMB, diskSizeMB}` |
| `GET` | `/health` | None | — | `200 OK` |

### 6.2 gRPC Services

**Orchestrator (port 5008)**:
- `SandboxService.Create(CreateRequest) -> CreateResponse`
- `SandboxService.Delete(DeleteRequest) -> Empty`
- `SandboxService.List(Empty) -> ListResponse`
- `SandboxService.Pause(PauseRequest) -> Empty`
- `SandboxService.Resume(ResumeRequest) -> ResumeResponse`

**envd (port 49983, ConnectRPC)**:
- `ProcessService.Exec(ExecRequest) -> stream ProcessEvent`
- `ProcessService.Connect(ConnectRequest) -> stream ProcessEvent`
- `ProcessService.SendInput(SendInputRequest) -> Empty`
- `ProcessService.SendSignal(SendSignalRequest) -> Empty`
- `ProcessService.List(Empty) -> ListResponse`
- `FilesystemService.Read(ReadRequest) -> ReadResponse`
- `FilesystemService.Write(WriteRequest) -> Empty`
- `FilesystemService.ListDir(ListDirRequest) -> ListDirResponse`
- `FilesystemService.MakeDir(MakeDirRequest) -> Empty`
- `FilesystemService.Remove(RemoveRequest) -> Empty`
- `FilesystemService.Stat(StatRequest) -> StatResponse`
- `FilesystemService.WatchDir(WatchDirRequest) -> stream WatchEvent`

**Template Manager (port 5009)**:
- `TemplateService.Build(BuildRequest) -> BuildResponse`
- `TemplateService.Status(StatusRequest) -> StatusResponse`

---

## 7. SDK Interface

### 7.1 Python SDK Usage

```python
from e2b import Sandbox

# Create sandbox (uses E2B_API_KEY and E2B_DOMAIN env vars)
sandbox = Sandbox.create("code-interpreter", timeout=300)

# Execute code
result = sandbox.run_code('print("hello")')
print(result.stdout)  # "hello\n"

# Filesystem
sandbox.files.write("/tmp/data.csv", "a,b,c\n1,2,3")
content = sandbox.files.read("/tmp/data.csv")
entries = sandbox.files.list("/tmp")

# Process
proc = sandbox.commands.run("python3 script.py")
print(proc.exit_code)

# Cleanup
sandbox.kill()
```

### 7.2 Desktop SDK Usage

```python
from e2b import Sandbox

desktop = Sandbox.create("desktop")

# Screenshot
screenshot = desktop.screenshot()  # PNG bytes

# Mouse/keyboard
desktop.mouse_move(100, 200)
desktop.click()
desktop.type_text("hello world")

# VNC URL
vnc_url = f"https://{desktop.get_host(6080)}"

desktop.kill()
```

---

## 8. Template Types

### 8.1 Base Template
- Ubuntu 22.04
- Python 3, Node.js, git, curl, wget
- General-purpose sandbox for code execution

### 8.2 Code Interpreter Template
- Base + Jupyter kernel
- Pre-installed: numpy, pandas, matplotlib, scipy
- Supports `run_code()` convenience method

### 8.3 Desktop Template
- Ubuntu 22.04 + Xvfb + XFCE4
- VNC server (x11vnc) + noVNC (WebSocket access on port 6080)
- Firefox, LibreOffice, xdotool, scrot, ffmpeg
- CJK fonts for international content
- Supports screenshot, mouse, keyboard operations

### 8.4 Browser-Use Template
- Base + headless Chrome/Chromium
- Playwright or Selenium pre-installed
- For web scraping and browser automation agents

---

## 9. Deployment Model

### 9.1 Infrastructure
- **IaC**: Terraform (AWS provider)
- **AMI**: Packer-built Ubuntu with Nomad, Consul, Docker, Firecracker pre-installed
- **Orchestration**: Nomad (services) + Consul (service discovery)
- **No Kubernetes** — Nomad is simpler and supports `raw_exec` driver needed for Firecracker

### 9.2 Deployment Steps
1. Build AMI with Packer
2. `terraform apply` to provision AWS infrastructure
3. Initialize database (migration.sql + seed.sql)
4. Build and push Go service Docker images to ECR
5. Deploy Nomad jobs
6. Build first template
7. Verify end-to-end with SDK

### 9.3 Configuration
All configuration via Terraform variables and environment variables:
- `E2B_DOMAIN` — platform domain (e.g., `e2b.example.com`)
- `STORAGE_PROVIDER=AWSBucket` — use S3 for storage (already supported in codebase)
- `DATABASE_URL` — PostgreSQL connection string
- `REDIS_URL` — Redis connection string
- Instance types, counts, and scaling as Terraform variables

---

## 10. Constraints and Assumptions

### 10.1 Constraints
- Firecracker requires KVM (`/dev/kvm`) — needs bare metal or nested virtualization (c5.metal, c8i with nested virt)
- Go services must be cross-compiled for Linux/amd64 (orchestrator cannot build on macOS due to Linux-specific syscalls like userfaultfd)
- Nomad `raw_exec` driver required for orchestrator (direct hardware access)
- Wildcard DNS and ACM certificate required for subdomain-based routing

### 10.2 Assumptions
- AWS account with sufficient EC2 limits
- Domain managed in Route53 (or DNS delegation to ALB)
- SSH key pair pre-created in target AWS region
- Internal use only — no need for multi-tenant isolation between teams initially

---

## 11. Success Criteria

| Criteria | How to Verify |
|----------|--------------|
| Sandbox creates in < 2s (cold boot) | Timer in SDK create call |
| Sandbox restores in < 200ms (snapshot) | Timer in SDK create call with existing template |
| Code execution returns correct output | `run_code('print(1+1)')` returns `"2\n"` |
| Filesystem operations work | Write file, read it back, content matches |
| Desktop VNC accessible | Connect to noVNC URL, see desktop |
| 50+ concurrent sandboxes | Load test with concurrent SDK calls |
| Clean Terraform deploy | `terraform apply` succeeds on fresh AWS account |
| All services healthy on Nomad | `nomad job status` shows all allocations running |
