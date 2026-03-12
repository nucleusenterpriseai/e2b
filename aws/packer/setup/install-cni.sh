#!/usr/bin/env bash
set -euo pipefail

# Install CNI plugins for Nomad and Firecracker networking
# Pinned to CNI plugins v1.4.1

CNI_VERSION="1.4.1"
CNI_DIR="/opt/cni/bin"
ARCH="amd64"

echo "==> Installing CNI plugins v${CNI_VERSION}"

# Create CNI directories
sudo mkdir -p "${CNI_DIR}"
sudo mkdir -p /etc/cni/net.d

# Download and install CNI plugins
DOWNLOAD_URL="https://github.com/containernetworking/plugins/releases/download/v${CNI_VERSION}/cni-plugins-linux-${ARCH}-v${CNI_VERSION}.tgz"

curl -fsSL "${DOWNLOAD_URL}" -o /tmp/cni-plugins.tgz
sudo tar xzf /tmp/cni-plugins.tgz -C "${CNI_DIR}"
rm -f /tmp/cni-plugins.tgz

# Set proper permissions
sudo chmod -R 755 "${CNI_DIR}"

# Verify installation
echo "==> Installed CNI plugins:"
ls -la "${CNI_DIR}/"

# Install tc-redirect-tap plugin for Firecracker (part of the AWS tc-redirect-tap project)
# This plugin is used to redirect traffic from a TAP device to a container network namespace
TC_REDIRECT_TAP_VERSION="0.0.2"

# tc-redirect-tap is typically built from source; we download a prebuilt binary if available
# or the orchestrator handles TAP setup natively. For now, ensure the base CNI plugins are present.

# Configure CNI for Nomad
sudo tee /etc/cni/net.d/10-e2b-bridge.conflist > /dev/null <<'CNI_CONFIG'
{
    "cniVersion": "1.0.0",
    "name": "e2b-bridge",
    "plugins": [
        {
            "type": "bridge",
            "bridge": "nomad-bridge",
            "isGateway": true,
            "ipMasq": true,
            "ipam": {
                "type": "host-local",
                "ranges": [
                    [
                        {
                            "subnet": "172.26.64.0/20"
                        }
                    ]
                ],
                "routes": [
                    {
                        "dst": "0.0.0.0/0"
                    }
                ]
            }
        },
        {
            "type": "firewall"
        },
        {
            "type": "portmap",
            "capabilities": {
                "portMappings": true
            }
        }
    ]
}
CNI_CONFIG

echo "==> CNI plugins installed successfully"
