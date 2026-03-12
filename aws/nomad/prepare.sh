#!/usr/bin/env bash
set -euo pipefail

# prepare.sh — Build Go binaries, Docker images, and push to ECR
#
# Prerequisites:
#   - AWS CLI configured with ECR push permissions
#   - Docker running locally
#   - Go 1.25+ installed
#
# Usage:
#   ./prepare.sh                    # Build and push everything
#   ./prepare.sh --skip-push        # Build only, don't push to ECR
#   ./prepare.sh --service api      # Build and push only the API service

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
INFRA_DIR="${PROJECT_ROOT}/infra"
PACKAGES_DIR="${INFRA_DIR}/packages"

# Configuration
AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")}"
ECR_REGISTRY="${ECR_REGISTRY:-${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com}"
ECR_REPO_PREFIX="${ECR_REPO_PREFIX:-e2b-orchestration}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
COMMIT_SHA="${COMMIT_SHA:-$(git -C "${PROJECT_ROOT}" rev-parse --short HEAD 2>/dev/null || echo "unknown")}"

# Parse arguments
SKIP_PUSH=false
TARGET_SERVICE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-push)
            SKIP_PUSH=true
            shift
            ;;
        --service)
            TARGET_SERVICE="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1"
            echo "Usage: $0 [--skip-push] [--service <name>]"
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

    if ! command -v go &>/dev/null; then
        err "Go is not installed"
        exit 1
    fi

    if ! command -v docker &>/dev/null; then
        err "Docker is not installed"
        exit 1
    fi

    if ! docker info &>/dev/null; then
        err "Docker daemon is not running"
        exit 1
    fi

    if ! command -v aws &>/dev/null; then
        err "AWS CLI is not installed"
        exit 1
    fi

    if [ -z "${AWS_ACCOUNT_ID}" ]; then
        err "Could not determine AWS account ID. Ensure AWS credentials are configured."
        exit 1
    fi

    log "Prerequisites OK (Go $(go version | awk '{print $3}'), Docker $(docker --version | awk '{print $3}'), AWS account ${AWS_ACCOUNT_ID})"
}

ecr_login() {
    if [ "${SKIP_PUSH}" = true ]; then
        return
    fi
    log "Authenticating with ECR..."
    aws ecr get-login-password --region "${AWS_REGION}" | \
        docker login --username AWS --password-stdin "${ECR_REGISTRY}"
}

ensure_ecr_repo() {
    local repo_name="$1"
    if ! aws ecr describe-repositories --repository-names "${repo_name}" --region "${AWS_REGION}" &>/dev/null; then
        log "Creating ECR repository: ${repo_name}"
        aws ecr create-repository \
            --repository-name "${repo_name}" \
            --region "${AWS_REGION}" \
            --image-scanning-configuration scanOnPush=true \
            --encryption-configuration encryptionType=AES256
    fi
}

# --- Build functions ---

build_go_binary() {
    local service_name="$1"
    local source_dir="$2"
    local output_path="$3"

    log "Building Go binary: ${service_name}"
    cd "${source_dir}"

    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
        -ldflags="-s -w -X main.commitSHA=${COMMIT_SHA}" \
        -o "${output_path}" \
        .

    log "Built ${service_name} -> ${output_path}"
}

build_docker_image() {
    local service_name="$1"
    local dockerfile="$2"
    local context_dir="$3"
    local image_tag="${ECR_REGISTRY}/${ECR_REPO_PREFIX}/${service_name}:${IMAGE_TAG}"

    log "Building Docker image: ${image_tag}"
    docker build \
        --platform linux/amd64 \
        -t "${image_tag}" \
        -t "${ECR_REGISTRY}/${ECR_REPO_PREFIX}/${service_name}:${COMMIT_SHA}" \
        --build-arg COMMIT_SHA="${COMMIT_SHA}" \
        -f "${dockerfile}" \
        "${context_dir}"

    log "Built image: ${image_tag}"
}

push_image() {
    local service_name="$1"

    if [ "${SKIP_PUSH}" = true ]; then
        log "Skipping push for ${service_name} (--skip-push)"
        return
    fi

    local repo_name="${ECR_REPO_PREFIX}/${service_name}"
    ensure_ecr_repo "${repo_name}"

    local image_latest="${ECR_REGISTRY}/${repo_name}:${IMAGE_TAG}"
    local image_sha="${ECR_REGISTRY}/${repo_name}:${COMMIT_SHA}"

    log "Pushing ${image_latest}"
    docker push "${image_latest}"
    docker push "${image_sha}"

    log "Pushed ${service_name} to ECR"
}

# --- Service build targets ---

build_api() {
    build_docker_image "api" \
        "${PACKAGES_DIR}/api/Dockerfile" \
        "${PACKAGES_DIR}"
    push_image "api"
}

build_client_proxy() {
    build_docker_image "client-proxy" \
        "${PACKAGES_DIR}/client-proxy/Dockerfile" \
        "${PACKAGES_DIR}"
    push_image "client-proxy"
}

build_docker_reverse_proxy() {
    build_docker_image "docker-reverse-proxy" \
        "${PACKAGES_DIR}/docker-reverse-proxy/Dockerfile" \
        "${PACKAGES_DIR}"
    push_image "docker-reverse-proxy"
}

build_orchestrator() {
    # Orchestrator runs via raw_exec, so we build a standalone binary
    # and upload it to S3 for Nomad artifact fetching
    local bin_dir="${PACKAGES_DIR}/orchestrator/bin"
    mkdir -p "${bin_dir}"

    build_go_binary "orchestrator" \
        "${PACKAGES_DIR}/orchestrator" \
        "${bin_dir}/orchestrator"

    if [ "${SKIP_PUSH}" = false ]; then
        local s3_bucket="${E2B_ARTIFACTS_BUCKET:-e2b-dev-artifacts}"
        log "Uploading orchestrator binary to s3://${s3_bucket}/orchestrator/"
        aws s3 cp "${bin_dir}/orchestrator" \
            "s3://${s3_bucket}/orchestrator/orchestrator" \
            --region "${AWS_REGION}"
        log "Uploaded orchestrator binary to S3"
    fi
}

# --- Main ---

main() {
    log "=== E2B Prepare: Build & Push ==="
    log "Project root: ${PROJECT_ROOT}"
    log "Commit: ${COMMIT_SHA}"
    log "ECR Registry: ${ECR_REGISTRY}"
    log "Image tag: ${IMAGE_TAG}"

    check_prerequisites
    ecr_login

    if [ -n "${TARGET_SERVICE}" ]; then
        case "${TARGET_SERVICE}" in
            api)                    build_api ;;
            client-proxy)           build_client_proxy ;;
            docker-reverse-proxy)   build_docker_reverse_proxy ;;
            orchestrator)           build_orchestrator ;;
            *)
                err "Unknown service: ${TARGET_SERVICE}"
                err "Valid services: api, client-proxy, docker-reverse-proxy, orchestrator"
                exit 1
                ;;
        esac
    else
        build_api
        build_client_proxy
        build_docker_reverse_proxy
        build_orchestrator
    fi

    log "=== Prepare complete ==="
}

main
