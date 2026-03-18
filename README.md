# E2B Self-Hosted

Self-hosted [E2B](https://github.com/e2b-dev/infra) sandbox platform on AWS. Run isolated code execution environments using Firecracker microVMs — each sandbox gets its own kernel, filesystem, and network in ~500ms.

Built on top of the open-source [e2b-dev/infra](https://github.com/e2b-dev/infra) (Apache 2.0).

## Why

- **Fast**: Sandbox creation in ~500ms (vs 10-30s for k8s pods)
- **Secure**: Each sandbox is a full Firecracker microVM with its own Linux kernel
- **Dense**: 350+ concurrent sandboxes on a single bare-metal node
- **Simple**: One `terraform apply` — zero manual steps
- **Compatible**: Works with the official [E2B Python/JS SDK](https://pypi.org/project/e2b/)

## Architecture

```
Your App (Python/JS/curl)
  |
  |  REST API (:80)           — create / list / delete sandboxes
  |  Sandbox Proxy (:5007)    — SDK <-> envd (commands, files, streams)
  v
┌──────────────────────────────────────────────┐
│  EC2 bare-metal (c6g.metal)                  │
│                                              │
│  API Server    Orchestrator    PostgreSQL     │
│  (:80)         (:5008 gRPC)    Redis         │
│                (:5007 proxy)                 │
│                                              │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐        │
│  │  VM 1   │ │  VM 2   │ │  VM N   │  ...   │
│  │  envd   │ │  envd   │ │  envd   │        │
│  └─────────┘ └─────────┘ └─────────┘        │
│        Firecracker microVMs (up to 350+)     │
└──────────────────────────────────────────────┘
```

## Quick Start

### 1. Configure and deploy

```bash
cd aws/terraform/single-node
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` — at minimum set:

```hcl
key_name       = "your-ec2-keypair"
e2b_repo_url   = "https://github.com/your-org/e2b.git"
e2b_repo_ref   = "main"
infra_repo_url = "https://github.com/your-org/infra.git"
infra_repo_ref = "feat/standard-firecracker-arm64"
```

Then:

```bash
terraform init && terraform apply
```

Bootstrap takes ~20 minutes (stock Ubuntu). Watch progress:

```bash
ssh -i ~/.ssh/<key>.pem ubuntu@<ip> 'tail -f /var/log/e2b-setup.log'
```

### 2. Get your API key

```bash
ssh -i ~/.ssh/<key>.pem ubuntu@<ip> 'sudo cat /opt/e2b/api-key'
```

### 3. Use from your application

```bash
pip install e2b
```

```python
from e2b import Sandbox

sandbox = Sandbox.create(
    template="base",
    api_url="http://<ec2-ip>:80",
    sandbox_url="http://<ec2-ip>:5007",
    timeout=300,
)

result = sandbox.commands.run("echo hello world")
print(result.stdout)  # "hello world\n"

sandbox.files.write("/tmp/test.py", "print('from sandbox')")
result = sandbox.commands.run("python3 /tmp/test.py")
print(result.stdout)  # "from sandbox\n"

sandbox.kill()
```

## Sandbox Auto-Termination

Sandboxes auto-terminate when the timeout countdown expires. The SDK sends periodic refresh calls to keep it alive. When your app stops refreshing (WebSocket disconnect, crash), the sandbox dies automatically.

```
t=0s   Create sandbox (timeout=30s)
t=10s  Refresh → resets to 30s from now
t=20s  Refresh → resets to 30s from now
t=25s  App disconnects → no more refreshes
t=55s  Sandbox auto-killed (30s after last refresh)
```

## Templates

| Template | Description | RAM |
|----------|-------------|-----|
| `base` | Ubuntu 22.04, Python 3, Node.js, git, curl | 512 MB |
| `desktop` | base + XFCE + Firefox + VNC + screenshot tools | 2 GB |

## Capacity (c6g.metal — 64 vCPU, 128 GB)

| Template | Max concurrent | Create time |
|----------|---------------|-------------|
| base (512 MB) | ~350 | ~500ms |
| desktop (2 GB) | ~60 | ~500ms |
| playwright (384 MB) | ~350 | ~500ms |

Tested: 60 concurrent desktop sandboxes each running Firefox + screenshot — 60/60 pass, 56s total.

## Replacing k8s Pods

| | k8s Pod | E2B Sandbox |
|---|---------|-------------|
| Startup | 10-30s | ~500ms |
| Isolation | namespace/cgroup | full microVM |
| Security | shared kernel | separate kernel |
| Max concurrent | cluster-limited | 350+ per node |
| Cleanup | slow pod delete | instant VM kill |

## Project Structure

```
aws/terraform/single-node/     # Terraform deployment (start here)
  ├── main.tf                   # EC2 instance, security group, variables
  ├── user-data.sh              # Boot script (AMI fast path or stock Ubuntu)
  ├── ec2-setup.sh              # Full platform setup (12 steps)
  ├── README.md                 # Detailed usage guide + troubleshooting
  └── terraform.tfvars.example  # Example configuration

aws/packer/setup/              # AMI builder + systemd units
  ├── e2b-orchestrator.service  # Orchestrator systemd unit
  ├── e2b-api.service           # API systemd unit
  ├── e2b-network.service       # Firecracker networking (iptables)
  └── setup-firecracker-networking.sh

aws/db/                         # API key generator
templates/                      # Sandbox template Dockerfiles
infra/                          # E2B platform (git submodule)
```

## Documentation

- **[Single-Node Deployment Guide](aws/terraform/single-node/README.md)** — full setup, SDK usage, REST API, auto-termination, HTTPS, troubleshooting
- **[Desktop Template Dockerfile](templates/desktop.Dockerfile)** — browser automation template

## Requirements

- AWS account with EC2 bare-metal access (`c6g.metal` for ARM64, or `c5.metal` for x86)
- Terraform >= 1.0
- EC2 key pair in target region
- A fork of this repo and [nucleusenterpriseai/infra](https://github.com/nucleusenterpriseai/infra) (or use ours directly)

## Upstream Fork

This project is built on top of [e2b-dev/infra](https://github.com/e2b-dev/infra) (Apache 2.0), forked at commit [`5c6a1de`](https://github.com/e2b-dev/infra/commit/5c6a1de19).

Our fork lives at [nucleusenterpriseai/infra](https://github.com/nucleusenterpriseai/infra) (branch `feat/standard-firecracker-arm64`) and is included as a git submodule under `infra/`.

**Changes from upstream:**
- Standard Firecracker v1.12.x support (upstream uses a custom fork)
- ARM64 (Graviton) compatibility (arch-aware busybox via `fetch-busybox.sh`)
- Configurable DNS nameserver (`E2B_DNS_NAMESERVER` env var)
- UFFD write-protect auto-detection
- Scoped iptables chains (`E2B-FORWARD`, `E2B-POSTROUTING`) — safe restart without breaking Docker
- Scaling improvements (`MaxSandboxesPerNode`, `maxStartingInstances`)
- ECR support for docker-reverse-proxy
- Sandbox expiry loop fix
- Proper systemd units with dependency ordering

To sync upstream updates:

```bash
cd infra
git remote add upstream https://github.com/e2b-dev/infra.git  # once
git fetch upstream && git merge upstream/main
cd .. && git add infra && git commit -m "chore: sync upstream infra"
```

## License

Apache License 2.0 — see [LICENSE](LICENSE).
