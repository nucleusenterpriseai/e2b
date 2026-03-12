#!/usr/bin/env bash
set -euo pipefail

# deploy.sh — Submit Nomad jobs and verify they are running
#
# Prerequisites:
#   - NOMAD_ADDR set (e.g., http://nomad-server:4646)
#   - NOMAD_TOKEN set (ACL token with job submission rights)
#   - nomad CLI installed
#
# Usage:
#   ./deploy.sh                     # Deploy all jobs
#   ./deploy.sh --job api           # Deploy only the API job
#   ./deploy.sh --dry-run           # Plan without running

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS_DIR="${SCRIPT_DIR}/jobs"

# Configuration
NOMAD_ADDR="${NOMAD_ADDR:-http://localhost:4646}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"  # seconds to wait for allocations

# Parse arguments
DRY_RUN=false
TARGET_JOB=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --job)
            TARGET_JOB="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1"
            echo "Usage: $0 [--dry-run] [--job <name>]"
            exit 1
            ;;
    esac
done

# --- Helper functions ---

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

err() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

check_prerequisites() {
    log "Checking prerequisites..."

    if ! command -v nomad &>/dev/null; then
        err "Nomad CLI is not installed"
        exit 1
    fi

    if [ -z "${NOMAD_ADDR}" ]; then
        err "NOMAD_ADDR is not set"
        exit 1
    fi

    # Verify connectivity
    if ! nomad status &>/dev/null; then
        err "Cannot connect to Nomad at ${NOMAD_ADDR}"
        exit 1
    fi

    log "Connected to Nomad at ${NOMAD_ADDR}"
    log "Nomad server status:"
    nomad server members 2>/dev/null || true
}

deploy_job() {
    local job_file="$1"
    local job_name
    job_name="$(basename "${job_file}" .hcl)"

    log "--- Deploying job: ${job_name} ---"

    # Process job file with envsubst to resolve environment variables (e.g., ECR_REGISTRY)
    local processed_file
    processed_file=$(mktemp "${TMPDIR:-/tmp}/nomad-job-XXXXXX.hcl")
    envsubst '${ECR_REGISTRY} ${E2B_ARTIFACTS_BUCKET}' < "${job_file}" > "${processed_file}"

    # Validate the job file
    log "Validating ${job_file}..."
    if ! nomad job validate "${processed_file}"; then
        err "Job validation failed for ${job_name}"
        rm -f "${processed_file}"
        return 1
    fi

    # Plan the job (shows diff)
    log "Planning ${job_name}..."
    nomad job plan "${processed_file}" || true  # plan returns non-zero if there are changes

    if [ "${DRY_RUN}" = true ]; then
        log "DRY RUN: Skipping submission for ${job_name}"
        rm -f "${processed_file}"
        return 0
    fi

    # Submit the job
    log "Submitting ${job_name}..."
    local eval_id
    eval_id=$(nomad job run "${processed_file}" 2>&1 | sed -n 's/.*Evaluation ID: "\([^"]*\)".*/\1/p' || echo "")

    if [ -n "${eval_id}" ]; then
        log "Evaluation ID: ${eval_id}"
    fi

    log "Job ${job_name} submitted successfully"

    rm -f "${processed_file}"
}

wait_for_job() {
    local job_name="$1"
    local timeout="${2:-${WAIT_TIMEOUT}}"
    local start_time
    start_time=$(date +%s)

    log "Waiting for job ${job_name} to be running (timeout: ${timeout}s)..."

    while true; do
        local elapsed
        elapsed=$(( $(date +%s) - start_time ))

        if [ "${elapsed}" -ge "${timeout}" ]; then
            err "Timeout waiting for job ${job_name} after ${timeout}s"
            nomad job status "${job_name}" 2>/dev/null || true
            return 1
        fi

        local status
        status=$(nomad job status -short "${job_name}" 2>/dev/null | grep "^Status" | awk '{print $NF}' || echo "unknown")

        case "${status}" in
            running)
                # Check if all allocations are healthy
                local unhealthy
                unhealthy=$(nomad job status "${job_name}" 2>/dev/null | grep -c "unhealthy" || echo "0")
                local pending
                pending=$(nomad job status "${job_name}" 2>/dev/null | grep -c "pending" || echo "0")

                if [ "${unhealthy}" = "0" ] && [ "${pending}" = "0" ]; then
                    log "Job ${job_name} is running and healthy"
                    return 0
                fi

                log "Job ${job_name} is running but has unhealthy/pending allocations (${elapsed}s elapsed)..."
                ;;
            dead)
                err "Job ${job_name} is dead"
                nomad job status "${job_name}" 2>/dev/null || true
                return 1
                ;;
            *)
                log "Job ${job_name} status: ${status} (${elapsed}s elapsed)..."
                ;;
        esac

        sleep 5
    done
}

health_check() {
    log "=== Running health checks ==="

    # Check Nomad job statuses
    log "Nomad job statuses:"
    nomad job status 2>/dev/null || true

    # Check Consul service registrations
    if command -v consul &>/dev/null; then
        log "Consul service catalog:"
        consul catalog services 2>/dev/null || true
    fi

    # Check specific service health via Consul DNS if available
    for svc in e2b-api e2b-client-proxy e2b-docker-reverse-proxy e2b-orchestrator; do
        if consul catalog services 2>/dev/null | grep -q "${svc}"; then
            local healthy
            healthy=$(consul health checks "${svc}" 2>/dev/null | grep -c "passing" || echo "0")
            log "Service ${svc}: ${healthy} passing health checks"
        fi
    done

    log "=== Health checks complete ==="
}

# --- Main ---

JOBS=(
    "docker-reverse-proxy"
    "api"
    "client-proxy"
    "orchestrator"
)

main() {
    log "=== E2B Nomad Deploy ==="
    log "Nomad address: ${NOMAD_ADDR}"
    log "Jobs directory: ${JOBS_DIR}"

    check_prerequisites

    if [ -n "${TARGET_JOB}" ]; then
        local job_file="${JOBS_DIR}/${TARGET_JOB}.hcl"
        if [ ! -f "${job_file}" ]; then
            err "Job file not found: ${job_file}"
            exit 1
        fi
        deploy_job "${job_file}"
        if [ "${DRY_RUN}" = false ]; then
            wait_for_job "${TARGET_JOB}"
        fi
    else
        # Deploy all jobs in order
        for job in "${JOBS[@]}"; do
            local job_file="${JOBS_DIR}/${job}.hcl"
            if [ ! -f "${job_file}" ]; then
                err "Job file not found: ${job_file}"
                continue
            fi
            deploy_job "${job_file}"
        done

        if [ "${DRY_RUN}" = false ]; then
            # Wait for all jobs
            log "Waiting for all jobs to stabilize..."
            sleep 10

            for job in "${JOBS[@]}"; do
                wait_for_job "${job}" || true
            done

            health_check
        fi
    fi

    log "=== Deploy complete ==="
}

main
