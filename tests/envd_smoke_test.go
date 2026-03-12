//go:build integration

// Package tests contains standalone smoke tests for the envd in-VM agent.
//
// These tests are designed to run against a live envd instance listening on
// localhost:49983 (started with the -isnotfc flag for local development).
//
// Run envd first:
//
//	cd infra/packages/envd && go build -o envd . && ./envd -port 49983 -isnotfc
//
// Then run the tests:
//
//	cd tests && go test -v -run TestEnvd -count=1 -timeout 60s
//
// These tests cover Phase 1 verification: process execution, filesystem
// operations, and auth rejection — all via ConnectRPC.
package tests

import (
	"bytes"
	"context"
	"encoding/base64"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/e2b-dev/infra/packages/shared/pkg/grpc/envd/filesystem"
	"github.com/e2b-dev/infra/packages/shared/pkg/grpc/envd/filesystem/filesystemconnect"
	"github.com/e2b-dev/infra/packages/shared/pkg/grpc/envd/process"
	"github.com/e2b-dev/infra/packages/shared/pkg/grpc/envd/process/processconnect"
)

const (
	// envdBaseURL is the default address for envd started with -isnotfc.
	envdBaseURL = "http://localhost:49983"

	// testTimeout is the default timeout for individual test operations.
	testTimeout = 30 * time.Second
)

// setUserHeader sets the Basic auth header used by envd's authn middleware
// to identify the user executing commands. When running with -isnotfc,
// no access token is needed; only the username is extracted.
func setUserHeader(header http.Header, user string) {
	userString := fmt.Sprintf("%s:", user)
	userBase64 := base64.StdEncoding.EncodeToString([]byte(userString))
	header.Set("Authorization", fmt.Sprintf("Basic %s", userBase64))
}

// newClients creates ConnectRPC clients for the process and filesystem services.
func newClients() (processconnect.ProcessClient, filesystemconnect.FilesystemClient) {
	hc := &http.Client{Timeout: testTimeout}
	pc := processconnect.NewProcessClient(hc, envdBaseURL)
	fc := filesystemconnect.NewFilesystemClient(hc, envdBaseURL)
	return pc, fc
}

// execAndCollect starts a process via the Process.Start streaming RPC,
// collects all stdout/stderr/exit events, and returns them.
type execResult struct {
	Stdout   string
	Stderr   string
	ExitCode int32
	Exited   bool
	PID      uint32
}

func execCommand(t *testing.T, ctx context.Context, pc processconnect.ProcessClient, cmd string, args []string, envs map[string]string, cwd *string) (*execResult, error) {
	t.Helper()

	noStdin := false
	req := connect.NewRequest(&process.StartRequest{
		Process: &process.ProcessConfig{
			Cmd:  cmd,
			Args: args,
			Envs: envs,
			Cwd:  cwd,
		},
		Stdin: &noStdin,
	})
	setUserHeader(req.Header(), "root")

	stream, err := pc.Start(ctx, req)
	if err != nil {
		return nil, fmt.Errorf("Start RPC failed: %w", err)
	}
	defer stream.Close()

	result := &execResult{}
	for stream.Receive() {
		msg := stream.Msg()
		if msg.GetEvent() == nil {
			continue
		}
		ev := msg.GetEvent()

		if startEv := ev.GetStart(); startEv != nil {
			result.PID = startEv.GetPid()
		}

		if dataEv := ev.GetData(); dataEv != nil {
			if stdout := dataEv.GetStdout(); stdout != nil {
				result.Stdout += string(stdout)
			}
			if stderr := dataEv.GetStderr(); stderr != nil {
				result.Stderr += string(stderr)
			}
		}

		if endEv := ev.GetEnd(); endEv != nil {
			result.ExitCode = endEv.GetExitCode()
			result.Exited = endEv.GetExited()
		}
	}

	if err := stream.Err(); err != nil {
		return result, fmt.Errorf("stream error: %w", err)
	}

	return result, nil
}

// uploadFileHTTP uploads a file to envd's POST /files HTTP endpoint.
func uploadFileHTTP(t *testing.T, filePath string, content string) {
	t.Helper()

	body := &bytes.Buffer{}
	writer := multipart.NewWriter(body)
	part, err := writer.CreateFormFile("file", filePath)
	require.NoError(t, err)
	_, err = part.Write([]byte(content))
	require.NoError(t, err)
	require.NoError(t, writer.Close())

	url := fmt.Sprintf("%s/files?path=%s&username=root", envdBaseURL, filePath)
	req, err := http.NewRequest("POST", url, body)
	require.NoError(t, err)
	req.Header.Set("Content-Type", writer.FormDataContentType())

	resp, err := http.DefaultClient.Do(req)
	require.NoError(t, err)
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)
	require.Equal(t, http.StatusOK, resp.StatusCode, "upload failed: %s", string(respBody))
}

// downloadFileHTTP downloads a file from envd's GET /files HTTP endpoint.
func downloadFileHTTP(t *testing.T, filePath string) string {
	t.Helper()

	url := fmt.Sprintf("%s/files?path=%s&username=root", envdBaseURL, filePath)
	resp, err := http.DefaultClient.Get(url)
	require.NoError(t, err)
	defer resp.Body.Close()

	data, err := io.ReadAll(resp.Body)
	require.NoError(t, err)
	require.Equal(t, http.StatusOK, resp.StatusCode, "download failed: %s", string(data))

	return string(data)
}

// ---------------------------------------------------------------------------
// Process Tests (E1-03 through E1-05, E1-11)
// ---------------------------------------------------------------------------

func TestEnvdProcessEchoHello(t *testing.T) {
	// E1-03: Exec "echo hello" -> stdout="hello\n", exit=0
	ctx, cancel := context.WithTimeout(context.Background(), testTimeout)
	defer cancel()

	pc, _ := newClients()
	result, err := execCommand(t, ctx, pc, "echo", []string{"hello"}, nil, nil)
	require.NoError(t, err)

	assert.Equal(t, "hello\n", result.Stdout, "stdout should be 'hello\\n'")
	assert.Equal(t, int32(0), result.ExitCode, "exit code should be 0")
	assert.True(t, result.PID > 0, "PID should be assigned")
}

func TestEnvdProcessExitCode(t *testing.T) {
	// E1-04: Exec "exit 42" -> exit code 42
	ctx, cancel := context.WithTimeout(context.Background(), testTimeout)
	defer cancel()

	pc, _ := newClients()
	result, err := execCommand(t, ctx, pc, "/bin/bash", []string{"-c", "exit 42"}, nil, nil)
	require.NoError(t, err)

	assert.Equal(t, int32(42), result.ExitCode, "exit code should be 42")
}

func TestEnvdProcessEnvVars(t *testing.T) {
	// E1-05: Exec with env var -> stdout contains FOO value
	ctx, cancel := context.WithTimeout(context.Background(), testTimeout)
	defer cancel()

	pc, _ := newClients()
	envs := map[string]string{"MY_TEST_VAR": "smoke_value_123"}
	result, err := execCommand(t, ctx, pc, "/bin/bash", []string{"-c", "echo $MY_TEST_VAR"}, envs, nil)
	require.NoError(t, err)

	assert.Equal(t, "smoke_value_123\n", result.Stdout)
	assert.Equal(t, int32(0), result.ExitCode)
}

func TestEnvdProcessStderr(t *testing.T) {
	// E1-11: Exec with stderr output -> stderr captured
	ctx, cancel := context.WithTimeout(context.Background(), testTimeout)
	defer cancel()

	pc, _ := newClients()
	result, err := execCommand(t, ctx, pc, "/bin/bash", []string{"-c", "echo err_output >&2"}, nil, nil)
	require.NoError(t, err)

	assert.Equal(t, "err_output\n", result.Stderr, "stderr should capture error output")
	assert.Empty(t, result.Stdout, "stdout should be empty")
	assert.Equal(t, int32(0), result.ExitCode)
}

func TestEnvdProcessList(t *testing.T) {
	// Verify the List RPC works (should return empty or current processes)
	ctx, cancel := context.WithTimeout(context.Background(), testTimeout)
	defer cancel()

	pc, _ := newClients()
	req := connect.NewRequest(&process.ListRequest{})
	setUserHeader(req.Header(), "root")

	resp, err := pc.List(ctx, req)
	require.NoError(t, err)
	// The list may or may not be empty, but the call should succeed
	assert.NotNil(t, resp.Msg)
}

func TestEnvdProcessConcurrent(t *testing.T) {
	// E1-16: Run 5 concurrent processes, all should complete independently
	ctx, cancel := context.WithTimeout(context.Background(), testTimeout)
	defer cancel()

	pc, _ := newClients()

	type result struct {
		idx int
		res *execResult
		err error
	}

	ch := make(chan result, 5)
	for i := 0; i < 5; i++ {
		go func(idx int) {
			expected := fmt.Sprintf("proc_%d", idx)
			r, err := execCommand(t, ctx, pc, "echo", []string{expected}, nil, nil)
			ch <- result{idx: idx, res: r, err: err}
		}(i)
	}

	for i := 0; i < 5; i++ {
		r := <-ch
		require.NoError(t, r.err, "process %d should succeed", r.idx)
		expected := fmt.Sprintf("proc_%d\n", r.idx)
		assert.Equal(t, expected, r.res.Stdout, "process %d stdout mismatch", r.idx)
		assert.Equal(t, int32(0), r.res.ExitCode, "process %d exit code should be 0", r.idx)
	}
}

// ---------------------------------------------------------------------------
// Filesystem Tests (E1-06 through E1-09, E1-15, E1-17, E1-18)
// ---------------------------------------------------------------------------

func TestEnvdFilesystemWriteRead(t *testing.T) {
	// E1-06: Write file, read it back -> content matches
	filePath := "/tmp/envd_smoke_test_rw.txt"
	content := "Hello from envd smoke test!"

	uploadFileHTTP(t, filePath, content)
	got := downloadFileHTTP(t, filePath)
	assert.Equal(t, content, got, "file content should match after roundtrip")

	// Clean up
	ctx, cancel := context.WithTimeout(context.Background(), testTimeout)
	defer cancel()
	_, fc := newClients()
	removeReq := connect.NewRequest(&filesystem.RemoveRequest{Path: filePath})
	setUserHeader(removeReq.Header(), "root")
	_, _ = fc.Remove(ctx, removeReq)
}

func TestEnvdFilesystemMakeDir(t *testing.T) {
	// E1-07: MakeDir recursive -> directory created
	ctx, cancel := context.WithTimeout(context.Background(), testTimeout)
	defer cancel()

	_, fc := newClients()

	dirPath := "/tmp/envd_smoke_mkdir_test"

	// Clean up first in case of previous failed run
	removeReq := connect.NewRequest(&filesystem.RemoveRequest{Path: dirPath})
	setUserHeader(removeReq.Header(), "root")
	_, _ = fc.Remove(ctx, removeReq)

	// Create directory
	mkdirReq := connect.NewRequest(&filesystem.MakeDirRequest{Path: dirPath})
	setUserHeader(mkdirReq.Header(), "root")
	mkdirResp, err := fc.MakeDir(ctx, mkdirReq)
	require.NoError(t, err)
	require.NotNil(t, mkdirResp.Msg.GetEntry())
	assert.Equal(t, filesystem.FileType_FILE_TYPE_DIRECTORY, mkdirResp.Msg.GetEntry().GetType())

	// Verify with Stat
	statReq := connect.NewRequest(&filesystem.StatRequest{Path: dirPath})
	setUserHeader(statReq.Header(), "root")
	statResp, err := fc.Stat(ctx, statReq)
	require.NoError(t, err)
	assert.Equal(t, filesystem.FileType_FILE_TYPE_DIRECTORY, statResp.Msg.GetEntry().GetType())

	// Clean up
	_, _ = fc.Remove(ctx, removeReq)
}

func TestEnvdFilesystemListDir(t *testing.T) {
	// E1-08: ListDir -> lists files with metadata
	ctx, cancel := context.WithTimeout(context.Background(), testTimeout)
	defer cancel()

	_, fc := newClients()

	baseDir := "/tmp/envd_smoke_listdir"

	// Clean up first
	removeReq := connect.NewRequest(&filesystem.RemoveRequest{Path: baseDir})
	setUserHeader(removeReq.Header(), "root")
	_, _ = fc.Remove(ctx, removeReq)

	// Create directory structure
	mkReq := connect.NewRequest(&filesystem.MakeDirRequest{Path: baseDir + "/subdir"})
	setUserHeader(mkReq.Header(), "root")
	_, err := fc.MakeDir(ctx, mkReq)
	require.NoError(t, err)

	// Upload a file into baseDir
	uploadFileHTTP(t, baseDir+"/hello.txt", "hello contents")

	// List the directory
	listReq := connect.NewRequest(&filesystem.ListDirRequest{
		Path:  baseDir,
		Depth: 1,
	})
	setUserHeader(listReq.Header(), "root")
	listResp, err := fc.ListDir(ctx, listReq)
	require.NoError(t, err)

	entries := listResp.Msg.GetEntries()
	require.GreaterOrEqual(t, len(entries), 2, "should list at least 2 entries (subdir + file)")

	// Build a map of entry names for assertions
	nameMap := make(map[string]*filesystem.EntryInfo)
	for _, e := range entries {
		nameMap[e.GetName()] = e
	}

	subEntry, ok := nameMap["subdir"]
	require.True(t, ok, "should find 'subdir' in listing")
	assert.Equal(t, filesystem.FileType_FILE_TYPE_DIRECTORY, subEntry.GetType())

	fileEntry, ok := nameMap["hello.txt"]
	require.True(t, ok, "should find 'hello.txt' in listing")
	assert.Equal(t, filesystem.FileType_FILE_TYPE_FILE, fileEntry.GetType())
	assert.Equal(t, int64(14), fileEntry.GetSize(), "file size should be 14 bytes")

	// Clean up
	_, _ = fc.Remove(ctx, removeReq)
}

func TestEnvdFilesystemRemove(t *testing.T) {
	// E1-09: Remove file -> file gone, subsequent stat fails
	ctx, cancel := context.WithTimeout(context.Background(), testTimeout)
	defer cancel()

	_, fc := newClients()

	filePath := "/tmp/envd_smoke_remove_test.txt"
	uploadFileHTTP(t, filePath, "to be deleted")

	// Verify it exists first
	statReq := connect.NewRequest(&filesystem.StatRequest{Path: filePath})
	setUserHeader(statReq.Header(), "root")
	_, err := fc.Stat(ctx, statReq)
	require.NoError(t, err)

	// Remove it
	removeReq := connect.NewRequest(&filesystem.RemoveRequest{Path: filePath})
	setUserHeader(removeReq.Header(), "root")
	_, err = fc.Remove(ctx, removeReq)
	require.NoError(t, err)

	// Verify it's gone
	_, err = fc.Stat(ctx, statReq)
	require.Error(t, err, "stat should fail after removal")
	var connectErr *connect.Error
	if assert.ErrorAs(t, err, &connectErr) {
		assert.Equal(t, connect.CodeNotFound, connectErr.Code(), "should be NOT_FOUND")
	}
}

func TestEnvdFilesystemStat(t *testing.T) {
	// E1-15: Stat file -> returns size, type, permissions
	ctx, cancel := context.WithTimeout(context.Background(), testTimeout)
	defer cancel()

	_, fc := newClients()

	filePath := "/tmp/envd_smoke_stat_test.txt"
	content := "stat test data"
	uploadFileHTTP(t, filePath, content)

	statReq := connect.NewRequest(&filesystem.StatRequest{Path: filePath})
	setUserHeader(statReq.Header(), "root")
	statResp, err := fc.Stat(ctx, statReq)
	require.NoError(t, err)

	entry := statResp.Msg.GetEntry()
	require.NotNil(t, entry)
	assert.Equal(t, "envd_smoke_stat_test.txt", entry.GetName())
	assert.Equal(t, filePath, entry.GetPath())
	assert.Equal(t, filesystem.FileType_FILE_TYPE_FILE, entry.GetType())
	assert.Equal(t, int64(len(content)), entry.GetSize())
	assert.NotEmpty(t, entry.GetPermissions(), "permissions string should be populated")
	assert.NotNil(t, entry.GetModifiedTime(), "modified time should be set")

	// Clean up
	removeReq := connect.NewRequest(&filesystem.RemoveRequest{Path: filePath})
	setUserHeader(removeReq.Header(), "root")
	_, _ = fc.Remove(ctx, removeReq)
}

func TestEnvdFilesystemReadNonExistent(t *testing.T) {
	// E1-17: Read non-existent file -> NOT_FOUND error
	ctx, cancel := context.WithTimeout(context.Background(), testTimeout)
	defer cancel()

	_, fc := newClients()

	statReq := connect.NewRequest(&filesystem.StatRequest{Path: "/tmp/this_file_does_not_exist_envd_smoke.txt"})
	setUserHeader(statReq.Header(), "root")
	_, err := fc.Stat(ctx, statReq)
	require.Error(t, err)
	var connectErr *connect.Error
	if assert.ErrorAs(t, err, &connectErr) {
		assert.Equal(t, connect.CodeNotFound, connectErr.Code())
	}
}

func TestEnvdFilesystemLargeFile(t *testing.T) {
	// E1-18: Large file write/read (1MB) -> content matches
	filePath := "/tmp/envd_smoke_large_test.bin"
	content := strings.Repeat("A", 1024*1024) // 1 MB

	uploadFileHTTP(t, filePath, content)
	got := downloadFileHTTP(t, filePath)
	assert.Equal(t, len(content), len(got), "large file size should match")
	assert.Equal(t, content, got, "large file content should match")

	// Clean up
	ctx, cancel := context.WithTimeout(context.Background(), testTimeout)
	defer cancel()
	_, fc := newClients()
	removeReq := connect.NewRequest(&filesystem.RemoveRequest{Path: filePath})
	setUserHeader(removeReq.Header(), "root")
	_, _ = fc.Remove(ctx, removeReq)
}

// ---------------------------------------------------------------------------
// Auth Tests (E1-10)
// ---------------------------------------------------------------------------

func TestEnvdAuthRejectionNoToken(t *testing.T) {
	// E1-10: Connect without auth token -> error
	// When envd is started with -isnotfc and no access token is configured,
	// the X-Access-Token auth layer is not active. However, the ConnectRPC
	// authn middleware uses HTTP Basic Auth for username extraction.
	//
	// We test that making a request with an INVALID username (one that does
	// not exist on the system) returns an authentication error.
	ctx, cancel := context.WithTimeout(context.Background(), testTimeout)
	defer cancel()

	_, fc := newClients()

	// Request with a non-existent user triggers authn.Errorf
	req := connect.NewRequest(&filesystem.ListDirRequest{Path: "/"})
	req.Header().Set("Authorization", fmt.Sprintf("Basic %s",
		base64.StdEncoding.EncodeToString([]byte("nonexistent_user_xyz:"))))
	_, err := fc.ListDir(ctx, req)
	require.Error(t, err, "request with invalid user should be rejected")
	var connectErr *connect.Error
	if assert.ErrorAs(t, err, &connectErr) {
		assert.Equal(t, connect.CodeUnauthenticated, connectErr.Code(),
			"should get UNAUTHENTICATED error for invalid user")
	}
}

func TestEnvdAuthAccessTokenRejection(t *testing.T) {
	// When envd has an access token configured, requests with a wrong
	// X-Access-Token header should be rejected with 401 or 403.
	// This test validates the HTTP-level auth (not ConnectRPC authn).
	//
	// When running with -isnotfc and no token configured, the access token
	// check is disabled (accessToken.IsSet() returns false), so this test
	// cannot meaningfully validate rejection. We skip in that case.
	url := fmt.Sprintf("%s/files?path=/tmp&username=root", envdBaseURL)

	// First, check if access token auth is active by making a request without any token.
	probeReq, err := http.NewRequest("GET", url, nil)
	require.NoError(t, err)
	probeResp, err := http.DefaultClient.Do(probeReq)
	require.NoError(t, err)
	defer probeResp.Body.Close()

	if probeResp.StatusCode == http.StatusOK {
		t.Skip("Access token auth is not enabled on this envd instance (no token configured); skipping rejection test")
	}

	// Access token auth is active — now test with a wrong token.
	req, err := http.NewRequest("GET", url, nil)
	require.NoError(t, err)
	req.Header.Set("X-Access-Token", "wrong-token-12345")

	resp, err := http.DefaultClient.Do(req)
	require.NoError(t, err)
	defer resp.Body.Close()

	assert.Contains(t, []int{http.StatusUnauthorized, http.StatusForbidden}, resp.StatusCode,
		"request with wrong access token should be rejected with 401 or 403, got %d", resp.StatusCode)
}

// ---------------------------------------------------------------------------
// Health Check Test (E1-02)
// ---------------------------------------------------------------------------

func TestEnvdHealthCheck(t *testing.T) {
	// E1-02: Health endpoint should respond
	resp, err := http.Get(fmt.Sprintf("%s/health", envdBaseURL))
	require.NoError(t, err)
	defer resp.Body.Close()

	// Health check returns 204 No Content
	assert.Equal(t, http.StatusNoContent, resp.StatusCode, "health check should return 204")
}
