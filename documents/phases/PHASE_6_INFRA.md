# Phase 6: AWS Infrastructure

**Duration**: 7 days
**Depends on**: Phase 0 (Terraform modules)
**Can run in parallel with**: Phases 1-4 (code work is independent)
**Status**: Terraform modules created, fixes in progress

---

## Objective

Build the Packer AMI, deploy AWS infrastructure with Terraform, create Nomad job definitions, initialize the database, and deploy all services. Two deployment profiles: dev (single-node, cheap) and prod (multi-node, HA).

## PRD (Phase 6)

### Deployment Profiles

**Dev Profile (Option 2 from cost discussion)**:
- 1x t3.small ($15/mo) — build server, PostgreSQL, Redis, API
- Metal instance spun up only for Firecracker testing
- Total: ~$15/mo + hourly metal cost during testing

**Prod Profile**:
- 3x t3.large — Nomad/Consul servers ($220/mo)
- 1x c5.metal — Firecracker client ($2,938/mo on-demand, ~$878/mo spot)
- 1x t3.large — API + client-proxy ($73/mo)
- RDS PostgreSQL db.t3.medium ($60/mo)
- ElastiCache Redis cache.t3.micro ($25/mo)
- ALB + NAT + S3 ($140/mo)
- **Total: ~$1,400/mo** (with metal spot)

### What We're Delivering
- Packer AMI with Nomad, Consul, Docker, Firecracker
- Terraform deploys all infrastructure
- Nomad job definitions for all services
- Database initialized with migrations + seed data
- All services running and healthy

### Success Criteria
- `terraform apply` succeeds
- Nomad cluster healthy (leader elected)
- Consul cluster healthy (all nodes registered)
- RDS accessible, migrations applied
- Redis accessible
- ALB serving HTTPS with valid cert
- All Nomad jobs running

## Dev Plan

### 6.1 Packer AMI (Day 1-2, 8 hours)

Create `/Users/mingli/projects/e2b/aws/packer/e2b-node.pkr.hcl`:

```hcl
packer {
  required_plugins {
    amazon = {
      version = ">= 1.2.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

source "amazon-ebs" "e2b" {
  ami_name      = "e2b-node-{{timestamp}}"
  instance_type = "t3.large"  # Build on t3, run on metal
  region        = var.region
  source_ami_filter {
    filters = {
      name                = "ubuntu/images/*ubuntu-jammy-22.04-amd64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["099720109477"]  # Canonical
  }
  ssh_username = "ubuntu"

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 100
    volume_type           = "gp3"
    delete_on_termination = true
  }
}

build {
  sources = ["source.amazon-ebs.e2b"]

  # System updates
  provisioner "shell" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get upgrade -y",
      "sudo apt-get install -y curl wget unzip jq awscli",
    ]
  }

  # Install Docker
  provisioner "shell" {
    script = "setup/install-docker.sh"
  }

  # Install Nomad
  provisioner "shell" {
    script = "setup/install-nomad.sh"
  }

  # Install Consul
  provisioner "shell" {
    script = "setup/install-consul.sh"
  }

  # Install Firecracker + Jailer
  provisioner "shell" {
    script = "setup/install-firecracker.sh"
  }

  # Install CNI plugins
  provisioner "shell" {
    script = "setup/install-cni.sh"
  }

  # System tuning
  provisioner "shell" {
    script = "setup/system-tuning.sh"
  }
}
```

Setup scripts to create:
- `setup/install-docker.sh`
- `setup/install-nomad.sh` (v1.7+)
- `setup/install-consul.sh` (v1.17+)
- `setup/install-firecracker.sh` (v1.7.0 + jailer)
- `setup/install-cni.sh`
- `setup/system-tuning.sh` (KVM access, sysctl, hugepages)

### 6.2 Bootstrap Terraform Backend (Day 2, 1 hour)

Create `aws/terraform/bootstrap/main.tf`:
```hcl
# Creates S3 bucket + DynamoDB table for Terraform state
resource "aws_s3_bucket" "tfstate" { ... }
resource "aws_dynamodb_table" "tflock" { ... }
```

```bash
cd aws/terraform/bootstrap
terraform init && terraform apply
```

### 6.3 Terraform Apply (Day 2-3, 4 hours)

```bash
cd aws/terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with actual values

terraform init
terraform validate
terraform plan
terraform apply
```

### 6.4 Nomad Job Definitions (Day 3-4, 8 hours)

Create HCL job files:

**`aws/nomad/jobs/api.hcl`**:
```hcl
job "api" {
  datacenters = ["dc1"]
  type = "service"

  constraint {
    attribute = "${node.class}"
    value     = "api"
  }

  group "api" {
    count = 1

    network {
      port "http" { static = 50001 }
      port "grpc" { static = 5009 }
    }

    task "api" {
      driver = "docker"
      config {
        image = "<ecr>/e2b-orchestration/api:latest"
        ports = ["http", "grpc"]
      }
      env {
        POSTGRES_CONNECTION_STRING = "..."
        REDIS_URL = "..."
        DOMAIN_NAME = "..."
        STORAGE_PROVIDER = "AWSBucket"
        SANDBOX_STORAGE_BACKEND = "redis"
      }
      resources {
        cpu    = 1000
        memory = 2048
      }
    }
  }
}
```

**`aws/nomad/jobs/orchestrator.hcl`**:
```hcl
job "orchestrator" {
  datacenters = ["dc1"]
  type = "system"  # Runs on every client node

  constraint {
    attribute = "${node.class}"
    value     = "client"
  }

  group "orchestrator" {
    task "orchestrator" {
      driver = "raw_exec"  # Needs KVM, TAP, iptables access
      config {
        command = "/opt/e2b/orchestrator"
      }
      env {
        STORAGE_PROVIDER = "AWSBucket"
        TEMPLATE_BUCKET_NAME = "..."
        ORCHESTRATOR_SERVICES = "orchestrator,template-manager"
      }
      resources {
        cpu    = 2000
        memory = 4096
      }
    }
  }
}
```

**`aws/nomad/jobs/client-proxy.hcl`**:
```hcl
job "client-proxy" {
  datacenters = ["dc1"]
  type = "service"

  constraint {
    attribute = "${node.class}"
    value     = "api"
  }

  group "proxy" {
    count = 1
    network {
      port "proxy" { static = 3002 }
      port "health" { static = 3003 }
    }
    task "client-proxy" {
      driver = "docker"
      config {
        image = "<ecr>/e2b-orchestration/client-proxy:latest"
        ports = ["proxy", "health"]
      }
      env {
        REDIS_URL = "..."
        API_GRPC_ADDRESS = "localhost:5009"
      }
    }
  }
}
```

Also create: `docker-reverse-proxy.hcl`

### 6.5 Database Init (Day 4, 2 hours)

```bash
cd aws/db
bash init.sh  # Runs goose migrations + seed data
```

### 6.6 Build & Push Docker Images (Day 4-5, 4 hours)

```bash
# Build Go services
cd infra/packages
GOOS=linux GOARCH=amd64 go build -o bin/api ./api
GOOS=linux GOARCH=amd64 go build -o bin/client-proxy ./client-proxy
GOOS=linux GOARCH=amd64 go build -o bin/docker-reverse-proxy ./docker-reverse-proxy

# Build Docker images
docker build -t e2b-api -f packages/api/Dockerfile .
docker build -t e2b-client-proxy -f packages/client-proxy/Dockerfile .

# Push to ECR
aws ecr get-login-password | docker login --username AWS --password-stdin <ecr>
docker tag e2b-api:latest <ecr>/e2b-orchestration/api:latest
docker push <ecr>/e2b-orchestration/api:latest
# ... repeat for other services
```

### 6.7 Deploy Nomad Jobs (Day 5, 2 hours)

```bash
cd aws/nomad
# Set NOMAD_ADDR to server
export NOMAD_ADDR=http://<server-ip>:4646
export NOMAD_TOKEN=<acl-token>

nomad job run jobs/api.hcl
nomad job run jobs/orchestrator.hcl
nomad job run jobs/client-proxy.hcl
nomad job run jobs/docker-reverse-proxy.hcl

# Verify
nomad job status
```

### 6.8 Verify Full Stack (Day 5-6, 4 hours)

```bash
# Health checks
curl https://api.e2b.example.com/health

# Create sandbox
curl -X POST https://api.e2b.example.com/sandboxes \
  -H "X-API-Key: $API_KEY" \
  -d '{"templateID": "base"}'

# SDK test
E2B_DOMAIN=e2b.example.com E2B_API_KEY=$API_KEY python3 -c "
from e2b import Sandbox
sb = Sandbox.create('base')
print(sb.commands.run('echo hello').stdout)
sb.kill()
"
```

### 6.9 Create Deploy Scripts (Day 6-7, 4 hours)

- `aws/nomad/prepare.sh` — Pre-deployment checks, build binaries, push images
- `aws/nomad/deploy.sh` — Deploy all Nomad jobs
- `Makefile` — Top-level build/deploy targets

## Test Cases (Phase 6)

### P0 (Must Pass)

| ID | Test | Expected |
|---|---|---|
| I6-01 | `terraform validate` | Valid configuration |
| I6-02 | `terraform apply` succeeds | All resources created |
| I6-03 | Nomad cluster healthy | 3 servers, leader elected |
| I6-04 | Consul cluster healthy | All nodes registered |
| I6-05 | RDS accessible from private subnets | PostgreSQL connection works |
| I6-06 | Redis accessible | `PING` -> `PONG` |
| I6-07 | ALB HTTPS works | Valid cert, 200 on /health |
| I6-08 | All Nomad jobs running | `nomad job status` shows running |
| I6-09 | Database migrations applied | All 90 migrations complete |
| I6-10 | End-to-end: API -> sandbox create -> exec -> delete | Works |

### P1 (Should Pass)

| ID | Test | Expected |
|---|---|---|
| I6-11 | Bastion SSH access | From allowed CIDR only |
| I6-12 | ASG replaces terminated instance | New instance joins cluster |
| I6-13 | SDK works through ALB | `Sandbox.create()` succeeds |
| I6-14 | S3 template storage | Upload/download works |
| I6-15 | ECR image pull | Nomad pulls from ECR |
| I6-16 | Secrets Manager access | EC2 can read tokens |

## Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Metal instance cost | High | Use spot instances, spin up only when needed |
| Nomad/Consul bootstrap race | Medium | User-data scripts with retry logic |
| ACM cert validation delay | Low | Allow 30min for DNS propagation |
| AMI build time | Low | ~20 min, do once |

## Deliverables
- [ ] Packer AMI built
- [ ] Terraform deployed
- [ ] Nomad jobs running
- [ ] Database initialized
- [ ] Docker images in ECR
- [ ] Full stack verified
- [ ] Deploy scripts
- [ ] Makefile
