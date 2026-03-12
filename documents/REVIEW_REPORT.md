# Consolidated Review Report: E2B Self-Hosted Sandbox Platform

**Date**: 2026-03-12
**Reviewers**: Tech Lead, QA Engineer, DevOps Engineer, Software Engineer
**Documents Reviewed**: PRD.md, DEV_PLAN.md, TEST_CASES.md, all Terraform code, upstream Go codebase

---

## Executive Summary

Four independent reviewers identified **5 critical blockers**, **15 major concerns**, and **20+ minor issues** across architecture, infrastructure, testing, and code. The most impactful finding is that the fork strategy should be **config-driven (not code-rewrite)** — most SaaS dependencies already have graceful fallbacks when env vars are unset.

**Revised timeline**: 25-30 working days (vs. 16 in original plan).

---

## CRITICAL BLOCKERS (Must Fix Before Any Deploy)

### CRIT-1: Client-Proxy Cannot Reach VMs Via vsock Across Hosts
**Found by**: Tech Lead
**Files**: `aws/terraform/modules/alb/main.tf:119-124`, `modules/compute/main.tf:327-354`

The client-proxy is placed on API nodes, but vsock is a hypervisor-local transport. It cannot proxy to a Firecracker VM on a different physical host. The current architecture breaks the entire SDK data path.

**Actual E2B behavior**: The client-proxy does NOT use vsock directly. Per the Software Engineer's review, it uses Redis (sandbox-catalog) to map `sandboxID -> orchestratorIP`, then proxies HTTP to `{orchestratorIP}:5007` (the orchestrator's built-in HTTP proxy). This works across hosts.

**Fix**: Ensure Redis connectivity between client-proxy and orchestrator. The ALB default route should send `*.domain` traffic to the client-proxy. The client-proxy then uses the Redis catalog to route to the correct orchestrator node. No vsock cross-host needed — the orchestrator handles the vsock-to-HTTP bridging locally.

---

### CRIT-2: c5.2xlarge Does NOT Support KVM
**Found by**: Tech Lead, DevOps
**File**: `aws/terraform/variables.tf:83`

Firecracker requires `/dev/kvm`. The default `client_instance_type = "c5.2xlarge"` is a virtualized instance without KVM access. No sandbox will ever boot.

**Fix**: Change default to `c5.metal` (or `c7i.metal-24xl` for newer gen). Add Terraform validation:
```hcl
variable "client_instance_type" {
  validation {
    condition     = can(regex("metal", var.client_instance_type))
    error_message = "Client instances must be bare metal for KVM support."
  }
}
```

---

### CRIT-3: Nomad/Consul Cluster Will Never Form
**Found by**: Tech Lead, DevOps
**Files**: `modules/compute/user-data/server.sh`, `client.sh`, `api.sh`

User-data scripts just run `systemctl start consul/nomad` with no join configuration. No `retry_join`, no server addresses, no bind addresses. The cluster will never form.

Additionally, `ec2:DescribeInstances` is missing from the IAM policy, so tag-based Consul `retry_join` will fail even if configured in the AMI.

**Fix**:
1. User-data scripts must generate `/etc/consul.d/consul.hcl` with `retry_join` using AWS tag discovery
2. Generate `/etc/nomad.d/nomad.hcl` with server addresses
3. Add `ec2:DescribeInstances` and `ec2:DescribeTags` to IAM policy
4. Set bind/advertise addresses from instance metadata

---

### CRIT-4: ACM Certificate Will Never Validate
**Found by**: Tech Lead, DevOps
**File**: `modules/alb/main.tf:1-12`

Certificate created with DNS validation but no Route53 zone, no validation records, no `aws_acm_certificate_validation` resource. HTTPS will never work.

**Fix**: Add Route53 hosted zone + validation records + `aws_acm_certificate_validation` resource. Or document manual DNS validation workflow.

---

### CRIT-5: API Server Won't Start — Missing Required Config
**Found by**: Software Engineer
**File**: `infra/packages/api/internal/cfg/model.go`

The API server has hard `required` env vars that aren't in the plan:
- `LOKI_URL` (logging — **required**, will panic without it)
- `VOLUME_TOKEN_ISSUER`, `VOLUME_TOKEN_SIGNING_METHOD`, `VOLUME_TOKEN_SIGNING_KEY`, `VOLUME_TOKEN_SIGNING_KEY_NAME` (all **required**)

**Fix**: Make these fields optional in the code (minimal code change) or deploy a Loki instance and configure volume token JWT.

---

## MAJOR CONCERNS (Should Fix Before Production)

### Architecture & Code

| # | Issue | Found By | Fix |
|---|-------|----------|-----|
| MAJ-1 | **Database schema is far more complex than planned.** The codebase uses 15+ tables (`envs` not `templates`, `team_limits`, `env_aliases`, `env_builds`, `clusters`, `volumes`, etc.). A 4-table simplified schema will break all sqlc-generated queries. | SW Engineer | Keep the full upstream schema. Run all 90 migrations. Seed simpler data. |
| MAJ-2 | **Auth is not "simple API key lookup."** 5 authenticators, OpenAPI spec enforcement, SHA-256 key hashing, separate auth DB connection. Cannot be replaced with a simple middleware. | SW Engineer | Keep the full auth package. Just use API key auth (don't set Supabase env vars). Make unused auth paths optional. |
| MAJ-3 | **Service discovery uses Nomad API + Redis, not Consul DNS.** The client-proxy routes via Redis sandbox-catalog. The API discovers orchestrators via Nomad allocations API. | SW Engineer | Correct the architecture docs. Ensure Redis is accessible from all services. |
| MAJ-4 | **The plan overestimates code changes needed.** ClickHouse, PostHog, LaunchDarkly, and Supabase all have graceful fallbacks when env vars are empty. No code removal needed. | SW Engineer | Change strategy: minimize code changes, maximize config changes. Target <200 lines of Go changes. |
| MAJ-5 | **16-day timeline is 2x too short.** All 4 reviewers flagged this. Realistic: 25-30 days. | All | Revise timeline. |

### Infrastructure (Terraform)

| # | Issue | Found By | Fix |
|---|-------|----------|-----|
| MAJ-6 | **Terraform state is local — data loss guaranteed.** S3 backend commented out, no DynamoDB locking. | Tech Lead, DevOps | Uncomment backend, add DynamoDB lock table, create bootstrap config. |
| MAJ-7 | **Nomad UI exposed to internet without auth.** `nomad.${domain}` ALB rule gives full cluster control to anyone. | Tech Lead, DevOps | Remove the Nomad listener rule. Access via bastion SSH tunnel only. |
| MAJ-8 | **Single IAM role for all node types.** Bastion gets S3/ECR/Secrets access. Compromised bastion = full access. | Tech Lead | Create separate IAM roles per node type (bastion, server, client, api). |
| MAJ-9 | **DB password in Terraform state as plaintext.** Variable marked `sensitive` but still in state JSON. | DevOps | Use `manage_master_user_password = true` or generate with `random_password` + Secrets Manager. |
| MAJ-10 | **No EBS config on client nodes.** Default 8GB root volume will fill instantly with VM rootfs overlays. | DevOps | Add `block_device_mappings` with 200-500GB gp3 volume. |
| MAJ-11 | **SSH bastion open to 0.0.0.0/0 by default.** | DevOps | Remove default, force operator to specify CIDR. |
| MAJ-12 | **RDS `skip_final_snapshot = true`.** Terraform destroy = permanent data loss. | DevOps | Set `false`, add `final_snapshot_identifier` and `deletion_protection = true`. |
| MAJ-13 | **Secrets Manager `recovery_window_in_days = 0`.** Destroy = immediate permanent secret deletion. | DevOps | Set to 7+ days for production. |
| MAJ-14 | **Docker proxy target group not wired to any ASG.** `docker.${domain}` will always 502. | DevOps | Pass `docker_proxy_tg_arn` to compute module, attach to API ASG. |
| MAJ-15 | **Redis transit encryption disabled.** Plaintext traffic in VPC. | Tech Lead, DevOps | Set `transit_encryption_enabled = true`. |

### Testing

| # | Issue | Found By | Fix |
|---|-------|----------|-----|
| MAJ-16 | **Test plan ignores existing upstream test suite (157 test files, 47 integration tests).** Proposes rewriting from scratch. | QA | Start with upstream tests, identify what breaks, adapt for self-hosted context. |
| MAJ-17 | **No tests for the actual modifications (auth migration, storage switch, dep removal).** | QA | Add "modification verification" test category. |
| MAJ-18 | **No database migration tests.** | QA | Test migration.sql against fresh PostgreSQL, verify sqlc query compatibility. |
| MAJ-19 | **No input validation / negative test matrix.** No tests for SQL injection, path traversal, oversized payloads. | QA | Add systematic negative test matrix per endpoint. |

---

## MINOR ISSUES (Fix When Convenient)

| # | Issue | Found By |
|---|-------|----------|
| MIN-1 | S3 buckets `force_destroy = true` — dangerous for prod | DevOps |
| MIN-2 | ECR `image_tag_mutability = "MUTABLE"` — non-reproducible deploys | Tech Lead |
| MIN-3 | No HTTP-to-HTTPS redirect on ALB | Tech Lead, DevOps |
| MIN-4 | No ALB access logging configured | Tech Lead, DevOps |
| MIN-5 | No VPC flow logs | DevOps |
| MIN-6 | VPC CIDR 10.0.0.0/16 may conflict with existing VPCs | Tech Lead |
| MIN-7 | No ASG scaling policies for client nodes | Tech Lead, DevOps |
| MIN-8 | No CloudWatch alarms defined | DevOps |
| MIN-9 | No VPC endpoints (S3, ECR, Secrets Manager) — adds NAT cost | DevOps |
| MIN-10 | RDS Multi-AZ enabled for dev (doubles cost) | DevOps |
| MIN-11 | Dual NAT gateways in dev ($130/mo extra) | DevOps |
| MIN-12 | KMS-encrypted S3 adds per-request cost vs SSE-S3 | DevOps |
| MIN-13 | No `terraform.tfvars.example` file | DevOps |
| MIN-14 | Provider version `~> 5.0` too broad, no lock file | Tech Lead |
| MIN-15 | Gossip key generation uses ASCII not raw bytes | Tech Lead |
| MIN-16 | No ALB deletion protection | DevOps |
| MIN-17 | No ASG health check grace period | DevOps |
| MIN-18 | No deregistration delay on target groups | Tech Lead |
| MIN-19 | Missing symlink, unicode, path traversal tests for envd | QA |
| MIN-20 | Test timing dependencies (flaky risk) in TC-105, TC-202, TC-216 | QA |

---

## KEY STRATEGIC RECOMMENDATION

### Minimize Code Changes, Maximize Config Changes

The Software Engineer's most impactful finding: **most SaaS dependencies already have graceful fallbacks.** The revised approach:

| Dependency | Original Plan | Revised Approach | Code Change? |
|---|---|---|---|
| ClickHouse | Remove code | Don't set `CLICKHOUSE_CONNECTION_STRING` | **None** |
| PostHog | Remove code | Don't set `POSTHOG_API_KEY` | **None** |
| LaunchDarkly | Remove code | Don't set `LAUNCH_DARKLY_API_KEY` | **None** |
| GCS Storage | Rewrite to S3 | Set `STORAGE_PROVIDER=AWSBucket` | **None** |
| Supabase Auth | Rewrite middleware | Keep auth package, only use API key flow | **None** |
| Loki | Not addressed | Make `LOKI_URL` not required | **~5 lines** |
| Volume Tokens | Not addressed | Make volume token config optional | **~10 lines** |
| Database | Simplify to 4 tables | Keep full schema, run all 90 migrations | **None** |

**Total Go code changes: ~15-20 lines** (making 2 config fields optional)
**Fork maintenance: trivial** (upstream merges will apply cleanly)

---

## REVISED TIMELINE

| Phase | Original | Revised | Reason |
|---|---|---|---|
| Phase 0: Setup | 1 day | 1 day | Same |
| Phase 1: envd | 3 days | 2 days | Less work needed (already minimal) |
| Phase 2: Orchestrator | 3 days | 4 days | Build on Linux, test Firecracker on metal instance |
| Phase 3: API + Proxy | 2 days | 5 days | Schema complexity, auth system, config fixes |
| Phase 4: Templates | 2 days | 4 days | Docker-in-Docker in raw_exec, ECR auth, build testing |
| Phase 5: SDK | 2 days | 2 days | Same (use existing SDKs) |
| Phase 6: AWS Infra | 3 days | 7 days | Fix all critical Terraform issues, Packer AMI, cluster bootstrap |
| Phase 7: Integration | 2 days | 5 days | Adapt upstream tests, add modification tests |
| **Total** | **16 days** | **30 days** | |

---

## TOP 10 ACTION ITEMS (Priority Order)

1. **Change fork strategy**: Config-driven, not code-rewrite. Keep upstream schema and auth intact.
2. **Fix client instance type**: Default to `c5.metal` or validated bare-metal type.
3. **Fix Nomad/Consul bootstrap**: Generate proper config in user-data with `retry_join` + IAM permissions.
4. **Add Route53 + ACM validation**: Certificate must validate for HTTPS to work.
5. **Enable Terraform S3 backend**: With DynamoDB locking and bootstrap config.
6. **Make Loki + volume token config optional**: ~15 lines of Go code change.
7. **Fix security issues**: Separate IAM roles, restrict SSH CIDR, remove Nomad listener, enable Redis TLS.
8. **Add EBS config to client nodes**: 200-500GB gp3 for rootfs overlays.
9. **Wire docker proxy target group**: Connect to API ASG.
10. **Adapt upstream test suite**: Don't rewrite 122 tests — adapt the existing 157.

---

## WHAT'S GOOD (Acknowledged by All Reviewers)

- **Module structure is clean**: Terraform organized well, dependencies flow correctly
- **Security group design is solid**: Least-privilege, SG-to-SG references for DB/Redis
- **IMDSv2 enforced on all instances**: Blocks SSRF credential theft
- **S3 bucket hardening**: Public access blocked, encrypted, versioned
- **envd is genuinely self-contained**: No SaaS deps, minimal changes needed
- **AWS S3 storage provider already exists**: Set env var and it works
- **SaaS deps have graceful fallbacks**: ClickHouse, PostHog, LaunchDarkly all handle empty config
- **Build order (envd -> orchestrator -> API -> infra) is correct**
- **PRD architecture diagram matches actual code**
- **Test case coverage is extensive**: 122 cases, good P0/P1/P2 classification
- **ECR lifecycle policies prevent unbounded image growth**
- **TLS 1.3 on ALB**: Current best practice
