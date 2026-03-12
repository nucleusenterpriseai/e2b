# Phase 6: Infrastructure — Results

**Date**: 2026-03-12
**Status**: Artifacts Created

---

## Summary

All infrastructure artifacts for Phase 6 have been created. This includes the Packer AMI definition, Nomad job files, deployment scripts, template Dockerfiles, a top-level Makefile, and the Terraform state bootstrap module.

## Files Created

### Step 1: Packer AMI Definition

| File | Description |
|------|-------------|
| `aws/packer/e2b-node.pkr.hcl` | Packer template: Ubuntu 22.04, t3.large build instance, 100GB gp3 root volume |
| `aws/packer/setup/install-docker.sh` | Docker CE 24.0.9 from official repo, overlay2 driver, live-restore |
| `aws/packer/setup/install-nomad.sh` | Nomad 1.7.7 from HashiCorp repo, raw_exec + docker plugins configured |
| `aws/packer/setup/install-consul.sh` | Consul 1.17.3 from HashiCorp repo, dnsmasq for DNS forwarding |
| `aws/packer/setup/install-firecracker.sh` | Firecracker v1.7.0 + jailer from GitHub releases |
| `aws/packer/setup/install-cni.sh` | CNI plugins v1.4.1, bridge network for Nomad |
| `aws/packer/setup/system-tuning.sh` | KVM udev rules, sysctl (ip_forward, conntrack, file limits), hugepages, PAM limits |

### Step 2: Nomad Job Definitions

| File | Description |
|------|-------------|
| `aws/nomad/jobs/api.hcl` | Docker job, ports 50001 (HTTP) + 5009 (gRPC), node_class=api, Consul service registration |
| `aws/nomad/jobs/orchestrator.hcl` | raw_exec system job, ports 5008 (gRPC) + 5007 (proxy), node_class=client, KVM access |
| `aws/nomad/jobs/client-proxy.hcl` | Docker job, ports 3002 (proxy) + 3003 (health), node_class=api |
| `aws/nomad/jobs/docker-reverse-proxy.hcl` | Docker job, port 5000 (HTTP), node_class=api |

All jobs include:
- Consul service registration with health checks
- Template blocks for Consul KV configuration injection
- Resource limits (CPU + memory)
- Update strategy with auto_revert
- Restart policies

### Step 3: Deployment Scripts

| File | Description |
|------|-------------|
| `aws/nomad/prepare.sh` | Builds Go binaries (linux/amd64), Docker images, pushes to ECR. Supports `--skip-push` and `--service <name>` |
| `aws/nomad/deploy.sh` | Submits Nomad jobs, waits for allocations, runs health checks. Supports `--dry-run` and `--job <name>` |

### Step 4: Template Dockerfiles

| File | Description |
|------|-------------|
| `templates/base.Dockerfile` | Ubuntu 22.04 + Python3 + Node.js 20 + git + build-essential |
| `templates/code-interpreter.Dockerfile` | Ubuntu 22.04 + numpy, pandas, matplotlib, scipy, jupyter, ipykernel |
| `templates/desktop.Dockerfile` | Ubuntu 22.04 + XFCE + Xvfb + x11vnc + noVNC + Firefox ESR + LibreOffice |
| `templates/browser-use.Dockerfile` | Ubuntu 22.04 + Chromium + Playwright + headless browser tooling |

### Step 5: Top-Level Makefile

| File | Description |
|------|-------------|
| `Makefile` | 40+ targets covering build, docker, packer, terraform, database, nomad, templates, and tests |

Key target groups:
- `build-*`: Go binary compilation (cross-compile linux/amd64)
- `docker-*`: Docker image build and ECR push
- `packer*`: AMI build pipeline
- `terraform-*`: init, plan, apply, destroy, output
- `db-*`: Database migration management
- `nomad-*`: Job deployment and status
- `template-*`: Template image builds
- `test-*`: Unit, integration, E2E test runners

### Step 6: Terraform State Bootstrap

| File | Description |
|------|-------------|
| `aws/terraform/bootstrap/main.tf` | S3 bucket (versioned, encrypted, lifecycle rules) + DynamoDB table (PAY_PER_REQUEST, PITR enabled) for Terraform state locking |

Outputs: `bucket_name`, `bucket_arn`, `dynamodb_table_name`, `dynamodb_table_arn`, `backend_config`

## Architecture Notes

### Port Assignments (from source code analysis)

| Service | Port | Protocol | Source |
|---------|------|----------|--------|
| API | 50001 (configurable via `-port` flag, default 80) | HTTP | `packages/api/main.go` |
| API gRPC | 5009 | gRPC | `API_GRPC_PORT` env, `packages/api/internal/cfg/model.go` |
| Orchestrator gRPC | 5008 | gRPC | `GRPC_PORT` env, `packages/orchestrator/internal/cfg/model.go` |
| Orchestrator Proxy | 5007 | HTTP | `PROXY_PORT` env, `packages/orchestrator/internal/cfg/model.go` |
| Client Proxy | 3002 | HTTP | `PROXY_PORT` env, `packages/client-proxy/internal/cfg/model.go` |
| Client Proxy Health | 3003 | HTTP | `HEALTH_PORT` env, `packages/client-proxy/internal/cfg/model.go` |
| Docker Reverse Proxy | 5000 | HTTP | `-port` flag, `packages/docker-reverse-proxy/main.go` |

### Key Environment Variables

- **API**: `POSTGRES_CONNECTION_STRING` (required), `REDIS_URL`, `API_GRPC_PORT`, `DOMAIN_NAME`, `SANDBOX_STORAGE_BACKEND`, `ADMIN_TOKEN`
- **Orchestrator**: `GRPC_PORT`, `PROXY_PORT`, `ORCHESTRATOR_SERVICES`, `STORAGE_PROVIDER`, `NODE_IP`, `REDIS_URL`, `DOMAIN_NAME`
- **Client Proxy**: `PROXY_PORT`, `HEALTH_PORT`, `REDIS_URL`, `API_GRPC_ADDRESS`
- **Docker Reverse Proxy**: `GCP_PROJECT_ID`, `DOMAIN_NAME`, `GCP_DOCKER_REPOSITORY_NAME`, `GOOGLE_SERVICE_ACCOUNT_BASE64`, `GCP_REGION`

### Node Classes

- `api` — Runs API, client-proxy, docker-reverse-proxy (Docker driver)
- `client` — Runs orchestrator (raw_exec, requires KVM/metal instance)
- `server` — Nomad/Consul servers (no application jobs)

## Next Steps

1. Build the AMI: `make packer`
2. Bootstrap Terraform state: `make bootstrap-init`
3. Deploy infrastructure: `make terraform-init terraform-plan terraform-apply`
4. Configure Consul KV with service environment variables
5. Build and push Docker images: `make docker-build docker-push`
6. Initialize database: `make db-init`
7. Deploy Nomad jobs: `make nomad-deploy`
8. Verify: `make nomad-status`
