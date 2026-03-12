# Phase 2: Orchestrator — Firecracker VM Manager

**Duration**: 4 days
**Depends on**: Phase 1
**Status**: Not Started

---

## Objective

Verify the orchestrator builds on Linux, boots Firecracker VMs with envd inside, manages TAP networking, and performs snapshot create/restore. Minimal code changes (set `STORAGE_PROVIDER=AWSBucket`).

## PRD (Phase 2)

### What the Orchestrator Does
The orchestrator is the core VM manager running on Firecracker host nodes. It runs ~10 concurrent subsystems:
- **Sandbox Manager**: Create/delete/pause/resume Firecracker VMs via `firecracker-go-sdk`
- **Network Pool**: Pre-allocate TAP devices + IPs (172.16.x.x range)
- **Rootfs Manager**: OverlayFS setup (read-only base + writable upper)
- **Template Cache**: Download snapshots from S3, cache locally
- **Sandbox Proxy**: HTTP reverse proxy on port 5007 (bridges vsock to HTTP)
- **NBD Pool**: Network Block Devices for rootfs mounting
- **gRPC Server**: SandboxService on port 5008
- **TCP Firewall**: Hostname-based egress filtering
- **Cgroup Manager**: Host-level resource management
- **Template Manager**: (optionally co-located) Template build pipeline

### What We're Delivering
- Orchestrator binary built on Linux
- Firecracker VM boot with envd reachable via vsock
- TAP networking: VM has internet access
- Snapshot create + restore cycle verified
- S3 storage path confirmed working

### What We're NOT Changing
- No code changes to orchestrator (use `STORAGE_PROVIDER=AWSBucket` env var)
- Firecracker SDK usage stays as-is
- Network pool code stays as-is
- All features controlled via env vars and LaunchDarkly fallbacks

### Key Config Env Vars
```bash
STORAGE_PROVIDER=AWSBucket
TEMPLATE_BUCKET_NAME=<s3-bucket>
GRPC_PORT=5008
PROXY_PORT=5007
FIRECRACKER_VERSIONS_DIR=/fc-versions
HOST_KERNELS_DIR=/fc-kernels
ORCHESTRATOR_BASE_PATH=/orchestrator
SANDBOX_DIR=/fc-vm
ALLOW_SANDBOX_INTERNET=true
NODE_IP=<instance-private-ip>
ORCHESTRATOR_SERVICES=orchestrator
# Don't set these (graceful fallbacks):
# CLICKHOUSE_CONNECTION_STRING
# LAUNCH_DARKLY_API_KEY
```

### Success Criteria
- Orchestrator binary builds on Linux
- Firecracker VM boots with base rootfs + envd
- envd reachable via vsock from host
- TAP networking: VM can `curl https://httpbin.org/ip`
- Snapshot create + restore works
- Snapshot restore < 200ms

## Dev Plan

### 2.1 Set Up Linux Build Environment (Day 1, 2 hours)

Option A: Use the dev EC2 instance (t3.small for building, metal for testing):
```bash
# On t3.small (build-only, no KVM needed)
sudo apt-get update && sudo apt-get install -y golang-go git
cd /home/ubuntu && git clone <our-repo>
cd infra/packages/orchestrator
go build -o orchestrator .
```

Option B: Cross-compile on macOS won't work (userfaultfd Linux syscalls). Must build on Linux.

### 2.2 Prepare Firecracker Host (Day 1, 4 hours)

On a metal instance (c5.metal or equivalent):
```bash
# Install Firecracker
FCVER=v1.7.0
curl -L https://github.com/firecracker-microvm/firecracker/releases/download/${FCVER}/firecracker-${FCVER}-x86_64.tgz | tar xz
sudo mv release-${FCVER}-x86_64/firecracker-${FCVER}-x86_64 /usr/local/bin/firecracker
sudo mv release-${FCVER}-x86_64/jailer-${FCVER}-x86_64 /usr/local/bin/jailer

# Verify KVM
ls -la /dev/kvm
sudo setfacl -m u:${USER}:rw /dev/kvm

# Download kernel
curl -L -o /opt/fc/vmlinux-6.1.102 <firecracker-kernel-url>

# Install CNI plugins
sudo mkdir -p /opt/cni/bin
curl -L https://github.com/containernetworking/plugins/releases/download/v1.3.0/cni-plugins-linux-amd64-v1.3.0.tgz | sudo tar xz -C /opt/cni/bin
```

### 2.3 Build Base Rootfs (Day 1-2, 4 hours)

Create minimal ext4 rootfs with envd injected:
```bash
# Create ext4 image
dd if=/dev/zero of=rootfs.ext4 bs=1M count=512
mkfs.ext4 rootfs.ext4

# Mount and populate from Docker
docker export $(docker create ubuntu:22.04) | sudo tar xf - -C /mnt/rootfs

# Inject envd binary
sudo cp envd /mnt/rootfs/usr/local/bin/envd
sudo chmod +x /mnt/rootfs/usr/local/bin/envd

# Create init script
sudo tee /mnt/rootfs/sbin/init-envd << 'EOF'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
ip addr add 172.16.0.2/24 dev eth0
ip link set eth0 up
ip route add default via 172.16.0.1
/usr/local/bin/envd -port 49983 -isnotfc &
exec /bin/sh
EOF
sudo chmod +x /mnt/rootfs/sbin/init-envd
```

### 2.4 Manual Firecracker Boot Test (Day 2, 2 hours)

Before testing the orchestrator, verify Firecracker works directly:
```bash
# Start Firecracker
firecracker --api-sock /tmp/fc-test.sock

# Configure via API (separate terminal)
curl --unix-socket /tmp/fc-test.sock -X PUT http://localhost/boot-source \
  -d '{"kernel_image_path": "/opt/fc/vmlinux-6.1.102", "boot_args": "console=ttyS0 init=/sbin/init-envd"}'

curl --unix-socket /tmp/fc-test.sock -X PUT http://localhost/drives/rootfs \
  -d '{"drive_id": "rootfs", "path_on_host": "rootfs.ext4", "is_root_device": true}'

curl --unix-socket /tmp/fc-test.sock -X PUT http://localhost/machine-config \
  -d '{"vcpu_count": 1, "mem_size_mib": 256}'

# Start VM
curl --unix-socket /tmp/fc-test.sock -X PUT http://localhost/actions -d '{"action_type": "InstanceStart"}'
```

### 2.5 Test Orchestrator (Day 2-3, 8 hours)

Start the orchestrator with S3 storage:
```bash
export STORAGE_PROVIDER=AWSBucket
export TEMPLATE_BUCKET_NAME=e2b-dev-fc-templates
export NODE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
export ORCHESTRATOR_SERVICES=orchestrator

./orchestrator
```

Test via gRPC:
```bash
# Use grpcurl or a Go test client
grpcurl -plaintext localhost:5008 orchestrator.SandboxService/List
grpcurl -plaintext -d '{"template_id":"base","sandbox_id":"test-001","vcpu":1,"memory_mb":256}' \
  localhost:5008 orchestrator.SandboxService/Create
```

### 2.6 Network Verification (Day 3, 2 hours)

After sandbox creation:
```bash
# Verify TAP device exists
ip link show | grep tap

# From inside VM (via vsock or serial console)
curl -s https://httpbin.org/ip  # Should return public IP
ping 8.8.8.8                    # Should work
```

### 2.7 Snapshot Test (Day 3-4, 4 hours)

```bash
# Create sandbox, write state file, pause (creates snapshot)
grpcurl -plaintext -d '{"sandbox_id":"test-001"}' \
  localhost:5008 orchestrator.SandboxService/Pause

# Verify snapshot in S3
aws s3 ls s3://e2b-dev-fc-templates/snapshots/

# Resume and verify state preserved
grpcurl -plaintext -d '{"sandbox_id":"test-001"}' \
  localhost:5008 orchestrator.SandboxService/Resume

# Verify file still exists inside VM
```

### 2.8 Run Existing Tests (Day 4, 2 hours)

```bash
cd /Users/mingli/projects/e2b/infra/packages/orchestrator
go test ./... -v -count=1 -short
```

## Test Cases (Phase 2)

### P0 (Must Pass)

| ID | Test | Expected |
|---|---|---|
| O2-01 | Build orchestrator on Linux | Binary produced |
| O2-02 | Firecracker VM boots with kernel + rootfs | VM starts, serial console accessible |
| O2-03 | envd reachable inside VM | ConnectRPC responds on vsock |
| O2-04 | Exec command via envd through vsock | stdout returned correctly |
| O2-05 | TAP device created for VM | `ip link` shows tapN |
| O2-06 | VM has outbound internet | `curl httpbin.org` works from VM |
| O2-07 | SandboxService.Create via gRPC | Returns sandbox_id |
| O2-08 | SandboxService.Delete via gRPC | VM terminated, TAP cleaned up |
| O2-09 | SandboxService.List via gRPC | Lists running sandboxes |

### P1 (Should Pass)

| ID | Test | Expected |
|---|---|---|
| O2-10 | Snapshot create (Pause) | Memory + disk snapshot created |
| O2-11 | Snapshot restore (Resume) | VM resumes, envd reachable |
| O2-12 | Snapshot restore < 200ms | Measured latency under threshold |
| O2-13 | State preserved after restore | File written before pause readable after resume |
| O2-14 | Network works after restore | VM can reach internet post-resume |
| O2-15 | Multiple concurrent VMs | 3+ VMs with unique IPs |
| O2-16 | VM-to-VM isolation | Sandbox A cannot reach sandbox B |
| O2-17 | TAP cleanup on delete | TAP device removed |
| O2-18 | S3 template download | Orchestrator fetches template from S3 |

## Instance Requirements

**For building (no KVM needed):**
- t3.small or any Linux instance
- 2GB RAM, 20GB disk
- Go 1.25+ installed

**For Firecracker testing (KVM required):**
- Bare metal instance (c5.metal, m5.metal, etc.)
- Ubuntu 22.04
- `/dev/kvm` accessible
- 200GB+ disk for rootfs overlays
- IAM role with S3 access

## Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Metal instance cost | High | Use spot pricing, spin up only for testing |
| Firecracker version incompatibility | Medium | Pin to v1.7.0, match upstream |
| UFFD not supported on kernel | High | Use Firecracker-provided kernel |
| S3 auth from EC2 | Low | Use IAM instance profile |

## Deliverables
- [ ] Orchestrator Linux binary
- [ ] Firecracker VM boot verified with envd
- [ ] TAP networking verified
- [ ] Snapshot create/restore verified
- [ ] S3 storage path verified
- [ ] Test results documented
