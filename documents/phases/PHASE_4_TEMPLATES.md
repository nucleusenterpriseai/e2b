# Phase 4: Template System

**Duration**: 4 days
**Depends on**: Phase 2 (orchestrator), Phase 3 (API + DB)
**Status**: Not Started

---

## Objective

Get the template build pipeline working: Dockerfile -> Docker image -> ext4 rootfs -> Firecracker boot -> snapshot -> S3 upload. Create base and desktop template Dockerfiles.

## PRD (Phase 4)

### How Template Building Works
The template-manager (optionally co-located with orchestrator via `ORCHESTRATOR_SERVICES=orchestrator,template-manager`) handles:

1. **Receive build request** via gRPC `TemplateService.TemplateCreate`
2. **Pull Docker image** from ECR (or build from Dockerfile)
3. **Extract filesystem** layers -> create ext4 rootfs
4. **Inject envd** binary + init script into rootfs
5. **Boot Firecracker VM** with rootfs + kernel
6. **Wait for envd** health check (confirms VM is working)
7. **Run setup commands** (optional provisioning)
8. **Snapshot VM** (memory + disk state)
9. **Upload snapshot to S3** (`STORAGE_PROVIDER=AWSBucket`)
10. **Update template status** in PostgreSQL -> "ready"

### What We're Delivering
- Template build pipeline working end-to-end
- Base template: Ubuntu 22.04 + Python3 + Node.js + git
- Desktop template: Ubuntu 22.04 + Xvfb + XFCE + VNC + browser
- Snapshots stored in S3
- Snapshot restore creates sandbox in < 200ms

### What We're NOT Changing
- Template-manager code stays as-is
- Set `STORAGE_PROVIDER=AWSBucket` for S3
- Docker-reverse-proxy handles ECR auth

### Key Config Env Vars (Template Manager)
```bash
ORCHESTRATOR_SERVICES=orchestrator,template-manager
STORAGE_PROVIDER=AWSBucket
TEMPLATE_BUCKET_NAME=e2b-dev-fc-templates
DOCKER_REGISTRY=<account>.dkr.ecr.<region>.amazonaws.com
# Docker auth handled by docker-reverse-proxy or IAM role
```

### Success Criteria
- Template build from Dockerfile succeeds
- Snapshot uploaded to S3
- Sandbox created from snapshot in < 200ms
- Base template: `echo hello` works
- Desktop template: VNC accessible

## Dev Plan

### 4.1 Create Template Dockerfiles (Day 1, 4 hours)

**`templates/base.Dockerfile`**:
```dockerfile
FROM ubuntu:22.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl wget git sudo ca-certificates \
    python3 python3-pip python3-venv \
    nodejs npm \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash user && echo "user ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
USER user
WORKDIR /home/user
```

**`templates/code-interpreter.Dockerfile`**:
```dockerfile
FROM ubuntu:22.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl wget git sudo ca-certificates \
    python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --no-cache-dir \
    numpy pandas matplotlib scipy requests jupyter ipykernel

RUN useradd -m -s /bin/bash user && echo "user ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
USER user
WORKDIR /home/user
```

**`templates/desktop.Dockerfile`**:
```dockerfile
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    xvfb xfce4 xfce4-goodies x11vnc novnc websockify \
    firefox-esr libreoffice \
    xdotool scrot ffmpeg imagemagick \
    fonts-noto-cjk fonts-liberation \
    python3 python3-pip curl wget git sudo ca-certificates \
    dbus-x11 \
    && rm -rf /var/lib/apt/lists/*

# VNC startup script
RUN echo '#!/bin/bash\n\
Xvfb :99 -screen 0 1920x1080x24 &\n\
sleep 1\n\
export DISPLAY=:99\n\
startxfce4 &\n\
x11vnc -display :99 -forever -nopw -listen 0.0.0.0 -rfbport 5900 &\n\
websockify --web /usr/share/novnc 6080 localhost:5900 &\n\
wait' > /usr/local/bin/start-desktop.sh && chmod +x /usr/local/bin/start-desktop.sh

RUN useradd -m -s /bin/bash user && echo "user ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
USER user
WORKDIR /home/user
```

**`templates/browser-use.Dockerfile`**:
```dockerfile
FROM ubuntu:22.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl wget git sudo ca-certificates \
    python3 python3-pip python3-venv \
    chromium-browser \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --no-cache-dir playwright && playwright install-deps

RUN useradd -m -s /bin/bash user && echo "user ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
USER user
WORKDIR /home/user
```

### 4.2 Push Base Image to ECR (Day 1, 2 hours)

```bash
# Auth to ECR
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <account>.dkr.ecr.us-east-1.amazonaws.com

# Build and push
docker build -t e2b-base -f templates/base.Dockerfile .
docker tag e2b-base:latest <account>.dkr.ecr.us-east-1.amazonaws.com/e2b-templates:base
docker push <account>.dkr.ecr.us-east-1.amazonaws.com/e2b-templates:base
```

### 4.3 Prepare Firecracker Kernel (Day 1, 1 hour)

```bash
# Download kernel to S3
curl -L -o vmlinux-6.1.102 https://github.com/firecracker-microvm/firecracker/releases/...
aws s3 cp vmlinux-6.1.102 s3://e2b-dev-fc-kernels/vmlinux-6.1.102
```

### 4.4 Test Template Build Pipeline (Day 2-3, 8 hours)

```bash
# Trigger build via API
curl -X POST http://localhost:50001/templates \
  -H "X-API-Key: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "templateID": "base",
    "dockerfile": "FROM ubuntu:22.04\nRUN apt-get update && apt-get install -y python3 curl git"
  }'

# Monitor build status
curl http://localhost:50001/templates/base -H "X-API-Key: $API_KEY"
# Wait for status: "ready"

# Verify snapshot in S3
aws s3 ls s3://e2b-dev-fc-templates/
```

### 4.5 Test Sandbox from Template (Day 3, 4 hours)

```bash
# Create sandbox from built template
curl -X POST http://localhost:50001/sandboxes \
  -H "X-API-Key: $API_KEY" \
  -d '{"templateID": "base"}'

# Should restore from snapshot in <200ms
# Verify envd works
# Verify python3 is available inside sandbox
```

### 4.6 Build Desktop Template (Day 3-4, 4 hours)

Desktop template is larger (~2GB) and takes longer to build:
```bash
docker build -t e2b-desktop -f templates/desktop.Dockerfile .
# Push to ECR, trigger template build
# Verify VNC accessible on port 6080
```

### 4.7 Test All Templates (Day 4, 4 hours)

For each template, verify:
1. Build completes (status -> "ready")
2. Sandbox creates from snapshot
3. Core functionality works (python3, VNC, browser, etc.)

## Test Cases (Phase 4)

### P0 (Must Pass)

| ID | Test | Expected |
|---|---|---|
| T4-01 | Build base template from Dockerfile | Status -> "ready" |
| T4-02 | Snapshot exists in S3 after build | Memory + disk snapshot in bucket |
| T4-03 | Create sandbox from base template | Sandbox ready, envd reachable |
| T4-04 | Snapshot restore < 200ms | Measured latency |
| T4-05 | Exec `python3 -c "print('ok')"` in base sandbox | stdout="ok\n" |
| T4-06 | Exec `git --version` in base sandbox | Version string returned |
| T4-07 | Kernel boots Firecracker VM | Serial console output |

### P1 (Should Pass)

| ID | Test | Expected |
|---|---|---|
| T4-08 | Build code-interpreter template | Status -> "ready" |
| T4-09 | `import numpy` works in code-interpreter | No import error |
| T4-10 | Build desktop template | Status -> "ready" (may take 10+ min) |
| T4-11 | VNC accessible on desktop sandbox | noVNC loads in browser |
| T4-12 | Screenshot capture on desktop | Valid PNG returned |
| T4-13 | Build browser-use template | Status -> "ready" |
| T4-14 | ECR pull via docker-reverse-proxy | Image pulled successfully |
| T4-15 | Template build failure (bad Dockerfile) | Status -> "failed" with error |
| T4-16 | Multiple templates coexist | Different templates produce different sandboxes |

## Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Docker-in-Docker in raw_exec context | High | Verify Docker daemon accessible from Nomad raw_exec |
| Large desktop image (2GB+) | Medium | May need larger EBS, longer build timeout |
| ECR auth for template builds | Medium | Verify docker-reverse-proxy or direct ECR auth |
| S3 multipart upload for large snapshots | Medium | Verify AWS storage implementation handles large files |

## Deliverables
- [ ] 4 template Dockerfiles created
- [ ] Base template builds and creates sandboxes
- [ ] Snapshot stored in S3, restores in <200ms
- [ ] Desktop template builds with VNC accessible
- [ ] All templates verified end-to-end
