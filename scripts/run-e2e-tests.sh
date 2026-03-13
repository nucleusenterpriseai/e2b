#!/usr/bin/env bash
# =============================================================================
# E2B Self-Hosted End-to-End Test Runner
# =============================================================================
# Runs all test suites for a self-hosted E2B deployment:
#   1. Orchestrator integration tests  (tests/orchestrator/)
#   2. Upstream integration tests      (infra/tests/integration/)
#
# The script classifies upstream tests into three categories:
#   - RUN_AS_IS:    Work with self-hosted without changes
#   - NEEDS_DB:     Require POSTGRES_CONNECTION_STRING
#   - SKIP:         SaaS-only (Supabase auth, ClickHouse metrics, etc.)
#
# Prerequisites:
#   - Go toolchain installed
#   - Self-hosted deployment running (API, orchestrator, proxy)
#   - Environment variables set (see --help or .env.self-hosted)
#
# Usage:
#   ./scripts/run-e2e-tests.sh                         # Run all eligible tests
#   ./scripts/run-e2e-tests.sh --suite orchestrator    # Orchestrator tests only
#   ./scripts/run-e2e-tests.sh --suite upstream        # Upstream tests only
#   ./scripts/run-e2e-tests.sh --suite upstream --category api/sandboxes
#   ./scripts/run-e2e-tests.sh --env /path/to/.env     # Load env from file
#   ./scripts/run-e2e-tests.sh --report                # Generate test report
#   ./scripts/run-e2e-tests.sh --dry-run               # Show what would run
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ORCHESTRATOR_TESTS_DIR="$PROJECT_ROOT/tests/orchestrator"
UPSTREAM_TESTS_DIR="$PROJECT_ROOT/infra/tests/integration"
REPORT_DIR="$PROJECT_ROOT/test-reports"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SUITE="all"              # all | orchestrator | upstream
CATEGORY=""              # e.g., api/sandboxes, envd, orchestrator, proxies
ENV_FILE=""
DRY_RUN=false
GENERATE_REPORT=false
TIMEOUT="600s"
PARALLEL=4

# Orchestrator test flags (passed through to run-integration-tests.sh)
BUILD_ID="${TEST_BUILD_ID:-}"
TEMPLATE_ID="${TEST_TEMPLATE_ID:-}"
KERNEL_VERSION="${TEST_KERNEL_VERSION:-}"
FIRECRACKER_VERSION="${TEST_FIRECRACKER_VERSION:-}"

# ---------------------------------------------------------------------------
# Colors (disabled if not a terminal)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Run end-to-end tests for a self-hosted E2B deployment.

Options:
  --suite SUITE          Which test suite to run: all, orchestrator, upstream
                         (default: all)
  --category PATH        Upstream sub-path, e.g. api/sandboxes, envd, proxies
  --env FILE             Load environment variables from FILE
  --report               Generate a test report in test-reports/
  --dry-run              Print what would run without executing
  --timeout DURATION     Go test timeout (default: 600s)
  --parallel N           Max parallel tests (default: 4)
  --build-id ID          Orchestrator build ID
  --template-id ID       Template ID (default: base)
  --kernel VERSION       Kernel version for orchestrator tests
  --firecracker VERSION  Firecracker version for orchestrator tests
  -h, --help             Show this help message

Environment variables (see infra/tests/integration/.env.self-hosted):
  TESTS_API_SERVER_URL        API server URL
  TESTS_E2B_API_KEY           Team API key
  TESTS_E2B_ACCESS_TOKEN      Access token
  TESTS_SANDBOX_TEMPLATE_ID   Template ID (default: base)
  TESTS_ENVD_PROXY            Client-proxy / envd proxy URL
  TESTS_ORCHESTRATOR_HOST     Orchestrator gRPC address
  POSTGRES_CONNECTION_STRING  Database URL (for DB-dependent tests)
  ORCHESTRATOR_ADDR           Orchestrator gRPC address (orchestrator tests)
  PROXY_ADDR                  Sandbox proxy address (orchestrator tests)

Examples:
  # Run everything with env file
  $(basename "$0") --env .env.self-hosted.local

  # Run only upstream sandbox tests
  $(basename "$0") --suite upstream --category api/sandboxes

  # Dry run to see what tests would execute
  $(basename "$0") --dry-run
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --suite)       SUITE="$2"; shift 2 ;;
        --category)    CATEGORY="$2"; shift 2 ;;
        --env)         ENV_FILE="$2"; shift 2 ;;
        --report)      GENERATE_REPORT=true; shift ;;
        --dry-run)     DRY_RUN=true; shift ;;
        --timeout)     TIMEOUT="$2"; shift 2 ;;
        --parallel)    PARALLEL="$2"; shift 2 ;;
        --build-id)    BUILD_ID="$2"; shift 2 ;;
        --template-id) TEMPLATE_ID="$2"; shift 2 ;;
        --kernel)      KERNEL_VERSION="$2"; shift 2 ;;
        --firecracker) FIRECRACKER_VERSION="$2"; shift 2 ;;
        -h|--help)     usage ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            echo "Run '$(basename "$0") --help' for usage." >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Load environment file
# ---------------------------------------------------------------------------
if [[ -n "$ENV_FILE" ]]; then
    if [[ ! -f "$ENV_FILE" ]]; then
        echo "ERROR: Environment file not found: $ENV_FILE" >&2
        exit 1
    fi
    echo -e "${BLUE}Loading environment from: $ENV_FILE${NC}"
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
fi

# ---------------------------------------------------------------------------
# Test classification: which upstream tests to run / skip
# ---------------------------------------------------------------------------
# Tests that work with self-hosted using only API key auth (no DB needed):
UPSTREAM_RUN_AS_IS=(
    "api/health_test.go"
    "api/sandboxes/sandbox_test.go"
    "api/sandboxes/sandbox_kill_test.go"
    "api/sandboxes/sandbox_list_test.go"
    "api/sandboxes/sandbox_detail_test.go"
    "api/sandboxes/sandbox_pause_test.go"
    "api/sandboxes/sandbox_resume_test.go"
    "api/sandboxes/sandbox_timeout_test.go"
    "api/sandboxes/sandbox_refresh_test.go"
    "api/sandboxes/sandbox_connect_test.go"
    "api/sandboxes/sandbox_internet_test.go"
    "api/sandboxes/sandbox_secure_test.go"
    "api/sandboxes/sandbox_auto_pause_test.go"
    "api/sandboxes/sandbox_network_out_test.go"
    "api/sandboxes/snapshot_template_test.go"
    "api/metrics/sandbox_metrics_test.go"
    "api/metrics/sandbox_list_metrics_test.go"
    "api/volumes/crud_test.go"
    "envd/filesystem_test.go"
    "envd/process_test.go"
    "envd/auth_test.go"
    "envd/watcher_test.go"
    "envd/signatures_test.go"
    "envd/hyperloop_test.go"
    "envd/localhost_bind_test.go"
    "orchestrator/sandbox_test.go"
    "orchestrator/sandbox_entropy_test.go"
    "orchestrator/sandbox_memory_integrity_test.go"
    "orchestrator/sandbox_object_not_found_test.go"
    "proxies/closed_port_test.go"
    "proxies/sandbox_not_found_test.go"
    "proxies/auto_resume_test.go"
    "proxies/mask_request_host_test.go"
    "proxies/traffic_access_token_test.go"
)

# Tests that require POSTGRES_CONNECTION_STRING (create users/teams via DB):
UPSTREAM_NEEDS_DB=(
    "api/apikey_test.go"
    "api/access_token_test.go"
    "team_test.go"
    "api/metrics/team_metrics_test.go"
    "api/metrics/team_metrics_max_test.go"
)

# Tests that require SaaS-only features and should always be skipped:
UPSTREAM_SKIP=(
    "api/auth/supabase_test.go"
)

# Upstream tests that need DB also need Supabase JWT for some sub-tests.
# The test framework already handles this gracefully: WithSupabaseToken()
# calls t.Skip() when TESTS_SUPABASE_JWT_SECRET is empty, so those
# sub-tests will auto-skip without failing.

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
validate_orchestrator_env() {
    local missing=()
    # Orchestrator tests use env vars with defaults, so nothing strictly required
    # but we warn if the endpoint is probably not reachable
    if [[ -z "${ORCHESTRATOR_ADDR:-}" ]]; then
        echo -e "${YELLOW}  ORCHESTRATOR_ADDR not set; using default localhost:5008${NC}"
    fi
    if [[ -z "${PROXY_ADDR:-}" ]]; then
        echo -e "${YELLOW}  PROXY_ADDR not set; using default localhost:5007${NC}"
    fi
}

validate_upstream_env() {
    local missing=()
    [[ -z "${TESTS_API_SERVER_URL:-}" ]] && missing+=("TESTS_API_SERVER_URL")
    [[ -z "${TESTS_E2B_API_KEY:-}" ]] && missing+=("TESTS_E2B_API_KEY")
    [[ -z "${TESTS_E2B_ACCESS_TOKEN:-}" ]] && missing+=("TESTS_E2B_ACCESS_TOKEN")
    [[ -z "${TESTS_ENVD_PROXY:-}" ]] && missing+=("TESTS_ENVD_PROXY")

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${RED}ERROR: Missing required environment variables for upstream tests:${NC}" >&2
        for var in "${missing[@]}"; do
            echo "  - $var" >&2
        done
        echo "" >&2
        echo "Set these variables or use --env to load from a file." >&2
        echo "See: infra/tests/integration/.env.self-hosted" >&2
        return 1
    fi

    if [[ -z "${TESTS_SANDBOX_TEMPLATE_ID:-}" ]]; then
        export TESTS_SANDBOX_TEMPLATE_ID="base"
    fi

    if [[ -z "${POSTGRES_CONNECTION_STRING:-}" ]]; then
        echo -e "${YELLOW}  POSTGRES_CONNECTION_STRING not set; DB-dependent tests will be skipped${NC}"
    fi
}

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------
TOTAL_SUITES=0
PASSED_SUITES=0
FAILED_SUITES=0
SKIPPED_SUITES=0

declare -a RESULTS=()

record_result() {
    local name="$1" status="$2" duration="$3"
    RESULTS+=("$status|$name|${duration}s")
    ((TOTAL_SUITES++)) || true
    case "$status" in
        PASS) ((PASSED_SUITES++)) || true ;;
        FAIL) ((FAILED_SUITES++)) || true ;;
        SKIP) ((SKIPPED_SUITES++)) || true ;;
    esac
}

# ---------------------------------------------------------------------------
# Run orchestrator tests
# ---------------------------------------------------------------------------
run_orchestrator_tests() {
    echo ""
    echo -e "${BOLD}================================================================${NC}"
    echo -e "${BOLD}  Suite 1: Orchestrator Integration Tests${NC}"
    echo -e "${BOLD}================================================================${NC}"

    if [[ ! -d "$ORCHESTRATOR_TESTS_DIR" ]]; then
        echo -e "${YELLOW}  SKIP: Test directory not found: $ORCHESTRATOR_TESTS_DIR${NC}"
        record_result "orchestrator" "SKIP" "0"
        return 0
    fi

    validate_orchestrator_env

    # Forward flags
    [[ -n "$BUILD_ID" ]] && export TEST_BUILD_ID="$BUILD_ID"
    [[ -n "$TEMPLATE_ID" ]] && export TEST_TEMPLATE_ID="$TEMPLATE_ID"
    [[ -n "$KERNEL_VERSION" ]] && export TEST_KERNEL_VERSION="$KERNEL_VERSION"
    [[ -n "$FIRECRACKER_VERSION" ]] && export TEST_FIRECRACKER_VERSION="$FIRECRACKER_VERSION"

    echo "  Directory:     $ORCHESTRATOR_TESTS_DIR"
    echo "  Build ID:      ${TEST_BUILD_ID:-<default: base-build>}"
    echo "  Template:      ${TEST_TEMPLATE_ID:-<default: base>}"
    echo "  Orchestrator:  ${ORCHESTRATOR_ADDR:-localhost:5008}"
    echo "  Proxy:         ${PROXY_ADDR:-localhost:5007}"
    echo ""

    if $DRY_RUN; then
        echo -e "${BLUE}  [DRY RUN] Would run: go test -tags integration -v -count=1 -timeout $TIMEOUT -skip '^TestSandboxPauseResume$' ./...${NC}"
        record_result "orchestrator" "SKIP" "0"
        return 0
    fi

    local start_time
    start_time=$(date +%s)

    set +e
    (cd "$ORCHESTRATOR_TESTS_DIR" && go test \
        -tags integration \
        -v \
        -count=1 \
        -timeout "$TIMEOUT" \
        -skip "^TestSandboxPauseResume$" \
        ./... 2>&1) | tee "${REPORT_DIR}/orchestrator.log"
    local exit_code=${PIPESTATUS[0]}
    set -e

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    if [[ $exit_code -eq 0 ]]; then
        record_result "orchestrator" "PASS" "$duration"
        echo -e "${GREEN}  Orchestrator tests: PASS (${duration}s)${NC}"
    else
        record_result "orchestrator" "FAIL" "$duration"
        echo -e "${RED}  Orchestrator tests: FAIL (${duration}s, exit=$exit_code)${NC}"
    fi

    return $exit_code
}

# ---------------------------------------------------------------------------
# Run upstream tests (one category at a time)
# ---------------------------------------------------------------------------
run_upstream_category() {
    local category="$1"
    local test_path="./internal/tests/${category}"
    local label="upstream/${category}"

    # Check if the path exists
    if [[ "$category" == *.go ]]; then
        # Single file
        test_path="./internal/tests/${category}"
        if [[ ! -f "$UPSTREAM_TESTS_DIR/$test_path" ]]; then
            echo -e "${YELLOW}  SKIP: File not found: $test_path${NC}"
            record_result "$label" "SKIP" "0"
            return 0
        fi
    else
        # Directory
        if [[ ! -d "$UPSTREAM_TESTS_DIR/internal/tests/${category}" ]]; then
            echo -e "${YELLOW}  SKIP: Directory not found: internal/tests/${category}${NC}"
            record_result "$label" "SKIP" "0"
            return 0
        fi
        test_path="./internal/tests/${category}/..."
    fi

    if $DRY_RUN; then
        echo -e "${BLUE}  [DRY RUN] Would run: go test -v -count=1 -timeout $TIMEOUT -parallel $PARALLEL $test_path${NC}"
        record_result "$label" "SKIP" "0"
        return 0
    fi

    local start_time
    start_time=$(date +%s)

    local log_file="${REPORT_DIR}/upstream-$(echo "$category" | tr '/' '-').log"

    set +e
    (cd "$UPSTREAM_TESTS_DIR" && go test \
        -v \
        -count=1 \
        -timeout "$TIMEOUT" \
        -parallel "$PARALLEL" \
        "$test_path" 2>&1) | tee "$log_file"
    local exit_code=${PIPESTATUS[0]}
    set -e

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    if [[ $exit_code -eq 0 ]]; then
        record_result "$label" "PASS" "$duration"
        echo -e "${GREEN}  ${label}: PASS (${duration}s)${NC}"
    else
        record_result "$label" "FAIL" "$duration"
        echo -e "${RED}  ${label}: FAIL (${duration}s, exit=$exit_code)${NC}"
    fi

    return $exit_code
}

run_upstream_tests() {
    echo ""
    echo -e "${BOLD}================================================================${NC}"
    echo -e "${BOLD}  Suite 2: Upstream Integration Tests (Self-Hosted)${NC}"
    echo -e "${BOLD}================================================================${NC}"

    if [[ ! -d "$UPSTREAM_TESTS_DIR" ]]; then
        echo -e "${YELLOW}  SKIP: Upstream test directory not found: $UPSTREAM_TESTS_DIR${NC}"
        record_result "upstream" "SKIP" "0"
        return 0
    fi

    validate_upstream_env || return 1

    echo "  API Server:    ${TESTS_API_SERVER_URL}"
    echo "  Template:      ${TESTS_SANDBOX_TEMPLATE_ID}"
    echo "  Envd Proxy:    ${TESTS_ENVD_PROXY}"
    echo "  Orchestrator:  ${TESTS_ORCHESTRATOR_HOST:-<not set>}"
    echo "  Database:      ${POSTGRES_CONNECTION_STRING:+set}${POSTGRES_CONNECTION_STRING:-<not set>}"
    echo ""

    local has_db=false
    [[ -n "${POSTGRES_CONNECTION_STRING:-}" ]] && has_db=true

    local overall_exit=0

    # If a specific category was requested, run only that
    if [[ -n "$CATEGORY" ]]; then
        run_upstream_category "$CATEGORY" || overall_exit=1
        return $overall_exit
    fi

    # Run the main_test.go first (caches template)
    echo -e "${BOLD}--- Caching template (main_test.go) ---${NC}"
    if ! $DRY_RUN; then
        set +e
        (cd "$UPSTREAM_TESTS_DIR" && go test \
            -v \
            -count=1 \
            -timeout "$TIMEOUT" \
            -run "TestCacheTemplate" \
            ./internal/main_test.go 2>&1) | tee "${REPORT_DIR}/upstream-cache.log"
        local cache_exit=${PIPESTATUS[0]}
        set -e

        if [[ $cache_exit -ne 0 ]]; then
            echo -e "${RED}  Template caching failed; upstream tests may not work${NC}"
        fi
    fi

    # Determine which categories to run
    declare -A categories_to_run

    for test_file in "${UPSTREAM_RUN_AS_IS[@]}"; do
        local dir
        dir=$(dirname "$test_file")
        categories_to_run["$dir"]=1
    done

    if $has_db; then
        for test_file in "${UPSTREAM_NEEDS_DB[@]}"; do
            local dir
            dir=$(dirname "$test_file")
            categories_to_run["$dir"]=1
        done
    else
        echo ""
        echo -e "${YELLOW}  DB-dependent tests will be skipped (no POSTGRES_CONNECTION_STRING):${NC}"
        for test_file in "${UPSTREAM_NEEDS_DB[@]}"; do
            echo -e "${YELLOW}    - $test_file${NC}"
            record_result "upstream/${test_file}" "SKIP" "0"
        done
    fi

    echo ""
    echo -e "${YELLOW}  SaaS-only tests (always skipped):${NC}"
    for test_file in "${UPSTREAM_SKIP[@]}"; do
        echo -e "${YELLOW}    - $test_file${NC}"
        record_result "upstream/${test_file}" "SKIP" "0"
    done

    # Build the skip pattern for SaaS-only tests
    # Supabase tests auto-skip when TESTS_SUPABASE_JWT_SECRET is empty,
    # but we also filter them out to keep the output clean.
    local skip_pattern=""
    if [[ -z "${TESTS_SUPABASE_JWT_SECRET:-}" ]]; then
        skip_pattern="TestSandboxCreateWithSupabaseToken|TestSandboxCreateWithForeignTeamAccess"
    fi

    echo ""

    # Run each category
    local sorted_categories
    sorted_categories=$(echo "${!categories_to_run[@]}" | tr ' ' '\n' | sort)

    for category in $sorted_categories; do
        echo -e "${BOLD}--- upstream/${category} ---${NC}"
        run_upstream_category "$category" || overall_exit=1
        echo ""
    done

    return $overall_exit
}

# ---------------------------------------------------------------------------
# Generate report
# ---------------------------------------------------------------------------
generate_report() {
    local report_file="${REPORT_DIR}/e2e-report-$(date +%Y%m%d-%H%M%S).txt"

    {
        echo "================================================================"
        echo "  E2B Self-Hosted E2E Test Report"
        echo "  Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "================================================================"
        echo ""
        echo "Environment:"
        echo "  API Server:       ${TESTS_API_SERVER_URL:-<not set>}"
        echo "  Template:         ${TESTS_SANDBOX_TEMPLATE_ID:-base}"
        echo "  Envd Proxy:       ${TESTS_ENVD_PROXY:-<not set>}"
        echo "  Orchestrator:     ${TESTS_ORCHESTRATOR_HOST:-<not set>}"
        echo "  Database:         ${POSTGRES_CONNECTION_STRING:+configured}${POSTGRES_CONNECTION_STRING:-<not set>}"
        echo "  Orch. Addr:       ${ORCHESTRATOR_ADDR:-localhost:5008}"
        echo "  Proxy Addr:       ${PROXY_ADDR:-localhost:5007}"
        echo ""
        echo "================================================================"
        echo "  Results Summary"
        echo "================================================================"
        echo ""
        printf "  %-50s %s\n" "SUITE" "STATUS"
        printf "  %-50s %s\n" "-----" "------"
        for result in "${RESULTS[@]}"; do
            local status name duration
            IFS='|' read -r status name duration <<< "$result"
            local color=""
            case "$status" in
                PASS) color="$GREEN" ;;
                FAIL) color="$RED" ;;
                SKIP) color="$YELLOW" ;;
            esac
            printf "  %-50s ${color}%-6s${NC} %s\n" "$name" "$status" "$duration"
        done
        echo ""
        echo "================================================================"
        echo "  Total: $TOTAL_SUITES  Passed: $PASSED_SUITES  Failed: $FAILED_SUITES  Skipped: $SKIPPED_SUITES"
        echo "================================================================"
    } | tee "$report_file"

    echo ""
    echo "Report saved to: $report_file"
}

# ---------------------------------------------------------------------------
# Print summary
# ---------------------------------------------------------------------------
print_summary() {
    echo ""
    echo -e "${BOLD}================================================================${NC}"
    echo -e "${BOLD}  E2E Test Summary${NC}"
    echo -e "${BOLD}================================================================${NC}"
    echo ""
    printf "  %-50s %s\n" "SUITE" "STATUS"
    printf "  %-50s %s\n" "-----" "------"
    for result in "${RESULTS[@]}"; do
        local status name duration
        IFS='|' read -r status name duration <<< "$result"
        local color=""
        case "$status" in
            PASS) color="$GREEN" ;;
            FAIL) color="$RED" ;;
            SKIP) color="$YELLOW" ;;
        esac
        printf "  %-50s ${color}%-6s${NC} %s\n" "$name" "$status" "$duration"
    done
    echo ""
    echo -e "${BOLD}  Total: $TOTAL_SUITES  Passed: $PASSED_SUITES  Failed: $FAILED_SUITES  Skipped: $SKIPPED_SUITES${NC}"
    echo -e "${BOLD}================================================================${NC}"

    if [[ $FAILED_SUITES -gt 0 ]]; then
        echo -e "${RED}  OVERALL: FAIL${NC}"
    elif [[ $PASSED_SUITES -gt 0 ]]; then
        echo -e "${GREEN}  OVERALL: PASS${NC}"
    else
        echo -e "${YELLOW}  OVERALL: NO TESTS RAN${NC}"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo -e "${BOLD}================================================================${NC}"
    echo -e "${BOLD}  E2B Self-Hosted E2E Test Runner${NC}"
    echo -e "${BOLD}================================================================${NC}"
    echo "  Suite:    $SUITE"
    echo "  Timeout:  $TIMEOUT"
    echo "  Parallel: $PARALLEL"
    if [[ -n "$CATEGORY" ]]; then
        echo "  Category: $CATEGORY"
    fi
    if $DRY_RUN; then
        echo -e "  ${YELLOW}Mode: DRY RUN${NC}"
    fi

    # Create report directory
    mkdir -p "$REPORT_DIR"

    local overall_exit=0

    case "$SUITE" in
        all)
            run_orchestrator_tests || overall_exit=1
            run_upstream_tests || overall_exit=1
            ;;
        orchestrator)
            run_orchestrator_tests || overall_exit=1
            ;;
        upstream)
            run_upstream_tests || overall_exit=1
            ;;
        *)
            echo "ERROR: Unknown suite: $SUITE (expected: all, orchestrator, upstream)" >&2
            exit 1
            ;;
    esac

    print_summary

    if $GENERATE_REPORT; then
        generate_report
    fi

    exit $overall_exit
}

main
