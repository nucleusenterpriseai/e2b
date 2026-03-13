//go:build integration && linux

// Package orchestrator_test contains integration tests for E2B desktop/browser sandboxes.
//
// These tests exercise the desktop template (TC-1001 through TC-1008), verifying
// that Xvfb, XFCE, VNC, noVNC, screenshot capture, keyboard input, and browser
// launch all work correctly inside a Firecracker VM.
//
// Prerequisites:
//   - Orchestrator running on ORCHESTRATOR_ADDR (default localhost:5008)
//   - Sandbox proxy running on PROXY_ADDR (default localhost:5007)
//   - Desktop template built and available (TEST_DESKTOP_TEMPLATE_ID)
//   - Firecracker, KVM, kernel, rootfs, and envd all set up
//
// Run:
//
//	cd tests/orchestrator && \
//	  TEST_DESKTOP_TEMPLATE_ID=desktop TEST_DESKTOP_BUILD_ID=desktop-build \
//	  go test -tags integration -v -run TestDesktop -count=1 -timeout 600s
package orchestrator_test

import (
	"context"
	"encoding/hex"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"google.golang.org/protobuf/types/known/timestamppb"

	orchestrator "github.com/e2b-dev/infra/packages/shared/pkg/grpc/orchestrator"
)

const (
	// desktopStartupWait is the time to wait after creating a desktop sandbox
	// for Xvfb, XFCE, VNC, and noVNC to fully start.
	desktopStartupWait = 30 * time.Second

	// desktopCreateTimeout is an extended timeout for desktop sandbox creation,
	// since the desktop rootfs is larger than the base template.
	desktopCreateTimeout = 180 * time.Second

	// envDesktopTemplateID is the env var for the desktop template ID.
	envDesktopTemplateID = "TEST_DESKTOP_TEMPLATE_ID"

	// envDesktopBuildID is the env var for the desktop template build ID.
	envDesktopBuildID = "TEST_DESKTOP_BUILD_ID"

	// envBrowserTemplateID is the env var for the browser-use template ID.
	envBrowserTemplateID = "TEST_BROWSER_TEMPLATE_ID"

	// envBrowserBuildID is the env var for the browser-use template build ID.
	envBrowserBuildID = "TEST_BROWSER_BUILD_ID"

	// pngMagic is the hex-encoded first 8 bytes of a valid PNG file.
	pngMagic = "89504e470d0a1a0a"
)

// desktopTemplateID returns the template ID for desktop sandboxes.
// Tests are skipped if the env var is not set.
func desktopTemplateID(t *testing.T) string {
	t.Helper()
	id := os.Getenv(envDesktopTemplateID)
	if id == "" {
		t.Skipf("skipping: %s not set", envDesktopTemplateID)
	}
	return id
}

// desktopBuildID returns the build ID for desktop sandboxes.
func desktopBuildID(t *testing.T) string {
	t.Helper()
	id := os.Getenv(envDesktopBuildID)
	if id == "" {
		// Fall back to the template ID with "-build" suffix.
		return desktopTemplateID(t) + "-build"
	}
	return id
}

// browserTemplateID returns the template ID for browser-use sandboxes.
// Returns empty string if not set (caller should skip).
func browserTemplateID() string {
	return os.Getenv(envBrowserTemplateID)
}

// browserBuildID returns the build ID for browser-use sandboxes.
func browserBuildID() string {
	id := os.Getenv(envBrowserBuildID)
	if id == "" {
		tmpl := browserTemplateID()
		if tmpl != "" {
			return tmpl + "-build"
		}
	}
	return id
}

// createDesktopSandbox creates a desktop sandbox with appropriate resource
// allocations (more RAM and disk for the desktop environment) and waits for
// the desktop services to start. It registers cleanup to delete the sandbox.
func createDesktopSandbox(t *testing.T, client orchestrator.SandboxServiceClient, sandboxID string) string {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), desktopCreateTimeout)
	defer cancel()

	now := timestamppb.Now()
	endTime := timestamppb.New(now.AsTime().Add(10 * time.Minute))

	resp, err := client.Create(ctx, &orchestrator.SandboxCreateRequest{
		Sandbox: &orchestrator.SandboxConfig{
			TemplateId:         desktopTemplateID(t),
			BuildId:            desktopBuildID(t),
			KernelVersion:      kernelVersion(),
			FirecrackerVersion: firecrackerVersion(),
			SandboxId:          sandboxID,
			Vcpu:               2,
			RamMb:              1024,
			TeamId:             "test-team",
			MaxSandboxLength:   1,
			TotalDiskSizeMb:    2048,
		},
		StartTime: now,
		EndTime:   endTime,
	})
	require.NoError(t, err, "failed to create desktop sandbox %s", sandboxID)
	require.NotEmpty(t, resp.GetClientId(), "create response should return a client_id")

	// Register cleanup: delete the sandbox when test finishes.
	t.Cleanup(func() {
		deleteCtx, deleteCancel := context.WithTimeout(context.Background(), orchTestTimeout)
		defer deleteCancel()
		_, deleteErr := client.Delete(deleteCtx, &orchestrator.SandboxDeleteRequest{
			SandboxId: sandboxID,
		})
		if deleteErr != nil {
			t.Logf("cleanup: failed to delete desktop sandbox %s: %v", sandboxID, deleteErr)
		}
	})

	// Wait for the desktop environment to fully start (Xvfb + XFCE + VNC).
	t.Logf("waiting %s for desktop services to start in sandbox %s...", desktopStartupWait, sandboxID)
	time.Sleep(desktopStartupWait)

	return resp.GetClientId()
}

// ---------------------------------------------------------------------------
// TC-1001: Desktop Template Boot
// ---------------------------------------------------------------------------

func TestDesktopBoot(t *testing.T) {
	// TC-1001: Create desktop sandbox, verify Xvfb + XFCE + VNC running.
	skipIfOrchestratorUnavailable(t)
	conn := dialOrchestrator(t)
	client := orchestrator.NewSandboxServiceClient(conn)

	sandboxID := genSandboxID("tdesktop")
	createDesktopSandbox(t, client, sandboxID)

	// Check that Xvfb is running.
	xvfbResult := execInSandbox(t, sandboxID, "sh", []string{"-c", "pgrep -x Xvfb || pgrep -f 'Xvfb :99'"})
	assert.Equal(t, int32(0), xvfbResult.ExitCode,
		"Xvfb should be running; pgrep output: stdout=%q stderr=%q", xvfbResult.Stdout, xvfbResult.Stderr)
	assert.NotEmpty(t, strings.TrimSpace(xvfbResult.Stdout),
		"Xvfb process should have a PID")

	// Check that XFCE session is running (xfce4-session or xfdesktop).
	xfceResult := execInSandbox(t, sandboxID, "sh", []string{"-c", "pgrep -f 'xfce4-session|xfdesktop|xfwm4'"})
	assert.Equal(t, int32(0), xfceResult.ExitCode,
		"XFCE should be running; pgrep output: stdout=%q stderr=%q", xfceResult.Stdout, xfceResult.Stderr)
	assert.NotEmpty(t, strings.TrimSpace(xfceResult.Stdout),
		"XFCE process should have a PID")

	// Check that x11vnc is running.
	vncResult := execInSandbox(t, sandboxID, "sh", []string{"-c", "pgrep -x x11vnc"})
	assert.Equal(t, int32(0), vncResult.ExitCode,
		"x11vnc should be running; pgrep output: stdout=%q stderr=%q", vncResult.Stdout, vncResult.Stderr)
	assert.NotEmpty(t, strings.TrimSpace(vncResult.Stdout),
		"x11vnc process should have a PID")

	t.Logf("desktop boot verified: Xvfb=%s, XFCE=%s, VNC=%s",
		strings.TrimSpace(xvfbResult.Stdout),
		strings.TrimSpace(xfceResult.Stdout),
		strings.TrimSpace(vncResult.Stdout))
}

// ---------------------------------------------------------------------------
// TC-1002: VNC Port (5900) Listening
// ---------------------------------------------------------------------------

func TestDesktopVNCPort(t *testing.T) {
	// TC-1002: Verify port 5900 is listening (VNC server).
	skipIfOrchestratorUnavailable(t)
	conn := dialOrchestrator(t)
	client := orchestrator.NewSandboxServiceClient(conn)

	sandboxID := genSandboxID("tvncport")
	createDesktopSandbox(t, client, sandboxID)

	// Check that port 5900 is listening using ss.
	result := execInSandbox(t, sandboxID, "ss", []string{"-ltn"})
	assert.Equal(t, int32(0), result.ExitCode,
		"ss -ltn should succeed; stderr=%q", result.Stderr)
	assert.Contains(t, result.Stdout, ":5900",
		"port 5900 (VNC) should be listening; ss output:\n%s", result.Stdout)

	t.Logf("VNC port 5900 confirmed listening")
}

// ---------------------------------------------------------------------------
// TC-1003: noVNC Port (6080) Listening
// ---------------------------------------------------------------------------

func TestDesktopNoVNCPort(t *testing.T) {
	// TC-1003: Verify port 6080 is listening (noVNC websocket proxy).
	skipIfOrchestratorUnavailable(t)
	conn := dialOrchestrator(t)
	client := orchestrator.NewSandboxServiceClient(conn)

	sandboxID := genSandboxID("tnovnc")
	createDesktopSandbox(t, client, sandboxID)

	// Check that port 6080 is listening using ss.
	result := execInSandbox(t, sandboxID, "ss", []string{"-ltn"})
	assert.Equal(t, int32(0), result.ExitCode,
		"ss -ltn should succeed; stderr=%q", result.Stderr)
	assert.Contains(t, result.Stdout, ":6080",
		"port 6080 (noVNC) should be listening; ss output:\n%s", result.Stdout)

	t.Logf("noVNC port 6080 confirmed listening")
}

// ---------------------------------------------------------------------------
// TC-1004: Screenshot Capture
// ---------------------------------------------------------------------------

func TestDesktopScreenshot(t *testing.T) {
	// TC-1004: Run scrot to capture a screenshot, read it back, verify PNG magic bytes.
	skipIfOrchestratorUnavailable(t)
	conn := dialOrchestrator(t)
	client := orchestrator.NewSandboxServiceClient(conn)

	sandboxID := genSandboxID("tscrot")
	createDesktopSandbox(t, client, sandboxID)

	// Capture a screenshot with scrot. DISPLAY=:99 is set in the template env.
	captureResult := execInSandboxWithEnv(t, sandboxID, "scrot", []string{"/tmp/screenshot.png"},
		map[string]string{"DISPLAY": ":99"})
	require.Equal(t, int32(0), captureResult.ExitCode,
		"scrot should succeed; stderr=%q", captureResult.Stderr)

	// Verify the file exists and has non-zero size.
	statResult := execInSandbox(t, sandboxID, "stat", []string{"--format=%s", "/tmp/screenshot.png"})
	require.Equal(t, int32(0), statResult.ExitCode,
		"screenshot file should exist; stderr=%q", statResult.Stderr)
	fileSize := strings.TrimSpace(statResult.Stdout)
	assert.NotEqual(t, "0", fileSize,
		"screenshot file should have non-zero size, got %s bytes", fileSize)

	// Read the first 8 bytes and verify PNG magic bytes.
	hexResult := execInSandbox(t, sandboxID, "xxd", []string{"-p", "-l", "8", "/tmp/screenshot.png"})
	require.Equal(t, int32(0), hexResult.ExitCode,
		"xxd should succeed; stderr=%q", hexResult.Stderr)

	hexBytes := strings.TrimSpace(hexResult.Stdout)
	assert.Equal(t, pngMagic, hexBytes,
		"first 8 bytes should be PNG magic; got %q", hexBytes)

	t.Logf("screenshot captured: %s bytes, PNG magic verified", fileSize)
}

// ---------------------------------------------------------------------------
// TC-1005: Keyboard Input
// ---------------------------------------------------------------------------

func TestDesktopKeyboard(t *testing.T) {
	// TC-1005: Run xdotool to type "hello", take a screenshot (smoke test).
	skipIfOrchestratorUnavailable(t)
	conn := dialOrchestrator(t)
	client := orchestrator.NewSandboxServiceClient(conn)

	sandboxID := genSandboxID("tkeybd")
	createDesktopSandbox(t, client, sandboxID)

	// Use xdotool to simulate keyboard input. We type individual keys.
	xdoResult := execInSandboxWithEnv(t, sandboxID, "xdotool",
		[]string{"key", "h", "e", "l", "l", "o"},
		map[string]string{"DISPLAY": ":99"})
	assert.Equal(t, int32(0), xdoResult.ExitCode,
		"xdotool key should succeed; stderr=%q", xdoResult.Stderr)

	// Small delay for the keystrokes to be processed by the desktop.
	time.Sleep(2 * time.Second)

	// Take a screenshot to prove the desktop is responsive after keyboard input.
	captureResult := execInSandboxWithEnv(t, sandboxID, "scrot", []string{"/tmp/keyboard_test.png"},
		map[string]string{"DISPLAY": ":99"})
	require.Equal(t, int32(0), captureResult.ExitCode,
		"scrot should succeed after keyboard input; stderr=%q", captureResult.Stderr)

	// Verify the screenshot file exists (non-zero).
	statResult := execInSandbox(t, sandboxID, "stat", []string{"--format=%s", "/tmp/keyboard_test.png"})
	require.Equal(t, int32(0), statResult.ExitCode,
		"keyboard test screenshot should exist; stderr=%q", statResult.Stderr)
	fileSize := strings.TrimSpace(statResult.Stdout)
	assert.NotEqual(t, "0", fileSize,
		"keyboard test screenshot should have non-zero size")

	// Verify PNG magic bytes on the keyboard test screenshot.
	hexResult := execInSandbox(t, sandboxID, "xxd", []string{"-p", "-l", "8", "/tmp/keyboard_test.png"})
	require.Equal(t, int32(0), hexResult.ExitCode,
		"xxd should succeed; stderr=%q", hexResult.Stderr)
	hexBytes := strings.TrimSpace(hexResult.Stdout)
	assert.Equal(t, pngMagic, hexBytes,
		"keyboard test screenshot should have PNG magic bytes; got %q", hexBytes)

	t.Logf("keyboard input smoke test passed: xdotool key succeeded, screenshot valid")
}

// ---------------------------------------------------------------------------
// TC-1006: Browser Launch (Firefox)
// ---------------------------------------------------------------------------

func TestDesktopBrowserLaunch(t *testing.T) {
	// TC-1006: Launch firefox-esr, wait, verify the process exists.
	skipIfOrchestratorUnavailable(t)
	conn := dialOrchestrator(t)
	client := orchestrator.NewSandboxServiceClient(conn)

	sandboxID := genSandboxID("tfirefox")
	createDesktopSandbox(t, client, sandboxID)

	// Launch Firefox in the background. We use sh -c so the & works.
	launchResult := execInSandboxWithEnv(t, sandboxID, "sh",
		[]string{"-c", "firefox-esr --no-remote about:blank &"},
		map[string]string{"DISPLAY": ":99"})
	// sh -c with & will return quickly with exit code 0.
	assert.Equal(t, int32(0), launchResult.ExitCode,
		"firefox launch command should succeed; stderr=%q", launchResult.Stderr)

	// Wait for Firefox to start up.
	t.Logf("waiting 8s for Firefox to start...")
	time.Sleep(8 * time.Second)

	// Verify Firefox is running by checking for its process.
	pgrepResult := execInSandbox(t, sandboxID, "sh", []string{"-c", "pgrep -f 'firefox-esr|firefox' | head -1"})
	assert.Equal(t, int32(0), pgrepResult.ExitCode,
		"firefox-esr process should be running; stderr=%q", pgrepResult.Stderr)
	firefoxPID := strings.TrimSpace(pgrepResult.Stdout)
	assert.NotEmpty(t, firefoxPID,
		"firefox-esr should have a PID")

	t.Logf("Firefox launched successfully with PID %s", firefoxPID)
}

// ---------------------------------------------------------------------------
// TC-1007: Browser-Use Template
// ---------------------------------------------------------------------------

func TestDesktopBrowserUseTemplate(t *testing.T) {
	// TC-1007: Create sandbox from browser-use template, verify chromium-browser exists.
	skipIfOrchestratorUnavailable(t)

	browserTmpl := browserTemplateID()
	if browserTmpl == "" {
		t.Skipf("skipping: %s not set", envBrowserTemplateID)
	}

	conn := dialOrchestrator(t)
	client := orchestrator.NewSandboxServiceClient(conn)

	sandboxID := genSandboxID("tbrowser")

	ctx, cancel := context.WithTimeout(context.Background(), desktopCreateTimeout)
	defer cancel()

	now := timestamppb.Now()
	endTime := timestamppb.New(now.AsTime().Add(10 * time.Minute))

	browserBuild := browserBuildID()

	resp, err := client.Create(ctx, &orchestrator.SandboxCreateRequest{
		Sandbox: &orchestrator.SandboxConfig{
			TemplateId:         browserTmpl,
			BuildId:            browserBuild,
			KernelVersion:      kernelVersion(),
			FirecrackerVersion: firecrackerVersion(),
			SandboxId:          sandboxID,
			Vcpu:               2,
			RamMb:              1024,
			TeamId:             "test-team",
			MaxSandboxLength:   1,
			TotalDiskSizeMb:    2048,
		},
		StartTime: now,
		EndTime:   endTime,
	})
	require.NoError(t, err, "failed to create browser-use sandbox %s", sandboxID)
	require.NotEmpty(t, resp.GetClientId(), "browser-use sandbox should return a client_id")

	// Register cleanup.
	t.Cleanup(func() {
		deleteCtx, deleteCancel := context.WithTimeout(context.Background(), orchTestTimeout)
		defer deleteCancel()
		_, deleteErr := client.Delete(deleteCtx, &orchestrator.SandboxDeleteRequest{
			SandboxId: sandboxID,
		})
		if deleteErr != nil {
			t.Logf("cleanup: failed to delete browser-use sandbox %s: %v", sandboxID, deleteErr)
		}
	})

	// Wait for the environment to start.
	t.Logf("waiting %s for browser-use sandbox to start...", desktopStartupWait)
	time.Sleep(desktopStartupWait)

	// Verify that a Chromium-based browser is installed.
	// Common names: chromium-browser, chromium, google-chrome, google-chrome-stable
	whichResult := execInSandbox(t, sandboxID, "sh", []string{"-c",
		"which chromium-browser || which chromium || which google-chrome || which google-chrome-stable"})
	assert.Equal(t, int32(0), whichResult.ExitCode,
		"a chromium-based browser should be installed; stderr=%q", whichResult.Stderr)
	browserPath := strings.TrimSpace(whichResult.Stdout)
	assert.NotEmpty(t, browserPath,
		"chromium browser binary should be found on PATH")

	t.Logf("browser-use template verified: browser at %s", browserPath)
}

// ---------------------------------------------------------------------------
// TC-1008: Desktop Sandbox Cleanup
// ---------------------------------------------------------------------------

func TestDesktopCleanup(t *testing.T) {
	// TC-1008: Create and delete desktop sandbox, verify it is removed from the list.
	skipIfOrchestratorUnavailable(t)
	conn := dialOrchestrator(t)
	client := orchestrator.NewSandboxServiceClient(conn)

	sandboxID := genSandboxID("tcleanup")

	// Create the desktop sandbox WITHOUT the auto-cleanup helper,
	// since we want to manually delete and verify.
	ctx, cancel := context.WithTimeout(context.Background(), desktopCreateTimeout)
	defer cancel()

	now := timestamppb.Now()
	endTime := timestamppb.New(now.AsTime().Add(10 * time.Minute))

	resp, err := client.Create(ctx, &orchestrator.SandboxCreateRequest{
		Sandbox: &orchestrator.SandboxConfig{
			TemplateId:         desktopTemplateID(t),
			BuildId:            desktopBuildID(t),
			KernelVersion:      kernelVersion(),
			FirecrackerVersion: firecrackerVersion(),
			SandboxId:          sandboxID,
			Vcpu:               2,
			RamMb:              1024,
			TeamId:             "test-team",
			MaxSandboxLength:   1,
			TotalDiskSizeMb:    2048,
		},
		StartTime: now,
		EndTime:   endTime,
	})
	require.NoError(t, err, "failed to create desktop sandbox for cleanup test")
	require.NotEmpty(t, resp.GetClientId())

	// Wait briefly for the sandbox to register (no need for full desktop startup).
	time.Sleep(5 * time.Second)

	// Verify it appears in the list.
	sandboxes := listSandboxes(t, client)
	require.True(t, sandboxInList(sandboxes, sandboxID),
		"desktop sandbox %s should appear in list after creation", sandboxID)

	// Delete the sandbox.
	deleteSandbox(t, client, sandboxID)

	// Verify it is gone from the list.
	sandboxesAfter := listSandboxes(t, client)
	assert.False(t, sandboxInList(sandboxesAfter, sandboxID),
		"desktop sandbox %s should NOT appear in list after deletion", sandboxID)

	t.Logf("desktop sandbox cleanup verified: %s created and deleted cleanly", sandboxID)
}

// ---------------------------------------------------------------------------
// Compile-time check: ensure pngMagic constant is valid hex.
// ---------------------------------------------------------------------------

func init() {
	if _, err := hex.DecodeString(pngMagic); err != nil {
		panic("pngMagic is not valid hex: " + err.Error())
	}
}