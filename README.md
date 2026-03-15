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

```bash
cd aws/terraform/single-node
cp terraform.tfvars.example terraform.tfvars  # edit with your values
terraform init && terraform apply
```

Then:

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
  ├── main.tf                   # EC2 instance, security group
  ├── user-data.sh              # Boot script (AMI or fresh)
  ├── ec2-setup.sh              # Full platform setup (12 steps)
  ├── README.md                 # Detailed usage guide
  └── terraform.tfvars.example

aws/terraform/                  # Multi-node deployment (WIP)
aws/packer/                     # AMI builder
aws/db/                         # DB migrations + seed
aws/nomad/                      # Nomad job definitions

templates/                      # Sandbox template Dockerfiles
tests/                          # Integration + performance tests
scripts/                        # Setup and build scripts
documents/                      # Design docs
```

## Documentation

- **[Single-Node Deployment Guide](aws/terraform/single-node/README.md)** — full setup, SDK usage, REST API, auto-termination, HTTPS, k8s migration
- **[Desktop Template Dockerfile](templates/desktop.Dockerfile)** — browser automation template

## Requirements

- AWS account with EC2 bare-metal access (c6g.metal or equivalent)
- Terraform >= 1.0
- EC2 key pair in target region

## License

Apache License 2.0 — see [LICENSE](LICENSE).

Built on [e2b-dev/infra](https://github.com/e2b-dev/infra) (Apache 2.0).
