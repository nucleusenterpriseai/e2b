# E2B Desktop Template
# Ubuntu 22.04 with XFCE desktop, VNC, and browser
#
# Provides a full graphical desktop environment accessible via VNC/noVNC.
# Used for browser automation, GUI testing, and visual tasks.
#
# Ports:
#   5900 - VNC (x11vnc)
#   6080 - noVNC (websocket proxy for browser access)

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# Install desktop environment and VNC
RUN apt-get update && apt-get install -y --no-install-recommends \
    # X11 and display server
    xvfb \
    x11-utils \
    x11-xserver-utils \
    # XFCE desktop environment
    xfce4 \
    xfce4-goodies \
    xfce4-terminal \
    # VNC server and web client
    x11vnc \
    novnc \
    websockify \
    # Browser
    firefox-esr \
    # Office suite (lightweight)
    libreoffice-calc \
    libreoffice-writer \
    libreoffice-impress \
    # Screen capture and automation
    xdotool \
    scrot \
    ffmpeg \
    imagemagick \
    # Fonts
    fonts-noto-cjk \
    fonts-liberation \
    fonts-dejavu-core \
    fonts-ubuntu \
    # D-Bus (required for XFCE)
    dbus-x11 \
    at-spi2-core \
    # Development tools
    python3 \
    python3-pip \
    curl \
    wget \
    git \
    sudo \
    ca-certificates \
    # Utilities
    file \
    xclip \
    && rm -rf /var/lib/apt/lists/*

# Create desktop startup script
RUN cat > /usr/local/bin/start-desktop.sh <<'STARTUP' && chmod +x /usr/local/bin/start-desktop.sh
#!/bin/bash
set -e

# Configure display
export DISPLAY=:99
export RESOLUTION="${RESOLUTION:-1920x1080x24}"

# Start Xvfb (virtual framebuffer)
echo "Starting Xvfb on display ${DISPLAY} with resolution ${RESOLUTION}"
Xvfb ${DISPLAY} -screen 0 ${RESOLUTION} -ac +extension GLX +render -noreset &
XVFB_PID=$!
sleep 2

# Start D-Bus session
eval $(dbus-launch --sh-syntax)
export DBUS_SESSION_BUS_ADDRESS

# Start XFCE desktop
echo "Starting XFCE desktop"
startxfce4 &
sleep 3

# Start VNC server (no password, listen on all interfaces)
echo "Starting x11vnc on port 5900"
x11vnc -display ${DISPLAY} -forever -nopw -listen 0.0.0.0 -rfbport 5900 -shared &
X11VNC_PID=$!

# Start noVNC websocket proxy
echo "Starting noVNC on port 6080"
websockify --web /usr/share/novnc 6080 localhost:5900 &
NOVNC_PID=$!

echo "Desktop environment ready"
echo "  VNC: port 5900"
echo "  noVNC: port 6080"

# Wait for any process to exit
wait -n ${XVFB_PID} ${X11VNC_PID} ${NOVNC_PID}
STARTUP

# Create default user with passwordless sudo
RUN useradd -m -s /bin/bash user \
    && echo "user ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

USER user
WORKDIR /home/user

# Set display for user session
ENV DISPLAY=:99
