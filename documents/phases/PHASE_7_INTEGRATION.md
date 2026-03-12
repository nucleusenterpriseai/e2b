# Phase 7: Integration Testing & Desktop

**Duration**: 5 days
**Depends on**: All previous phases
**Status**: Not Started

---

## Objective

Run full end-to-end tests across all templates, verify desktop/VNC workflows, run performance benchmarks, validate security isolation, and adapt the upstream test suite.

## PRD (Phase 7)

### What We're Delivering
- All 4 templates working end-to-end (base, code-interpreter, desktop, browser-use)
- Adapted upstream integration test suite passing
- Performance benchmarks documented
- Security isolation validated
- Operations runbook for common tasks

### Success Criteria
- SDK creates sandboxes from all templates
- Desktop VNC accessible, screenshot/mouse/keyboard work
- 10+ concurrent sandboxes without degradation
- Snapshot restore < 200ms (p95)
- VM-to-VM isolation verified
- All P0 tests from TEST_CASES.md passing

## Dev Plan

### 7.1 Adapt Upstream Integration Tests (Day 1-2, 8 hours)

The upstream has 47 integration test files at `infra/tests/integration/`. Steps:

1. **Inventory existing tests**:
```bash
find infra/tests/integration -name "*_test.go" | wc -l
```

2. **Set env vars for our deployment**:
```bash
export TESTS_API_SERVER_URL=https://api.e2b.example.com
export TESTS_E2B_API_KEY=<our-key>
export TESTS_ORCHESTRATOR_HOST=<orchestrator-ip>:5008
```

3. **Run and triage**:
```bash
cd infra/tests/integration
go test ./... -v -count=1 2>&1 | tee test-results.txt
```

4. **Fix failing tests**:
   - Supabase auth tests -> skip or adapt for API key auth
   - ClickHouse tests -> skip (no ClickHouse deployed)
   - GCS tests -> verify S3 path works
   - Keep all sandbox, process, filesystem, template tests

### 7.2 Desktop Template Testing (Day 2-3, 8 hours)

```python
from e2b import Sandbox
import time

# Create desktop sandbox
desktop = Sandbox.create("desktop", timeout=300)

# Wait for desktop to initialize
time.sleep(10)

# Test 1: VNC accessible
vnc_url = f"https://{desktop.get_host(6080)}"
print(f"VNC URL: {vnc_url}")
# Verify accessible via browser

# Test 2: Screenshot
screenshot = desktop.screenshot()
assert len(screenshot) > 1000  # Valid PNG, not empty
with open("screenshot.png", "wb") as f:
    f.write(screenshot)

# Test 3: Mouse + keyboard
desktop.mouse_move(500, 400)
desktop.click()
time.sleep(1)
desktop.type_text("hello world")
time.sleep(1)
screenshot2 = desktop.screenshot()

# Test 4: Launch browser
result = desktop.commands.run("firefox --no-remote about:blank &")
time.sleep(5)
screenshot3 = desktop.screenshot()

desktop.kill()
```

### 7.3 Performance Benchmarks (Day 3, 4 hours)

```python
import time
import statistics

# Benchmark 1: Snapshot restore time
times = []
for i in range(10):
    start = time.time()
    sb = Sandbox.create("base", timeout=30)
    elapsed = time.time() - start
    times.append(elapsed)
    sb.kill()

print(f"Snapshot restore: p50={statistics.median(times):.3f}s, "
      f"p95={sorted(times)[8]:.3f}s, "
      f"p99={sorted(times)[9]:.3f}s")

# Benchmark 2: Process exec latency
sb = Sandbox.create("base", timeout=120)
exec_times = []
for i in range(100):
    start = time.time()
    sb.commands.run("echo hello")
    exec_times.append(time.time() - start)
sb.kill()

print(f"Exec latency: p50={statistics.median(exec_times)*1000:.1f}ms, "
      f"p95={sorted(exec_times)[94]*1000:.1f}ms")

# Benchmark 3: Filesystem latency
sb = Sandbox.create("base", timeout=120)
write_times = []
read_times = []
for i in range(100):
    start = time.time()
    sb.files.write(f"/tmp/bench-{i}.txt", f"data-{i}" * 100)
    write_times.append(time.time() - start)

    start = time.time()
    sb.files.read(f"/tmp/bench-{i}.txt")
    read_times.append(time.time() - start)
sb.kill()

print(f"Write: p50={statistics.median(write_times)*1000:.1f}ms")
print(f"Read: p50={statistics.median(read_times)*1000:.1f}ms")

# Benchmark 4: Concurrent sandboxes
import concurrent.futures

def create_and_use(i):
    sb = Sandbox.create("base", timeout=60)
    sb.commands.run(f"echo sandbox-{i}")
    sb.kill()
    return True

start = time.time()
with concurrent.futures.ThreadPoolExecutor(max_workers=10) as ex:
    results = list(ex.map(create_and_use, range(10)))
print(f"10 concurrent sandboxes: {time.time()-start:.1f}s")
```

### 7.4 Security Validation (Day 4, 4 hours)

```python
# Test 1: VM-to-VM isolation
sb_a = Sandbox.create("base", timeout=60)
sb_b = Sandbox.create("base", timeout=60)

# Get IPs (from sandbox metadata or exec)
ip_a = sb_a.commands.run("hostname -I").stdout.strip()
ip_b = sb_b.commands.run("hostname -I").stdout.strip()

# Try to reach B from A
result = sb_a.commands.run(f"ping -c 1 -W 2 {ip_b}")
assert result.exit_code != 0  # Should fail

result = sb_a.commands.run(f"curl -s --max-time 2 http://{ip_b}:49983/")
assert result.exit_code != 0  # Should fail

sb_a.kill()
sb_b.kill()

# Test 2: Cannot reach host services
sb = Sandbox.create("base", timeout=60)
# Try Nomad API
result = sb.commands.run("curl -s --max-time 2 http://172.16.0.1:4646/v1/agent/self")
assert result.exit_code != 0 or "error" in result.stdout.lower()

# Try Consul API
result = sb.commands.run("curl -s --max-time 2 http://172.16.0.1:8500/v1/agent/self")
assert result.exit_code != 0 or "error" in result.stdout.lower()
sb.kill()

# Test 3: Auth rejection
# Attempt gRPC call without token
import grpc
# ... connect to envd without Bearer token -> UNAUTHENTICATED

# Test 4: Internet blocking
sb = Sandbox.create("base", timeout=60, allow_internet=False)
result = sb.commands.run("curl -s --max-time 5 https://httpbin.org/ip")
assert result.exit_code != 0  # Should timeout/fail
sb.kill()
```

### 7.5 Operations Runbook (Day 4-5, 4 hours)

Document common operations:
- How to SSH to bastion -> server/client/api nodes
- How to check Nomad job status and logs
- How to view Consul service health
- How to run database migrations
- How to deploy a new version of a service
- How to build and deploy a new template
- How to scale client nodes (ASG adjustment)
- How to restart a stuck service
- How to check ALB target health
- How to access RDS via bastion tunnel
- Troubleshooting: sandbox creation failures, network issues

### 7.6 Stress Testing (Day 5, 4 hours)

```python
# Stress test: max concurrent sandboxes
import concurrent.futures
import time

max_sandboxes = 0
sandboxes = []

try:
    for i in range(100):
        sb = Sandbox.create("base", timeout=60)
        sandboxes.append(sb)
        max_sandboxes = i + 1
        print(f"Created sandbox {i+1}")

        # Quick health check
        result = sb.commands.run("echo ok")
        if "ok" not in result.stdout:
            print(f"DEGRADED at sandbox {i+1}")
            break
except Exception as e:
    print(f"FAILED at sandbox {max_sandboxes}: {e}")
finally:
    print(f"Max concurrent: {max_sandboxes}")
    for sb in sandboxes:
        try:
            sb.kill()
        except:
            pass
```

## Test Cases (Phase 7)

### P0 (Must Pass)

| ID | Test | Expected |
|---|---|---|
| I7-01 | Base template: create -> exec -> delete | Works |
| I7-02 | Code-interpreter: `import numpy` | Works |
| I7-03 | Desktop: VNC accessible | noVNC loads |
| I7-04 | 10 concurrent sandboxes | All succeed |
| I7-05 | VM-to-VM isolation | Cannot reach other VMs |
| I7-06 | Auth rejection (no token) | UNAUTHENTICATED |
| I7-07 | Snapshot restore p95 < 500ms | Benchmark passes |
| I7-08 | Upstream integration tests (adapted) | 80%+ passing |

### P1 (Should Pass)

| ID | Test | Expected |
|---|---|---|
| I7-09 | Desktop screenshot | Valid PNG |
| I7-10 | Desktop mouse/keyboard | Input reflected in screenshot |
| I7-11 | Browser-use template | Headless Chrome works |
| I7-12 | Process exec p50 < 50ms | Benchmark passes |
| I7-13 | Filesystem p50 < 10ms | Benchmark passes |
| I7-14 | Internet blocked when disabled | No outbound |
| I7-15 | Cannot reach host Nomad/Consul | Firewall blocks |
| I7-16 | 50+ concurrent sandboxes | No degradation |
| I7-17 | Sandbox auto-timeout cleanup | Sandbox destroyed after timeout |
| I7-18 | Snapshot state preserved | File written before pause readable after resume |

## Deliverables
- [ ] Upstream test suite adapted and passing
- [ ] All 4 templates working end-to-end
- [ ] Desktop VNC workflow verified
- [ ] Performance benchmark results documented
- [ ] Security isolation validated
- [ ] Stress test results (max concurrent sandboxes)
- [ ] Operations runbook
- [ ] Final test report
