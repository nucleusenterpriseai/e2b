//go:build integration && linux

// Package orchestrator_test contains performance benchmark tests for the E2B orchestrator.
//
// These tests measure cold boot time, exec latency, filesystem latency,
// concurrent sandbox creation, memory overhead, and template build time.
//
// Prerequisites are the same as orchestrator_integration_test.go:
//   - Orchestrator running on ORCHESTRATOR_ADDR (default localhost:5008)
//   - Sandbox proxy running on PROXY_ADDR (default localhost:5007)
//   - Firecracker, KVM, kernel, rootfs, and envd all set up
//
// Run:
//
//	cd tests/orchestrator && go test -tags integration -v -run TestBenchmark -count=1 -timeout 600s
package orchestrator_test

import (
	"context"
	"fmt"
	"math"
	"os"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"google.golang.org/protobuf/types/known/timestamppb"

	orchestrator "github.com/e2b-dev/infra/packages/shared/pkg/grpc/orchestrator"
)

// ---------------------------------------------------------------------------
// Percentile and statistics helpers
// ---------------------------------------------------------------------------

// percentilesResult holds computed percentiles and basic statistics.
type percentilesResult struct {
	P50 float64
	P95 float64
	P99 float64
	Min float64
	Max float64
	Avg float64
}

// computePercentiles computes p50, p95, p99, min, max, and avg for a slice
// of durations (in milliseconds). The input slice is sorted in place.
func computePercentiles(durationsMs []float64) percentilesResult {
	sort.Float64s(durationsMs)

	n := len(durationsMs)
	if n == 0 {
		return percentilesResult{}
	}

	sum := 0.0
	for _, d := range durationsMs {
		sum += d
	}

	return percentilesResult{
		P50: percentile(durationsMs, 50),
		P95: percentile(durationsMs, 95),
		P99: percentile(durationsMs, 99),
		Min: durationsMs[0],
		Max: durationsMs[n-1],
		Avg: sum / float64(n),
	}
}

// percentile returns the p-th percentile from a sorted slice of float64 values.
// Uses nearest-rank method.
func percentile(sorted []float64, p float64) float64 {
	n := len(sorted)
	if n == 0 {
		return 0
	}
	rank := int(math.Ceil(p/100.0*float64(n))) - 1
	if rank < 0 {
		rank = 0
	}
	if rank >= n {
		rank = n - 1
	}
	return sorted[rank]
}

// ---------------------------------------------------------------------------
// Benchmark helper: create sandbox without t.Cleanup auto-delete
// ---------------------------------------------------------------------------

// benchCreateSandbox creates a sandbox and returns the sandbox ID and client ID.
// Unlike createSandbox, it does NOT register t.Cleanup — the caller is responsible
// for deletion. This is needed in benchmarks where we time deletion separately.
func benchCreateSandbox(t *testing.T, client orchestrator.SandboxServiceClient, sandboxID string) string {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), createTimeout)
	defer cancel()

	now := timestamppb.Now()
	endTime := timestamppb.New(now.AsTime().Add(10 * time.Minute))

	resp, err := client.Create(ctx, &orchestrator.SandboxCreateRequest{
		Sandbox: &orchestrator.SandboxConfig{
			TemplateId:         templateID(),
			BuildId:            buildID(),
			KernelVersion:      kernelVersion(),
			FirecrackerVersion: firecrackerVersion(),
			SandboxId:          sandboxID,
			Vcpu:               1,
			RamMb:              256,
			TeamId:             "bench-team",
			MaxSandboxLength:   1,
			TotalDiskSizeMb:    512,
		},
		StartTime: now,
		EndTime:   endTime,
	})
	require.NoError(t, err, "failed to create sandbox %s", sandboxID)
	require.NotEmpty(t, resp.GetClientId(), "create response should return a client_id")
	return resp.GetClientId()
}

// benchDeleteSandbox deletes a sandbox, logging but not failing on error.
func benchDeleteSandbox(t *testing.T, client orchestrator.SandboxServiceClient, sandboxID string) {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), orchTestTimeout)
	defer cancel()

	_, err := client.Delete(ctx, &orchestrator.SandboxDeleteRequest{
		SandboxId: sandboxID,
	})
	if err != nil {
		t.Logf("cleanup: failed to delete sandbox %s: %v", sandboxID, err)
	}
}

// ---------------------------------------------------------------------------
// TC-901: Cold Boot Time
// ---------------------------------------------------------------------------

func TestBenchmarkColdBoot(t *testing.T) {
	// TC-901: Measure time from Create call to first successful exec.
	// Run 10 times, report avg/min/max. Target: < 2s average.
	skipIfOrchestratorUnavailable(t)
	conn := dialOrchestrator(t)
	client := orchestrator.NewSandboxServiceClient(conn)

	const iterations = 10
	durations := make([]float64, 0, iterations)
	var sandboxIDs []string

	for i := 0; i < iterations; i++ {
		sandboxID := genSandboxID(fmt.Sprintf("bcold%d", i))
		sandboxIDs = append(sandboxIDs, sandboxID)

		start := time.Now()

		// Create the sandbox.
		benchCreateSandbox(t, client, sandboxID)

		// Poll with exec until we get a successful response from envd.
		// This measures true cold boot time: Create -> envd ready.
		var execOK bool
		for attempt := 0; attempt < 30; attempt++ {
			result := execInSandbox(t, sandboxID, "echo", []string{"ready"})
			if result != nil && strings.Contains(result.Stdout, "ready") {
				execOK = true
				break
			}
			time.Sleep(200 * time.Millisecond)
		}

		elapsed := time.Since(start)
		if !execOK {
			t.Logf("  iteration %d: FAILED (exec never succeeded after %v)", i, elapsed)
			continue
		}

		ms := float64(elapsed.Milliseconds())
		durations = append(durations, ms)
		t.Logf("  iteration %d: %.0f ms", i, ms)
	}

	// Cleanup all sandboxes.
	t.Cleanup(func() {
		for _, id := range sandboxIDs {
			benchDeleteSandbox(t, client, id)
		}
	})

	require.NotEmpty(t, durations, "at least one cold boot iteration should succeed")

	stats := computePercentiles(durations)
	t.Logf("")
	t.Logf("=== TC-901: Cold Boot Time ===")
	t.Logf("  Iterations : %d / %d succeeded", len(durations), iterations)
	t.Logf("  Avg        : %.0f ms", stats.Avg)
	t.Logf("  Min        : %.0f ms", stats.Min)
	t.Logf("  Max        : %.0f ms", stats.Max)
	t.Logf("  Target     : < 2000 ms avg")
	t.Logf("  Result     : %s", passOrFail(stats.Avg < 2000))
}

// ---------------------------------------------------------------------------
// TC-902: Snapshot Restore Time (SKIPPED)
// ---------------------------------------------------------------------------

func TestBenchmarkSnapshotRestore(t *testing.T) {
	// TC-902: Measure time from Create (snapshot-based) to envd ready.
	// TODO: Re-enable once PauseResume is fixed. Currently Pause/Resume
	// is broken so snapshot-based create cannot be reliably tested.
	t.Skip("TC-902: skipped — PauseResume is still broken. TODO: re-enable when snapshot restore works.")
}

// ---------------------------------------------------------------------------
// TC-903: Process Exec Latency
// ---------------------------------------------------------------------------

func TestBenchmarkExecLatency(t *testing.T) {
	// TC-903: In one sandbox, run "echo hello" 100 times.
	// Report p50/p95/p99. Target: p50 < 20ms, p99 < 100ms.
	skipIfOrchestratorUnavailable(t)
	conn := dialOrchestrator(t)
	client := orchestrator.NewSandboxServiceClient(conn)

	sandboxID := genSandboxID("bexec")
	createSandbox(t, client, sandboxID)

	// Wait for envd to stabilize.
	time.Sleep(3 * time.Second)

	// Warm up: one exec to prime any caches.
	_ = execInSandbox(t, sandboxID, "echo", []string{"warmup"})

	const iterations = 100
	durations := make([]float64, 0, iterations)

	for i := 0; i < iterations; i++ {
		start := time.Now()
		result := execInSandbox(t, sandboxID, "echo", []string{"hello"})
		elapsed := time.Since(start)

		if result == nil || !strings.Contains(result.Stdout, "hello") {
			t.Logf("  iteration %d: exec failed or bad output", i)
			continue
		}

		ms := float64(elapsed.Microseconds()) / 1000.0
		durations = append(durations, ms)
	}

	require.NotEmpty(t, durations, "at least one exec iteration should succeed")

	stats := computePercentiles(durations)
	t.Logf("")
	t.Logf("=== TC-903: Exec Latency (echo hello x %d) ===", iterations)
	t.Logf("  Succeeded  : %d / %d", len(durations), iterations)
	t.Logf("  P50        : %.2f ms", stats.P50)
	t.Logf("  P95        : %.2f ms", stats.P95)
	t.Logf("  P99        : %.2f ms", stats.P99)
	t.Logf("  Min        : %.2f ms", stats.Min)
	t.Logf("  Max        : %.2f ms", stats.Max)
	t.Logf("  Avg        : %.2f ms", stats.Avg)
	t.Logf("  Targets    : p50 < 20 ms, p99 < 100 ms")
	t.Logf("  P50 result : %s", passOrFail(stats.P50 < 20))
	t.Logf("  P99 result : %s", passOrFail(stats.P99 < 100))
}

// ---------------------------------------------------------------------------
// TC-904: Filesystem Read Latency
// ---------------------------------------------------------------------------

func TestBenchmarkFSReadLatency(t *testing.T) {
	// TC-904: Write a 1KB file once, then read it 100 times.
	// Report p50/p95/p99. Target: p50 < 5ms, p99 < 50ms.
	skipIfOrchestratorUnavailable(t)
	conn := dialOrchestrator(t)
	client := orchestrator.NewSandboxServiceClient(conn)

	sandboxID := genSandboxID("bfsread")
	createSandbox(t, client, sandboxID)

	// Wait for envd to stabilize.
	time.Sleep(3 * time.Second)

	// Write a 1KB file (1024 bytes of 'A').
	writeResult := execInSandbox(t, sandboxID, "sh", []string{
		"-c", "head -c 1024 /dev/urandom | base64 | head -c 1024 > /tmp/bench_read.txt && echo OK",
	})
	require.Contains(t, writeResult.Stdout, "OK", "should write 1KB file successfully")

	const iterations = 100
	durations := make([]float64, 0, iterations)

	for i := 0; i < iterations; i++ {
		start := time.Now()
		result := execInSandbox(t, sandboxID, "cat", []string{"/tmp/bench_read.txt"})
		elapsed := time.Since(start)

		if result == nil || result.ExitCode != 0 {
			t.Logf("  iteration %d: read failed", i)
			continue
		}

		ms := float64(elapsed.Microseconds()) / 1000.0
		durations = append(durations, ms)
	}

	require.NotEmpty(t, durations, "at least one FS read iteration should succeed")

	stats := computePercentiles(durations)
	t.Logf("")
	t.Logf("=== TC-904: FS Read Latency (cat 1KB file x %d) ===", iterations)
	t.Logf("  Succeeded  : %d / %d", len(durations), iterations)
	t.Logf("  P50        : %.2f ms", stats.P50)
	t.Logf("  P95        : %.2f ms", stats.P95)
	t.Logf("  P99        : %.2f ms", stats.P99)
	t.Logf("  Min        : %.2f ms", stats.Min)
	t.Logf("  Max        : %.2f ms", stats.Max)
	t.Logf("  Avg        : %.2f ms", stats.Avg)
	t.Logf("  Targets    : p50 < 5 ms, p99 < 50 ms")
	t.Logf("  P50 result : %s", passOrFail(stats.P50 < 5))
	t.Logf("  P99 result : %s", passOrFail(stats.P99 < 50))
}

// ---------------------------------------------------------------------------
// TC-905: Filesystem Write Latency
// ---------------------------------------------------------------------------

func TestBenchmarkFSWriteLatency(t *testing.T) {
	// TC-905: Write a 1KB file 100 times (different filenames).
	// Report p50/p95/p99. Target: p50 < 10ms, p99 < 100ms.
	skipIfOrchestratorUnavailable(t)
	conn := dialOrchestrator(t)
	client := orchestrator.NewSandboxServiceClient(conn)

	sandboxID := genSandboxID("bfswrite")
	createSandbox(t, client, sandboxID)

	// Wait for envd to stabilize.
	time.Sleep(3 * time.Second)

	const iterations = 100
	durations := make([]float64, 0, iterations)

	for i := 0; i < iterations; i++ {
		fileName := fmt.Sprintf("/tmp/bench_write_%d.txt", i)
		// Write 1024 bytes of deterministic data using printf to avoid /dev/urandom overhead.
		cmd := fmt.Sprintf("printf '%%01024d' 0 > %s && echo OK", fileName)

		start := time.Now()
		result := execInSandbox(t, sandboxID, "sh", []string{"-c", cmd})
		elapsed := time.Since(start)

		if result == nil || !strings.Contains(result.Stdout, "OK") {
			t.Logf("  iteration %d: write failed", i)
			continue
		}

		ms := float64(elapsed.Microseconds()) / 1000.0
		durations = append(durations, ms)
	}

	require.NotEmpty(t, durations, "at least one FS write iteration should succeed")

	stats := computePercentiles(durations)
	t.Logf("")
	t.Logf("=== TC-905: FS Write Latency (write 1KB file x %d) ===", iterations)
	t.Logf("  Succeeded  : %d / %d", len(durations), iterations)
	t.Logf("  P50        : %.2f ms", stats.P50)
	t.Logf("  P95        : %.2f ms", stats.P95)
	t.Logf("  P99        : %.2f ms", stats.P99)
	t.Logf("  Min        : %.2f ms", stats.Min)
	t.Logf("  Max        : %.2f ms", stats.Max)
	t.Logf("  Avg        : %.2f ms", stats.Avg)
	t.Logf("  Targets    : p50 < 10 ms, p99 < 100 ms")
	t.Logf("  P50 result : %s", passOrFail(stats.P50 < 10))
	t.Logf("  P99 result : %s", passOrFail(stats.P99 < 100))
}

// ---------------------------------------------------------------------------
// TC-906: Concurrent Sandbox Creation
// ---------------------------------------------------------------------------

func TestBenchmarkConcurrentCreate(t *testing.T) {
	// TC-906: Create N sandboxes in parallel (N=5,10,20,50).
	// Report success count and total time. Target: 50+ on metal.
	skipIfOrchestratorUnavailable(t)
	conn := dialOrchestrator(t)
	client := orchestrator.NewSandboxServiceClient(conn)

	concurrencyLevels := []int{5, 10, 20, 50}

	type concResult struct {
		N         int
		Succeeded int
		Failed    int
		Duration  time.Duration
	}

	allResults := make([]concResult, 0, len(concurrencyLevels))

	for _, n := range concurrencyLevels {
		t.Logf("--- concurrent creation: N=%d ---", n)

		var (
			wg       sync.WaitGroup
			mu       sync.Mutex
			created  []string
			failures int
		)

		start := time.Now()

		for i := 0; i < n; i++ {
			wg.Add(1)
			go func(idx int) {
				defer wg.Done()

				sandboxID := genSandboxID(fmt.Sprintf("bconc%dx%d", n, idx))

				ctx, cancel := context.WithTimeout(context.Background(), createTimeout)
				defer cancel()

				now := timestamppb.Now()
				endTime := timestamppb.New(now.AsTime().Add(5 * time.Minute))

				_, err := client.Create(ctx, &orchestrator.SandboxCreateRequest{
					Sandbox: &orchestrator.SandboxConfig{
						TemplateId:         templateID(),
						BuildId:            buildID(),
						KernelVersion:      kernelVersion(),
						FirecrackerVersion: firecrackerVersion(),
						SandboxId:          sandboxID,
						Vcpu:               1,
						RamMb:              256,
						TeamId:             "bench-team",
						MaxSandboxLength:   1,
						TotalDiskSizeMb:    512,
					},
					StartTime: now,
					EndTime:   endTime,
				})

				mu.Lock()
				defer mu.Unlock()
				if err != nil {
					failures++
					t.Logf("  N=%d idx=%d FAILED: %v", n, idx, err)
				} else {
					created = append(created, sandboxID)
				}
			}(i)
		}

		wg.Wait()
		elapsed := time.Since(start)

		cr := concResult{
			N:         n,
			Succeeded: len(created),
			Failed:    failures,
			Duration:  elapsed,
		}
		allResults = append(allResults, cr)

		t.Logf("  N=%d: %d/%d succeeded in %v", n, cr.Succeeded, n, elapsed)

		// Cleanup this batch before moving to next concurrency level.
		var cleanupWg sync.WaitGroup
		for _, id := range created {
			cleanupWg.Add(1)
			go func(sandboxID string) {
				defer cleanupWg.Done()
				benchDeleteSandbox(t, client, sandboxID)
			}(id)
		}
		cleanupWg.Wait()

		// Brief pause between levels.
		time.Sleep(2 * time.Second)
	}

	t.Logf("")
	t.Logf("=== TC-906: Concurrent Sandbox Creation ===")
	t.Logf("  %-6s  %-10s  %-10s  %-12s", "N", "Succeeded", "Failed", "Duration")
	t.Logf("  %-6s  %-10s  %-10s  %-12s", "------", "----------", "----------", "------------")
	for _, cr := range allResults {
		t.Logf("  %-6d  %-10d  %-10d  %-12v", cr.N, cr.Succeeded, cr.Failed, cr.Duration.Round(time.Millisecond))
	}
	t.Logf("  Target     : 50+ sandboxes on bare metal")
}

// ---------------------------------------------------------------------------
// TC-907: Memory Overhead per Sandbox
// ---------------------------------------------------------------------------

func TestBenchmarkMemoryOverhead(t *testing.T) {
	// TC-907: Create 10 sandboxes (256MB each), measure host memory.
	// Report per-sandbox overhead. Target: < 10MB overhead.
	skipIfOrchestratorUnavailable(t)
	conn := dialOrchestrator(t)
	client := orchestrator.NewSandboxServiceClient(conn)

	// Read host available memory before creating sandboxes.
	memBefore := readMemAvailableKB(t)
	if memBefore == 0 {
		t.Skip("cannot read /proc/meminfo on this host — memory benchmark skipped")
	}
	t.Logf("  MemAvailable before: %d KB (%.1f MB)", memBefore, float64(memBefore)/1024.0)

	const numSandboxes = 10
	var sandboxIDs []string

	for i := 0; i < numSandboxes; i++ {
		sandboxID := genSandboxID(fmt.Sprintf("bmem%d", i))
		benchCreateSandbox(t, client, sandboxID)
		sandboxIDs = append(sandboxIDs, sandboxID)
	}

	// Wait for all sandboxes to fully boot.
	time.Sleep(5 * time.Second)

	// Read host available memory after creation.
	memAfter := readMemAvailableKB(t)
	t.Logf("  MemAvailable after:  %d KB (%.1f MB)", memAfter, float64(memAfter)/1024.0)

	// Cleanup sandboxes.
	t.Cleanup(func() {
		for _, id := range sandboxIDs {
			benchDeleteSandbox(t, client, id)
		}
	})

	// Calculate overhead.
	// Expected memory per sandbox = 256MB. Total expected = 256 * 10 = 2560 MB.
	// Actual memory consumed = memBefore - memAfter (in KB).
	consumedKB := int64(0)
	if memBefore > memAfter {
		consumedKB = memBefore - memAfter
	}
	consumedMB := float64(consumedKB) / 1024.0
	expectedMB := float64(numSandboxes) * 256.0
	overheadMB := consumedMB - expectedMB
	perSandboxOverheadMB := overheadMB / float64(numSandboxes)

	t.Logf("")
	t.Logf("=== TC-907: Memory Overhead per Sandbox ===")
	t.Logf("  Sandboxes      : %d (256 MB each)", numSandboxes)
	t.Logf("  Expected total : %.0f MB", expectedMB)
	t.Logf("  Actual consumed: %.1f MB", consumedMB)
	t.Logf("  Total overhead : %.1f MB", overheadMB)
	t.Logf("  Per-sandbox    : %.1f MB", perSandboxOverheadMB)
	t.Logf("  Target         : < 10 MB per sandbox")
	t.Logf("  Result         : %s", passOrFail(perSandboxOverheadMB < 10))
}

// readMemAvailableKB reads MemAvailable from /proc/meminfo and returns it in KB.
func readMemAvailableKB(t *testing.T) int64 {
	t.Helper()

	data, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		t.Logf("warning: could not read /proc/meminfo: %v (memory benchmark will be approximate)", err)
		return 0
	}

	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "MemAvailable:") {
			var value int64
			_, scanErr := fmt.Sscanf(line, "MemAvailable: %d kB", &value)
			if scanErr == nil {
				return value
			}
		}
	}

	t.Logf("warning: MemAvailable not found in /proc/meminfo")
	return 0
}

// ---------------------------------------------------------------------------
// TC-908: Template Build Time
// ---------------------------------------------------------------------------

func TestBenchmarkTemplateBuild(t *testing.T) {
	// TC-908: Time a full template build (cold boot from base template).
	// Since the orchestrator gRPC API does not have a dedicated template build
	// RPC, we measure the time to create a sandbox from scratch (which triggers
	// the full rootfs + snapshot pipeline on first use of a template).
	// Target: < 5 minutes.
	skipIfOrchestratorUnavailable(t)
	conn := dialOrchestrator(t)
	client := orchestrator.NewSandboxServiceClient(conn)

	sandboxID := genSandboxID("btmpl")

	start := time.Now()

	// Create sandbox — this exercises the full template pipeline for a cold boot.
	benchCreateSandbox(t, client, sandboxID)

	// Wait for envd to become ready by polling exec.
	var execOK bool
	for attempt := 0; attempt < 60; attempt++ {
		result := execInSandbox(t, sandboxID, "echo", []string{"template-ready"})
		if result != nil && strings.Contains(result.Stdout, "template-ready") {
			execOK = true
			break
		}
		time.Sleep(1 * time.Second)
	}

	elapsed := time.Since(start)

	// Cleanup.
	t.Cleanup(func() {
		benchDeleteSandbox(t, client, sandboxID)
	})

	require.True(t, execOK, "template build sandbox should become ready")

	t.Logf("")
	t.Logf("=== TC-908: Template Build Time ===")
	t.Logf("  Template   : %s (build %s)", templateID(), buildID())
	t.Logf("  Duration   : %v", elapsed.Round(time.Millisecond))
	t.Logf("  Target     : < 5 min")
	t.Logf("  Result     : %s", passOrFail(elapsed < 5*time.Minute))
}

// ---------------------------------------------------------------------------
// TestBenchmarkReport: Aggregate summary
// ---------------------------------------------------------------------------

func TestBenchmarkReport(t *testing.T) {
	// This test runs all individual benchmarks and prints a combined summary.
	// It uses t.Run subtests so each benchmark is independently reportable.
	skipIfOrchestratorUnavailable(t)
	conn := dialOrchestrator(t)
	client := orchestrator.NewSandboxServiceClient(conn)

	type benchResult struct {
		Name   string
		Status string
		Detail string
	}

	var (
		mu      sync.Mutex
		results []benchResult
	)

	addResult := func(name, status, detail string) {
		mu.Lock()
		defer mu.Unlock()
		results = append(results, benchResult{
			Name:   name,
			Status: status,
			Detail: detail,
		})
	}

	// --- TC-901: Cold Boot ---
	t.Run("ColdBoot", func(t *testing.T) {
		const iterations = 10
		durations := make([]float64, 0, iterations)
		var sandboxIDs []string

		for i := 0; i < iterations; i++ {
			sandboxID := genSandboxID(fmt.Sprintf("rpcold%d", i))
			sandboxIDs = append(sandboxIDs, sandboxID)

			start := time.Now()
			benchCreateSandbox(t, client, sandboxID)

			var execOK bool
			for attempt := 0; attempt < 30; attempt++ {
				result := execInSandbox(t, sandboxID, "echo", []string{"ready"})
				if result != nil && strings.Contains(result.Stdout, "ready") {
					execOK = true
					break
				}
				time.Sleep(200 * time.Millisecond)
			}
			elapsed := time.Since(start)
			if execOK {
				durations = append(durations, float64(elapsed.Milliseconds()))
			}
		}

		t.Cleanup(func() {
			for _, id := range sandboxIDs {
				benchDeleteSandbox(t, client, id)
			}
		})

		if len(durations) > 0 {
			stats := computePercentiles(durations)
			status := "PASS"
			if stats.Avg >= 2000 {
				status = "FAIL"
			}
			addResult("TC-901 Cold Boot", status,
				fmt.Sprintf("avg=%.0fms min=%.0fms max=%.0fms (%d/%d)", stats.Avg, stats.Min, stats.Max, len(durations), iterations))
		} else {
			addResult("TC-901 Cold Boot", "FAIL", "no successful iterations")
		}
	})

	// --- TC-902: Snapshot Restore (SKIPPED) ---
	t.Run("SnapshotRestore", func(t *testing.T) {
		addResult("TC-902 Snapshot Restore", "SKIP", "PauseResume broken")
		t.Skip("TC-902: skipped — PauseResume is still broken")
	})

	// --- TC-903: Exec Latency ---
	t.Run("ExecLatency", func(t *testing.T) {
		sandboxID := genSandboxID("rpexec")
		createSandbox(t, client, sandboxID)
		time.Sleep(3 * time.Second)
		_ = execInSandbox(t, sandboxID, "echo", []string{"warmup"})

		const iterations = 100
		durations := make([]float64, 0, iterations)
		for i := 0; i < iterations; i++ {
			start := time.Now()
			result := execInSandbox(t, sandboxID, "echo", []string{"hello"})
			elapsed := time.Since(start)
			if result != nil && strings.Contains(result.Stdout, "hello") {
				durations = append(durations, float64(elapsed.Microseconds())/1000.0)
			}
		}

		if len(durations) > 0 {
			stats := computePercentiles(durations)
			status := "PASS"
			if stats.P50 >= 20 || stats.P99 >= 100 {
				status = "FAIL"
			}
			addResult("TC-903 Exec Latency", status,
				fmt.Sprintf("p50=%.1fms p95=%.1fms p99=%.1fms", stats.P50, stats.P95, stats.P99))
		} else {
			addResult("TC-903 Exec Latency", "FAIL", "no successful iterations")
		}
	})

	// --- TC-904: FS Read Latency ---
	t.Run("FSReadLatency", func(t *testing.T) {
		sandboxID := genSandboxID("rpfsrd")
		createSandbox(t, client, sandboxID)
		time.Sleep(3 * time.Second)

		writeResult := execInSandbox(t, sandboxID, "sh", []string{
			"-c", "head -c 1024 /dev/urandom | base64 | head -c 1024 > /tmp/bench_read.txt && echo OK",
		})
		require.Contains(t, writeResult.Stdout, "OK")

		const iterations = 100
		durations := make([]float64, 0, iterations)
		for i := 0; i < iterations; i++ {
			start := time.Now()
			result := execInSandbox(t, sandboxID, "cat", []string{"/tmp/bench_read.txt"})
			elapsed := time.Since(start)
			if result != nil && result.ExitCode == 0 {
				durations = append(durations, float64(elapsed.Microseconds())/1000.0)
			}
		}

		if len(durations) > 0 {
			stats := computePercentiles(durations)
			status := "PASS"
			if stats.P50 >= 5 || stats.P99 >= 50 {
				status = "FAIL"
			}
			addResult("TC-904 FS Read", status,
				fmt.Sprintf("p50=%.1fms p95=%.1fms p99=%.1fms", stats.P50, stats.P95, stats.P99))
		} else {
			addResult("TC-904 FS Read", "FAIL", "no successful iterations")
		}
	})

	// --- TC-905: FS Write Latency ---
	t.Run("FSWriteLatency", func(t *testing.T) {
		sandboxID := genSandboxID("rpfswr")
		createSandbox(t, client, sandboxID)
		time.Sleep(3 * time.Second)

		const iterations = 100
		durations := make([]float64, 0, iterations)
		for i := 0; i < iterations; i++ {
			cmd := fmt.Sprintf("printf '%%01024d' 0 > /tmp/bench_write_%d.txt && echo OK", i)
			start := time.Now()
			result := execInSandbox(t, sandboxID, "sh", []string{"-c", cmd})
			elapsed := time.Since(start)
			if result != nil && strings.Contains(result.Stdout, "OK") {
				durations = append(durations, float64(elapsed.Microseconds())/1000.0)
			}
		}

		if len(durations) > 0 {
			stats := computePercentiles(durations)
			status := "PASS"
			if stats.P50 >= 10 || stats.P99 >= 100 {
				status = "FAIL"
			}
			addResult("TC-905 FS Write", status,
				fmt.Sprintf("p50=%.1fms p95=%.1fms p99=%.1fms", stats.P50, stats.P95, stats.P99))
		} else {
			addResult("TC-905 FS Write", "FAIL", "no successful iterations")
		}
	})

	// --- TC-906: Concurrent Create ---
	t.Run("ConcurrentCreate", func(t *testing.T) {
		concurrencyLevels := []int{5, 10, 20, 50}
		var details []string

		for _, n := range concurrencyLevels {
			var (
				wg       sync.WaitGroup
				mu2      sync.Mutex
				created  []string
				failures int
			)

			start := time.Now()
			for i := 0; i < n; i++ {
				wg.Add(1)
				go func(idx int) {
					defer wg.Done()
					sandboxID := genSandboxID(fmt.Sprintf("rpcc%dx%d", n, idx))

					ctx, cancel := context.WithTimeout(context.Background(), createTimeout)
					defer cancel()

					now := timestamppb.Now()
					endTime := timestamppb.New(now.AsTime().Add(5 * time.Minute))

					_, err := client.Create(ctx, &orchestrator.SandboxCreateRequest{
						Sandbox: &orchestrator.SandboxConfig{
							TemplateId:         templateID(),
							BuildId:            buildID(),
							KernelVersion:      kernelVersion(),
							FirecrackerVersion: firecrackerVersion(),
							SandboxId:          sandboxID,
							Vcpu:               1,
							RamMb:              256,
							TeamId:             "bench-team",
							MaxSandboxLength:   1,
							TotalDiskSizeMb:    512,
						},
						StartTime: now,
						EndTime:   endTime,
					})

					mu2.Lock()
					defer mu2.Unlock()
					if err != nil {
						failures++
					} else {
						created = append(created, sandboxID)
					}
				}(i)
			}
			wg.Wait()
			elapsed := time.Since(start)

			details = append(details, fmt.Sprintf("N=%d:%d/%d in %v", n, len(created), n, elapsed.Round(time.Millisecond)))

			// Cleanup.
			var cleanupWg sync.WaitGroup
			for _, id := range created {
				cleanupWg.Add(1)
				go func(sid string) {
					defer cleanupWg.Done()
					benchDeleteSandbox(t, client, sid)
				}(id)
			}
			cleanupWg.Wait()
			time.Sleep(2 * time.Second)
		}

		addResult("TC-906 Concurrent", "INFO", strings.Join(details, "; "))
	})

	// --- TC-907: Memory Overhead ---
	t.Run("MemoryOverhead", func(t *testing.T) {
		memBefore := readMemAvailableKB(t)
		if memBefore == 0 {
			addResult("TC-907 Memory", "SKIP", "/proc/meminfo not available")
			t.Skip("cannot read /proc/meminfo on this host")
		}

		const numSandboxes = 10
		var sandboxIDs []string
		for i := 0; i < numSandboxes; i++ {
			sandboxID := genSandboxID(fmt.Sprintf("rpmem%d", i))
			benchCreateSandbox(t, client, sandboxID)
			sandboxIDs = append(sandboxIDs, sandboxID)
		}
		time.Sleep(5 * time.Second)

		memAfter := readMemAvailableKB(t)

		t.Cleanup(func() {
			for _, id := range sandboxIDs {
				benchDeleteSandbox(t, client, id)
			}
		})

		consumedKB := int64(0)
		if memBefore > memAfter {
			consumedKB = memBefore - memAfter
		}
		consumedMB := float64(consumedKB) / 1024.0
		expectedMB := float64(numSandboxes) * 256.0
		overheadMB := consumedMB - expectedMB
		perSandbox := overheadMB / float64(numSandboxes)

		status := "PASS"
		if perSandbox >= 10 {
			status = "FAIL"
		}
		addResult("TC-907 Memory", status,
			fmt.Sprintf("%.1fMB/sandbox overhead (consumed=%.0fMB expected=%.0fMB)", perSandbox, consumedMB, expectedMB))
	})

	// --- TC-908: Template Build ---
	t.Run("TemplateBuild", func(t *testing.T) {
		sandboxID := genSandboxID("rptmpl")
		start := time.Now()
		benchCreateSandbox(t, client, sandboxID)

		var execOK bool
		for attempt := 0; attempt < 60; attempt++ {
			result := execInSandbox(t, sandboxID, "echo", []string{"template-ready"})
			if result != nil && strings.Contains(result.Stdout, "template-ready") {
				execOK = true
				break
			}
			time.Sleep(1 * time.Second)
		}
		elapsed := time.Since(start)

		t.Cleanup(func() {
			benchDeleteSandbox(t, client, sandboxID)
		})

		if execOK {
			status := "PASS"
			if elapsed >= 5*time.Minute {
				status = "FAIL"
			}
			addResult("TC-908 Template Build", status,
				fmt.Sprintf("%v", elapsed.Round(time.Millisecond)))
		} else {
			addResult("TC-908 Template Build", "FAIL", "sandbox never became ready")
		}
	})

	// --- Print summary table ---
	t.Logf("")
	t.Logf("===========================================================================")
	t.Logf("  PERFORMANCE BENCHMARK SUMMARY")
	t.Logf("===========================================================================")
	t.Logf("  %-28s  %-6s  %s", "Benchmark", "Status", "Details")
	t.Logf("  %-28s  %-6s  %s", "----------------------------", "------", "-------")
	for _, r := range results {
		t.Logf("  %-28s  %-6s  %s", r.Name, r.Status, r.Detail)
	}
	t.Logf("===========================================================================")
}

// ---------------------------------------------------------------------------
// TC-909: Node Capacity — Max Concurrent Sandboxes
// ---------------------------------------------------------------------------

func TestBenchmarkNodeCapacity(t *testing.T) {
	// TC-909: Ramp up sandbox count until creation starts failing.
	// Creates sandboxes in batches, verifying each is functional (exec "echo ok").
	// Reports the maximum number of healthy concurrent sandboxes the node can run.
	//
	// Strategy: start at batchSize, keep adding batches until:
	//   - A creation fails, or
	//   - An exec health check fails, or
	//   - We hit the hard ceiling
	//
	// Uses 1 vCPU / 128MB per sandbox to maximize density.
	skipIfOrchestratorUnavailable(t)
	conn := dialOrchestrator(t)
	client := orchestrator.NewSandboxServiceClient(conn)

	const (
		batchSize  = 10
		maxTotal   = 200 // hard ceiling — don't try more than this
		ramMB      = 128
		vcpu       = 1
	)

	var (
		liveSandboxes []string
		totalCreated  int
		totalFailed   int
		firstFailAt   int
		hitLimit      bool
	)

	memBefore := readMemAvailableKB(t)

	// Cleanup everything at the end.
	t.Cleanup(func() {
		t.Logf("  Cleaning up %d sandboxes...", len(liveSandboxes))
		var wg sync.WaitGroup
		for _, id := range liveSandboxes {
			wg.Add(1)
			go func(sid string) {
				defer wg.Done()
				benchDeleteSandbox(t, client, sid)
			}(id)
		}
		wg.Wait()
		t.Logf("  Cleanup done.")
	})

	for batch := 0; !hitLimit && totalCreated < maxTotal; batch++ {
		remaining := maxTotal - totalCreated
		n := batchSize
		if n > remaining {
			n = remaining
		}

		t.Logf("--- Batch %d: creating %d sandboxes (total so far: %d) ---", batch, n, totalCreated)

		var (
			wg       sync.WaitGroup
			mu       sync.Mutex
			created  []string
			failures int
		)

		start := time.Now()

		for i := 0; i < n; i++ {
			wg.Add(1)
			go func(idx int) {
				defer wg.Done()
				sandboxID := genSandboxID(fmt.Sprintf("bcap%dx%d", batch, idx))

				ctx, cancel := context.WithTimeout(context.Background(), createTimeout)
				defer cancel()

				now := timestamppb.Now()
				endTime := timestamppb.New(now.AsTime().Add(10 * time.Minute))

				_, err := client.Create(ctx, &orchestrator.SandboxCreateRequest{
					Sandbox: &orchestrator.SandboxConfig{
						TemplateId:         templateID(),
						BuildId:            buildID(),
						KernelVersion:      kernelVersion(),
						FirecrackerVersion: firecrackerVersion(),
						SandboxId:          sandboxID,
						Vcpu:               int64(vcpu),
						RamMb:              int64(ramMB),
						TeamId:             "bench-team",
						MaxSandboxLength:   1,
						TotalDiskSizeMb:    512,
					},
					StartTime: now,
					EndTime:   endTime,
				})

				mu.Lock()
				defer mu.Unlock()
				if err != nil {
					failures++
					t.Logf("  sandbox %s FAILED: %v", sandboxID, err)
				} else {
					created = append(created, sandboxID)
				}
			}(i)
		}
		wg.Wait()
		elapsed := time.Since(start)

		totalCreated += len(created)
		totalFailed += failures
		liveSandboxes = append(liveSandboxes, created...)

		t.Logf("  Batch %d: %d/%d created in %v (total live: %d)", batch, len(created), n, elapsed.Round(time.Millisecond), len(liveSandboxes))

		if failures > 0 && firstFailAt == 0 {
			firstFailAt = totalCreated
			hitLimit = true
			break
		}

		// Health check: exec in a sample of live sandboxes (first, last, middle).
		sampleIdxs := []int{0}
		if len(liveSandboxes) > 1 {
			sampleIdxs = append(sampleIdxs, len(liveSandboxes)-1)
		}
		if len(liveSandboxes) > 2 {
			sampleIdxs = append(sampleIdxs, len(liveSandboxes)/2)
		}

		healthFailed := 0
		for _, idx := range sampleIdxs {
			result := execInSandbox(t, liveSandboxes[idx], "echo", []string{"ok"})
			if result == nil || !strings.Contains(result.Stdout, "ok") {
				healthFailed++
				t.Logf("  HEALTH CHECK FAILED for sandbox %s (index %d)", liveSandboxes[idx], idx)
			}
		}
		if healthFailed > 0 {
			t.Logf("  %d/%d health checks failed at %d sandboxes — stopping ramp", healthFailed, len(sampleIdxs), len(liveSandboxes))
			hitLimit = true
			break
		}

		// Brief pause to let the system settle.
		time.Sleep(1 * time.Second)
	}

	memAfter := readMemAvailableKB(t)

	// Report.
	consumedMB := float64(memBefore-memAfter) / 1024.0
	if memAfter > memBefore {
		consumedMB = 0
	}
	perSandboxMB := float64(0)
	if len(liveSandboxes) > 0 {
		perSandboxMB = consumedMB / float64(len(liveSandboxes))
	}

	t.Logf("")
	t.Logf("===========================================================================")
	t.Logf("  TC-909: NODE CAPACITY TEST")
	t.Logf("===========================================================================")
	t.Logf("  Config         : %d vCPU / %d MB RAM per sandbox", vcpu, ramMB)
	t.Logf("  Max live       : %d sandboxes", len(liveSandboxes))
	t.Logf("  Total created  : %d", totalCreated)
	t.Logf("  Total failed   : %d", totalFailed)
	if firstFailAt > 0 {
		t.Logf("  First fail at  : %d sandboxes", firstFailAt)
	}
	if hitLimit {
		t.Logf("  Limit reached  : YES")
	} else {
		t.Logf("  Limit reached  : NO (hit ceiling of %d)", maxTotal)
	}
	t.Logf("  Memory before  : %.0f MB", float64(memBefore)/1024.0)
	t.Logf("  Memory after   : %.0f MB", float64(memAfter)/1024.0)
	t.Logf("  Memory used    : %.0f MB total, %.1f MB/sandbox", consumedMB, perSandboxMB)
	t.Logf("===========================================================================")
}

// ---------------------------------------------------------------------------
// TC-910: Concurrent Workload Stress Test
// ---------------------------------------------------------------------------

// TestBenchmarkConcurrentWorkload creates sandboxes in batches and runs a real
// Python workload in ALL of them concurrently: fetch Google News, parse headlines,
// save to a file. This tests real CPU + network I/O + disk I/O under load.
//
// The test ramps up until failures occur or the ceiling is hit.
func TestBenchmarkConcurrentWorkload(t *testing.T) {
	skipIfOrchestratorUnavailable(t)
	conn := dialOrchestrator(t)
	client := orchestrator.NewSandboxServiceClient(conn)

	const (
		batchSize     = 10
		maxTotal      = 200
		ramMB         = 256 // need more RAM for Python + network I/O
		vcpu          = 1
		workTimeout   = 60 * time.Second
		createTimeout = 30 * time.Second
	)

	// Python script that fetches Google News, parses headlines, saves to file.
	pythonScript := `
import urllib.request
import html.parser
import json
import time

class HeadlineParser(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self.in_article = False
        self.headlines = []
        self.current = ""
    def handle_starttag(self, tag, attrs):
        if tag == 'article':
            self.in_article = True
        if tag == 'a' and self.in_article:
            self.current = ""
    def handle_data(self, data):
        if self.in_article:
            self.current += data.strip()
    def handle_endtag(self, tag):
        if tag == 'article':
            self.in_article = False
            if self.current:
                self.headlines.append(self.current[:120])
                self.current = ""

start = time.time()
try:
    req = urllib.request.Request(
        'https://news.google.com/rss',
        headers={'User-Agent': 'Mozilla/5.0'}
    )
    resp = urllib.request.urlopen(req, timeout=15)
    data = resp.read().decode('utf-8', errors='replace')
    # Parse RSS titles
    titles = []
    import xml.etree.ElementTree as ET
    root = ET.fromstring(data)
    for item in root.iter('item'):
        title = item.find('title')
        if title is not None and title.text:
            titles.append(title.text[:120])
    elapsed = time.time() - start
    result = {
        'status': 'ok',
        'headlines': len(titles),
        'sample': titles[:5],
        'elapsed_s': round(elapsed, 2)
    }
except Exception as e:
    elapsed = time.time() - start
    result = {
        'status': 'error',
        'error': str(e)[:200],
        'elapsed_s': round(elapsed, 2)
    }

# Save to file
with open('/tmp/news_result.json', 'w') as f:
    json.dump(result, f)

# Print result for stdout capture
print(json.dumps(result))
`

	type workloadResult struct {
		SandboxID string
		Stdout    string
		Success   bool
		Duration  time.Duration
	}

	var (
		liveSandboxes []string
		totalCreated  int
		totalFailed   int
		hitLimit      bool
	)

	memBefore := readMemAvailableKB(t)

	t.Cleanup(func() {
		t.Logf("  Cleaning up %d sandboxes...", len(liveSandboxes))
		var wg sync.WaitGroup
		for _, id := range liveSandboxes {
			wg.Add(1)
			go func(sid string) {
				defer wg.Done()
				benchDeleteSandbox(t, client, sid)
			}(id)
		}
		wg.Wait()
		t.Logf("  Cleanup done.")
	})

	var allWorkloadResults []workloadResult

	for batch := 0; !hitLimit && totalCreated < maxTotal; batch++ {
		remaining := maxTotal - totalCreated
		n := batchSize
		if n > remaining {
			n = remaining
		}

		t.Logf("--- Batch %d: creating %d sandboxes (total so far: %d) ---", batch, n, totalCreated)

		// Create sandboxes concurrently.
		var (
			wg       sync.WaitGroup
			mu       sync.Mutex
			created  []string
			failures int
		)

		start := time.Now()
		for i := 0; i < n; i++ {
			wg.Add(1)
			go func(idx int) {
				defer wg.Done()
				sandboxID := genSandboxID(fmt.Sprintf("bwrk%dx%d", batch, idx))

				ctx, cancel := context.WithTimeout(context.Background(), createTimeout)
				defer cancel()

				now := timestamppb.Now()
				endTime := timestamppb.New(now.AsTime().Add(15 * time.Minute))

				_, err := client.Create(ctx, &orchestrator.SandboxCreateRequest{
					Sandbox: &orchestrator.SandboxConfig{
						TemplateId:         templateID(),
						BuildId:            buildID(),
						KernelVersion:      kernelVersion(),
						FirecrackerVersion: firecrackerVersion(),
						SandboxId:          sandboxID,
						Vcpu:               int64(vcpu),
						RamMb:              int64(ramMB),
						TeamId:             "bench-team",
						MaxSandboxLength:   1,
						TotalDiskSizeMb:    512,
					},
					StartTime: now,
					EndTime:   endTime,
				})

				mu.Lock()
				defer mu.Unlock()
				if err != nil {
					failures++
					t.Logf("  create %s FAILED: %v", sandboxID, err)
				} else {
					created = append(created, sandboxID)
				}
			}(i)
		}
		wg.Wait()
		createElapsed := time.Since(start)

		totalCreated += len(created)
		totalFailed += failures
		liveSandboxes = append(liveSandboxes, created...)

		t.Logf("  Batch %d: %d/%d created in %v (total live: %d)",
			batch, len(created), n, createElapsed.Round(time.Millisecond), len(liveSandboxes))

		if failures > 0 {
			hitLimit = true
			break
		}

		// Now run the Python workload in ALL live sandboxes concurrently.
		t.Logf("  Running workload in ALL %d sandboxes concurrently...", len(liveSandboxes))
		workStart := time.Now()

		var workWg sync.WaitGroup
		batchResults := make([]workloadResult, len(liveSandboxes))

		for i, sid := range liveSandboxes {
			workWg.Add(1)
			go func(idx int, sandboxID string) {
				defer workWg.Done()
				wStart := time.Now()

				result := execInSandbox(t, sandboxID, "python3", []string{"-c", pythonScript})

				wr := workloadResult{
					SandboxID: sandboxID,
					Duration:  time.Since(wStart),
				}
				if result != nil && strings.Contains(result.Stdout, `"status": "ok"`) {
					wr.Success = true
					wr.Stdout = result.Stdout
				} else if result != nil {
					wr.Stdout = result.Stdout
					if result.Stderr != "" {
						wr.Stdout += " STDERR:" + result.Stderr
					}
				}
				batchResults[idx] = wr
			}(i, sid)
		}
		workWg.Wait()
		workElapsed := time.Since(workStart)

		// Count successes/failures.
		successes := 0
		var durations []float64
		for _, wr := range batchResults {
			if wr.Success {
				successes++
				durations = append(durations, wr.Duration.Seconds())
			}
		}

		// Show sample failures.
		failCount := len(liveSandboxes) - successes
		if failCount > 0 {
			shown := 0
			for _, wr := range batchResults {
				if !wr.Success && shown < 3 {
					t.Logf("    FAILED %s: %s", wr.SandboxID, wr.Stdout[:min(len(wr.Stdout), 200)])
					shown++
				}
			}
		}

		sort.Float64s(durations)
		p50, p95, p99 := float64(0), float64(0), float64(0)
		if len(durations) > 0 {
			p50 = durations[len(durations)*50/100]
			p95 = durations[len(durations)*95/100]
			if len(durations) > 1 {
				p99 = durations[len(durations)*99/100]
			} else {
				p99 = durations[len(durations)-1]
			}
		}

		t.Logf("  Workload: %d/%d succeeded in %v (p50=%.1fs p95=%.1fs p99=%.1fs)",
			successes, len(liveSandboxes), workElapsed.Round(time.Millisecond), p50, p95, p99)

		allWorkloadResults = append(allWorkloadResults, batchResults...)

		// If more than 20% fail, stop.
		if failCount > len(liveSandboxes)/5 {
			t.Logf("  >20%% failures — stopping ramp")
			hitLimit = true
			break
		}

		time.Sleep(2 * time.Second)
	}

	memAfter := readMemAvailableKB(t)

	// Final report.
	totalSuccess := 0
	for _, wr := range allWorkloadResults {
		if wr.Success {
			totalSuccess++
		}
	}

	consumedMB := float64(memBefore-memAfter) / 1024.0
	if memAfter > memBefore {
		consumedMB = 0
	}
	perSandboxMB := float64(0)
	if len(liveSandboxes) > 0 {
		perSandboxMB = consumedMB / float64(len(liveSandboxes))
	}

	t.Logf("")
	t.Logf("===========================================================================")
	t.Logf("  TC-910: CONCURRENT WORKLOAD STRESS TEST")
	t.Logf("===========================================================================")
	t.Logf("  Workload       : Python fetch Google News RSS + parse + save")
	t.Logf("  Config         : %d vCPU / %d MB RAM per sandbox", vcpu, ramMB)
	t.Logf("  Max live       : %d sandboxes", len(liveSandboxes))
	t.Logf("  Total created  : %d", totalCreated)
	t.Logf("  Create failed  : %d", totalFailed)
	t.Logf("  Workload OK    : %d", totalSuccess)
	if hitLimit {
		t.Logf("  Limit reached  : YES")
	} else {
		t.Logf("  Limit reached  : NO (hit ceiling of %d)", maxTotal)
	}
	t.Logf("  Memory before  : %.0f MB", float64(memBefore)/1024.0)
	t.Logf("  Memory after   : %.0f MB", float64(memAfter)/1024.0)
	t.Logf("  Memory used    : %.0f MB total, %.1f MB/sandbox", consumedMB, perSandboxMB)
	t.Logf("===========================================================================")
}

// min returns the smaller of two ints.
func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// ---------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------

// passOrFail returns a human-readable pass/fail string.
func passOrFail(ok bool) string {
	if ok {
		return "PASS"
	}
	return "FAIL"
}