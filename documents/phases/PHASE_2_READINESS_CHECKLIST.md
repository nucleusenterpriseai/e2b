# Phase 2: Orchestrator Readiness Checklist

Saved from orchestrator code exploration. See full details in the agent output.

## Quick Reference: Minimum Env Vars to Start Orchestrator

```bash
# Required
NODE_ID=dev-001
NODE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
ORCHESTRATOR_SERVICES=orchestrator
STORAGE_PROVIDER=AWSBucket

# Paths (must exist on disk)
ORCHESTRATOR_BASE_PATH=/orchestrator
SANDBOX_DIR=/fc-vm
HOST_KERNELS_DIR=/fc-kernels
FIRECRACKER_VERSIONS_DIR=/fc-versions
HOST_ENVD_PATH=/fc-envd/envd
SANDBOX_CACHE_DIR=/orchestrator/sandbox-cache
SNAPSHOT_CACHE_DIR=/mnt/snapshot-cache
TEMPLATE_CACHE_DIR=/orchestrator/template-cache

# Network
GRPC_PORT=5008
PROXY_PORT=5007
ALLOW_SANDBOX_INTERNET=true

# Optional (graceful fallbacks when empty)
# CLICKHOUSE_CONNECTION_STRING=
# LAUNCH_DARKLY_API_KEY=
# REDIS_URL=
# OTEL_COLLECTOR_GRPC_ENDPOINT=
# LOGS_COLLECTOR_ADDRESS=
```

## Host Prerequisites

1. **Kernel module**: `modprobe nbd nbds_max=4096`
2. **Directories**: `/orchestrator`, `/fc-vm`, `/fc-kernels`, `/fc-versions`, `/fc-envd`, `/mnt/snapshot-cache`
3. **Binaries**: firecracker, jailer, vmlinux kernel, envd
4. **Permissions**: Must run as root (iptables, namespaces, cgroups)
5. **Packages**: iproute2, iptables, util-linux (unshare)
6. **KVM**: `/dev/kvm` accessible

## Key Findings

- OTEL_COLLECTOR_GRPC_ENDPOINT and LOGS_COLLECTOR_ADDRESS are marked `required` in config — may need to be made optional (like we did for LOKI_URL)
- Orchestrator needs ~10 subsystems running concurrently (proxy, firewall, NBD pool, network pool, etc.)
- Network uses veth pairs + TAP devices in dedicated namespaces (not just simple TAP)
- NBD devices used for rootfs mounting (not direct file mount) — requires kernel module
- Template caching uses P2P via Redis for multi-node setups
