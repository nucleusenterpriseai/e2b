# Test Cases: E2B Self-Hosted Sandbox Platform

**Version**: 1.0
**Date**: 2026-03-12

---

## Test Categories

| Category | Count | Priority |
|----------|-------|----------|
| [TC-1xx] envd (In-VM Agent) | 20 | P0 |
| [TC-2xx] Orchestrator (VM Lifecycle) | 18 | P0 |
| [TC-3xx] API Server | 16 | P0 |
| [TC-4xx] Client-Proxy | 8 | P1 |
| [TC-5xx] Template System | 10 | P1 |
| [TC-6xx] SDK Integration | 12 | P0 |
| [TC-7xx] Infrastructure (Terraform/Nomad) | 10 | P1 |
| [TC-8xx] Security | 12 | P0 |
| [TC-9xx] Performance | 8 | P2 |
| [TC-10xx] Desktop/Browser Templates | 8 | P1 |

**Priority**: P0 = Must pass for launch, P1 = Should pass, P2 = Nice to have

---

## TC-1xx: envd (In-VM Agent)

### Process Service

#### TC-101: Basic Command Execution
- **Priority**: P0
- **Precondition**: envd running with `ENVD_ACCESS_TOKEN=test-token`
- **Steps**:
  1. Connect to envd gRPC (port 49983) with Bearer token `test-token`
  2. Call `ProcessService.Exec` with command `echo hello`
- **Expected**: Stream returns ProcessEvent with stdout="hello\n" and exit code 0

#### TC-102: Command with Arguments
- **Priority**: P0
- **Precondition**: envd running
- **Steps**:
  1. Call `ProcessService.Exec` with command `ls -la /tmp`
- **Expected**: Stream returns directory listing of /tmp with exit code 0

#### TC-103: Command with Environment Variables
- **Priority**: P0
- **Precondition**: envd running
- **Steps**:
  1. Call `ProcessService.Exec` with command `echo $MY_VAR`, env_vars={"MY_VAR": "test123"}
- **Expected**: stdout="test123\n", exit code 0

#### TC-104: Command with Working Directory
- **Priority**: P1
- **Precondition**: envd running, /tmp exists
- **Steps**:
  1. Call `ProcessService.Exec` with command `pwd`, working_dir="/tmp"
- **Expected**: stdout="/tmp\n", exit code 0

#### TC-105: Long-Running Process
- **Priority**: P0
- **Precondition**: envd running
- **Steps**:
  1. Call `ProcessService.Exec` with command `sleep 5 && echo done`
  2. Wait for stream to complete
- **Expected**: After ~5s, stdout="done\n", exit code 0

#### TC-106: Process Stderr
- **Priority**: P0
- **Precondition**: envd running
- **Steps**:
  1. Call `ProcessService.Exec` with command `echo error >&2`
- **Expected**: Stream returns ProcessEvent with stderr="error\n", exit code 0

#### TC-107: Process Exit Code (Non-Zero)
- **Priority**: P0
- **Precondition**: envd running
- **Steps**:
  1. Call `ProcessService.Exec` with command `exit 42`
- **Expected**: Stream returns ProcessEvent with exit code 42

#### TC-108: Send Signal to Process
- **Priority**: P1
- **Precondition**: envd running
- **Steps**:
  1. Start long-running process: `sleep 300`
  2. Call `ProcessService.SendSignal` with SIGTERM
- **Expected**: Process terminates, exit event received

#### TC-109: Send Input to Process
- **Priority**: P1
- **Precondition**: envd running
- **Steps**:
  1. Start `cat` (reads from stdin)
  2. Call `ProcessService.SendInput` with data "hello\n"
- **Expected**: stdout="hello\n"

#### TC-110: PTY Mode (Connect)
- **Priority**: P1
- **Precondition**: envd running
- **Steps**:
  1. Call `ProcessService.Connect` to start a PTY shell (`/bin/bash`)
  2. Send input "echo PTY_TEST\n"
  3. Read output
- **Expected**: Output contains "PTY_TEST"

#### TC-111: List Processes
- **Priority**: P1
- **Precondition**: envd running with at least one background process
- **Steps**:
  1. Start a background process: `sleep 100 &`
  2. Call `ProcessService.List`
- **Expected**: Response includes the sleep process with correct PID

#### TC-112: Concurrent Process Execution
- **Priority**: P1
- **Precondition**: envd running
- **Steps**:
  1. Start 5 concurrent `echo $RANDOM` calls
  2. Wait for all to complete
- **Expected**: All 5 return different random numbers, all exit code 0

### Filesystem Service

#### TC-113: Write and Read File
- **Priority**: P0
- **Precondition**: envd running
- **Steps**:
  1. Call `FilesystemService.Write` with path="/tmp/test.txt", content="hello world"
  2. Call `FilesystemService.Read` with path="/tmp/test.txt"
- **Expected**: Read returns "hello world"

#### TC-114: Write Binary File
- **Priority**: P1
- **Precondition**: envd running
- **Steps**:
  1. Call `FilesystemService.Write` with binary content (e.g., PNG bytes)
  2. Call `FilesystemService.Read`
- **Expected**: Read returns identical binary content

#### TC-115: List Directory
- **Priority**: P0
- **Precondition**: envd running, /tmp has files
- **Steps**:
  1. Write files: /tmp/a.txt, /tmp/b.txt
  2. Call `FilesystemService.ListDir` with path="/tmp"
- **Expected**: Response includes a.txt and b.txt with correct metadata (name, type, size)

#### TC-116: Make Directory (Recursive)
- **Priority**: P0
- **Precondition**: envd running
- **Steps**:
  1. Call `FilesystemService.MakeDir` with path="/tmp/deep/nested/dir"
  2. Call `FilesystemService.ListDir` with path="/tmp/deep/nested"
- **Expected**: Directory "dir" exists in listing

#### TC-117: Remove File
- **Priority**: P0
- **Precondition**: envd running, /tmp/delete-me.txt exists
- **Steps**:
  1. Write /tmp/delete-me.txt
  2. Call `FilesystemService.Remove` with path="/tmp/delete-me.txt"
  3. Call `FilesystemService.Read` with path="/tmp/delete-me.txt"
- **Expected**: Remove succeeds, subsequent Read returns error (file not found)

#### TC-118: Stat File
- **Priority**: P1
- **Precondition**: envd running
- **Steps**:
  1. Write /tmp/stat-test.txt with content "12345"
  2. Call `FilesystemService.Stat` with path="/tmp/stat-test.txt"
- **Expected**: Returns size=5, type=file, permissions set

#### TC-119: Watch Directory
- **Priority**: P1
- **Precondition**: envd running
- **Steps**:
  1. Start `FilesystemService.WatchDir` on /tmp/watch-test/
  2. Create file /tmp/watch-test/new.txt
  3. Modify file /tmp/watch-test/new.txt
  4. Delete file /tmp/watch-test/new.txt
- **Expected**: Stream returns create, modify, delete events in order

#### TC-120: Read Non-Existent File
- **Priority**: P0
- **Precondition**: envd running
- **Steps**:
  1. Call `FilesystemService.Read` with path="/nonexistent/path"
- **Expected**: Returns error with appropriate error code (NOT_FOUND)

---

## TC-2xx: Orchestrator (VM Lifecycle)

### Sandbox Create/Delete

#### TC-201: Create Sandbox (Cold Boot)
- **Priority**: P0
- **Precondition**: Orchestrator running on KVM-capable host, base template available
- **Steps**:
  1. Call `SandboxService.Create` with template_id="base", vcpu=1, memory_mb=256
  2. Wait for response
- **Expected**: Returns sandbox_id, client_id, envd_access_token. envd reachable via vsock within 2s.

#### TC-202: Create Sandbox (Snapshot Restore)
- **Priority**: P0
- **Precondition**: Orchestrator running, template snapshot exists in S3
- **Steps**:
  1. Call `SandboxService.Create` with template_id that has pre-built snapshot
  2. Measure time to response
- **Expected**: Sandbox ready in < 200ms, envd health check passes

#### TC-203: Delete Sandbox
- **Priority**: P0
- **Precondition**: Running sandbox exists
- **Steps**:
  1. Call `SandboxService.Delete` with sandbox_id
  2. Verify VM process terminated
  3. Verify TAP device released
  4. Verify rootfs overlay cleaned up
- **Expected**: All resources freed, sandbox no longer in List response

#### TC-204: List Sandboxes
- **Priority**: P0
- **Precondition**: Multiple sandboxes running
- **Steps**:
  1. Create 3 sandboxes
  2. Call `SandboxService.List`
- **Expected**: Response contains all 3 sandboxes with correct IDs and status

#### TC-205: Delete Non-Existent Sandbox
- **Priority**: P1
- **Precondition**: Orchestrator running
- **Steps**:
  1. Call `SandboxService.Delete` with fake sandbox_id
- **Expected**: Returns appropriate error (NOT_FOUND)

### Snapshot/Resume

#### TC-206: Pause Sandbox (Create Snapshot)
- **Priority**: P1
- **Precondition**: Running sandbox with state (files created, processes running)
- **Steps**:
  1. Create sandbox, write file /tmp/state.txt with "before-snapshot"
  2. Call `SandboxService.Pause`
  3. Verify snapshot uploaded to S3
- **Expected**: VM paused, memory + disk snapshot stored in S3

#### TC-207: Resume Sandbox (Restore Snapshot)
- **Priority**: P1
- **Precondition**: Paused sandbox with snapshot in S3
- **Steps**:
  1. Call `SandboxService.Resume` with sandbox_id
  2. Read /tmp/state.txt from envd
- **Expected**: VM resumed, file content is "before-snapshot", processes restored

#### TC-208: Snapshot Restore Preserves Network
- **Priority**: P1
- **Precondition**: Snapshot exists
- **Steps**:
  1. Resume sandbox from snapshot
  2. Execute `curl -s https://httpbin.org/ip` inside VM
- **Expected**: Network connectivity works after restore

### Networking

#### TC-209: TAP Device Allocation
- **Priority**: P0
- **Precondition**: Orchestrator running
- **Steps**:
  1. Create sandbox
  2. Verify TAP device created on host
  3. Verify IP assigned from pool
- **Expected**: TAP device exists, IP in 172.16.x.x range

#### TC-210: Outbound Internet from VM
- **Priority**: P0
- **Precondition**: Sandbox running with allow_internet=true
- **Steps**:
  1. Execute `curl -s https://httpbin.org/ip` inside VM
- **Expected**: Returns JSON with public IP

#### TC-211: Internet Blocked When Disabled
- **Priority**: P1
- **Precondition**: Sandbox running with allow_internet=false
- **Steps**:
  1. Execute `curl -s --max-time 5 https://httpbin.org/ip` inside VM
- **Expected**: Connection times out or is refused

#### TC-212: Network Isolation Between VMs
- **Priority**: P0
- **Precondition**: Two sandboxes running
- **Steps**:
  1. From sandbox A, try to ping sandbox B's IP
  2. From sandbox A, try to connect to sandbox B's envd port
- **Expected**: Both attempts fail (network namespace isolation)

#### TC-213: TAP Device Cleanup on Delete
- **Priority**: P0
- **Precondition**: Sandbox running
- **Steps**:
  1. Note sandbox's TAP device name
  2. Delete sandbox
  3. Check if TAP device exists on host
- **Expected**: TAP device removed

### Resource Management

#### TC-214: CPU Limit Enforced
- **Priority**: P1
- **Precondition**: Sandbox created with vcpu=1
- **Steps**:
  1. Execute CPU-intensive command (`stress --cpu 4 --timeout 5`)
  2. Monitor CPU usage from host
- **Expected**: VM CPU usage capped at ~1 vCPU

#### TC-215: Memory Limit Enforced
- **Priority**: P1
- **Precondition**: Sandbox created with memory_mb=256
- **Steps**:
  1. Execute `python3 -c "x = 'a' * 300_000_000"` (allocate ~300MB)
- **Expected**: Process killed by OOM or allocation fails

#### TC-216: Sandbox Auto-Timeout
- **Priority**: P0
- **Precondition**: Sandbox created with timeout_seconds=10
- **Steps**:
  1. Create sandbox with 10s timeout
  2. Wait 15s
  3. Check sandbox status
- **Expected**: Sandbox automatically destroyed after timeout

#### TC-217: Concurrent Sandbox Creation
- **Priority**: P1
- **Precondition**: Orchestrator running
- **Steps**:
  1. Create 10 sandboxes concurrently
  2. Wait for all to be ready
- **Expected**: All 10 sandboxes created successfully, each with unique network

#### TC-218: IP Pool Exhaustion
- **Priority**: P2
- **Precondition**: Orchestrator configured with small IP pool
- **Steps**:
  1. Create sandboxes until pool is exhausted
  2. Try to create one more
- **Expected**: Returns resource exhaustion error, existing sandboxes unaffected

---

## TC-3xx: API Server

### Authentication

#### TC-301: Valid API Key
- **Priority**: P0
- **Steps**:
  1. `POST /sandboxes` with header `X-API-Key: <valid-key>`
- **Expected**: 200 response with sandbox data

#### TC-302: Invalid API Key
- **Priority**: P0
- **Steps**:
  1. `POST /sandboxes` with header `X-API-Key: invalid-key-123`
- **Expected**: 401 Unauthorized

#### TC-303: Missing API Key
- **Priority**: P0
- **Steps**:
  1. `POST /sandboxes` without X-API-Key header
- **Expected**: 401 Unauthorized

#### TC-304: Health Endpoint (No Auth)
- **Priority**: P0
- **Steps**:
  1. `GET /health` without any auth headers
- **Expected**: 200 OK

### Sandbox CRUD

#### TC-305: Create Sandbox
- **Priority**: P0
- **Steps**:
  1. `POST /sandboxes` with `{"templateID": "base"}`
- **Expected**: 200 with `{sandboxID, clientID, envdAccessToken}`

#### TC-306: Create Sandbox with Options
- **Priority**: P0
- **Steps**:
  1. `POST /sandboxes` with `{"templateID": "base", "vcpu": 2, "memoryMB": 512, "timeoutS": 600, "envVars": {"FOO": "bar"}, "metadata": {"purpose": "test"}}`
- **Expected**: 200 with sandbox created using specified options

#### TC-307: Create Sandbox with Invalid Template
- **Priority**: P1
- **Steps**:
  1. `POST /sandboxes` with `{"templateID": "nonexistent"}`
- **Expected**: 404 Not Found or 400 Bad Request

#### TC-308: List Sandboxes
- **Priority**: P0
- **Steps**:
  1. Create 3 sandboxes
  2. `GET /sandboxes`
- **Expected**: 200 with array of 3 sandbox objects

#### TC-309: Get Sandbox by ID
- **Priority**: P0
- **Steps**:
  1. Create sandbox, note ID
  2. `GET /sandboxes/{id}`
- **Expected**: 200 with sandbox details including metadata

#### TC-310: Delete Sandbox
- **Priority**: P0
- **Steps**:
  1. Create sandbox, note ID
  2. `DELETE /sandboxes/{id}`
  3. `GET /sandboxes/{id}`
- **Expected**: Delete returns 204, subsequent GET returns 404

#### TC-311: Update Sandbox Timeout
- **Priority**: P1
- **Steps**:
  1. Create sandbox with timeout 300s
  2. `PATCH /sandboxes/{id}` with `{"timeoutS": 600}`
  3. `GET /sandboxes/{id}`
- **Expected**: Timeout extended, end_at updated

#### TC-312: Delete Non-Existent Sandbox
- **Priority**: P1
- **Steps**:
  1. `DELETE /sandboxes/fake-id-123`
- **Expected**: 404 Not Found

### Templates

#### TC-313: Create Template
- **Priority**: P0
- **Steps**:
  1. `POST /templates` with `{"dockerfile": "FROM ubuntu:22.04"}`
- **Expected**: 200 with `{templateID, buildID, status: "building"}`

#### TC-314: Get Template Status
- **Priority**: P0
- **Steps**:
  1. Create template, note ID
  2. `GET /templates/{id}`
- **Expected**: 200 with template details including status

#### TC-315: Get Non-Existent Template
- **Priority**: P1
- **Steps**:
  1. `GET /templates/fake-template-id`
- **Expected**: 404 Not Found

#### TC-316: Team Scoping
- **Priority**: P1
- **Steps**:
  1. Create sandbox with Team A's API key
  2. List sandboxes with Team B's API key
- **Expected**: Team B does not see Team A's sandbox

---

## TC-4xx: Client-Proxy

#### TC-401: Route to Correct Sandbox
- **Priority**: P0
- **Precondition**: Sandbox running with known sandboxID and clientID
- **Steps**:
  1. Connect to `{sandboxID}-{clientID}.{domain}:3002`
  2. Send gRPC request to envd
- **Expected**: Connection routed to correct sandbox's envd

#### TC-402: Port Proxy
- **Priority**: P1
- **Precondition**: Sandbox running with a service on port 8080
- **Steps**:
  1. Start HTTP server on port 8080 inside sandbox
  2. Connect to `8080-{sandboxID}.{domain}`
- **Expected**: HTTP request forwarded to sandbox's port 8080

#### TC-403: Invalid Sandbox ID
- **Priority**: P1
- **Steps**:
  1. Connect to `fake-sandbox-id.{domain}:3002`
- **Expected**: Connection refused or error response

#### TC-404: WebSocket Upgrade
- **Priority**: P1
- **Precondition**: Sandbox running
- **Steps**:
  1. Connect via WebSocket to client-proxy
  2. Send streaming process exec request
- **Expected**: WebSocket connection established, streaming works

#### TC-405: Multiple Concurrent Connections
- **Priority**: P1
- **Steps**:
  1. Open 10 concurrent connections to same sandbox through proxy
- **Expected**: All connections work independently

#### TC-406: Connection After Sandbox Delete
- **Priority**: P1
- **Steps**:
  1. Connect to sandbox through proxy (success)
  2. Delete sandbox
  3. Try new connection through proxy
- **Expected**: New connection fails with appropriate error

#### TC-407: envd Auth Through Proxy
- **Priority**: P0
- **Steps**:
  1. Connect through proxy with valid envd Bearer token
  2. Connect through proxy with invalid token
- **Expected**: Valid token succeeds, invalid token returns 401

#### TC-408: Proxy Health Check
- **Priority**: P1
- **Steps**:
  1. Query client-proxy health endpoint
- **Expected**: Returns healthy status

---

## TC-5xx: Template System

#### TC-501: Build Template from Dockerfile
- **Priority**: P0
- **Steps**:
  1. Call template-manager with base Dockerfile
  2. Wait for build to complete
  3. Check template status
- **Expected**: Status transitions: building -> ready. Snapshot uploaded to S3.

#### TC-502: Build Template with Setup Commands
- **Priority**: P1
- **Steps**:
  1. Build template with Dockerfile + setup command `pip install requests`
  2. Create sandbox from template
  3. Execute `python3 -c "import requests; print('ok')"`
- **Expected**: "ok\n" — package available in sandbox

#### TC-503: Template Snapshot Upload to S3
- **Priority**: P0
- **Steps**:
  1. Build template
  2. Check S3 bucket for snapshot files
- **Expected**: Memory snapshot + rootfs snapshot exist in S3

#### TC-504: Template Snapshot Download and Restore
- **Priority**: P0
- **Steps**:
  1. Build template (creates S3 snapshot)
  2. Clear local cache
  3. Create sandbox (triggers S3 download + restore)
- **Expected**: Sandbox boots from downloaded snapshot

#### TC-505: Template Build Failure
- **Priority**: P1
- **Steps**:
  1. Submit template build with invalid Dockerfile (e.g., `FROM nonexistent:latest`)
- **Expected**: Status transitions: building -> failed. Error message captured.

#### TC-506: Multiple Templates
- **Priority**: P1
- **Steps**:
  1. Build base template
  2. Build code-interpreter template
  3. Create sandbox from each
- **Expected**: Both work, sandboxes have correct packages

#### TC-507: Template with Large Rootfs
- **Priority**: P2
- **Steps**:
  1. Build template with large Dockerfile (desktop: ~2GB)
  2. Create sandbox from template
- **Expected**: Build completes, sandbox boots correctly

#### TC-508: Kernel Compatibility
- **Priority**: P0
- **Steps**:
  1. Boot Firecracker VM with vmlinux-6.1.x kernel
  2. Verify envd starts inside VM
- **Expected**: Kernel boots, init script runs, envd reachable

#### TC-509: envd Injection into Rootfs
- **Priority**: P0
- **Steps**:
  1. Build rootfs from Dockerfile
  2. Verify envd binary exists at /usr/local/bin/envd inside rootfs
  3. Verify init script exists at /sbin/init
- **Expected**: Both files present with correct permissions (executable)

#### TC-510: ECR Integration
- **Priority**: P1
- **Steps**:
  1. Push Docker image to ECR
  2. Build template referencing ECR image
- **Expected**: Template build pulls from ECR successfully

---

## TC-6xx: SDK Integration

#### TC-601: Create Sandbox via Python SDK
- **Priority**: P0
- **Steps**:
  ```python
  from e2b import Sandbox
  sandbox = Sandbox.create("base", timeout=300)
  assert sandbox.sandbox_id is not None
  sandbox.kill()
  ```
- **Expected**: Sandbox created and destroyed without error

#### TC-602: Execute Code via SDK
- **Priority**: P0
- **Steps**:
  ```python
  sandbox = Sandbox.create("code-interpreter")
  result = sandbox.run_code('print(1 + 1)')
  assert "2" in result.stdout
  sandbox.kill()
  ```
- **Expected**: stdout contains "2"

#### TC-603: Filesystem Write via SDK
- **Priority**: P0
- **Steps**:
  ```python
  sandbox = Sandbox.create("base")
  sandbox.files.write("/tmp/test.txt", "hello world")
  content = sandbox.files.read("/tmp/test.txt")
  assert content == "hello world"
  sandbox.kill()
  ```
- **Expected**: File written and read back correctly

#### TC-604: Filesystem List via SDK
- **Priority**: P0
- **Steps**:
  ```python
  sandbox = Sandbox.create("base")
  sandbox.files.write("/tmp/sdk-test/a.txt", "a")
  sandbox.files.write("/tmp/sdk-test/b.txt", "b")
  entries = sandbox.files.list("/tmp/sdk-test")
  names = [e.name for e in entries]
  assert "a.txt" in names and "b.txt" in names
  sandbox.kill()
  ```
- **Expected**: Both files listed

#### TC-605: Process Run via SDK
- **Priority**: P0
- **Steps**:
  ```python
  sandbox = Sandbox.create("base")
  proc = sandbox.commands.run("echo SDK_TEST")
  assert proc.exit_code == 0
  assert "SDK_TEST" in proc.stdout
  sandbox.kill()
  ```
- **Expected**: Process completes with correct output

#### TC-606: Sandbox Timeout via SDK
- **Priority**: P1
- **Steps**:
  ```python
  sandbox = Sandbox.create("base", timeout=5)
  import time; time.sleep(10)
  # Try to use sandbox
  try:
      sandbox.commands.run("echo hello")
      assert False, "Should have timed out"
  except Exception:
      pass  # Expected
  ```
- **Expected**: Sandbox auto-destroyed after timeout, subsequent calls fail

#### TC-607: Environment Variables via SDK
- **Priority**: P1
- **Steps**:
  ```python
  sandbox = Sandbox.create("base", env_vars={"MY_VAR": "from_sdk"})
  proc = sandbox.commands.run("echo $MY_VAR")
  assert "from_sdk" in proc.stdout
  sandbox.kill()
  ```
- **Expected**: Environment variable available inside sandbox

#### TC-608: Multiple Sandboxes Concurrently
- **Priority**: P1
- **Steps**:
  ```python
  import concurrent.futures
  def create_and_run(i):
      sb = Sandbox.create("base")
      result = sb.commands.run(f"echo sandbox-{i}")
      sb.kill()
      return result.stdout.strip()

  with concurrent.futures.ThreadPoolExecutor(max_workers=5) as ex:
      results = list(ex.map(create_and_run, range(5)))
  assert len(set(results)) == 5  # All unique
  ```
- **Expected**: 5 sandboxes run concurrently without interference

#### TC-609: SDK Custom Domain
- **Priority**: P0
- **Steps**:
  ```python
  import os
  os.environ["E2B_DOMAIN"] = "e2b.ourcompany.com"
  os.environ["E2B_API_KEY"] = "<our-key>"
  sandbox = Sandbox.create("base")
  assert sandbox is not None
  sandbox.kill()
  ```
- **Expected**: SDK connects to our self-hosted API server

#### TC-610: SDK Error Handling - Invalid Template
- **Priority**: P1
- **Steps**:
  ```python
  try:
      sandbox = Sandbox.create("nonexistent-template")
      assert False
  except Exception as e:
      assert "not found" in str(e).lower() or "404" in str(e)
  ```
- **Expected**: Clear error message about template not found

#### TC-611: SDK Error Handling - Auth Failure
- **Priority**: P1
- **Steps**:
  ```python
  os.environ["E2B_API_KEY"] = "invalid-key"
  try:
      sandbox = Sandbox.create("base")
      assert False
  except Exception as e:
      assert "unauthorized" in str(e).lower() or "401" in str(e)
  ```
- **Expected**: Clear auth error

#### TC-612: SDK Streaming Output
- **Priority**: P1
- **Steps**:
  ```python
  sandbox = Sandbox.create("base")
  output_chunks = []
  proc = sandbox.commands.run(
      "for i in 1 2 3; do echo $i; sleep 1; done",
      on_stdout=lambda chunk: output_chunks.append(chunk)
  )
  assert len(output_chunks) >= 3  # Received streaming chunks
  sandbox.kill()
  ```
- **Expected**: Output received incrementally, not all at once

---

## TC-7xx: Infrastructure (Terraform/Nomad)

#### TC-701: Terraform Validate
- **Priority**: P0
- **Steps**:
  1. `cd aws/terraform && terraform init && terraform validate`
- **Expected**: "Success! The configuration is valid."

#### TC-702: Terraform Plan (Dry Run)
- **Priority**: P0
- **Steps**:
  1. Set required variables (region, domain, key_name, ami_id, db creds)
  2. `terraform plan`
- **Expected**: Plan shows expected resources without errors

#### TC-703: Terraform Apply
- **Priority**: P0
- **Steps**:
  1. `terraform apply -auto-approve`
- **Expected**: All resources created successfully

#### TC-704: Nomad Server Cluster Health
- **Priority**: P0
- **Steps**:
  1. SSH to bastion -> SSH to server node
  2. `nomad server members`
- **Expected**: 3 servers in "alive" state, 1 leader

#### TC-705: Consul Cluster Health
- **Priority**: P0
- **Steps**:
  1. `consul members`
- **Expected**: All nodes (server + client + api) registered

#### TC-706: RDS Connectivity
- **Priority**: P0
- **Steps**:
  1. From bastion/API node: `psql -h <rds-endpoint> -U <user> -d e2b`
- **Expected**: PostgreSQL connection established

#### TC-707: Redis Connectivity
- **Priority**: P0
- **Steps**:
  1. From server node: `redis-cli -h <redis-endpoint> ping`
- **Expected**: Returns "PONG"

#### TC-708: ALB HTTPS
- **Priority**: P0
- **Steps**:
  1. `curl https://api.e2b.example.com/health`
- **Expected**: Returns 200 with valid TLS certificate

#### TC-709: Nomad Job Deployment
- **Priority**: P0
- **Steps**:
  1. Submit all Nomad jobs (api, orchestrator, client-proxy, template-manager)
  2. `nomad job status`
- **Expected**: All jobs show "running" with healthy allocations

#### TC-710: Auto Scaling Group
- **Priority**: P1
- **Steps**:
  1. Verify client ASG has desired_count instances
  2. Terminate one instance
  3. Wait for replacement
- **Expected**: ASG launches replacement instance automatically

---

## TC-8xx: Security

#### TC-801: VM Isolation - No Cross-VM Access
- **Priority**: P0
- **Steps**:
  1. Create sandbox A and sandbox B
  2. From A, try to reach B's IP via ping/curl
- **Expected**: Connection fails (network namespace isolation)

#### TC-802: envd Rejects Unauthenticated Requests
- **Priority**: P0
- **Steps**:
  1. Connect to envd gRPC without Bearer token
  2. Call ProcessService.Exec
- **Expected**: Returns UNAUTHENTICATED error

#### TC-803: envd Rejects Wrong Token
- **Priority**: P0
- **Steps**:
  1. Connect to envd with Bearer token "wrong-token"
  2. Call ProcessService.Exec
- **Expected**: Returns UNAUTHENTICATED error

#### TC-804: API Rejects Invalid API Key
- **Priority**: P0
- **Steps**:
  1. `POST /sandboxes` with `X-API-Key: invalid`
- **Expected**: 401 Unauthorized

#### TC-805: Sandbox Cannot Access Host Services
- **Priority**: P0
- **Steps**:
  1. From inside sandbox, try to access host's Nomad API (port 4646)
  2. From inside sandbox, try to access host's Consul API (port 8500)
- **Expected**: Both connections fail

#### TC-806: Sandbox Cannot Access RDS Directly
- **Priority**: P1
- **Steps**:
  1. From inside sandbox, try to connect to RDS endpoint (port 5432)
- **Expected**: Connection fails (security group blocks VM IPs)

#### TC-807: Jailer Restrictions
- **Priority**: P1
- **Steps**:
  1. Create sandbox
  2. Verify Firecracker process runs in chroot
  3. Verify seccomp filter applied
  4. Verify cgroup limits set
- **Expected**: All Jailer restrictions active

#### TC-808: Bastion SSH Access
- **Priority**: P1
- **Steps**:
  1. SSH to bastion from allowed CIDR -> success
  2. SSH to bastion from non-allowed IP -> blocked
  3. SSH from bastion to server/client/api nodes -> success
  4. SSH directly to server/client/api from internet -> blocked
- **Expected**: Only bastion accessible from outside, internal nodes via bastion only

#### TC-809: Security Group Rules
- **Priority**: P0
- **Steps**:
  1. Verify ALB SG: only 80/443 from 0.0.0.0/0
  2. Verify server SG: Nomad/Consul ports from VPC only
  3. Verify client SG: orchestrator ports from VPC only
  4. Verify DB SG: 5432 from server/client/api/bastion SGs only
  5. Verify Redis SG: 6379 from server/client/api SGs only
- **Expected**: All rules match specification

#### TC-810: No Secrets in Logs
- **Priority**: P1
- **Steps**:
  1. Check API server logs for API key values
  2. Check orchestrator logs for envd access tokens
- **Expected**: Secrets never logged in plaintext

#### TC-811: Secrets Manager Access
- **Priority**: P1
- **Steps**:
  1. EC2 instances can read secrets via IAM role
  2. Non-EC2 entities cannot access secrets
- **Expected**: IAM policy correctly scoped

#### TC-812: S3 Bucket Access
- **Priority**: P1
- **Steps**:
  1. Verify S3 buckets are not publicly accessible
  2. Verify EC2 instances can read/write via IAM role
- **Expected**: Private buckets, IAM-based access only

---

## TC-9xx: Performance

#### TC-901: Cold Boot Time
- **Priority**: P1
- **Steps**:
  1. Measure time from `SandboxService.Create` call to envd health check passing
  2. Run 10 times, compute average
- **Expected**: Average < 2s

#### TC-902: Snapshot Restore Time
- **Priority**: P0
- **Steps**:
  1. Measure time from Create (snapshot-based) to envd ready
  2. Run 10 times, compute average
- **Expected**: Average < 200ms

#### TC-903: Process Exec Latency
- **Priority**: P1
- **Steps**:
  1. In a running sandbox, measure time for `echo hello` roundtrip
  2. Run 100 times, compute p50/p95/p99
- **Expected**: p50 < 20ms, p99 < 100ms

#### TC-904: Filesystem Read Latency
- **Priority**: P1
- **Steps**:
  1. Write 1KB file, measure read latency
  2. Run 100 times, compute p50/p95/p99
- **Expected**: p50 < 5ms, p99 < 50ms

#### TC-905: Filesystem Write Latency
- **Priority**: P1
- **Steps**:
  1. Measure write latency for 1KB file
  2. Run 100 times, compute p50/p95/p99
- **Expected**: p50 < 10ms, p99 < 100ms

#### TC-906: Concurrent Sandbox Limit
- **Priority**: P1
- **Steps**:
  1. Create sandboxes until failure or degradation
  2. Record max count and resource usage at each step
- **Expected**: 50+ sandboxes on c5.2xlarge before degradation

#### TC-907: Memory Usage per Sandbox
- **Priority**: P2
- **Steps**:
  1. Measure host memory before/after creating 10 sandboxes (256MB each)
  2. Calculate per-sandbox overhead
- **Expected**: < 10MB overhead per sandbox beyond configured memory

#### TC-908: Template Build Time
- **Priority**: P2
- **Steps**:
  1. Measure time to build base template (Dockerfile -> snapshot in S3)
- **Expected**: < 5 minutes for base template

---

## TC-10xx: Desktop/Browser Templates

#### TC-1001: Desktop Template Boot
- **Priority**: P1
- **Steps**:
  1. Create sandbox from desktop template
  2. Verify Xvfb running inside VM
  3. Verify XFCE desktop started
  4. Verify VNC server running
- **Expected**: Desktop environment fully started

#### TC-1002: VNC Access via noVNC
- **Priority**: P1
- **Steps**:
  1. Create desktop sandbox
  2. Connect to noVNC WebSocket URL (port 6080)
  3. Verify desktop visible in browser
- **Expected**: Desktop rendered in browser via WebSocket

#### TC-1003: Screenshot Capture
- **Priority**: P1
- **Steps**:
  1. Create desktop sandbox
  2. Take screenshot via SDK
  3. Verify image is valid PNG with non-zero size
- **Expected**: Valid PNG screenshot of desktop

#### TC-1004: Mouse Click
- **Priority**: P1
- **Steps**:
  1. Create desktop sandbox
  2. Move mouse to known position (e.g., desktop icon)
  3. Click
  4. Take screenshot
- **Expected**: Screenshot shows effect of click (e.g., icon selected)

#### TC-1005: Keyboard Input
- **Priority**: P1
- **Steps**:
  1. Create desktop sandbox
  2. Open text editor (via mouse or command)
  3. Type "hello world" via SDK
  4. Take screenshot
- **Expected**: Text visible in editor

#### TC-1006: Browser Launch
- **Priority**: P1
- **Steps**:
  1. Create desktop sandbox
  2. Execute `firefox --no-remote about:blank &` inside VM
  3. Wait 5s
  4. Take screenshot
- **Expected**: Firefox window visible in screenshot

#### TC-1007: Browser-Use Template
- **Priority**: P1
- **Steps**:
  1. Create sandbox from browser-use template
  2. Execute headless Chrome navigation script
- **Expected**: Script executes, page content accessible

#### TC-1008: Desktop Sandbox Cleanup
- **Priority**: P1
- **Steps**:
  1. Create and kill desktop sandbox
  2. Verify all resources freed (VM, TAP, rootfs)
- **Expected**: Clean deletion, no resource leaks

---

## Test Execution Order

### Smoke Tests (Run First)
TC-101, TC-113, TC-120, TC-201, TC-203, TC-301, TC-302, TC-304, TC-305, TC-310, TC-601

### Core Functionality
TC-102 through TC-112, TC-114 through TC-119, TC-202 through TC-218, TC-306 through TC-316

### Integration
TC-401 through TC-408, TC-501 through TC-510, TC-602 through TC-612

### Infrastructure
TC-701 through TC-710

### Security
TC-801 through TC-812

### Performance
TC-901 through TC-908

### Desktop/Browser
TC-1001 through TC-1008

---

## Test Environment Requirements

| Requirement | Details |
|-------------|---------|
| EC2 Instance | c5.metal or c8i.4xlarge (KVM support) |
| OS | Ubuntu 22.04 LTS |
| Firecracker | v1.7.0 + jailer |
| Kernel | vmlinux-6.1.102 |
| Go | 1.21+ |
| Docker | Docker CE latest |
| PostgreSQL | 15 (local or RDS) |
| Redis | 7.0 (local or ElastiCache) |
| Python | 3.10+ (for SDK tests) |
| Node.js | 18+ (for JS SDK tests) |
| Network | Internet access for template builds |
