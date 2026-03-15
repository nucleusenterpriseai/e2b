"""
E2B Concurrent Desktop Test — 60 sandboxes, each opens Firefox + takes screenshot.

Tests real computer-use workload:
  1. Create 60 desktop sandboxes concurrently
  2. Each sandbox: launch Firefox, navigate to a URL, take screenshot
  3. Verify screenshot is valid PNG with non-trivial size
  4. Kill all sandboxes

Run:
    E2B_API_KEY=<key> python3 tests/test_concurrent_desktop.py [--count 60]
"""
import os
import sys
import time
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed

if 'E2B_API_KEY' not in os.environ:
    print("E2B_API_KEY not set. Get it from: sudo cat /opt/e2b/api-key")
    sys.exit(1)

from e2b import Sandbox

API_URL = os.environ.get('E2B_API_URL', 'http://localhost:80')
SANDBOX_URL = os.environ.get('E2B_SANDBOX_URL', 'http://localhost:5007')
TEMPLATE = os.environ.get('E2B_DESKTOP_TEMPLATE', 'desktop')
TIMEOUT = 600
DESKTOP_STARTUP_WAIT = 30
BROWSER_WAIT = 10


def run_browser_test(task_id):
    """Single test task: create sandbox, open browser, screenshot, verify, cleanup."""
    t0 = time.time()
    sandbox = None
    try:
        # Create sandbox
        sandbox = Sandbox.create(
            template=TEMPLATE,
            api_url=API_URL,
            sandbox_url=SANDBOX_URL,
            timeout=TIMEOUT,
            secure=False,
        )
        t_create = time.time() - t0

        # Wait for desktop services
        time.sleep(DESKTOP_STARTUP_WAIT)

        # Launch Firefox to a test page
        sandbox.commands.run(
            'DISPLAY=:99 firefox-esr --no-remote "data:text/html,<h1>E2B Test %d</h1><p>Sandbox: %s</p>" &'
            % (task_id, sandbox.sandbox_id),
            background=True,
        )
        time.sleep(BROWSER_WAIT)

        # Verify Firefox is running
        result = sandbox.commands.run("pgrep -f 'firefox-esr|firefox' | head -1")
        if result.exit_code != 0 or not result.stdout.strip():
            return task_id, 'FAIL', 'Firefox not running', time.time() - t0

        # Take screenshot
        result = sandbox.commands.run(
            'DISPLAY=:99 scrot /tmp/screenshot.png && stat --format=%s /tmp/screenshot.png'
        )
        if result.exit_code != 0:
            return task_id, 'FAIL', f'Screenshot failed: {result.stderr}', time.time() - t0

        file_size = int(result.stdout.strip().split('\n')[-1])
        if file_size < 1000:
            return task_id, 'FAIL', f'Screenshot too small: {file_size} bytes', time.time() - t0

        # Verify PNG magic bytes
        hex_result = sandbox.commands.run(
            "od -A n -t x1 -N 4 /tmp/screenshot.png | tr -d ' \\n'"
        )
        if '89504e47' not in hex_result.stdout.strip():
            return task_id, 'FAIL', f'Not PNG: {hex_result.stdout.strip()}', time.time() - t0

        t_total = time.time() - t0
        return task_id, 'PASS', f'create={t_create:.1f}s screenshot={file_size}B', t_total

    except Exception as e:
        return task_id, 'FAIL', str(e)[:100], time.time() - t0
    finally:
        if sandbox:
            try:
                sandbox.kill()
            except Exception:
                pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--count', type=int, default=60, help='Number of concurrent tests')
    parser.add_argument('--workers', type=int, default=0, help='Max parallel workers (0=count)')
    parser.add_argument('--batch', type=int, default=15, help='Batch size for staggered launch (0=all at once)')
    parser.add_argument('--batch-delay', type=float, default=2.0, help='Seconds between batches')
    args = parser.parse_args()

    count = args.count
    workers = args.workers or count

    print(f'=== Concurrent Desktop Browser Test ===')
    print(f'  Count:    {count} sandboxes')
    print(f'  Workers:  {workers} parallel')
    print(f'  API:      {API_URL}')
    print(f'  Sandbox:  {SANDBOX_URL}')
    print(f'  Template: {TEMPLATE}')
    print()

    batch_size = args.batch or count
    batch_delay = args.batch_delay

    t_start = time.time()
    results = []

    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {}
        for batch_start in range(0, count, batch_size):
            batch_end = min(batch_start + batch_size, count)
            if batch_start > 0:
                print(f'  --- batch delay {batch_delay}s ---')
                time.sleep(batch_delay)
            for i in range(batch_start, batch_end):
                futures[pool.submit(run_browser_test, i)] = i

        for future in as_completed(futures):
            task_id, status, detail, elapsed = future.result()
            results.append((task_id, status, detail, elapsed))
            passed = sum(1 for _, s, _, _ in results if s == 'PASS')
            failed = sum(1 for _, s, _, _ in results if s == 'FAIL')
            print(f'  [{len(results):3d}/{count}] {status}  Task {task_id:3d}  ({elapsed:.1f}s)  {detail}')

    t_total = time.time() - t_start
    passed = sum(1 for _, s, _, _ in results if s == 'PASS')
    failed = sum(1 for _, s, _, _ in results if s == 'FAIL')
    times = [e for _, s, _, e in results if s == 'PASS']

    print()
    print(f'=== Results ===')
    print(f'  Passed:   {passed}/{count}')
    print(f'  Failed:   {failed}/{count}')
    print(f'  Total:    {t_total:.1f}s')
    if times:
        print(f'  Avg time: {sum(times)/len(times):.1f}s')
        print(f'  Min time: {min(times):.1f}s')
        print(f'  Max time: {max(times):.1f}s')
    print(f'  Rate:     {passed/t_total*60:.1f} tests/min')

    sys.exit(0 if failed == 0 else 1)


if __name__ == '__main__':
    main()
