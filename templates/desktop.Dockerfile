# E2B Desktop Template
# Extends e2bdev/base with XFCE desktop, VNC, and browser
#
# Provides a full graphical desktop environment accessible via VNC/noVNC.
# Used for browser automation, GUI testing, and visual tasks.
#
# Ports:
#   5900 - VNC (x11vnc)
#   6080 - noVNC (websocket proxy for browser access)
#
# Build: docker build -f templates/desktop.Dockerfile -t desktop:latest .
# The template build pipeline uses create-build with -from-image pointing here.

FROM e2bdev/base:latest

ENV DEBIAN_FRONTEND=noninteractive

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
    # Screen capture and automation
    xdotool \
    scrot \
    ffmpeg \
    imagemagick \
    # Fonts
    fonts-noto-cjk \
    fonts-liberation \
    fonts-dejavu-core \
    fonts-freefont-ttf \
    # D-Bus (required for XFCE)
    dbus-x11 \
    at-spi2-core \
    # Utilities
    file \
    xclip \
    && rm -rf /var/lib/apt/lists/*

# Create desktop startup script using printf (heredocs don't work in Docker RUN)
RUN printf '%s\n' \
    '#!/bin/bash' \
    'set -e' \
    '' \
    'export DISPLAY=:99' \
    'export RESOLUTION="${RESOLUTION:-1920x1080x24}"' \
    '' \
    'echo "Starting Xvfb on display ${DISPLAY} with resolution ${RESOLUTION}"' \
    'Xvfb ${DISPLAY} -screen 0 ${RESOLUTION} -ac +extension GLX +render -noreset &' \
    'XVFB_PID=$!' \
    'sleep 2' \
    '' \
    'eval $(dbus-launch --sh-syntax)' \
    'export DBUS_SESSION_BUS_ADDRESS' \
    '' \
    'echo "Starting XFCE desktop"' \
    'startxfce4 &' \
    'sleep 3' \
    '' \
    'echo "Starting x11vnc on port 5900"' \
    'x11vnc -display ${DISPLAY} -forever -nopw -listen 0.0.0.0 -rfbport 5900 -shared &' \
    'X11VNC_PID=$!' \
    '' \
    'echo "Starting noVNC on port 6080"' \
    'websockify --web /usr/share/novnc 6080 localhost:5900 &' \
    'NOVNC_PID=$!' \
    '' \
    'echo "Desktop environment ready"' \
    'echo "  VNC: port 5900"' \
    'echo "  noVNC: port 6080"' \
    '' \
    'wait -n ${XVFB_PID} ${X11VNC_PID} ${NOVNC_PID}' \
    > /usr/local/bin/start-desktop.sh \
    && chmod +x /usr/local/bin/start-desktop.sh

# Set display for all sessions
ENV DISPLAY=:99
