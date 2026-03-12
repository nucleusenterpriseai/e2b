# E2B Base Template
# Ubuntu 22.04 with Python3, Node.js, and common development tools
#
# This is the default template used when no specific template is requested.
# The envd binary and init script are injected by the template-manager during
# the Firecracker rootfs build process.

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# Install system packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Core utilities
    curl \
    wget \
    git \
    sudo \
    ca-certificates \
    gnupg \
    lsb-release \
    unzip \
    zip \
    jq \
    vim \
    nano \
    htop \
    net-tools \
    iputils-ping \
    dnsutils \
    openssh-client \
    # Build essentials
    build-essential \
    gcc \
    g++ \
    make \
    # Python 3
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    # Networking
    socat \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 20.x LTS from NodeSource
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g npm@latest

# Verify installations
RUN python3 --version && pip3 --version && node --version && npm --version && git --version

# Create default user with passwordless sudo
RUN useradd -m -s /bin/bash user \
    && echo "user ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

USER user
WORKDIR /home/user
