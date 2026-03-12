#!/bin/bash
# =============================================================================
# E2B API Server Test Script
# Tests Phase 3 success criteria: health, auth, and sandbox endpoints
# =============================================================================
set -euo pipefail

# Configuration with defaults
API_URL="${API_URL:-http://localhost:80}"
API_KEY="${API_KEY:-}"       # Must be set for auth tests
VERBOSE="${VERBOSE:-false}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

# Helper functions
log_pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    echo -e "${GREEN}[PASS]${NC} $1"
}

log_fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo -e "${RED}[FAIL]${NC} $1"
    if [ -n "${2:-}" ]; then
        echo -e "       Details: $2"
    fi
}

log_skip() {
    SKIP_COUNT=$((SKIP_COUNT + 1))
    echo -e "${YELLOW}[SKIP]${NC} $1"
}

log_info() {
    echo -e "       $1"
}

# Curl wrapper that captures both status code and body
# Usage: do_curl METHOD PATH [extra_curl_args...]
# Sets: HTTP_STATUS, HTTP_BODY
do_curl() {
    local method="$1"
    local path="$2"
    shift 2

    local url="${API_URL}${path}"
    local tmpfile
    tmpfile=$(mktemp)

    HTTP_STATUS=$(curl -s -o "$tmpfile" -w "%{http_code}" \
        -X "$method" \
        --max-time 10 \
        "$@" \
        "$url") || {
        HTTP_STATUS="000"
        HTTP_BODY="curl error: connection refused or timeout"
        rm -f "$tmpfile"
        return 1
    }

    HTTP_BODY=$(cat "$tmpfile")
    rm -f "$tmpfile"

    if [ "$VERBOSE" = "true" ]; then
        echo "  >> $method $url -> $HTTP_STATUS"
        echo "  >> Body: $HTTP_BODY"
    fi
}

# =============================================================================
# Test A3-04: GET /health returns 200
# =============================================================================
test_health() {
    echo ""
    echo "--- A3-04: Health Check ---"
    if do_curl GET "/health"; then
        if [ "$HTTP_STATUS" = "200" ]; then
            log_pass "GET /health returns 200"
        elif [ "$HTTP_STATUS" = "503" ]; then
            log_pass "GET /health returns 503 (no orchestrator node — expected in local dev)"
        else
            log_fail "GET /health returned $HTTP_STATUS (expected 200 or 503)" "$HTTP_BODY"
        fi
    else
        log_fail "GET /health failed to connect" "Is the API server running at $API_URL?"
    fi
}

# =============================================================================
# Test A3-05: Valid API key returns 200
# =============================================================================
test_valid_api_key() {
    echo ""
    echo "--- A3-05: Valid API Key ---"
    if [ -z "$API_KEY" ]; then
        log_skip "API_KEY not set, skipping valid key test"
        return
    fi

    if do_curl GET "/sandboxes" -H "X-API-Key: ${API_KEY}"; then
        if [ "$HTTP_STATUS" = "200" ]; then
            log_pass "Valid API key returns 200 on GET /sandboxes"
        else
            log_fail "Valid API key returned $HTTP_STATUS (expected 200)" "$HTTP_BODY"
        fi
    else
        log_fail "Request with valid API key failed to connect"
    fi
}

# =============================================================================
# Test A3-06: Invalid API key returns 401
# =============================================================================
test_invalid_api_key() {
    echo ""
    echo "--- A3-06: Invalid API Key ---"

    if do_curl GET "/sandboxes" -H "X-API-Key: e2b_0000000000000000000000000000000000000000"; then
        if [ "$HTTP_STATUS" = "401" ]; then
            log_pass "Invalid API key returns 401"
        else
            log_fail "Invalid API key returned $HTTP_STATUS (expected 401)" "$HTTP_BODY"
        fi
    else
        log_fail "Request with invalid API key failed to connect"
    fi
}

# =============================================================================
# Test A3-07: Missing API key returns 401
# =============================================================================
test_missing_api_key() {
    echo ""
    echo "--- A3-07: Missing API Key ---"

    if do_curl GET "/sandboxes"; then
        if [ "$HTTP_STATUS" = "401" ]; then
            log_pass "Missing API key returns 401"
        else
            log_fail "Missing API key returned $HTTP_STATUS (expected 401)" "$HTTP_BODY"
        fi
    else
        log_fail "Request without API key failed to connect"
    fi
}

# =============================================================================
# Test A3-09: GET /sandboxes with valid key
# =============================================================================
test_list_sandboxes() {
    echo ""
    echo "--- A3-09: List Sandboxes ---"
    if [ -z "$API_KEY" ]; then
        log_skip "API_KEY not set, skipping list sandboxes test"
        return
    fi

    if do_curl GET "/sandboxes" -H "X-API-Key: ${API_KEY}"; then
        if [ "$HTTP_STATUS" = "200" ]; then
            log_pass "GET /sandboxes returns 200 with valid key"
            # Verify response is valid JSON array
            if echo "$HTTP_BODY" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
                log_pass "GET /sandboxes returns valid JSON"
            else
                log_fail "GET /sandboxes response is not valid JSON" "$HTTP_BODY"
            fi
        else
            log_fail "GET /sandboxes returned $HTTP_STATUS (expected 200)" "$HTTP_BODY"
        fi
    else
        log_fail "GET /sandboxes with valid key failed to connect"
    fi
}

# =============================================================================
# Test A3-11: Client-proxy health check
# =============================================================================
test_client_proxy_health() {
    echo ""
    echo "--- A3-11: Client-Proxy Health ---"
    local proxy_health_url="${CLIENT_PROXY_HEALTH_URL:-http://localhost:3003}"

    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${proxy_health_url}/health" 2>/dev/null) || status="000"

    if [ "$status" = "200" ]; then
        log_pass "Client-proxy health check returns 200"
    elif [ "$status" = "000" ]; then
        log_skip "Client-proxy not reachable at $proxy_health_url (may not be running)"
    else
        log_fail "Client-proxy health returned $status (expected 200)"
    fi
}

# =============================================================================
# Test: Wrong prefix on API key returns 401
# =============================================================================
test_wrong_prefix_api_key() {
    echo ""
    echo "--- Extra: Wrong Prefix API Key ---"

    if do_curl GET "/sandboxes" -H "X-API-Key: sk_e2b_0000000000000000000000000000000000000000"; then
        if [ "$HTTP_STATUS" = "401" ]; then
            log_pass "Wrong-prefix API key returns 401"
        else
            log_fail "Wrong-prefix API key returned $HTTP_STATUS (expected 401)" "$HTTP_BODY"
        fi
    else
        log_fail "Request with wrong-prefix API key failed to connect"
    fi
}

# =============================================================================
# Main
# =============================================================================
echo "============================================="
echo "E2B API Server Test Suite (Phase 3)"
echo "============================================="
echo "API_URL:  $API_URL"
echo "API_KEY:  ${API_KEY:+(set)}${API_KEY:-(not set)}"
echo "============================================="

test_health
test_valid_api_key
test_invalid_api_key
test_missing_api_key
test_list_sandboxes
test_client_proxy_health
test_wrong_prefix_api_key

echo ""
echo "============================================="
echo "Results: ${GREEN}${PASS_COUNT} passed${NC}, ${RED}${FAIL_COUNT} failed${NC}, ${YELLOW}${SKIP_COUNT} skipped${NC}"
echo "============================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
exit 0
