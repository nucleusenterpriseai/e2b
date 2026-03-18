# E2B Self-Hosted — Single Node

Firecracker-based sandbox platform on a single bare-metal EC2 instance.
Each sandbox is an isolated microVM with its own filesystem, network, and processes.

## Architecture

```
Your App (Python/JS/curl)
  |
  |  REST API (port 80)          — sandbox lifecycle (create/list/delete)
  |  Sandbox Proxy (port 5007)   — SDK ↔ envd communication (commands, files, streams)
  v
┌──────────────────────────────────────────┐
│  EC2 bare-metal (c6g.metal)              │
│                                          │
│  API Server (:80)                        │
│  Orchestrator (:5008 gRPC, :5007 proxy)  │
│  PostgreSQL + Redis (Docker)             │
│                                          │
│  ┌────────┐ ┌────────┐ ┌────────┐       │
│  │ VM 1   │ │ VM 2   │ │ VM N   │       │
│  │ envd   │ │ envd   │ │ envd   │       │
│  │ (app)  │ │ (app)  │ │ (app)  │       │
│  └────────┘ └────────┘ └────────┘       │
│       Firecracker microVMs               │
└──────────────────────────────────────────┘
```

## Quick Start

### 1. Deploy

```bash
cd aws/terraform/single-node
cp terraform.tfvars.example terraform.tfvars   # edit with your values
terraform init
terraform apply
```

With pre-built AMI: ~1 min. From scratch: ~15 min.

### 2. Get connection info

```bash
# SSH to instance
ssh -i ~/.ssh/<key>.pem ubuntu@<public-ip>

# Get API key
sudo cat /opt/e2b/api-key
```

### 3. Use from your application

Set these environment variables:

```bash
export E2B_API_KEY="e2b_..."                       # from /opt/e2b/api-key
export E2B_API_URL="http://<public-ip>:80"         # API endpoint
export E2B_SANDBOX_URL="http://<public-ip>:5007"   # sandbox proxy
```

For HTTPS, put an ALB or nginx in front (see [HTTPS Setup](#https-setup) below).

---

## Usage — Python SDK

```bash
pip install e2b
```

### Create a sandbox and run commands

```python
from e2b import Sandbox

# Create sandbox (default timeout: 5 min)
sandbox = Sandbox.create(
    template="base",                              # or "desktop"
    api_url="http://<ip>:80",
    sandbox_url="http://<ip>:5007",
    timeout=300,                                  # seconds (max 24h)
    secure=False,
)

# Run a command
result = sandbox.commands.run("echo hello world")
print(result.stdout)   # "hello world\n"
print(result.exit_code) # 0

# Run Python
result = sandbox.commands.run("python3 -c 'print(2+2)'")
print(result.stdout)   # "4\n"

# Install packages and run
sandbox.commands.run("pip install requests")
result = sandbox.commands.run("python3 -c 'import requests; print(requests.get(\"https://httpbin.org/ip\").json())'")
print(result.stdout)

# Kill sandbox when done
sandbox.kill()
```

### File operations

```python
# Write a file
sandbox.files.write("/home/user/script.py", "print('hello from file')")

# Read a file
content = sandbox.files.read("/home/user/script.py")

# List directory
entries = sandbox.files.list("/home/user")
for entry in entries:
    print(f"  {entry.name}  {'dir' if entry.is_dir else 'file'}")

# Run the script you wrote
result = sandbox.commands.run("python3 /home/user/script.py")
print(result.stdout)  # "hello from file\n"
```

### Background processes

```python
# Start a long-running process
proc = sandbox.commands.run("python3 -m http.server 8080", background=True)

# Do other work...
result = sandbox.commands.run("curl -s http://localhost:8080")
print(result.stdout)
```

### Context manager (auto-cleanup)

```python
with Sandbox.create(template="base", api_url="http://<ip>:80", sandbox_url="http://<ip>:5007") as sandbox:
    result = sandbox.commands.run("whoami")
    print(result.stdout)
# sandbox is automatically killed when exiting the block
```

### Desktop sandbox (browser, screenshot)

```python
sandbox = Sandbox.create(
    template="desktop",
    api_url="http://<ip>:80",
    sandbox_url="http://<ip>:5007",
    timeout=600,
)

# Wait for desktop to start
import time
time.sleep(30)

# Launch Firefox
sandbox.commands.run(
    'DISPLAY=:99 firefox-esr "https://example.com" &',
    background=True,
)
time.sleep(10)

# Take screenshot
sandbox.commands.run("DISPLAY=:99 scrot /tmp/screenshot.png")

# Download screenshot
png_bytes = sandbox.files.read("/tmp/screenshot.png", format="bytes")
with open("screenshot.png", "wb") as f:
    f.write(png_bytes)

sandbox.kill()
```

---

## Usage — REST API (curl)

### Create a sandbox

```bash
curl -X POST http://<ip>:80/sandboxes \
  -H "X-API-Key: e2b_..." \
  -H "Content-Type: application/json" \
  -d '{
    "templateID": "base",
    "timeout": 300
  }'
```

Response:

```json
{
  "sandboxID": "i1abc2def3ghi",
  "clientID": "...",
  "envdAccessToken": "..."
}
```

### List running sandboxes

```bash
curl http://<ip>:80/sandboxes \
  -H "X-API-Key: e2b_..."
```

### Delete a sandbox

```bash
curl -X DELETE http://<ip>:80/sandboxes/<sandboxID> \
  -H "X-API-Key: e2b_..."
```

### Extend timeout (keep alive)

```bash
curl -X POST http://<ip>:80/sandboxes/<sandboxID>/timeout \
  -H "X-API-Key: e2b_..." \
  -H "Content-Type: application/json" \
  -d '{"timeout": 600}'
```

---

## Sandbox Lifecycle & Auto-Termination

```
create (timeout=30s)
  |
  v
RUNNING ──── timeout expires ──── KILLED (auto)
  ^                                  ^
  |── refresh (keep alive) ─────────|  (resets countdown)
  |                                  |
  |── manual kill ───────────────────|
```

### How it works

- Every sandbox has a **timeout countdown** (default: 15s if not specified).
- The SDK automatically sends **refresh** calls (`POST /sandboxes/<id>/refreshes`) to reset the countdown.
- When your app stops refreshing (e.g. WebSocket disconnects, crash), the countdown expires and the sandbox is killed.
- This is **the built-in disconnect detection mechanism** — no custom idle detection needed.

### Auto-terminate on disconnect (recommended pattern)

Create the sandbox with a **short timeout** (e.g. 30s). Your app sends keep-alive refreshes every ~10s while the user's WebSocket is connected. When the WebSocket drops, refreshes stop, and the sandbox auto-terminates in 30s.

```python
import threading
import time
from e2b import Sandbox

class SandboxSession:
    """Manages a sandbox tied to a WebSocket connection."""

    def __init__(self, api_url, sandbox_url, api_key, timeout=30):
        self.timeout = timeout
        self.sandbox = Sandbox.create(
            template="base",
            api_url=api_url,
            sandbox_url=sandbox_url,
            timeout=timeout,
            secure=False,
        )
        self._alive = True
        self._refresh_thread = threading.Thread(target=self._keep_alive, daemon=True)
        self._refresh_thread.start()

    def _keep_alive(self):
        """Send refresh every timeout/3 seconds while session is active."""
        interval = max(self.timeout // 3, 5)
        while self._alive:
            try:
                self.sandbox.set_timeout(self.timeout)
            except Exception:
                break
            time.sleep(interval)

    def on_websocket_disconnect(self):
        """Stop refreshing — sandbox auto-terminates after timeout."""
        self._alive = False
        # Don't call sandbox.kill() — let it timeout naturally
        # This handles cases where disconnect is temporary

    def on_websocket_reconnect(self):
        """Resume refreshing if sandbox is still alive."""
        self._alive = True
        self._refresh_thread = threading.Thread(target=self._keep_alive, daemon=True)
        self._refresh_thread.start()

    def kill(self):
        """Immediately kill sandbox."""
        self._alive = False
        try:
            self.sandbox.kill()
        except Exception:
            pass
```

### Timeline example

```
t=0s   App creates sandbox (timeout=30s)
t=10s  App refreshes → timeout resets to 30s from now
t=20s  App refreshes → timeout resets to 30s from now
t=25s  WebSocket disconnects → app stops refreshing
t=55s  Sandbox auto-terminates (30s after last refresh)
```

### Timeout values

| Setting | Value |
|---------|-------|
| Default (SDK, no param) | 15 seconds |
| Recommended for WS-tied | 30 seconds |
| Long-running tasks | 300-3600 seconds |
| Max | 24 hours (tier limit) |
| Minimum | 0 (kills immediately) |

### Refresh endpoint (keep alive)

```bash
# Reset timeout countdown (extends sandbox life by <duration> seconds)
curl -X POST http://<ip>:80/sandboxes/<sandboxID>/refreshes \
  -H "X-API-Key: e2b_..." \
  -H "Content-Type: application/json" \
  -d '{"duration": 30}'
```

### Examples

```python
# Create with 30s timeout (auto-terminates if no refresh)
sandbox = Sandbox.create(template="base", timeout=30, ...)

# Extend timeout (SDK method)
sandbox.set_timeout(30)  # 30 more seconds from now

# Kill immediately
sandbox.kill()
```

### What happens on termination

1. Firecracker VM process is killed
2. Network (TAP device, iptables rules) is cleaned up
3. Rootfs overlay is deleted
4. Resources (CPU, memory, network slot) are returned to the pool

---

## Available Templates

| Template | Description | RAM | Use case |
|----------|-------------|-----|----------|
| `base` | Ubuntu 22.04, Python 3, Node.js, git, curl | 512 MB | General code execution |
| `desktop` | base + XFCE + Firefox + VNC + screenshot tools | 2048 MB | Browser automation, CUA |

---

## HTTPS Setup

For production, put nginx or an ALB in front:

### Option A: nginx on the instance

```bash
sudo apt install -y nginx certbot python3-certbot-nginx

sudo cat > /etc/nginx/sites-available/e2b <<'EOF'
server {
    listen 443 ssl;
    server_name e2b.yourdomain.com;

    ssl_certificate     /etc/letsencrypt/live/e2b.yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/e2b.yourdomain.com/privkey.pem;

    # API
    location / {
        proxy_pass http://127.0.0.1:80;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    # Sandbox proxy (WebSocket support)
    location /ws {
        proxy_pass http://127.0.0.1:5007;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

sudo ln -s /etc/nginx/sites-available/e2b /etc/nginx/sites-enabled/
sudo certbot --nginx -d e2b.yourdomain.com
sudo systemctl reload nginx
```

Then use:

```python
sandbox = Sandbox.create(
    template="base",
    api_url="https://e2b.yourdomain.com",
    sandbox_url="https://e2b.yourdomain.com",
)
```

### Option B: AWS ALB

Add an ALB with ACM certificate in Terraform. Route by path:
- `/*` → target group port 80 (API)
- WebSocket upgrade → target group port 5007 (sandbox proxy)

---

## Integration Example — Replace k8s Pods

If your application currently spawns k8s pods for code execution, replace with E2B:

### Before (k8s)

```python
# Slow: 10-30s pod startup, shared cluster resources
from kubernetes import client
v1 = client.CoreV1Api()
pod = v1.create_namespaced_pod(namespace="default", body={...})
# wait for pod ready...
# exec into pod...
# cleanup pod...
```

### After (E2B)

```python
# Fast: ~500ms sandbox creation, full VM isolation
from e2b import Sandbox

sandbox = Sandbox.create(
    template="base",
    api_url="http://<e2b-ip>:80",
    sandbox_url="http://<e2b-ip>:5007",
    timeout=300,
)
result = sandbox.commands.run("python3 -c 'print(42)'")
print(result.stdout)  # "42\n"
sandbox.kill()
```

### Key differences from k8s

| Feature | k8s Pod | E2B Sandbox |
|---------|---------|-------------|
| Startup time | 10-30s | ~500ms |
| Isolation | namespace/cgroup | full microVM (Firecracker) |
| Security | shared kernel | separate kernel per sandbox |
| Max concurrent | limited by cluster | 350+ per bare-metal node |
| Cleanup | pod deletion (slow) | instant VM kill |
| Filesystem | ephemeral or PVC | ephemeral (per-sandbox) |
| Network | pod network | isolated TAP + NAT |

---

## Capacity (c6g.metal — 64 vCPU, 128 GB RAM)

| Template | Max concurrent | Create time |
|----------|---------------|-------------|
| base (512 MB) | ~350 | ~500ms |
| desktop (2 GB) | ~60 | ~500ms |
| playwright (384 MB) | ~350 | ~500ms |

---

## Terraform Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `region` | `ap-southeast-1` | AWS region |
| `instance_type` | `c6g.metal` | Must be bare-metal (KVM support) |
| `use_spot` | `true` | Use spot instance (~70% cheaper) |
| `volume_size` | `200` | EBS volume in GB |
| `key_name` | — | EC2 key pair name (required) |
| `ami_override` | `""` | Pre-built AMI ID. Empty = stock Ubuntu full setup (~20 min) |
| `e2b_repo_url` | `""` | Git URL of your e2b fork (required for stock Ubuntu) |
| `e2b_repo_ref` | `""` | Branch or tag to clone (commit SHAs not supported) |
| `infra_repo_url` | `https://github.com/e2b-dev/infra.git` | Git URL of the infra repo fork |
| `infra_repo_ref` | `main` | Branch or tag of infra repo |
| `kernel_url` | `""` | HTTPS URL for kernel binary. Empty = downloads from GitHub release |
| `fc_version` | `v1.12.1` | Firecracker version |
| `fc_commit` | `a41d3fb` | Firecracker commit hash |
| `kernel_version` | `vmlinux-6.1.158` | Kernel version identifier |
| `go_version` | `1.25.4` | Go toolchain version |

### Minimal terraform.tfvars for stock Ubuntu deploy

```hcl
region        = "ap-southeast-1"
key_name      = "your-ec2-keypair"
instance_type = "c6g.metal"
use_spot      = true
volume_size   = 200
ami_override  = ""

# Required for stock Ubuntu — these repos contain the setup scripts and platform code
e2b_repo_url   = "https://github.com/your-org/e2b.git"
e2b_repo_ref   = "main"
infra_repo_url = "https://github.com/your-org/infra.git"
infra_repo_ref = "feat/standard-firecracker-arm64"
```

> **Note**: Changing any of these variables triggers instance replacement (`user_data_replace_on_change = true`).

---

## What Bootstrap Does (12 steps)

The stock Ubuntu setup (`ec2-setup.sh`) runs automatically via user-data:

1. Install system packages (git, build-essential, etc.)
2. Install Docker
3. Install Go
4. Create data directories
5. Configure HugePages
6. Kernel tuning + install Firecracker networking helper
7. Start Docker services (PostgreSQL, Redis, Docker Registry)
8. Clone and build E2B infrastructure (orchestrator, API, envd, create-build)
9. Download Firecracker binary and kernel
10. Run database migrations + seed data + generate API key
11. Start E2B services (orchestrator, API) via systemd
12. Build base + desktop templates (stops orchestrator, runs create-build, restarts)

Total time: ~20 minutes on c6g.metal.

---

## Operations

```bash
# SSH to instance
ssh -i ~/.ssh/<key>.pem ubuntu@<ip>

# View logs
sudo tail -f /var/log/api.log
sudo tail -f /var/log/orchestrator.log
sudo tail -f /var/log/e2b-setup.log    # bootstrap log

# Restart services
sudo /opt/e2b/restart-services.sh

# Check health
curl http://localhost:80/health

# See API key
sudo cat /opt/e2b/api-key

# Service management
sudo systemctl status e2b-orchestrator e2b-api e2b-network
sudo journalctl -u e2b-orchestrator -f
sudo journalctl -u e2b-api -f

# Check template status
sudo docker exec e2b-postgres psql -U e2b -d e2b \
  -c "SELECT env_id, status, status_group FROM env_builds;"
```

---

## Troubleshooting

### Bootstrap fails at step 11 (services)

Check `/var/log/e2b-setup.log` for the exact error. Common causes:
- **grep pipefail**: If no stale iptables rules exist on a fresh node, the cleanup `grep` returns exit 1 under `set -o pipefail`. This is fixed in current code.
- **Missing systemd unit files**: The setup checks both `$E2B_HOME/aws/packer/setup/` and `$E2B_HOME/custom/aws/packer/setup/` for service files.

### Template build fails with "context deadline exceeded"

- The default build timeout is 5 minutes. The setup uses `-timeout 15`.
- Check if the orchestrator is stopped before create-build runs — both bind the same ports.

### Template build fails with "Kernel panic - error -8"

The embedded busybox binary doesn't match the host architecture. The setup runs `infra/scripts/fetch-busybox.sh` to pull the correct arch binary before building.

### Template build fails with "Unable to locate package"

The TCP firewall proxy is intercepting build sandbox traffic. Verify the orchestrator is stopped during template builds (ec2-setup.sh stops it in step 12).

### API health check fails after restart

The API takes 15-20 seconds to initialize (cluster discovery, node sync). Wait and retry.

### "failed to find sandbox for connection" in orchestrator.log

The TCP firewall proxy received traffic from a sandbox that isn't registered in its map. This happens when the orchestrator and create-build run simultaneously (port conflict).

### DNS not working inside sandboxes

Check `/etc/resolv.conf` in the sandbox — it should contain `nameserver 8.8.8.8` (or the value of `E2B_DNS_NAMESERVER` env var). Verify the E2B iptables chains are active:

```bash
sudo iptables -L E2B-FORWARD -n
sudo iptables -t nat -L E2B-POSTROUTING -n
```

---

## Environment Variables

### Orchestrator (`/opt/e2b/orchestrator.env`)

| Variable | Description |
|----------|-------------|
| `NODE_ID` | Node identifier |
| `POSTGRES_CONNECTION_STRING` | PostgreSQL connection URL |
| `REDIS_URL` | Redis address |
| `GRPC_PORT` | Orchestrator gRPC port (default: 5008) |
| `PROXY_PORT` | Sandbox proxy port (default: 5007) |
| `E2B_DNS_NAMESERVER` | DNS nameserver for sandboxes (default: 8.8.8.8) |
| `STORAGE_PROVIDER` | `Local` or `GCS` |

### API (`/opt/e2b/api.env`)

| Variable | Description |
|----------|-------------|
| `API_PORT` | HTTP listen port (default: 3000, mapped to 80) |
| `ORCHESTRATOR_ADDRESS` | Orchestrator gRPC address |
| `ADMIN_TOKEN` | Admin API token |
| `DEFAULT_KERNEL_VERSION` | Kernel version for new sandboxes |
