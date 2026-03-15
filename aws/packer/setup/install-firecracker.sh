#!/usr/bin/env bash
set -euo pipefail

# Install Firecracker and Jailer from official GitHub releases
# Supports both x86_64 and aarch64 (ARM64/Graviton)

FIRECRACKER_VERSION="${FIRECRACKER_VERSION:-1.12.1}"

# Auto-detect architecture from Packer env var or uname
if [ -n "${TARGET_ARCH:-}" ]; then
  case "$TARGET_ARCH" in
    arm64|aarch64) ARCH="aarch64" ;;
    x86_64|amd64)  ARCH="x86_64"  ;;
    *) echo "ERROR: unsupported TARGET_ARCH=$TARGET_ARCH"; exit 1 ;;
  esac
else
  ARCH=$(uname -m)
fi

echo "==> Installing Firecracker v${FIRECRACKER_VERSION}"

RELEASE_URL="https://github.com/firecracker-microvm/firecracker/releases/download/v${FIRECRACKER_VERSION}/firecracker-v${FIRECRACKER_VERSION}-${ARCH}.tgz"

# Download and extract Firecracker release
cd /tmp
curl -fsSL "${RELEASE_URL}" -o "firecracker-v${FIRECRACKER_VERSION}-${ARCH}.tgz"
tar xzf "firecracker-v${FIRECRACKER_VERSION}-${ARCH}.tgz"

RELEASE_DIR="release-v${FIRECRACKER_VERSION}-${ARCH}"

# Install binaries
sudo install -o root -g root -m 0755 "${RELEASE_DIR}/firecracker-v${FIRECRACKER_VERSION}-${ARCH}" /usr/local/bin/firecracker
sudo install -o root -g root -m 0755 "${RELEASE_DIR}/jailer-v${FIRECRACKER_VERSION}-${ARCH}" /usr/local/bin/jailer

# Clean up
rm -rf "/tmp/firecracker-v${FIRECRACKER_VERSION}-${ARCH}.tgz" "/tmp/${RELEASE_DIR}"

# Create directories used by Firecracker VMs
sudo mkdir -p /fc-vm
sudo mkdir -p /fc-versions
sudo mkdir -p /fc-kernels
sudo mkdir -p /fc-envd

# Create a versioned directory for this Firecracker release
sudo mkdir -p "/fc-versions/v${FIRECRACKER_VERSION}"
sudo ln -sf /usr/local/bin/firecracker "/fc-versions/v${FIRECRACKER_VERSION}/firecracker"
sudo ln -sf /usr/local/bin/jailer "/fc-versions/v${FIRECRACKER_VERSION}/jailer"

echo "==> Firecracker installed successfully"
firecracker --version
jailer --version
