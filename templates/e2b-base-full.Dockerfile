# =============================================================================
# E2B Base Full Dockerfile
# =============================================================================
# Builds a base image with all packages pre-installed that the orchestrator's
# provision.sh needs. This avoids requiring internet access during Firecracker
# VM provisioning, which is critical because:
#
#   1. Firecracker VMs may not have internet access during the provisioning
#      phase (before networking is fully configured).
#   2. Even when internet is available, downloading packages during every build
#      is slow and flaky.
#
# The package list here MUST match the PACKAGES variable in:
#   infra/packages/orchestrator/internal/template/build/phases/base/provision.sh
#
# Usage:
#   docker build -f e2b-base-full.Dockerfile -t e2b-base-full:latest .
# =============================================================================

FROM e2bdev/base:latest

# Install all packages that provision.sh expects to find pre-installed.
# This is the same list as PACKAGES in provision.sh:
#   systemd systemd-sysv openssh-server sudo chrony socat curl
#   ca-certificates fuse3 iptables git nfs-common
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    systemd systemd-sysv openssh-server sudo chrony socat ca-certificates \
    fuse3 iptables git nfs-common curl && \
    apt-get clean && rm -rf /var/lib/apt/lists/*
