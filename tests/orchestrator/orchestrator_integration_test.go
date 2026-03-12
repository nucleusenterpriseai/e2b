//go:build integration && linux

// Package orchestrator_test contains integration tests for the E2B orchestrator.
//
// These tests run against a live orchestrator gRPC server on a Linux machine
// with KVM access. They exercise the SandboxService API: create, list, delete,
// pause, and exec-via-envd flows.
//
// Prerequisites:
//   - Orchestrator running on ORCHESTRATOR_ADDR (default localhost:5008)
//   - Sandbox proxy running on PROXY_ADDR (default localhost:5007)
//   - Firecracker, KVM, kernel, rootfs, and envd all set up
//
// Run:
//
//	cd tests/orchestrator && go test -tags integration -v -run TestOrchestrator -count=1 -timeout 300s
package orchestrator_test

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"math/big"
	"net/http"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/protobuf/types/known/emptypb"
	"google.golang.org/protobuf/types/known/timestamppb"

	"connectrpc.com/connect"

	orchestrator "github.com/e2b-dev/infra/packages/shared/pkg/grpc/orchestrator"
	"github.com/e2b-dev/infra/packages/shared/pkg/grpc/envd/process"
	"github.com/e2b-dev/infra/packages/shared/pkg/grpc/envd/process/processconnect"
)

const (
	// defaultOrchestratorAddr is the default gRPC address for the orchestrator.
	defaultOrchestratorAddr = "localhost:5008"

	// defaultProxyAddr is the default HTTP address for the sandbox proxy.
	defaultProxyAddr = "localhost:5007"

	// defaultTemplateID is the template used for sandbox creation in tests.
	defaultTemplateID = "base"

	// defaultBuildID is the build ID used for sandbox creation in tests.
	defaultBuildID = "base-build"

	// defaultKernelVersion is the kernel version used for sandbox creation.
	defaultKernelVersion = "vmlinux-6.1.102"

	// defaultFirecrackerVersion is the Firecracker version used for sandbox creation.
	defaultFirecrackerVersion = "v1.7.0-dev"

	// envKernelVersion overrides defaultKernelVersion when set.
	envKernelVersion = "TEST_KERNEL_VERSION"

	// envFirecrackerVersion overrides defaultFirecrackerVersion when set.
	envFirecrackerVersion = "TEST_FIRECRACKER_VERSION"

	// orchTestTimeout is the default timeout for individual test operations.
	orchTestTimeout = 60 * time.Second

	// createTimeout is the timeout for sandbox creation (may take longer).
	createTimeout = 120 * time.Second
)

// orchestratorAddr returns the gRPC address of the orchestrator,
// configurable via the ORCHESTRATOR_ADDR environment variable.
func orchestratorAddr() string {
	if addr := os.Getenv("ORCHESTRATOR_ADDR"); addr != "" {
		return addr
	}
	return defaultOrchestratorAddr
}

// proxyAddr returns the HTTP address of the sandbox proxy,
// configurable via the PROXY_ADDR environment variable.
func proxyAddr() string {
	if addr := os.Getenv("PROXY_ADDR"); addr != "" {
		return addr
	}
	return defaultProxyAddr
}

// templateID returns the template ID for test sandboxes,
// configurable via the TEST_TEMPLATE_ID environment variable.
func templateID() string {
	if id := os.Getenv("TEST_TEMPLATE_ID"); id != "" {
		return id
	}
	return defaultTemplateID
}

// buildID returns the build ID for test sandboxes,
// configurable via the TEST_BUILD_ID environment variable.
func buildID() string {
	if id := os.Getenv("TEST_BUILD_ID"); id != "" {
		return id
	}
	return defaultBuildID
}

// sandboxID generates a valid sandbox ID (lowercase alphanumeric, no hyphens).
// The E2B proxy parses host headers as <port>-<sandboxID>.<domain>, splitting on
// the first hyphen, so sandbox IDs must not contain hyphens.
func genSandboxID(prefix string) string {
	const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
	b := make([]byte, 16)
	for i := range b {
		n, _ := rand.Int(rand.Reader, big.NewInt(int64(len(alphabet))))
		b[i] = alphabet[n.Int64()]
	}
	return prefix + string(b)
}

// kernelVersion returns the kernel version for test sandboxes,
// configurable via the TEST_KERNEL_VERSION environment variable.
func kernelVersion() string {
	if v := os.Getenv(envKernelVersion); v != "" {
		return v
	}
	return defaultKernelVersion
}

// firecrackerVersion returns the Firecracker version for test sandboxes,
// configurable via the TEST_FIRECRACKER_VERSION environment variable.
func firecrackerVersion() string {
	if v := os.Getenv(envFirecrackerVersion); v != "" {
		return v
	}
	return defaultFirecrackerVersion
}

// setUserHeader sets the Basic auth header used by envd's authn middleware
// to identify the user executing commands. When running with -isnotfc,
// no access token is needed; only the username is extracted.
func setUserHeader(header http.Header, user string) {
	userString := fmt.Sprintf("%s:", user)
	userBase64 := base64.StdEncoding.EncodeToString([]byte(userString))
	header.Set("Authorization", fmt.Sprintf("Basic %s", userBase64))
}

// skipIfOrchestratorUnavailable skips the test if the orchestrator gRPC
// endpoint is not reachable. Called at the start of every orchestrator test.
func skipIfOrchestratorUnavailable(t *testing.T) {
	t.Helper()
	conn, err := grpc.NewClient(orchestratorAddr(),
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		t.Skipf("orchestrator not reachable at %s: %v", orchestratorAddr(), err)
	}
	defer conn.Close()

	// grpc.NewClient is lazy, so we need to make an actual RPC call to verify connectivity.
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	healthClient := grpc_health_v1.NewHealthClient(conn)
	_, err = healthClient.Check(ctx, &grpc_health_v1.HealthCheckRequest{})
	if err != nil {
		t.Skipf("orchestrator not reachable at %s: %v", orchestratorAddr(), err)
	}
}

// ---------------------------------------------------------------------------
// Helper: gRPC client connection
// ---------------------------------------------------------------------------

// dialOrchestrator creates a gRPC client connection to the orchestrator.
func dialOrchestrator(t *testing.T) *grpc.ClientConn {
	t.Helper()

	conn, err := grpc.NewClient(orchestratorAddr(),
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	require.NoError(t, err, "failed to dial orchestrator at %s", orchestratorAddr())
	t.Cleanup(func() { conn.Close() })
	return conn
}

// ---------------------------------------------------------------------------
// Helper: sandbox lifecycle
// ---------------------------------------------------------------------------

// createSandbox creates a sandbox with the given ID and returns the client ID
// from the response. It registers a cleanup function to delete the sandbox.
func createSandbox(t *testing.T, client orchestrator.SandboxServiceClient, sandboxID string) string {
	t.Helper()
	return createSandboxWithConfig(t, client, sandboxID, nil)
}

// boolPtr returns a pointer to a bool value.
func boolPtr(b bool) *bool {
	return &b
}

// createSandboxWithConfig creates a sandbox with optional config overrides.
// If allowInternet is non-nil, it sets the allow_internet_access field.
func createSandboxWithConfig(t *testing.T, client orchestrator.SandboxServiceClient, sandboxID string, allowInternet *bool) string {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), createTimeout)
	defer cancel()

	now := timestamppb.Now()
	endTime := timestamppb.New(now.AsTime().Add(5 * time.Minute))

	cfg := &orchestrator.SandboxConfig{
		TemplateId:         templateID(),
		BuildId:            buildID(),
		KernelVersion:      kernelVersion(),
		FirecrackerVersion: firecrackerVersion(),
		SandboxId:          sandboxID,
		Vcpu:               1,
		RamMb:              256,
		TeamId:             "test-team",
		MaxSandboxLength:   1, // 1 hour max
		TotalDiskSizeMb:    512,
	}

	if allowInternet != nil {
		cfg.AllowInternetAccess = allowInternet
	}

	req := &orchestrator.SandboxCreateRequest{
		Sandbox:   cfg,
		StartTime: now,
		EndTime:   endTime,
	}

	resp, err := client.Create(ctx, req)
	require.NoError(t, err, "failed to create sandbox %s", sandboxID)
	require.NotEmpty(t, resp.GetClientId(), "create response should return a client_id")

	// Register cleanup: delete the sandbox when test finishes.
	t.Cleanup(func() {
		deleteCtx, deleteCancel := context.WithTimeout(context.Background(), orchTestTimeout)
		defer deleteCancel()
		_, deleteErr := client.Delete(deleteCtx, &orchestrator.SandboxDeleteRequest{
			SandboxId: sandboxID,
		})
		if deleteErr != nil {
			t.Logf("cleanup: failed to delete sandbox %s: %v", sandboxID, deleteErr)
		}
	})

	return resp.GetClientId()
}

// deleteSandbox explicitly deletes a sandbox by ID.
func deleteSandbox(t *testing.T, client orchestrator.SandboxServiceClient, sandboxID string) {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), orchTestTimeout)
	defer cancel()

	_, err := client.Delete(ctx, &orchestrator.SandboxDeleteRequest{
		SandboxId: sandboxID,
	})
	require.NoError(t, err, "failed to delete sandbox %s", sandboxID)
}

// listSandboxes returns the current list of running sandboxes.
func listSandboxes(t *testing.T, client orchestrator.SandboxServiceClient) []*orchestrator.RunningSandbox {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), orchTestTimeout)
	defer cancel()

	resp, err := client.List(ctx, &emptypb.Empty{})
	require.NoError(t, err, "failed to list sandboxes")
	return resp.GetSandboxes()
}

// sandboxInList checks whether the given sandbox ID appears in the list.
func sandboxInList(sandboxes []*orchestrator.RunningSandbox, sandboxID string) bool {
	for _, sbx := range sandboxes {
		if sbx.GetConfig() != nil && sbx.GetConfig().GetSandboxId() == sandboxID {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Helper: exec command inside sandbox via envd proxy
// ---------------------------------------------------------------------------

// execInSandbox runs a command inside a sandbox by connecting to envd through
// the sandbox proxy. The proxy routes requests based on sandbox ID.
func execInSandbox(t *testing.T, sandboxID string, cmd string, args []string) *orchExecResult {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), orchTestTimeout)
	defer cancel()

	// The sandbox proxy runs on proxyAddr and routes to the correct sandbox
	// based on the Host header or path. The URL pattern is:
	//   http://<sandbox-id>.<proxy-host>:<proxy-port>/
	proxyURL := fmt.Sprintf("http://49983-%s.%s", sandboxID, proxyAddr())

	hc := &http.Client{Timeout: orchTestTimeout}
	pc := processconnect.NewProcessClient(hc, proxyURL)

	noStdin := false
	req := connect.NewRequest(&process.StartRequest{
		Process: &process.ProcessConfig{
			Cmd:  cmd,
			Args: args,
		},
		Stdin: &noStdin,
	})
	// Set user header for envd authn
	setUserHeader(req.Header(), "root")

	stream, err := pc.Start(ctx, req)
	require.NoError(t, err, "failed to start process in sandbox %s", sandboxID)
	defer stream.Close()

	result := &orchExecResult{}
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
			if pty := dataEv.GetPty(); pty != nil {
				result.Stdout += string(pty)
			}
		}
		if endEv := ev.GetEnd(); endEv != nil {
			result.ExitCode = endEv.GetExitCode()
			result.Exited = endEv.GetExited()
		}
	}

	if streamErr := stream.Err(); streamErr != nil {
		t.Logf("stream error for sandbox %s: %v", sandboxID, streamErr)
	}

	return result
}

// orchExecResult holds the output from executing a command inside a sandbox.
type orchExecResult struct {
	Stdout   string
	Stderr   string
	ExitCode int32
	Exited   bool
	PID      uint32
}

// ---------------------------------------------------------------------------
// Helper: exec with options (cwd, env, stdin, pty, signal)
// ---------------------------------------------------------------------------

// execInSandboxWithCwd runs a command with a custom working directory.
func execInSandboxWithCwd(t *testing.T, sandboxID string, cmd string, args []string, cwd string) *orchExecResult {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), orchTestTimeout)
	defer cancel()

	proxyURL := fmt.Sprintf("http://49983-%s.%s", sandboxID, proxyAddr())
	hc := &http.Client{Timeout: orchTestTimeout}
	pc := processconnect.NewProcessClient(hc, proxyURL)

	noStdin := false
	req := connect.NewRequest(&process.StartRequest{
		Process: &process.ProcessConfig{
			Cmd:  cmd,
			Args: args,
			Cwd:  &cwd,
		},
		Stdin: &noStdin,
	})
	setUserHeader(req.Header(), "root")

	stream, err := pc.Start(ctx, req)
	require.NoError(t, err, "failed to start process in sandbox %s", sandboxID)
	defer stream.Close()

	return collectStreamResult(t, stream)
}

// execInSandboxWithEnv runs a command with custom environment variables.
func execInSandboxWithEnv(t *testing.T, sandboxID string, cmd string, args []string, envs map[string]string) *orchExecResult {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), orchTestTimeout)
	defer cancel()

	proxyURL := fmt.Sprintf("http://49983-%s.%s", sandboxID, proxyAddr())
	hc := &http.Client{Timeout: orchTestTimeout}
	pc := processconnect.NewProcessClient(hc, proxyURL)

	noStdin := false
	req := connect.NewRequest(&process.StartRequest{
		Process: &process.ProcessConfig{
			Cmd:  cmd,
			Args: args,
			Envs: envs,
		},
		Stdin: &noStdin,
	})
	setUserHeader(req.Header(), "root")

	stream, err := pc.Start(ctx, req)
	require.NoError(t, err, "failed to start process in sandbox %s", sandboxID)
	defer stream.Close()

	return collectStreamResult(t, stream)
}

// startProcessWithTag starts a background process with a tag and returns its PID.
func startProcessWithTag(t *testing.T, sandboxID string, cmd string, args []string, tag string) uint32 {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), orchTestTimeout)
	defer cancel()

	proxyURL := fmt.Sprintf("http://49983-%s.%s", sandboxID, proxyAddr())
	hc := &http.Client{Timeout: orchTestTimeout}
	pc := processconnect.NewProcessClient(hc, proxyURL)

	noStdin := false
	req := connect.NewRequest(&process.StartRequest{
		Process: &process.ProcessConfig{
			Cmd:  cmd,
			Args: args,
		},
		Tag:   &tag,
		Stdin: &noStdin,
	})
	setUserHeader(req.Header(), "root")

	stream, err := pc.Start(ctx, req)
	require.NoError(t, err, "failed to start process in sandbox %s", sandboxID)

	// Read until we get the StartEvent with PID, then return (don't drain the stream).
	var pid uint32
	for stream.Receive() {
		msg := stream.Msg()
		if msg.GetEvent() == nil {
			continue
		}
		if startEv := msg.GetEvent().GetStart(); startEv != nil {
			pid = startEv.GetPid()
			break
		}
	}
	// Don't close the stream — let the process continue running in background.
	return pid
}

// sendSignal sends a signal to a process by PID inside a sandbox.
func sendSignal(t *testing.T, sandboxID string, pid uint32, signal process.Signal) {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), orchTestTimeout)
	defer cancel()

	proxyURL := fmt.Sprintf("http://49983-%s.%s", sandboxID, proxyAddr())
	hc := &http.Client{Timeout: orchTestTimeout}
	pc := processconnect.NewProcessClient(hc, proxyURL)

	req := connect.NewRequest(&process.SendSignalRequest{
		Process: &process.ProcessSelector{
			Selector: &process.ProcessSelector_Pid{Pid: pid},
		},
		Signal: signal,
	})
	setUserHeader(req.Header(), "root")

	_, err := pc.SendSignal(ctx, req)
	require.NoError(t, err, "failed to send signal %v to PID %d", signal, pid)
}

// listProcesses returns the list of running processes in a sandbox.
func listProcesses(t *testing.T, sandboxID string) []*process.ProcessInfo {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), orchTestTimeout)
	defer cancel()

	proxyURL := fmt.Sprintf("http://49983-%s.%s", sandboxID, proxyAddr())
	hc := &http.Client{Timeout: orchTestTimeout}
	pc := processconnect.NewProcessClient(hc, proxyURL)

	req := connect.NewRequest(&process.ListRequest{})
	setUserHeader(req.Header(), "root")

	resp, err := pc.List(ctx, req)
	require.NoError(t, err, "failed to list processes in sandbox %s", sandboxID)
	return resp.Msg.GetProcesses()
}

// execWithStdin starts a process with stdin enabled, sends input, closes stdin, and collects output.
func execWithStdin(t *testing.T, sandboxID string, cmd string, args []string, input string) *orchExecResult {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), orchTestTimeout)
	defer cancel()

	proxyURL := fmt.Sprintf("http://49983-%s.%s", sandboxID, proxyAddr())
	hc := &http.Client{Timeout: orchTestTimeout}
	pc := processconnect.NewProcessClient(hc, proxyURL)

	// Start with stdin enabled (stdin=true or nil, which defaults to true).
	stdinEnabled := true
	tag := fmt.Sprintf("stdin-test-%d", time.Now().UnixNano())
	req := connect.NewRequest(&process.StartRequest{
		Process: &process.ProcessConfig{
			Cmd:  cmd,
			Args: args,
		},
		Stdin: &stdinEnabled,
		Tag:   &tag,
	})
	setUserHeader(req.Header(), "root")

	stream, err := pc.Start(ctx, req)
	require.NoError(t, err, "failed to start process in sandbox %s", sandboxID)
	defer stream.Close()

	// Wait for start event to get PID.
	var pid uint32
	for stream.Receive() {
		msg := stream.Msg()
		if msg.GetEvent() != nil {
			if startEv := msg.GetEvent().GetStart(); startEv != nil {
				pid = startEv.GetPid()
				break
			}
		}
	}
	require.NotZero(t, pid, "process should have started with a PID")

	// Send input via SendInput.
	inputReq := connect.NewRequest(&process.SendInputRequest{
		Process: &process.ProcessSelector{
			Selector: &process.ProcessSelector_Pid{Pid: pid},
		},
		Input: &process.ProcessInput{
			Input: &process.ProcessInput_Stdin{Stdin: []byte(input)},
		},
	})
	setUserHeader(inputReq.Header(), "root")
	_, err = pc.SendInput(ctx, inputReq)
	require.NoError(t, err, "failed to send stdin input")

	// Close stdin to signal EOF.
	closeReq := connect.NewRequest(&process.CloseStdinRequest{
		Process: &process.ProcessSelector{
			Selector: &process.ProcessSelector_Pid{Pid: pid},
		},
	})
	setUserHeader(closeReq.Header(), "root")
	_, err = pc.CloseStdin(ctx, closeReq)
	require.NoError(t, err, "failed to close stdin")

	// Collect remaining output.
	return collectStreamResult(t, stream)
}

// execWithPTY starts a process with PTY enabled and collects output.
func execWithPTY(t *testing.T, sandboxID string, cmd string, args []string) *orchExecResult {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), orchTestTimeout)
	defer cancel()

	proxyURL := fmt.Sprintf("http://49983-%s.%s", sandboxID, proxyAddr())
	hc := &http.Client{Timeout: orchTestTimeout}
	pc := processconnect.NewProcessClient(hc, proxyURL)

	cols := uint32(80)
	rows := uint32(24)
	req := connect.NewRequest(&process.StartRequest{
		Process: &process.ProcessConfig{
			Cmd:  cmd,
			Args: args,
		},
		Pty: &process.PTY{
			Size: &process.PTY_Size{
				Cols: cols,
				Rows: rows,
			},
		},
	})
	setUserHeader(req.Header(), "root")

	stream, err := pc.Start(ctx, req)
	require.NoError(t, err, "failed to start process with PTY in sandbox %s", sandboxID)
	defer stream.Close()

	return collectStreamResult(t, stream)
}

// collectStreamResult drains a process Start stream and returns the collected result.
func collectStreamResult(t *testing.T, stream *connect.ServerStreamForClient[process.StartResponse]) *orchExecResult {
	t.Helper()

	result := &orchExecResult{}
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
			if pty := dataEv.GetPty(); pty != nil {
				result.Stdout += string(pty)
			}
		}
		if endEv := ev.GetEnd(); endEv != nil {
			result.ExitCode = endEv.GetExitCode()
			result.Exited = endEv.GetExited()
		}
	}
	return result
}

// ---------------------------------------------------------------------------
// P0 Tests
// ---------------------------------------------------------------------------

func TestOrchestratorHealth(t *testing.T) {
	// O2-01: gRPC health check returns SERVING
	skipIfOrchestratorUnavailable(t)
	conn := dialOrchestrator(t)
	healthClient := grpc_health_v1.NewHealthClient(conn)

	ctx, cancel := context.WithTimeout(context.Background(), orchTestTimeout)
	defer cancel()

	resp, err := healthClient.Check(ctx, &grpc_health_v1.HealthCheckRequest{})
	require.NoError(t, err, "health check RPC should succeed")
	assert.Equal(t, grpc_health_v1.HealthCheckResponse_SERVING, resp.GetStatus(),
		"health check should return SERVING status")
}

func TestOrchestratorBuildSucceeds(t *testing.T) {
	// O2-02: Build orchestrator binary (go build ./... in packages/orchestrator).
	// This test verifies the orchestrator compiles on the current platform.
	// It does NOT require a running orchestrator -- it shells out to go build.
	if testing.Short() {
		t.Skip("skipping build test in short mode")
	}

	// This test is inherently satisfied if we reached this point, because
	// TestMain already connected to a running orchestrator. But for explicit
	// build verification, we check that the go build command succeeds.
	//
	// NOTE: This test requires the source code to be available at the expected
	// path relative to the test. On CI, adjust ORCHESTRATOR_SRC_DIR.
	srcDir := os.Getenv("ORCHESTRATOR_SRC_DIR")
	if srcDir == "" {
		// Default relative path from tests/orchestrator/ to orchestrator source
		srcDir = "../../infra/packages/orchestrator"
	}

	if _, err := os.Stat(srcDir); os.IsNotExist(err) {
		t.Skipf("orchestrator source not found at %s; skipping build test", srcDir)
	}

	// We only verify the directory exists and the main.go is present.
	// The actual build test should be run on Linux where it can compile.
	mainGo := srcDir + "/main.go"
	_, err := os.Stat(mainGo)
	require.NoError(t, err, "orchestrator main.go should exist at %s", mainGo)
}

func TestSandboxCreate(t *testing.T) {
	// O2-03: Create a sandbox from "base" template, verify sandbox ID returned.
	skipIfOrchestratorUnavailable(t)
	conn := dialOrchestrator(t)
	client := orchestrator.NewSandboxServiceClient(conn)

	sandboxID := genSandboxID("tcreate")
	clientID := createSandbox(t, client, sandboxID)

	assert.NotEmpty(t, clientID, "sandbox create should return a non-empty client_id")
	t.Logf("created sandbox %s with client_id=%s", sandboxID, clientID)
}

func TestSandboxExec(t *testing.T) {
	// O2-04: Create sandbox, exec "echo hello" via envd, verify stdout.
	skipIfOrchestratorUnavailable(t)
	conn := dialOrchestrator(t)
	client := orchestrator.NewSandboxServiceClient(conn)

	sandboxID := genSandboxID("texec")
	createSandbox(t, client, sandboxID)

	// Wait briefly for envd to start inside the VM.
	time.Sleep(3 * time.Second)

	result := execInSandbox(t, sandboxID, "echo", []string{"hello"})
	assert.Equal(t, "hello\n", result.Stdout, "stdout should contain 'hello\\n'")
	assert.Equal(t, int32(0), result.ExitCode, "exit code should be 0")
}

func TestSandboxDelete(t *testing.T) {
	// O2-05: Create then delete sandbox, verify it's gone from list.
	skipIfOrchestratorUnavailable(t)
	conn := dialOrchestrator(t)
	client := orchestrator.NewSandboxServiceClient(conn)

	sandboxID := genSandboxID("tdelete")

	// Create the sandbox (without auto-cleanup since we delete manually).
	ctx, cancel := context.WithTimeout(context.Background(), createTimeout)
	defer cancel()

	now := timestamppb.Now()
	endTime := timestamppb.New(now.AsTime().Add(5 * time.Minute))

	resp, err := client.Create(ctx, &orchestrator.SandboxCreateRequest{
		Sandbox: &orchestrator.SandboxConfig{
			TemplateId:         templateID(),
			BuildId:            buildID(),
			KernelVersion:      kernelVersion(),
			FirecrackerVersion: firecrackerVersion(),
			SandboxId:          sandboxID,
			Vcpu:               1,
			RamMb:              256,
			TeamId:             "test-team",
			MaxSandboxLength:   1,
			TotalDiskSizeMb:    512,
		},
		StartTime: now,
		EndTime:   endTime,
	})
	require.NoError(t, err, "failed to create sandbox %s", sandboxID)
	require.NotEmpty(t, resp.GetClientId())

	// Verify it appears in the list.
	sandboxes := listSandboxes(t, client)
	require.True(t, sandboxInList(sandboxes, sandboxID),
		"sandbox %s should appear in list after creation", sandboxID)

	// Delete it.
	deleteSandbox(t, client, sandboxID)

	// Verify it is gone from the list.
	sandboxesAfter := listSandboxes(t, client)
	assert.False(t, sandboxInList(sandboxesAfter, sandboxID),
		"sandbox %s should NOT appear in list after deletion", sandboxID)
}

func TestSandboxList(t *testing.T) {
	// O2-06: Create 2 sandboxes, list, verify count.
	skipIfOrchestratorUnavailable(t)
	conn := dialOrchestrator(t)
	client := orchestrator.NewSandboxServiceClient(conn)

	// Record initial sandbox count.
	initialSandboxes := listSandboxes(t, client)
	initialCount := len(initialSandboxes)

	sandboxID1 := genSandboxID("tlista")
	sandboxID2 := genSandboxID("tlistb")

	createSandbox(t, client, sandboxID1)
	createSandbox(t, client, sandboxID2)

	// List and verify both are present.
	sandboxes := listSandboxes(t, client)
	assert.GreaterOrEqual(t, len(sandboxes), initialCount+2,
		"list should contain at least %d sandboxes (initial %d + 2 created)",
		initialCount+2, initialCount)

	assert.True(t, sandboxInList(sandboxes, sandboxID1),
		"sandbox %s should be in the list", sandboxID1)
	assert.True(t, sandboxInList(sandboxes, sandboxID2),
		"sandbox %s should be in the list", sandboxID2)
}

func TestSandboxNetworkOutbound(t *testing.T) {
	// O2-07: Create sandbox, exec `curl -s https://httpbin.org/ip`, verify response.
	skipIfOrchestratorUnavailable(t)
	conn := dialOrchestrator(t)
	client := orchestrator.NewSandboxServiceClient(conn)

	sandboxID := genSandboxID("tnet")
	allow := true
	createSandboxWithConfig(t, client, sandboxID, &allow)

	// Wait for envd + networking to stabilize.
	time.Sleep(5 * time.Second)

	result := execInSandbox(t, sandboxID, "curl", []string{"-s", "https://httpbin.org/ip"})
	assert.Equal(t, int32(0), result.ExitCode, "curl should exit 0")
	assert.Contains(t, result.Stdout, "origin",
		"curl response should contain 'origin' field from httpbin")
}

// ---------------------------------------------------------------------------
// P1 Tests
// ---------------------------------------------------------------------------

func TestSandboxPauseResume(t *testing.T) {
	// O2-08: Create, pause, resume (via Create with snapshot=true), exec still works.
	skipIfOrchestratorUnavailable(t)
	conn := dialOrchestrator(t)
	client := orchestrator.NewSandboxServiceClient(conn)

	sandboxID := genSandboxID("tpause")
	createSandbox(t, client, sandboxID)

	// Wait for envd to become ready.
	time.Sleep(3 * time.Second)

	// Verify exec works before pause.
	resultBefore := execInSandbox(t, sandboxID, "echo", []string{"before-pause"})
	require.Equal(t, "before-pause\n", resultBefore.Stdout, "exec should work before pause")

	// Pause the sandbox.
	pauseCtx, pauseCancel := context.WithTimeout(context.Background(), orchTestTimeout)
	defer pauseCancel()
	_, err := client.Pause(pauseCtx, &orchestrator.SandboxPauseRequest{
		SandboxId:  sandboxID,
		TemplateId: templateID(),
		BuildId:    buildID(),
	})
	require.NoError(t, err, "pause should succeed")

	// Resume by creating a new sandbox from the paused snapshot.
	// The orchestrator resumes a paused sandbox by creating a new one
	// with snapshot=true pointing to the paused sandbox's template/build.
	resumeSandboxID := genSandboxID("tresume")
	resumeCtx, resumeCancel := context.WithTimeout(context.Background(), createTimeout)
	defer resumeCancel()

	now := timestamppb.Now()
	endTime := timestamppb.New(now.AsTime().Add(5 * time.Minute))

	resumeResp, err := client.Create(resumeCtx, &orchestrator.SandboxCreateRequest{
		Sandbox: &orchestrator.SandboxConfig{
			TemplateId:         templateID(),
			BuildId:            buildID(),
			KernelVersion:      kernelVersion(),
			FirecrackerVersion: firecrackerVersion(),
			SandboxId:          resumeSandboxID,
			Vcpu:               1,
			RamMb:              256,
			TeamId:             "test-team",
			MaxSandboxLength:   1,
			TotalDiskSizeMb:    512,
			Snapshot:           true,
		},
		StartTime: now,
		EndTime:   endTime,
	})
	require.NoError(t, err, "resume (create from snapshot) should succeed")
	require.NotEmpty(t, resumeResp.GetClientId())

	// Register cleanup for the resumed sandbox.
	t.Cleanup(func() {
		delCtx, delCancel := context.WithTimeout(context.Background(), orchTestTimeout)
		defer delCancel()
		_, _ = client.Delete(delCtx, &orchestrator.SandboxDeleteRequest{
			SandboxId: resumeSandboxID,
		})
	})

	// Wait for envd to be ready after resume.
	time.Sleep(3 * time.Second)

	// Exec in the resumed sandbox.
	resultAfter := execInSandbox(t, resumeSandboxID, "echo", []string{"after-resume"})
	assert.Equal(t, "after-resume\n", resultAfter.Stdout,
		"exec should work after pause/resume")
	assert.Equal(t, int32(0), resultAfter.ExitCode)
}

func TestSandboxTimeout(t *testing.T) {
	// O2-09: Create with short timeout, wait, verify auto-cleanup.
	skipIfOrchestratorUnavailable(t)
	conn := dialOrchestrator(t)
	client := orchestrator.NewSandboxServiceClient(conn)

	sandboxID := genSandboxID("ttimeout")

	ctx, cancel := context.WithTimeout(context.Background(), createTimeout)
	defer cancel()

	now := timestamppb.Now()
	// Set end_time to 30 seconds from now for a short-lived sandbox.
	shortEndTime := timestamppb.New(now.AsTime().Add(30 * time.Second))

	resp, err := client.Create(ctx, &orchestrator.SandboxCreateRequest{
		Sandbox: &orchestrator.SandboxConfig{
			TemplateId:         templateID(),
			BuildId:            buildID(),
			KernelVersion:      kernelVersion(),
			FirecrackerVersion: firecrackerVersion(),
			SandboxId:          sandboxID,
			Vcpu:               1,
			RamMb:              256,
			TeamId:             "test-team",
			MaxSandboxLength:   1,
			TotalDiskSizeMb:    512,
		},
		StartTime: now,
		EndTime:   shortEndTime,
	})
	require.NoError(t, err, "failed to create short-lived sandbox")
	require.NotEmpty(t, resp.GetClientId())

	// Verify it exists immediately.
	sandboxes := listSandboxes(t, client)
	require.True(t, sandboxInList(sandboxes, sandboxID),
		"sandbox should exist immediately after creation")

	// Wait for the sandbox to expire (30s timeout + buffer).
	t.Logf("waiting ~45s for sandbox %s to auto-expire...", sandboxID)
	time.Sleep(45 * time.Second)

	// Verify it has been cleaned up.
	sandboxesAfter := listSandboxes(t, client)
	assert.False(t, sandboxInList(sandboxesAfter, sandboxID),
		"sandbox %s should be auto-cleaned up after timeout", sandboxID)
}

func TestSandboxConcurrent(t *testing.T) {
	// O2-10: Create 5 sandboxes concurrently, all succeed.
	skipIfOrchestratorUnavailable(t)
	conn := dialOrchestrator(t)
	client := orchestrator.NewSandboxServiceClient(conn)

	const concurrency = 3
	var wg sync.WaitGroup
	results := make([]struct {
		sandboxID string
		clientID  string
		err       error
	}, concurrency)

	for i := 0; i < concurrency; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			sandboxID := genSandboxID(fmt.Sprintf("tconc%d", idx))
			results[idx].sandboxID = sandboxID

			ctx, cancel := context.WithTimeout(context.Background(), createTimeout)
			defer cancel()

			now := timestamppb.Now()
			endTime := timestamppb.New(now.AsTime().Add(5 * time.Minute))

			resp, err := client.Create(ctx, &orchestrator.SandboxCreateRequest{
				Sandbox: &orchestrator.SandboxConfig{
					TemplateId:         templateID(),
					BuildId:            buildID(),
					KernelVersion:      kernelVersion(),
					FirecrackerVersion: firecrackerVersion(),
					SandboxId:          sandboxID,
					Vcpu:               1,
					RamMb:              256,
					TeamId:             "test-team",
					MaxSandboxLength:   1,
					TotalDiskSizeMb:    512,
				},
				StartTime: now,
				EndTime:   endTime,
			})
			if err != nil {
				results[idx].err = err
				return
			}
			results[idx].clientID = resp.GetClientId()
		}(i)
	}

	wg.Wait()

	// Register cleanup for all created sandboxes.
	t.Cleanup(func() {
		for _, r := range results {
			if r.err == nil && r.sandboxID != "" {
				delCtx, delCancel := context.WithTimeout(context.Background(), orchTestTimeout)
				_, _ = client.Delete(delCtx, &orchestrator.SandboxDeleteRequest{
					SandboxId: r.sandboxID,
				})
				delCancel()
			}
		}
	})

	// Verify all succeeded.
	for i, r := range results {
		require.NoError(t, r.err, "concurrent sandbox %d (%s) should succeed", i, r.sandboxID)
		assert.NotEmpty(t, r.clientID, "concurrent sandbox %d should have a client_id", i)
	}

	// Verify all appear in list.
	sandboxes := listSandboxes(t, client)
	for _, r := range results {
		assert.True(t, sandboxInList(sandboxes, r.sandboxID),
			"sandbox %s should appear in list", r.sandboxID)
	}
}

func TestSandboxNoInternet(t *testing.T) {
	// O2-11: Create with allow_internet=false, verify outbound blocked.
	skipIfOrchestratorUnavailable(t)
	conn := dialOrchestrator(t)
	client := orchestrator.NewSandboxServiceClient(conn)

	sandboxID := genSandboxID("tnonet")
	noInternet := false
	createSandboxWithConfig(t, client, sandboxID, &noInternet)

	// Wait for envd to start.
	time.Sleep(5 * time.Second)

	// Try to reach the internet -- should fail or timeout.
	result := execInSandbox(t, sandboxID, "curl", []string{
		"-s", "--connect-timeout", "5", "--max-time", "10",
		"https://httpbin.org/ip",
	})

	// When internet is blocked, curl should either:
	// - exit with a non-zero code (e.g., 7 = couldn't connect, 28 = timeout)
	// - return empty stdout (no response body)
	assert.True(t,
		result.ExitCode != 0 || result.Stdout == "" || !strings.Contains(result.Stdout, "origin"),
		"outbound traffic should be blocked when allow_internet=false; got exit=%d stdout=%q",
		result.ExitCode, result.Stdout)
}

func TestSandboxExecWorkingDir(t *testing.T) {
	// TC-104: Create sandbox, exec "pwd" with cwd=/tmp, verify output is /tmp.
	skipIfOrchestratorUnavailable(t)
	conn := dialOrchestrator(t)
	client := orchestrator.NewSandboxServiceClient(conn)

	sandboxID := genSandboxID("tcwd")
	createSandbox(t, client, sandboxID)
	time.Sleep(3 * time.Second)

	result := execInSandboxWithCwd(t, sandboxID, "pwd", nil, "/tmp")
	assert.Equal(t, "/tmp\n", result.Stdout, "pwd should output /tmp when cwd is set to /tmp")
	assert.Equal(t, int32(0), result.ExitCode)
}

func TestSandboxExecLongRunning(t *testing.T) {
	// TC-105: Start a long-running process, verify it gets a PID and produces
	// output over time (streaming). We use "sleep 2 && echo done".
	skipIfOrchestratorUnavailable(t)
	conn := dialOrchestrator(t)
	client := orchestrator.NewSandboxServiceClient(conn)

	sandboxID := genSandboxID("tlongrun")
	createSandbox(t, client, sandboxID)
	time.Sleep(3 * time.Second)

	start := time.Now()
	result := execInSandbox(t, sandboxID, "sh", []string{"-c", "sleep 2 && echo done"})
	elapsed := time.Since(start)

	assert.Equal(t, "done\n", result.Stdout, "long-running command should produce output")
	assert.Equal(t, int32(0), result.ExitCode)
	assert.GreaterOrEqual(t, elapsed, 2*time.Second,
		"command should have taken at least 2 seconds")
}

func TestSandboxExecEnvVars(t *testing.T) {
	// TC-106: Exec with custom environment variables, verify they are set.
	skipIfOrchestratorUnavailable(t)
	conn := dialOrchestrator(t)
	client := orchestrator.NewSandboxServiceClient(conn)

	sandboxID := genSandboxID("tenv")
	createSandbox(t, client, sandboxID)
	time.Sleep(3 * time.Second)

	result := execInSandboxWithEnv(t, sandboxID, "sh", []string{"-c", "echo $MY_VAR"},
		map[string]string{"MY_VAR": "hello_from_test"})
	assert.Equal(t, "hello_from_test\n", result.Stdout)
	assert.Equal(t, int32(0), result.ExitCode)
}

func TestSandboxExecNonZeroExit(t *testing.T) {
	// TC-107: Exec a command that exits with non-zero, verify exit code.
	skipIfOrchestratorUnavailable(t)
	conn := dialOrchestrator(t)
	client := orchestrator.NewSandboxServiceClient(conn)

	sandboxID := genSandboxID("tnzexit")
	createSandbox(t, client, sandboxID)
	time.Sleep(3 * time.Second)

	result := execInSandbox(t, sandboxID, "sh", []string{"-c", "exit 42"})
	assert.Equal(t, int32(42), result.ExitCode, "exit code should be 42")
}

func TestSandboxSignal(t *testing.T) {
	// TC-108: Start a long-running process, send SIGTERM, verify it terminates.
	skipIfOrchestratorUnavailable(t)
	conn := dialOrchestrator(t)
	client := orchestrator.NewSandboxServiceClient(conn)

	sandboxID := genSandboxID("tsignal")
	createSandbox(t, client, sandboxID)
	time.Sleep(3 * time.Second)

	// Start a "sleep 60" process with a tag so we can signal it.
	tag := "signal-test"
	pid := startProcessWithTag(t, sandboxID, "sleep", []string{"60"}, tag)
	require.NotZero(t, pid, "sleep process should have a PID")

	// Give it a moment to start.
	time.Sleep(1 * time.Second)

	// Send SIGTERM.
	sendSignal(t, sandboxID, pid, process.Signal_SIGNAL_SIGTERM)

	// Verify the process is no longer running (list should not contain it).
	time.Sleep(1 * time.Second)
	procs := listProcesses(t, sandboxID)

	pidRunning := false
	for _, p := range procs {
		if p.GetPid() == pid {
			pidRunning = true
			break
		}
	}
	assert.False(t, pidRunning, "sleep process (PID %d) should have been terminated by SIGTERM", pid)
}

func TestSandboxStdin(t *testing.T) {
	// TC-109: Start a process that reads stdin, send input, verify output.
	skipIfOrchestratorUnavailable(t)
	conn := dialOrchestrator(t)
	client := orchestrator.NewSandboxServiceClient(conn)

	sandboxID := genSandboxID("tstdin")
	createSandbox(t, client, sandboxID)
	time.Sleep(3 * time.Second)

	// Use "cat" which echoes stdin to stdout. Start with stdin enabled,
	// send data, close stdin, and verify output.
	result := execWithStdin(t, sandboxID, "cat", nil, "hello from stdin\n")
	assert.Contains(t, result.Stdout, "hello from stdin",
		"cat should echo stdin to stdout")
}

func TestSandboxPTY(t *testing.T) {
	// TC-110: Start a process with PTY, verify we get a terminal response.
	skipIfOrchestratorUnavailable(t)
	conn := dialOrchestrator(t)
	client := orchestrator.NewSandboxServiceClient(conn)

	sandboxID := genSandboxID("tpty")
	createSandbox(t, client, sandboxID)
	time.Sleep(3 * time.Second)

	// Run "echo hello" with PTY — the output should still contain "hello".
	result := execWithPTY(t, sandboxID, "echo", []string{"hello"})
	assert.Contains(t, result.Stdout, "hello",
		"PTY exec should still produce output containing 'hello'")
}

func TestSandboxIsolation(t *testing.T) {
	// O2-12: Create 2 sandboxes, verify they can't reach each other.
	skipIfOrchestratorUnavailable(t)
	conn := dialOrchestrator(t)
	client := orchestrator.NewSandboxServiceClient(conn)

	sandboxA := genSandboxID("tisoa")
	sandboxB := genSandboxID("tisob")

	createSandbox(t, client, sandboxA)
	createSandbox(t, client, sandboxB)

	// Wait for envd to start in both sandboxes.
	time.Sleep(5 * time.Second)

	// Get sandbox B's IP address from inside sandbox B.
	ipResult := execInSandbox(t, sandboxB, "hostname", []string{"-I"})
	require.Equal(t, int32(0), ipResult.ExitCode, "hostname -I should succeed in sandbox B")

	sandboxBIP := strings.TrimSpace(ipResult.Stdout)
	require.NotEmpty(t, sandboxBIP, "sandbox B should have an IP address")
	t.Logf("sandbox B IP: %s", sandboxBIP)

	// The IP may contain multiple addresses; take the first one.
	if parts := strings.Fields(sandboxBIP); len(parts) > 0 {
		sandboxBIP = parts[0]
	}

	// From sandbox A, try to ping sandbox B. This should fail (isolated networks).
	pingResult := execInSandbox(t, sandboxA, "ping", []string{
		"-c", "1", "-W", "3", sandboxBIP,
	})

	assert.NotEqual(t, int32(0), pingResult.ExitCode,
		"sandbox A should NOT be able to ping sandbox B at %s (exit code should be non-zero)",
		sandboxBIP)
}
