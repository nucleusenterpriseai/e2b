# E2B Self-Hosted — Top-Level Makefile
#
# Targets cover the full lifecycle: build, infrastructure, deploy, test
#
# Prerequisites:
#   - Go 1.25+, Docker, Terraform, Packer, Nomad CLI, AWS CLI
#   - AWS credentials configured
#
# Quick start (dev):
#   make build-all
#   make packer
#   make terraform-init terraform-plan terraform-apply
#   make db-init
#   make docker-build docker-push
#   make nomad-deploy
#
# For more details, see documents/phases/PHASE_6_INFRA.md

SHELL := /bin/bash
.DEFAULT_GOAL := help

# --- Configuration ---

PROJECT_ROOT  := $(shell pwd)
INFRA_DIR     := $(PROJECT_ROOT)/infra
PACKAGES_DIR  := $(INFRA_DIR)/packages
AWS_DIR       := $(PROJECT_ROOT)/aws
TEMPLATES_DIR := $(PROJECT_ROOT)/templates

AWS_REGION       ?= us-east-1
ENVIRONMENT      ?= dev
IMAGE_TAG        ?= latest
COMMIT_SHA       ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")

# ECR configuration (override with environment variables)
AWS_ACCOUNT_ID   ?= $(shell aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "000000000000")
ECR_REGISTRY     ?= $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com
ECR_REPO_PREFIX  ?= e2b-orchestration

# Go build settings
GOOS             ?= linux
GOARCH           ?= amd64
CGO_ENABLED      ?= 0
GO_LDFLAGS       := -s -w -X main.commitSHA=$(COMMIT_SHA)
GO_BUILD         := CGO_ENABLED=$(CGO_ENABLED) GOOS=$(GOOS) GOARCH=$(GOARCH) go build -ldflags="$(GO_LDFLAGS)"

# ============================================================================
# Build Targets
# ============================================================================

.PHONY: build-envd
build-envd: ## Build the envd binary (in-VM daemon)
	@echo "==> Building envd"
	cd $(PACKAGES_DIR)/envd && $(GO_BUILD) -o bin/envd .

.PHONY: build-api
build-api: ## Build the API binary
	@echo "==> Building API"
	cd $(PACKAGES_DIR)/api && $(GO_BUILD) -o bin/api .

.PHONY: build-client-proxy
build-client-proxy: ## Build the client-proxy binary
	@echo "==> Building client-proxy"
	cd $(PACKAGES_DIR)/client-proxy && $(GO_BUILD) -o bin/client-proxy .

.PHONY: build-orchestrator
build-orchestrator: ## Build the orchestrator binary
	@echo "==> Building orchestrator"
	cd $(PACKAGES_DIR)/orchestrator && $(GO_BUILD) -o bin/orchestrator .

.PHONY: build-docker-reverse-proxy
build-docker-reverse-proxy: ## Build the docker-reverse-proxy binary
	@echo "==> Building docker-reverse-proxy"
	cd $(PACKAGES_DIR)/docker-reverse-proxy && $(GO_BUILD) -o bin/docker-reverse-proxy .

.PHONY: build-all
build-all: build-envd build-api build-client-proxy build-orchestrator build-docker-reverse-proxy ## Build all Go binaries
	@echo "==> All binaries built"

# ============================================================================
# Docker Targets
# ============================================================================

.PHONY: ecr-login
ecr-login: ## Authenticate Docker with ECR
	@echo "==> Logging in to ECR"
	aws ecr get-login-password --region $(AWS_REGION) | \
		docker login --username AWS --password-stdin $(ECR_REGISTRY)

.PHONY: docker-build-api
docker-build-api: ## Build API Docker image
	@echo "==> Building API Docker image"
	docker build --platform linux/amd64 \
		-t $(ECR_REGISTRY)/$(ECR_REPO_PREFIX)/api:$(IMAGE_TAG) \
		-t $(ECR_REGISTRY)/$(ECR_REPO_PREFIX)/api:$(COMMIT_SHA) \
		--build-arg COMMIT_SHA=$(COMMIT_SHA) \
		-f $(PACKAGES_DIR)/api/Dockerfile \
		$(PACKAGES_DIR)

.PHONY: docker-build-client-proxy
docker-build-client-proxy: ## Build client-proxy Docker image
	@echo "==> Building client-proxy Docker image"
	docker build --platform linux/amd64 \
		-t $(ECR_REGISTRY)/$(ECR_REPO_PREFIX)/client-proxy:$(IMAGE_TAG) \
		-t $(ECR_REGISTRY)/$(ECR_REPO_PREFIX)/client-proxy:$(COMMIT_SHA) \
		--build-arg COMMIT_SHA=$(COMMIT_SHA) \
		-f $(PACKAGES_DIR)/client-proxy/Dockerfile \
		$(PACKAGES_DIR)

.PHONY: docker-build-docker-reverse-proxy
docker-build-docker-reverse-proxy: ## Build docker-reverse-proxy Docker image
	@echo "==> Building docker-reverse-proxy Docker image"
	docker build --platform linux/amd64 \
		-t $(ECR_REGISTRY)/$(ECR_REPO_PREFIX)/docker-reverse-proxy:$(IMAGE_TAG) \
		-t $(ECR_REGISTRY)/$(ECR_REPO_PREFIX)/docker-reverse-proxy:$(COMMIT_SHA) \
		--build-arg COMMIT_SHA=$(COMMIT_SHA) \
		-f $(PACKAGES_DIR)/docker-reverse-proxy/Dockerfile \
		$(PACKAGES_DIR)

.PHONY: docker-build
docker-build: docker-build-api docker-build-client-proxy docker-build-docker-reverse-proxy ## Build all Docker images
	@echo "==> All Docker images built"

.PHONY: docker-push
docker-push: ecr-login ## Push all Docker images to ECR
	@echo "==> Pushing images to ECR"
	docker push $(ECR_REGISTRY)/$(ECR_REPO_PREFIX)/api:$(IMAGE_TAG)
	docker push $(ECR_REGISTRY)/$(ECR_REPO_PREFIX)/api:$(COMMIT_SHA)
	docker push $(ECR_REGISTRY)/$(ECR_REPO_PREFIX)/client-proxy:$(IMAGE_TAG)
	docker push $(ECR_REGISTRY)/$(ECR_REPO_PREFIX)/client-proxy:$(COMMIT_SHA)
	docker push $(ECR_REGISTRY)/$(ECR_REPO_PREFIX)/docker-reverse-proxy:$(IMAGE_TAG)
	docker push $(ECR_REGISTRY)/$(ECR_REPO_PREFIX)/docker-reverse-proxy:$(COMMIT_SHA)
	@echo "==> All images pushed"

# ============================================================================
# Packer Targets
# ============================================================================

.PHONY: packer-init
packer-init: ## Initialize Packer plugins
	@echo "==> Initializing Packer"
	cd $(AWS_DIR)/packer && packer init .

.PHONY: packer-validate
packer-validate: packer-init ## Validate Packer template
	@echo "==> Validating Packer template"
	cd $(AWS_DIR)/packer && packer validate .

.PHONY: packer
packer: packer-init ## Build AMI with Packer
	@echo "==> Building AMI with Packer"
	cd $(AWS_DIR)/packer && packer build \
		-var "region=$(AWS_REGION)" \
		.

# ============================================================================
# Terraform Targets
# ============================================================================

.PHONY: terraform-init
terraform-init: ## Initialize Terraform
	@echo "==> Initializing Terraform"
	cd $(AWS_DIR)/terraform && terraform init

.PHONY: terraform-validate
terraform-validate: ## Validate Terraform configuration
	@echo "==> Validating Terraform"
	cd $(AWS_DIR)/terraform && terraform validate

.PHONY: terraform-plan
terraform-plan: ## Plan Terraform changes
	@echo "==> Planning Terraform changes"
	cd $(AWS_DIR)/terraform && terraform plan -out=tfplan

.PHONY: terraform-apply
terraform-apply: ## Apply Terraform changes
	@echo "==> Applying Terraform changes"
	cd $(AWS_DIR)/terraform && terraform apply tfplan

.PHONY: terraform-destroy
terraform-destroy: ## Destroy Terraform infrastructure (DANGEROUS)
	@echo "WARNING: This will destroy all infrastructure!"
	@read -p "Type 'yes' to confirm: " confirm && [ "$$confirm" = "yes" ]
	cd $(AWS_DIR)/terraform && terraform destroy

.PHONY: terraform-output
terraform-output: ## Show Terraform outputs
	cd $(AWS_DIR)/terraform && terraform output

.PHONY: bootstrap-init
bootstrap-init: ## Initialize Terraform state backend (S3 + DynamoDB)
	@echo "==> Bootstrapping Terraform backend"
	cd $(AWS_DIR)/terraform/bootstrap && terraform init && terraform apply

# ============================================================================
# Database Targets
# ============================================================================

.PHONY: db-init
db-init: ## Run database migrations and seed data
	@echo "==> Initializing database"
	@if [ -z "$(POSTGRES_CONNECTION_STRING)" ]; then \
		echo "ERROR: POSTGRES_CONNECTION_STRING is not set"; \
		exit 1; \
	fi
	cd $(INFRA_DIR) && go run ./packages/db/cmd/migrate up
	@echo "==> Database initialized"

.PHONY: db-migrate
db-migrate: ## Run pending database migrations
	@echo "==> Running migrations"
	cd $(INFRA_DIR) && go run ./packages/db/cmd/migrate up

.PHONY: db-status
db-status: ## Show migration status
	@echo "==> Migration status"
	cd $(INFRA_DIR) && go run ./packages/db/cmd/migrate status

# ============================================================================
# Nomad Targets
# ============================================================================

.PHONY: nomad-deploy
nomad-deploy: ## Deploy all Nomad jobs
	@echo "==> Deploying Nomad jobs"
	$(AWS_DIR)/nomad/deploy.sh

.PHONY: nomad-deploy-dry-run
nomad-deploy-dry-run: ## Plan Nomad jobs without deploying
	@echo "==> Planning Nomad jobs (dry run)"
	$(AWS_DIR)/nomad/deploy.sh --dry-run

.PHONY: nomad-status
nomad-status: ## Show status of all Nomad jobs
	@echo "==> Nomad job statuses"
	nomad job status

.PHONY: nomad-logs-api
nomad-logs-api: ## Tail API service logs
	nomad alloc logs -f -job api

.PHONY: nomad-logs-orchestrator
nomad-logs-orchestrator: ## Tail orchestrator service logs
	nomad alloc logs -f -job orchestrator

# ============================================================================
# Template Targets
# ============================================================================

.PHONY: template-base
template-base: ## Build base template Docker image
	@echo "==> Building base template"
	docker build --platform linux/amd64 \
		-t $(ECR_REGISTRY)/e2b-templates:base \
		-f $(TEMPLATES_DIR)/base.Dockerfile \
		$(TEMPLATES_DIR)

.PHONY: template-code-interpreter
template-code-interpreter: ## Build code-interpreter template Docker image
	@echo "==> Building code-interpreter template"
	docker build --platform linux/amd64 \
		-t $(ECR_REGISTRY)/e2b-templates:code-interpreter \
		-f $(TEMPLATES_DIR)/code-interpreter.Dockerfile \
		$(TEMPLATES_DIR)

.PHONY: template-desktop
template-desktop: ## Build desktop template Docker image
	@echo "==> Building desktop template"
	docker build --platform linux/amd64 \
		-t $(ECR_REGISTRY)/e2b-templates:desktop \
		-f $(TEMPLATES_DIR)/desktop.Dockerfile \
		$(TEMPLATES_DIR)

.PHONY: template-browser-use
template-browser-use: ## Build browser-use template Docker image
	@echo "==> Building browser-use template"
	docker build --platform linux/amd64 \
		-t $(ECR_REGISTRY)/e2b-templates:browser-use \
		-f $(TEMPLATES_DIR)/browser-use.Dockerfile \
		$(TEMPLATES_DIR)

.PHONY: template-all
template-all: template-base template-code-interpreter template-desktop template-browser-use ## Build all template Docker images
	@echo "==> All templates built"

.PHONY: template-push
template-push: ecr-login ## Push all template images to ECR
	@echo "==> Pushing template images to ECR"
	docker push $(ECR_REGISTRY)/e2b-templates:base
	docker push $(ECR_REGISTRY)/e2b-templates:code-interpreter
	docker push $(ECR_REGISTRY)/e2b-templates:desktop
	docker push $(ECR_REGISTRY)/e2b-templates:browser-use
	@echo "==> All template images pushed"

# ============================================================================
# Local Dev Targets
# ============================================================================

.PHONY: local-setup
local-setup: ## Set up local dev stack (PostgreSQL, Redis, DB migrations, API key)
	@echo "==> Setting up local development stack"
	$(PROJECT_ROOT)/scripts/local-setup.sh

.PHONY: local-api
local-api: ## Start the API server locally (port 50001)
	@echo "==> Starting API server"
	$(PROJECT_ROOT)/scripts/local-api.sh --port 50001

.PHONY: local-infra-up
local-infra-up: ## Start local PostgreSQL + Redis via Docker Compose
	@echo "==> Starting local infrastructure"
	docker compose -f $(PROJECT_ROOT)/docker-compose.local.yml up -d

.PHONY: local-infra-down
local-infra-down: ## Stop local PostgreSQL + Redis
	@echo "==> Stopping local infrastructure"
	docker compose -f $(PROJECT_ROOT)/docker-compose.local.yml down

# ============================================================================
# Test Targets
# ============================================================================

.PHONY: test-unit
test-unit: ## Run unit tests across all packages
	@echo "==> Running unit tests"
	cd $(INFRA_DIR) && go test -race -short ./packages/...

.PHONY: test-api
test-api: ## Run API integration tests (requires local API server)
	@echo "==> Running API integration tests"
	$(PROJECT_ROOT)/scripts/local-test.sh

.PHONY: test-api-go
test-api-go: ## Run Go API integration tests only
	@echo "==> Running Go API integration tests"
	cd $(PROJECT_ROOT)/tests && go test -tags integration -v -run TestAPI -count=1 -timeout 120s ./...

.PHONY: test-orchestrator
test-orchestrator: ## Run orchestrator integration tests (requires KVM host)
	@echo "==> Running orchestrator integration tests"
	cd $(PROJECT_ROOT)/tests/orchestrator && go test -tags integration -v -run TestOrchestrator -count=1 -timeout 300s ./...

.PHONY: test-sdk
test-sdk: ## Run SDK e2e tests (requires E2B_API_KEY and E2B_DOMAIN)
	@echo "==> Running SDK end-to-end tests"
	python3 -m pytest $(PROJECT_ROOT)/tests/test_sdk_e2e.py -v

.PHONY: test-sdk-smoke
test-sdk-smoke: ## Run SDK smoke test (quick, standalone script)
	@echo "==> Running SDK smoke test"
	python3 $(PROJECT_ROOT)/tests/test_sdk_e2e.py

.PHONY: test-sdk-fast
test-sdk-fast: ## Run SDK tests excluding slow tests
	@echo "==> Running SDK fast tests"
	python3 -m pytest $(PROJECT_ROOT)/tests/test_sdk_e2e.py -v -m "not slow"

.PHONY: test-all
test-all: test-unit test-api ## Run unit + API integration tests
	@echo "==> All tests passed"

.PHONY: lint
lint: ## Run linter
	@echo "==> Linting"
	cd $(INFRA_DIR) && golangci-lint run ./...

.PHONY: fmt
fmt: ## Format Go code
	@echo "==> Formatting"
	cd $(INFRA_DIR) && gofmt -s -w .

# ============================================================================
# Full Pipeline Targets
# ============================================================================

.PHONY: prepare
prepare: ## Build and push all artifacts (Docker images + orchestrator binary)
	@echo "==> Running full prepare pipeline"
	$(AWS_DIR)/nomad/prepare.sh

.PHONY: deploy
deploy: prepare nomad-deploy ## Full deploy: build, push, and deploy
	@echo "==> Full deployment complete"

# ============================================================================
# Help
# ============================================================================

.PHONY: help
help: ## Show this help message
	@echo "E2B Self-Hosted Makefile"
	@echo ""
	@echo "Usage: make <target>"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-30s\033[0m %s\n", $$1, $$2}'
