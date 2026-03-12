# E2B Browser Use Template
# Ubuntu 22.04 with Chromium and Playwright for browser automation
#
# Optimized for headless browser automation tasks including
# web scraping, testing, and AI-driven browser interaction.

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# Install system packages and Chromium
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    wget \
    git \
    sudo \
    ca-certificates \
    gnupg \
    # Python 3
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    # Chromium and dependencies
    chromium-browser \
    # X11 for headed mode (optional)
    xvfb \
    x11-utils \
    # Fonts for proper page rendering
    fonts-noto-cjk \
    fonts-liberation \
    fonts-dejavu-core \
    fonts-ubuntu \
    fonts-freefont-ttf \
    # Media codecs
    libavcodec-extra \
    # Shared libraries required by Chromium/Playwright
    libnss3 \
    libnspr4 \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libcups2 \
    libdrm2 \
    libdbus-1-3 \
    libxkbcommon0 \
    libxcomposite1 \
    libxdamage1 \
    libxfixes3 \
    libxrandr2 \
    libgbm1 \
    libpango-1.0-0 \
    libcairo2 \
    libasound2 \
    libatspi2.0-0 \
    && rm -rf /var/lib/apt/lists/*

# Install Playwright and browser automation tools
RUN pip3 install --no-cache-dir \
    playwright \
    beautifulsoup4 \
    lxml \
    requests \
    httpx \
    Pillow \
    pyyaml

# Install Playwright system dependencies and browsers
RUN playwright install-deps \
    && playwright install chromium

# Create helper script for headless browser
RUN cat > /usr/local/bin/start-browser.sh <<'BROWSER' && chmod +x /usr/local/bin/start-browser.sh
#!/bin/bash
# Start Xvfb for headed mode if needed
if [ "${HEADLESS:-true}" = "false" ]; then
    export DISPLAY=:99
    Xvfb :99 -screen 0 1920x1080x24 -ac &
    sleep 1
fi
exec "$@"
BROWSER

# Set Chromium flags for running in sandbox environment
ENV CHROMIUM_FLAGS="--no-sandbox --disable-gpu --disable-dev-shm-usage --disable-setuid-sandbox"

# Create default user with passwordless sudo
RUN useradd -m -s /bin/bash user \
    && echo "user ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

USER user
WORKDIR /home/user
