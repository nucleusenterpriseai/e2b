#!/usr/bin/env bash
set -euo pipefail

# Install Docker CE from official Docker repository
# Pinned to Docker CE 24.x stable channel

DOCKER_VERSION="5:24.0.9-1~ubuntu.22.04~jammy"

echo "==> Installing Docker CE ${DOCKER_VERSION}"

# Add Docker's official GPG key (idempotent)
if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
fi

# Set up the Docker repository (idempotent)
if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
fi

sudo apt-get update -y

# Install Docker CE, CLI, and containerd
sudo apt-get install -y \
    docker-ce="${DOCKER_VERSION}" \
    docker-ce-cli="${DOCKER_VERSION}" \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

# Hold Docker packages at pinned version
sudo apt-mark hold docker-ce docker-ce-cli

# Enable and start Docker
sudo systemctl enable docker
sudo systemctl start docker

# Add ubuntu user to docker group for Nomad access
sudo usermod -aG docker ubuntu

# Configure Docker daemon
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json > /dev/null <<'DAEMON_JSON'
{
    "storage-driver": "overlay2",
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "50m",
        "max-file": "5"
    },
    "default-ulimits": {
        "nofile": {
            "Name": "nofile",
            "Hard": 65536,
            "Soft": 65536
        }
    },
    "live-restore": true
}
DAEMON_JSON

sudo systemctl restart docker

echo "==> Docker installed successfully"
docker --version
