"""
E2B Concurrent Sandbox Performance Test

Tests creating and running multiple sandboxes concurrently to measure:
- Sandbox creation time (snapshot restore)
- Process execution latency
- File I/O latency
- Maximum concurrent sandbox capacity
- Resource utilization under load
"""
import os
import time
import json
import statistics
import concurrent.futures
from dataclasses import dataclass, field, asdict
from typing import List, Optional

# Set E2B_API_KEY env var before running (sudo cat /opt/e2b/api-key)
assert os.environ.get('E2B_API_KEY'), "E2B_API_KEY not set"

from e2b import Sandbox

API_URL = 'http://localhost:80'
SANDBOX_URL = 'http://localhost:5007'
TEMPLATE = 'base-template'
TIMEOUT = 600  # 10 min per sandbox

@dataclass
class SandboxResult:
    sandbox_id: str = ''
    create_time_ms: float = 0
    exec_time_ms: float = 0
    file_write_time_ms: float = 0
    file_read_time_ms: float = 0
    kill_time_ms: float = 0
    success: bool = False
    error: str = ''

def run_sandbox_test(index: int) -> SandboxResult:
    """Create a sandbox, run operations, and measure timings."""
    result = SandboxResult()
    sandbox = None
    try:
        # Create sandbox
        t0 = time.monotonic()
        sandbox = Sandbox.create(
            template=TEMPLATE,
            api_url=API_URL,
            sandbox_url=SANDBOX_URL,
            timeout=TIMEOUT,
            secure=False,
        )
        result.sandbox_id = sandbox.sandbox_id
        result.create_time_ms = (time.monotonic() - t0) * 1000

        # Execute command
        t0 = time.monotonic()
        cmd_result = sandbox.commands.run('echo hello')
        result.exec_time_ms = (time.monotonic() - t0) * 1000
        assert cmd_result.stdout.strip() == 'hello'

        # Write file
        t0 = time.monotonic()
        sandbox.files.write(f'/tmp/test_{index}.txt', f'test data {index}')
        result.file_write_time_ms = (time.monotonic() - t0) * 1000

        # Read file
        t0 = time.monotonic()
        content = sandbox.files.read(f'/tmp/test_{index}.txt')
        result.file_read_time_ms = (time.monotonic() - t0) * 1000
        assert content == f'test data {index}'

        result.success = True
    except Exception as e:
        result.error = str(e)
    finally:
        if sandbox:
            try:
                t0 = time.monotonic()
                sandbox.kill()
                result.kill_time_ms = (time.monotonic() - t0) * 1000
            except Exception:
                pass

    return result

def print_stats(label: str, values: List[float]):
    if not values:
        print(f'  {label}: no data')
        return
    p50 = statistics.median(values)
    p95 = sorted(values)[int(len(values) * 0.95)] if len(values) > 1 else values[0]
    p99 = sorted(values)[int(len(values) * 0.99)] if len(values) > 1 else values[0]
    avg = statistics.mean(values)
    mn = min(values)
    mx = max(values)
    print(f'  {label}: avg={avg:.0f}ms  p50={p50:.0f}ms  p95={p95:.0f}ms  p99={p99:.0f}ms  min={mn:.0f}ms  max={mx:.0f}ms')

def run_test(concurrency: int, total: int):
    print(f'\n{"="*60}')
    print(f' Concurrent Sandbox Performance Test')
    print(f' Concurrency: {concurrency}  Total: {total}')
    print(f'{"="*60}')

    results: List[SandboxResult] = []
    start_time = time.monotonic()

    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as executor:
        futures = {executor.submit(run_sandbox_test, i): i for i in range(total)}
        completed = 0
        for future in concurrent.futures.as_completed(futures):
            completed += 1
            result = future.result()
            results.append(result)
            status = 'OK' if result.success else f'FAIL: {result.error[:60]}'
            if completed % 10 == 0 or not result.success:
                print(f'  [{completed}/{total}] {result.sandbox_id[:12]}... {status} (create={result.create_time_ms:.0f}ms)')

    total_time = time.monotonic() - start_time
    successes = [r for r in results if r.success]
    failures = [r for r in results if not r.success]

    print(f'\n--- Results ---')
    print(f'  Total time: {total_time:.1f}s')
    print(f'  Success: {len(successes)}/{total} ({len(successes)/total*100:.1f}%)')
    print(f'  Failures: {len(failures)}')
    print(f'  Throughput: {total/total_time:.1f} sandboxes/sec')

    if successes:
        print(f'\n--- Latency (successful runs) ---')
        print_stats('Create (snapshot restore)', [r.create_time_ms for r in successes])
        print_stats('Exec (echo hello)', [r.exec_time_ms for r in successes])
        print_stats('File write (1KB)', [r.file_write_time_ms for r in successes])
        print_stats('File read (1KB)', [r.file_read_time_ms for r in successes])
        print_stats('Kill', [r.kill_time_ms for r in successes])

    if failures:
        print(f'\n--- Failure Details ---')
        error_counts = {}
        for r in failures:
            key = r.error[:100]
            error_counts[key] = error_counts.get(key, 0) + 1
        for err, count in sorted(error_counts.items(), key=lambda x: -x[1]):
            print(f'  [{count}x] {err}')

    # Write raw results to file
    results_file = f'/tmp/perf_results_{concurrency}c_{total}t.json'
    with open(results_file, 'w') as f:
        json.dump([asdict(r) for r in results], f, indent=2)
    print(f'\n  Raw results: {results_file}')

    return results

if __name__ == '__main__':
    import sys
    concurrency = int(sys.argv[1]) if len(sys.argv) > 1 else 10
    total = int(sys.argv[2]) if len(sys.argv) > 2 else 20

    run_test(concurrency, total)
