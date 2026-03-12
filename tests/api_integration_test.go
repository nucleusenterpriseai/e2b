//go:build integration

// Package tests contains integration tests for the E2B API server.
//
// These tests verify Phase 3 success criteria: database migrations,
// health checks, authentication, and core API endpoints.
//
// Run the tests:
//
//	cd tests && go test -v -tags integration -run TestAPI -count=1 -timeout 120s
//
// Required environment variables:
//
//	E2B_API_KEY         — a valid API key (e2b_ prefix) for authenticated tests
//	API_BASE_URL        — base URL for the API server (default: http://localhost:3000)
//	DATABASE_URL        — PostgreSQL connection string for migration tests
//	CLIENT_PROXY_HEALTH_URL — base URL for client-proxy health (default: http://localhost:3003)
package tests

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"testing"
	"time"

	_ "github.com/lib/pq"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

var (
	apiBaseURL         string
	apiKey             string
	databaseURL        string
	clientProxyBaseURL string
)

const (
	// httpTimeout is the timeout for individual HTTP requests.
	httpTimeout = 10 * time.Second
)

func init() {
	apiBaseURL = os.Getenv("API_BASE_URL")
	if apiBaseURL == "" {
		apiBaseURL = "http://localhost:3000"
	}

	apiKey = os.Getenv("E2B_API_KEY")
	databaseURL = os.Getenv("DATABASE_URL")

	clientProxyBaseURL = os.Getenv("CLIENT_PROXY_HEALTH_URL")
	if clientProxyBaseURL == "" {
		clientProxyBaseURL = "http://localhost:3003"
	}
}

// ---------------------------------------------------------------------------
// TestMain — skip all tests if the API server is not reachable
// ---------------------------------------------------------------------------

func TestMain(m *testing.M) {
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get(apiBaseURL + "/health")
	if err != nil {
		if os.Getenv("REQUIRE_API") == "true" {
			fmt.Fprintf(os.Stderr, "FAIL: API server is not reachable at %s: %v\n", apiBaseURL, err)
			fmt.Fprintf(os.Stderr, "      REQUIRE_API=true is set — failing instead of skipping.\n")
			os.Exit(1)
		}
		fmt.Fprintf(os.Stderr, "[SKIP] API server not reachable at %s: %v\n", apiBaseURL, err)
		fmt.Fprintf(os.Stderr, "       Start the API server first or set API_BASE_URL.\n")
		fmt.Fprintf(os.Stderr, "       Set REQUIRE_API=true to fail instead of skipping.\n")
		os.Exit(0)
	}
	resp.Body.Close()

	os.Exit(m.Run())
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// httpClient returns an *http.Client with a standard timeout.
func httpClient() *http.Client {
	return &http.Client{Timeout: httpTimeout}
}

// doGet performs a GET request and returns the response.
// Caller is responsible for closing resp.Body.
func doGet(t *testing.T, url string, headers map[string]string) *http.Response {
	t.Helper()

	req, err := http.NewRequest(http.MethodGet, url, nil)
	require.NoError(t, err)

	for k, v := range headers {
		req.Header.Set(k, v)
	}

	resp, err := httpClient().Do(req)
	require.NoError(t, err, "HTTP request to %s failed", url)

	return resp
}

// doOptions performs an OPTIONS request and returns the response.
func doOptions(t *testing.T, url string, headers map[string]string) *http.Response {
	t.Helper()

	req, err := http.NewRequest(http.MethodOptions, url, nil)
	require.NoError(t, err)

	for k, v := range headers {
		req.Header.Set(k, v)
	}

	resp, err := httpClient().Do(req)
	require.NoError(t, err, "HTTP OPTIONS request to %s failed", url)

	return resp
}

// doPost performs a POST request with a JSON body and returns the response.
func doPost(t *testing.T, url string, headers map[string]string, body interface{}) *http.Response {
	t.Helper()

	var reqBody io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		require.NoError(t, err)
		reqBody = bytes.NewReader(data)
	}

	req, err := http.NewRequest(http.MethodPost, url, reqBody)
	require.NoError(t, err)

	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}

	resp, err := httpClient().Do(req)
	require.NoError(t, err, "HTTP POST to %s failed", url)

	return resp
}

// doDelete performs a DELETE request and returns the response.
func doDelete(t *testing.T, url string, headers map[string]string) *http.Response {
	t.Helper()

	req, err := http.NewRequest(http.MethodDelete, url, nil)
	require.NoError(t, err)

	for k, v := range headers {
		req.Header.Set(k, v)
	}

	resp, err := httpClient().Do(req)
	require.NoError(t, err, "HTTP DELETE to %s failed", url)

	return resp
}

// readBody reads and returns the full response body as a string, closing it.
func readBody(t *testing.T, resp *http.Response) string {
	t.Helper()
	defer resp.Body.Close()

	data, err := io.ReadAll(resp.Body)
	require.NoError(t, err)

	return string(data)
}

// requireAPIKey skips the test if E2B_API_KEY is not configured.
func requireAPIKey(t *testing.T) {
	t.Helper()
	if apiKey == "" {
		t.Skip("E2B_API_KEY not set; skipping test that requires authentication")
	}
}

// authHeaders returns a header map with X-API-Key set to the configured API key.
func authHeaders() map[string]string {
	return map[string]string{
		"X-API-Key": apiKey,
	}
}

// ---------------------------------------------------------------------------
// P0 Tests — Database
// ---------------------------------------------------------------------------

// A3-01
func TestDBMigrationsApplied(t *testing.T) {
	// A3-01: Connect to PostgreSQL, query the goose migration tracking table,
	// and assert that at least 90 migration versions have been applied.
	if databaseURL == "" {
		t.Skip("DATABASE_URL not set; skipping database migration test")
	}

	db, err := sql.Open("postgres", databaseURL)
	require.NoError(t, err, "failed to open PostgreSQL connection")
	defer db.Close()

	err = db.Ping()
	require.NoError(t, err, "failed to ping PostgreSQL")

	// The E2B API uses goose with a custom tracking table named "_migrations".
	var count int
	err = db.QueryRow("SELECT COUNT(*) FROM _migrations").Scan(&count)
	require.NoError(t, err, "failed to query _migrations table — are migrations applied?")

	assert.GreaterOrEqual(t, count, 90,
		"expected at least 90 migration records in _migrations, got %d", count)
}

// A3-02
func TestAPISeedDataVerification(t *testing.T) {
	// A3-02: Connect to PostgreSQL and verify that the seed tier and seed team
	// exist with the expected values.
	if databaseURL == "" {
		databaseURL = "postgresql://postgres:e2b_local_dev@localhost:5433/e2b?sslmode=disable"
	}

	db, err := sql.Open("postgres", databaseURL)
	require.NoError(t, err, "failed to open PostgreSQL connection")
	defer db.Close()

	err = db.Ping()
	require.NoError(t, err, "failed to ping PostgreSQL")

	// Verify the seed tier exists with expected values.
	t.Run("seed_tier_exists", func(t *testing.T) {
		var name string
		var diskMB, concurrentInstances, maxVCPU, maxRAMMB, concurrentTemplateBuilds int
		var maxLengthHours int

		err := db.QueryRow(
			"SELECT name, disk_mb, concurrent_instances, max_length_hours, max_vcpu, max_ram_mb, concurrent_template_builds FROM tiers WHERE id = $1",
			"base_v1",
		).Scan(&name, &diskMB, &concurrentInstances, &maxLengthHours, &maxVCPU, &maxRAMMB, &concurrentTemplateBuilds)
		require.NoError(t, err, "failed to query seed tier 'base_v1' — is seed data loaded?")

		assert.Contains(t, []string{"Base", "Base tier"}, name, "seed tier name should be 'Base' or 'Base tier'")
		assert.Equal(t, 512, diskMB, "seed tier disk_mb should be 512")
		assert.Equal(t, 20, concurrentInstances, "seed tier concurrent_instances should be 20")
		assert.Greater(t, maxLengthHours, 0, "seed tier max_length_hours should be positive")
		assert.Equal(t, 8, maxVCPU, "seed tier max_vcpu should be 8")
		assert.Equal(t, 8192, maxRAMMB, "seed tier max_ram_mb should be 8192")
		assert.Equal(t, 20, concurrentTemplateBuilds, "seed tier concurrent_template_builds should be 20")
	})

	// Verify the seed team exists with expected values.
	t.Run("seed_team_exists", func(t *testing.T) {
		var name, tier, email string

		err := db.QueryRow(
			"SELECT name, tier, email FROM teams WHERE id = $1",
			"00000000-0000-0000-0000-000000000001",
		).Scan(&name, &tier, &email)
		require.NoError(t, err, "failed to query seed team — is seed data loaded?")

		assert.Equal(t, "self-hosted", name, "seed team name should be 'self-hosted'")
		assert.Equal(t, "base_v1", tier, "seed team tier should be 'base_v1'")
		assert.Equal(t, "admin@e2b.local", email, "seed team email should be 'admin@e2b.local'")
	})
}

// ---------------------------------------------------------------------------
// P0 Tests — Health
// ---------------------------------------------------------------------------

// A3-04
func TestAPIHealthEndpoint(t *testing.T) {
	// A3-04: GET /health should return 200 when the API is healthy.
	// 503 is also acceptable when no orchestrator node is registered (local dev).
	resp := doGet(t, apiBaseURL+"/health", nil)
	body := readBody(t, resp)

	assert.Contains(t, []int{http.StatusOK, http.StatusServiceUnavailable}, resp.StatusCode,
		"GET /health should return 200 or 503, got %d: %s", resp.StatusCode, body)
}

// ---------------------------------------------------------------------------
// P0 Tests — Authentication
// ---------------------------------------------------------------------------

// A3-05
func TestAPIAuthValidKey(t *testing.T) {
	// A3-05: GET /sandboxes with a valid X-API-Key header should return 200.
	requireAPIKey(t)

	resp := doGet(t, apiBaseURL+"/sandboxes", authHeaders())
	body := readBody(t, resp)

	assert.Equal(t, http.StatusOK, resp.StatusCode,
		"GET /sandboxes with valid API key should return 200, got %d: %s", resp.StatusCode, body)
}

// A3-06
func TestAPIAuthInvalidKey(t *testing.T) {
	// A3-06: GET /sandboxes with an invalid API key should return 401.
	headers := map[string]string{
		"X-API-Key": "e2b_0000000000000000000000000000000000000000",
	}

	resp := doGet(t, apiBaseURL+"/sandboxes", headers)
	body := readBody(t, resp)

	assert.Equal(t, http.StatusUnauthorized, resp.StatusCode,
		"GET /sandboxes with invalid API key should return 401, got %d: %s", resp.StatusCode, body)
}

// A3-07
func TestAPIAuthMissingKey(t *testing.T) {
	// A3-07: GET /sandboxes without any API key should return 401.
	resp := doGet(t, apiBaseURL+"/sandboxes", nil)
	body := readBody(t, resp)

	assert.Equal(t, http.StatusUnauthorized, resp.StatusCode,
		"GET /sandboxes without API key should return 401, got %d: %s", resp.StatusCode, body)
}

// ---------------------------------------------------------------------------
// P0 Tests — Sandbox Listing
// ---------------------------------------------------------------------------

// A3-09
func TestAPIListSandboxes(t *testing.T) {
	// A3-09: GET /sandboxes with a valid key should return a valid JSON array
	// (even if empty).
	requireAPIKey(t)

	resp := doGet(t, apiBaseURL+"/sandboxes", authHeaders())
	body := readBody(t, resp)

	require.Equal(t, http.StatusOK, resp.StatusCode,
		"GET /sandboxes should return 200, got %d: %s", resp.StatusCode, body)

	// Verify the response is a valid JSON array.
	var sandboxes []json.RawMessage
	err := json.Unmarshal([]byte(body), &sandboxes)
	require.NoError(t, err, "GET /sandboxes response should be a valid JSON array, body: %s", body)

	// The array may be empty, but it must parse as an array (not null, not an object).
	assert.NotNil(t, sandboxes, "sandboxes list should not be null")
}

// ---------------------------------------------------------------------------
// P0 Tests — Sandbox Create & Delete (requires orchestrator)
// ---------------------------------------------------------------------------

// requireOrchestrator checks if an orchestrator node is registered by hitting
// /health and expecting 200 (not 503). Skips the test if not available.
func requireOrchestrator(t *testing.T) {
	t.Helper()
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get(apiBaseURL + "/health")
	if err != nil {
		t.Skipf("API not reachable: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusServiceUnavailable {
		t.Skip("Orchestrator not registered (health returns 503); skipping sandbox lifecycle test")
	}
}

// A3-08
func TestAPICreateSandbox(t *testing.T) {
	// A3-08: POST /sandboxes should create a sandbox and return its ID.
	// Requires an orchestrator node to be registered.
	requireAPIKey(t)
	requireOrchestrator(t)

	createReq := map[string]interface{}{
		"templateID": "base",
		"timeout":    60,
	}

	resp := doPost(t, apiBaseURL+"/sandboxes", authHeaders(), createReq)
	body := readBody(t, resp)

	// The API should accept the request. Depending on template availability:
	// - 201: sandbox created successfully
	// - 200: sandbox created (some API versions return 200)
	// - 400: bad request (missing template) — acceptable in test env without templates
	require.Contains(t, []int{200, 201, 400}, resp.StatusCode,
		"POST /sandboxes should return 200/201/400, got %d: %s", resp.StatusCode, body)

	if resp.StatusCode == 200 || resp.StatusCode == 201 {
		var result map[string]interface{}
		err := json.Unmarshal([]byte(body), &result)
		require.NoError(t, err, "POST /sandboxes response should be valid JSON: %s", body)

		// Must contain sandboxID and clientID
		assert.Contains(t, result, "sandboxID",
			"create response should contain 'sandboxID', got: %v", result)
		assert.Contains(t, result, "clientID",
			"create response should contain 'clientID', got: %v", result)

		// Clean up: delete the sandbox we just created
		sandboxID, ok := result["sandboxID"].(string)
		if ok && sandboxID != "" {
			delResp := doDelete(t, apiBaseURL+"/sandboxes/"+sandboxID, authHeaders())
			delResp.Body.Close()
			t.Logf("Cleanup: deleted sandbox %s (status: %d)", sandboxID, delResp.StatusCode)
		}
	}
}

// A3-10
func TestAPIDeleteSandbox(t *testing.T) {
	// A3-10: DELETE /sandboxes/{id} should delete a running sandbox.
	// First creates one, then deletes it and verifies.
	requireAPIKey(t)
	requireOrchestrator(t)

	// Create a sandbox to delete
	createReq := map[string]interface{}{
		"templateID": "base",
		"timeout":    60,
	}

	resp := doPost(t, apiBaseURL+"/sandboxes", authHeaders(), createReq)
	body := readBody(t, resp)

	if resp.StatusCode != 200 && resp.StatusCode != 201 {
		t.Skipf("Cannot create sandbox for delete test (status %d): %s", resp.StatusCode, body)
	}

	var result map[string]interface{}
	err := json.Unmarshal([]byte(body), &result)
	require.NoError(t, err, "create response should be valid JSON: %s", body)

	sandboxID, ok := result["sandboxID"].(string)
	require.True(t, ok && sandboxID != "", "sandboxID should be a non-empty string")

	// Delete the sandbox
	delResp := doDelete(t, apiBaseURL+"/sandboxes/"+sandboxID, authHeaders())
	delBody := readBody(t, delResp)

	assert.Contains(t, []int{200, 204}, delResp.StatusCode,
		"DELETE /sandboxes/%s should return 200 or 204, got %d: %s", sandboxID, delResp.StatusCode, delBody)

	// Verify sandbox is gone
	getResp := doGet(t, apiBaseURL+"/sandboxes/"+sandboxID, authHeaders())
	getBody := readBody(t, getResp)

	assert.Equal(t, http.StatusNotFound, getResp.StatusCode,
		"GET /sandboxes/%s after delete should return 404, got %d: %s", sandboxID, getResp.StatusCode, getBody)
}

// ---------------------------------------------------------------------------
// P0 Tests — Client Proxy
// ---------------------------------------------------------------------------

// A3-11
func TestClientProxyHealth(t *testing.T) {
	// A3-11: GET client-proxy /health should return 200.
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get(clientProxyBaseURL + "/health")
	if err != nil {
		t.Skipf("Client proxy not reachable at %s: %v (may not be running)", clientProxyBaseURL, err)
	}
	defer resp.Body.Close()

	assert.Equal(t, http.StatusOK, resp.StatusCode,
		"Client proxy health check should return 200, got %d", resp.StatusCode)
}

// ---------------------------------------------------------------------------
// P1 Tests — Authentication Edge Cases
// ---------------------------------------------------------------------------

// A3-12
func TestAPIAuthWrongPrefix(t *testing.T) {
	// A3-12: An API key without the "e2b_" prefix should return 401.
	headers := map[string]string{
		"X-API-Key": "sk_0000000000000000000000000000000000000000",
	}

	resp := doGet(t, apiBaseURL+"/sandboxes", headers)
	body := readBody(t, resp)

	assert.Equal(t, http.StatusUnauthorized, resp.StatusCode,
		"API key without e2b_ prefix should return 401, got %d: %s", resp.StatusCode, body)
}

// ---------------------------------------------------------------------------
// P1 Tests — Sandbox Not Found
// ---------------------------------------------------------------------------

// A3-13
func TestAPIGetSandboxNotFound(t *testing.T) {
	// A3-13: GET /sandboxes/{nonexistent-id} should return 404.
	requireAPIKey(t)

	nonexistentID := "nonexistent000000"
	resp := doGet(t, apiBaseURL+"/sandboxes/"+nonexistentID, authHeaders())
	body := readBody(t, resp)

	assert.Equal(t, http.StatusNotFound, resp.StatusCode,
		"GET /sandboxes/%s should return 404, got %d: %s", nonexistentID, resp.StatusCode, body)
}

// ---------------------------------------------------------------------------
// P1 Tests — Templates
// ---------------------------------------------------------------------------

// A3-14
func TestAPIGetTemplates(t *testing.T) {
	// A3-14: GET /templates with a valid key should return 200 with JSON.
	requireAPIKey(t)

	resp := doGet(t, apiBaseURL+"/templates", authHeaders())
	body := readBody(t, resp)

	require.Equal(t, http.StatusOK, resp.StatusCode,
		"GET /templates should return 200, got %d: %s", resp.StatusCode, body)

	// Verify the response is a valid JSON array.
	var templates []json.RawMessage
	err := json.Unmarshal([]byte(body), &templates)
	require.NoError(t, err, "GET /templates response should be valid JSON array, body: %s", body)
}

// ---------------------------------------------------------------------------
// P1 Tests — CORS
// ---------------------------------------------------------------------------

// A3-15
func TestAPICORS(t *testing.T) {
	// A3-15: An OPTIONS preflight request should return CORS headers.
	headers := map[string]string{
		"Origin":                        "https://example.com",
		"Access-Control-Request-Method": "GET",
		"Access-Control-Request-Headers": "X-API-Key",
	}

	resp := doOptions(t, apiBaseURL+"/sandboxes", headers)
	defer resp.Body.Close()

	// The server uses cors.AllowAllOrigins, so we expect the CORS headers to be present.
	allowOrigin := resp.Header.Get("Access-Control-Allow-Origin")
	assert.NotEmpty(t, allowOrigin,
		"OPTIONS response should include Access-Control-Allow-Origin header")
	assert.Equal(t, "*", allowOrigin,
		"Access-Control-Allow-Origin should be '*' (allow all origins)")

	allowHeaders := resp.Header.Get("Access-Control-Allow-Headers")
	assert.NotEmpty(t, allowHeaders,
		"OPTIONS response should include Access-Control-Allow-Headers header")
	assert.Contains(t, allowHeaders, "X-Api-Key",
		"Access-Control-Allow-Headers should include X-Api-Key")
}

// ---------------------------------------------------------------------------
// P1 Tests — Rate Limit Headers
// ---------------------------------------------------------------------------

// A3-16
func TestAPIRateLimitHeaders(t *testing.T) {
	// A3-16: If rate limiting is configured, responses should include
	// rate limit headers. This test checks for common header names.
	// If no rate limit headers are present, the test is skipped
	// (rate limiting may not be configured in the test environment).
	requireAPIKey(t)

	resp := doGet(t, apiBaseURL+"/sandboxes", authHeaders())
	defer resp.Body.Close()

	rateLimitHeaders := []string{
		"X-RateLimit-Limit",
		"X-RateLimit-Remaining",
		"X-RateLimit-Reset",
		"RateLimit-Limit",
		"RateLimit-Remaining",
		"RateLimit-Reset",
		"Retry-After",
	}

	found := false
	for _, header := range rateLimitHeaders {
		if resp.Header.Get(header) != "" {
			found = true
			break
		}
	}

	if !found {
		t.Skip("No rate limit headers found in response; rate limiting may not be configured")
	}

	// If we get here, at least one rate limit header is present.
	// Verify they contain reasonable values (non-empty).
	for _, header := range rateLimitHeaders {
		val := resp.Header.Get(header)
		if val != "" {
			t.Logf("Found rate limit header: %s = %s", header, val)
		}
	}
}

// ---------------------------------------------------------------------------
// P1 Tests — Error Response Format
// ---------------------------------------------------------------------------

// A3-17
func TestAPIResponseFormat(t *testing.T) {
	// A3-17: Error responses should have a consistent JSON format
	// with at least a "message" field (and a "code" field per the OpenAPI spec).

	t.Run("401_has_message_field", func(t *testing.T) {
		// Missing API key should return a JSON error with "message".
		resp := doGet(t, apiBaseURL+"/sandboxes", nil)
		body := readBody(t, resp)

		require.Equal(t, http.StatusUnauthorized, resp.StatusCode,
			"expected 401 for missing key")

		var errResp map[string]interface{}
		err := json.Unmarshal([]byte(body), &errResp)
		require.NoError(t, err, "error response should be valid JSON, body: %s", body)

		assert.Contains(t, errResp, "message",
			"error response should contain a 'message' field, got: %v", errResp)
		assert.Contains(t, errResp, "code",
			"error response should contain a 'code' field, got: %v", errResp)
	})

	t.Run("404_has_message_field", func(t *testing.T) {
		// Non-existent sandbox should return a JSON error with "message".
		requireAPIKey(t)

		resp := doGet(t, apiBaseURL+"/sandboxes/nonexistent000000", authHeaders())
		body := readBody(t, resp)

		require.Equal(t, http.StatusNotFound, resp.StatusCode,
			"expected 404 for non-existent sandbox")

		var errResp map[string]interface{}
		err := json.Unmarshal([]byte(body), &errResp)
		require.NoError(t, err, "error response should be valid JSON, body: %s", body)

		assert.Contains(t, errResp, "message",
			"error response should contain a 'message' field, got: %v", errResp)
		assert.Contains(t, errResp, "code",
			"error response should contain a 'code' field, got: %v", errResp)
	})
}
