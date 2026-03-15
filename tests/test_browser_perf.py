"""
E2B Browser Automation Performance Test

Tests Playwright browser automation inside E2B sandboxes:
- Browser install + launch time
- Page load and interaction latency
- Screenshot capture
- Concurrent browser sandboxes
"""
import os
import time
import json
import statistics
import concurrent.futures
from dataclasses import dataclass, asdict
from typing import List

# Set E2B_API_KEY env var before running (sudo cat /opt/e2b/api-key)
assert os.environ.get('E2B_API_KEY'), "E2B_API_KEY not set"

from e2b import Sandbox

API_URL = 'http://localhost:80'
SANDBOX_URL = 'http://localhost:5007'
TEMPLATE = 'base-template'
TIMEOUT = 600

BROWSER_SETUP_SCRIPT = """
set -e
# Install browser deps
sudo apt-get update -qq 2>/dev/null
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
    libdbus-1-3 libxkbcommon0 libatspi2.0-0 libxcomposite1 libxdamage1 \
    libxfixes3 libxrandr2 libgbm1 libpango-1.0-0 libcairo2 libasound2 \
    libwayland-client0 fonts-liberation xvfb 2>/dev/null
# Install Playwright
pip3 install playwright 2>/dev/null
python3 -m playwright install chromium 2>/dev/null
echo "BROWSER_SETUP_DONE"
"""

BROWSER_TEST_SCRIPT = """
import time, json, sys

results = {}

try:
    from playwright.sync_api import sync_playwright

    t0 = time.monotonic()
    with sync_playwright() as p:
        # Launch browser
        t_launch = time.monotonic()
        browser = p.chromium.launch(
            headless=True,
            args=['--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage',
                  '--single-process', '--disable-software-rasterizer']
        )
        results['browser_launch_ms'] = (time.monotonic() - t_launch) * 1000

        # Create page
        t_page = time.monotonic()
        page = browser.new_page()
        results['new_page_ms'] = (time.monotonic() - t_page) * 1000

        # Set content and extract text
        t_content = time.monotonic()
        page.set_content('<html><body><h1 id="title">Hello E2B</h1><p id="msg">Performance Test</p></body></html>')
        title = page.evaluate('document.querySelector("#title").textContent')
        msg = page.evaluate('document.querySelector("#msg").textContent')
        results['set_content_ms'] = (time.monotonic() - t_content) * 1000
        results['title'] = title
        results['msg'] = msg

        # Navigate to data URL
        t_nav = time.monotonic()
        page.goto('data:text/html,<h1>Navigation Test</h1>')
        nav_text = page.evaluate('document.querySelector("h1").textContent')
        results['navigate_ms'] = (time.monotonic() - t_nav) * 1000
        results['nav_text'] = nav_text

        # Screenshot
        t_screenshot = time.monotonic()
        page.screenshot(path='/tmp/screenshot.png')
        results['screenshot_ms'] = (time.monotonic() - t_screenshot) * 1000

        # JavaScript execution
        t_js = time.monotonic()
        js_result = page.evaluate('() => { let sum = 0; for(let i=0; i<1000000; i++) sum += i; return sum; }')
        results['js_exec_ms'] = (time.monotonic() - t_js) * 1000
        results['js_result'] = js_result

        results['total_ms'] = (time.monotonic() - t0) * 1000
        results['success'] = True

        browser.close()
except Exception as e:
    results['success'] = False
    results['error'] = str(e)

print(json.dumps(results))
"""


@dataclass
class BrowserResult:
    sandbox_id: str = ''
    create_time_ms: float = 0
    setup_time_ms: float = 0
    browser_launch_ms: float = 0
    new_page_ms: float = 0
    set_content_ms: float = 0
    navigate_ms: float = 0
    screenshot_ms: float = 0
    js_exec_ms: float = 0
    total_browser_ms: float = 0
    kill_time_ms: float = 0
    success: bool = False
    error: str = ''


def run_browser_test(index: int, skip_setup: bool = False) -> BrowserResult:
    """Create a sandbox, install Playwright, run browser tests."""
    result = BrowserResult()
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

        if not skip_setup:
            # Install browser dependencies
            t0 = time.monotonic()
            cmd = sandbox.commands.run(BROWSER_SETUP_SCRIPT, timeout=300)
            result.setup_time_ms = (time.monotonic() - t0) * 1000
            if 'BROWSER_SETUP_DONE' not in cmd.stdout:
                result.error = f'Setup failed: {cmd.stderr[:200]}'
                return result

        # Write test script
        sandbox.files.write('/tmp/browser_test.py', BROWSER_TEST_SCRIPT)

        # Run browser test
        t0 = time.monotonic()
        cmd = sandbox.commands.run('python3 /tmp/browser_test.py', timeout=120)
        total_test_ms = (time.monotonic() - t0) * 1000

        # Parse results
        try:
            browser_results = json.loads(cmd.stdout.strip().split('\n')[-1])
            if browser_results.get('success'):
                result.browser_launch_ms = browser_results.get('browser_launch_ms', 0)
                result.new_page_ms = browser_results.get('new_page_ms', 0)
                result.set_content_ms = browser_results.get('set_content_ms', 0)
                result.navigate_ms = browser_results.get('navigate_ms', 0)
                result.screenshot_ms = browser_results.get('screenshot_ms', 0)
                result.js_exec_ms = browser_results.get('js_exec_ms', 0)
                result.total_browser_ms = browser_results.get('total_ms', total_test_ms)
                result.success = True
            else:
                result.error = browser_results.get('error', 'unknown error')
        except (json.JSONDecodeError, IndexError) as e:
            result.error = f'Parse error: {e}; stdout: {cmd.stdout[:200]}'

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
    avg = statistics.mean(values)
    mn = min(values)
    mx = max(values)
    print(f'  {label}: avg={avg:.0f}ms  p50={p50:.0f}ms  p95={p95:.0f}ms  min={mn:.0f}ms  max={mx:.0f}ms')


def run_test(concurrency: int, total: int):
    print(f'\n{"="*60}')
    print(f' Browser Automation Performance Test')
    print(f' Concurrency: {concurrency}  Total: {total}')
    print(f'{"="*60}')

    results: List[BrowserResult] = []
    start_time = time.monotonic()

    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as executor:
        futures = {executor.submit(run_browser_test, i): i for i in range(total)}
        completed = 0
        for future in concurrent.futures.as_completed(futures):
            completed += 1
            result = future.result()
            results.append(result)
            status = 'OK' if result.success else f'FAIL: {result.error[:60]}'
            print(f'  [{completed}/{total}] {result.sandbox_id[:12]}... {status} '
                  f'(create={result.create_time_ms:.0f}ms setup={result.setup_time_ms:.0f}ms '
                  f'browser={result.total_browser_ms:.0f}ms)')

    total_time = time.monotonic() - start_time
    successes = [r for r in results if r.success]
    failures = [r for r in results if not r.success]

    print(f'\n--- Results ---')
    print(f'  Total time: {total_time:.1f}s')
    print(f'  Success: {len(successes)}/{total} ({len(successes)/total*100:.1f}%)')
    print(f'  Failures: {len(failures)}')

    if successes:
        print(f'\n--- Latency (successful runs) ---')
        print_stats('Sandbox create', [r.create_time_ms for r in successes])
        print_stats('Browser setup (apt+pip+install)', [r.setup_time_ms for r in successes])
        print_stats('Browser launch', [r.browser_launch_ms for r in successes])
        print_stats('New page', [r.new_page_ms for r in successes])
        print_stats('Set content + evaluate', [r.set_content_ms for r in successes])
        print_stats('Navigate (data URL)', [r.navigate_ms for r in successes])
        print_stats('Screenshot', [r.screenshot_ms for r in successes])
        print_stats('JS execution (1M loop)', [r.js_exec_ms for r in successes])
        print_stats('Total browser test', [r.total_browser_ms for r in successes])
        print_stats('Kill sandbox', [r.kill_time_ms for r in successes])

    if failures:
        print(f'\n--- Failure Details ---')
        error_counts = {}
        for r in failures:
            key = r.error[:100]
            error_counts[key] = error_counts.get(key, 0) + 1
        for err, count in sorted(error_counts.items(), key=lambda x: -x[1]):
            print(f'  [{count}x] {err}')

    results_file = f'/tmp/browser_perf_{concurrency}c_{total}t.json'
    with open(results_file, 'w') as f:
        json.dump([asdict(r) for r in results], f, indent=2)
    print(f'\n  Raw results: {results_file}')

    return results


if __name__ == '__main__':
    import sys
    concurrency = int(sys.argv[1]) if len(sys.argv) > 1 else 2
    total = int(sys.argv[2]) if len(sys.argv) > 2 else 3

    run_test(concurrency, total)
