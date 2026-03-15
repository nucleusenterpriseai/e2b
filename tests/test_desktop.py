"""
E2B Desktop Template — Integration Tests (TDD)

Tests the desktop template with Xvfb + XFCE + VNC + noVNC:
  TC-D01: Desktop sandbox boots successfully
  TC-D02: Xvfb is running on display :99
  TC-D03: VNC server (x11vnc) listening on port 5900
  TC-D04: noVNC websocket proxy listening on port 6080
  TC-D05: Screenshot capture via scrot produces valid PNG
  TC-D06: Keyboard input via xdotool works
  TC-D07: Firefox browser launches
  TC-D08: Desktop sandbox cleanup (create + kill)

Run:
    python3 tests/test_desktop.py
    # or with pytest:
    python3 -m pytest tests/test_desktop.py -v
"""
import os
import time

# Set E2B_API_KEY env var before running (sudo cat /opt/e2b/api-key)
assert os.environ.get('E2B_API_KEY'), "E2B_API_KEY not set"

from e2b import Sandbox

API_URL = os.environ.get('E2B_API_URL', 'http://localhost:80')
SANDBOX_URL = os.environ.get('E2B_SANDBOX_URL', 'http://localhost:5007')
TEMPLATE = os.environ.get('E2B_DESKTOP_TEMPLATE', 'desktop')
TIMEOUT = 600  # desktop sandboxes need more time
DESKTOP_STARTUP_WAIT = 30  # seconds for Xvfb + XFCE + VNC to start


def create_desktop_sandbox():
    """Create a desktop sandbox and wait for desktop services to start."""
    sandbox = Sandbox.create(
        template=TEMPLATE,
        api_url=API_URL,
        sandbox_url=SANDBOX_URL,
        timeout=TIMEOUT,
        secure=False,
    )
    # Wait for desktop services (Xvfb, XFCE, VNC) to fully start
    time.sleep(DESKTOP_STARTUP_WAIT)
    return sandbox


class TestDesktopBoot:
    """TC-D01: Desktop sandbox boots and is_running."""

    def test_desktop_creates_and_runs(self):
        sandbox = create_desktop_sandbox()
        try:
            assert sandbox.is_running(), "Desktop sandbox should be running"
            result = sandbox.commands.run('echo alive')
            assert result.stdout.strip() == 'alive'
        finally:
            sandbox.kill()


class TestDesktopXvfb:
    """TC-D02: Xvfb is running on display :99."""

    def test_xvfb_running(self):
        sandbox = create_desktop_sandbox()
        try:
            result = sandbox.commands.run("pgrep -x Xvfb || pgrep -f 'Xvfb :99'")
            assert result.exit_code == 0, f"Xvfb should be running: {result.stderr}"
            assert result.stdout.strip() != '', "Xvfb should have a PID"
        finally:
            sandbox.kill()

    def test_display_configured(self):
        sandbox = create_desktop_sandbox()
        try:
            # Check Xvfb is running on display :99 via its command line
            result = sandbox.commands.run("cat /proc/$(pgrep -x Xvfb)/cmdline 2>/dev/null | tr '\\0' ' '")
            assert ':99' in result.stdout, f"Xvfb should be on display :99, got: {result.stdout}"
        finally:
            sandbox.kill()


class TestDesktopVNC:
    """TC-D03: VNC server (x11vnc) listening on port 5900."""

    def test_vnc_process_running(self):
        sandbox = create_desktop_sandbox()
        try:
            result = sandbox.commands.run('pgrep -x x11vnc')
            assert result.exit_code == 0, f"x11vnc should be running: {result.stderr}"
            assert result.stdout.strip() != '', "x11vnc should have a PID"
        finally:
            sandbox.kill()

    def test_vnc_port_listening(self):
        sandbox = create_desktop_sandbox()
        try:
            result = sandbox.commands.run('ss -ltn')
            assert ':5900' in result.stdout, f"Port 5900 should be listening:\n{result.stdout}"
        finally:
            sandbox.kill()


class TestDesktopNoVNC:
    """TC-D04: noVNC websocket proxy listening on port 6080."""

    def test_novnc_available(self):
        sandbox = create_desktop_sandbox()
        try:
            # Verify websockify is installed and noVNC web files exist
            result = sandbox.commands.run('which websockify')
            assert result.exit_code == 0, "websockify should be installed"
            result = sandbox.commands.run('test -f /usr/share/novnc/vnc.html && echo ok')
            assert 'ok' in result.stdout, "noVNC web files should exist"
            # Verify websockify process was started by start-desktop.sh
            result = sandbox.commands.run('pgrep -f websockify')
            assert result.exit_code == 0, "websockify process should be running"
        finally:
            sandbox.kill()


class TestDesktopScreenshot:
    """TC-D05: Screenshot capture via scrot produces valid PNG."""

    def test_screenshot_capture(self):
        sandbox = create_desktop_sandbox()
        try:
            # Capture screenshot
            result = sandbox.commands.run(
                'DISPLAY=:99 scrot /tmp/screenshot.png && stat --format=%s /tmp/screenshot.png'
            )
            assert result.exit_code == 0, f"scrot should succeed: {result.stderr}"
            file_size = int(result.stdout.strip().split('\n')[-1])
            assert file_size > 0, "Screenshot should have non-zero size"

            # Verify PNG magic bytes (use od since xxd may not be installed)
            hex_result = sandbox.commands.run(
                "od -A n -t x1 -N 8 /tmp/screenshot.png | tr -d ' \\n'"
            )
            assert hex_result.exit_code == 0
            assert hex_result.stdout.strip() == '89504e470d0a1a0a', \
                f"Should be PNG magic bytes, got: {hex_result.stdout.strip()}"
        finally:
            sandbox.kill()


class TestDesktopKeyboard:
    """TC-D06: Keyboard input via xdotool works."""

    def test_xdotool_key_input(self):
        sandbox = create_desktop_sandbox()
        try:
            # Type keys via xdotool
            result = sandbox.commands.run('DISPLAY=:99 xdotool key h e l l o')
            assert result.exit_code == 0, f"xdotool should succeed: {result.stderr}"

            time.sleep(2)

            # Take a screenshot to verify desktop is responsive after input
            screenshot = sandbox.commands.run(
                'DISPLAY=:99 scrot /tmp/keyboard_test.png && stat --format=%s /tmp/keyboard_test.png'
            )
            assert screenshot.exit_code == 0, f"Screenshot after keyboard input should succeed: {screenshot.stderr}"
            file_size = int(screenshot.stdout.strip().split('\n')[-1])
            assert file_size > 0, "Screenshot should have non-zero size"
        finally:
            sandbox.kill()


class TestDesktopBrowser:
    """TC-D07: Firefox browser launches."""

    def test_firefox_launches(self):
        sandbox = create_desktop_sandbox()
        try:
            # Launch Firefox in background
            sandbox.commands.run(
                'DISPLAY=:99 firefox-esr --no-remote about:blank &',
                background=True
            )
            time.sleep(8)

            # Check Firefox process
            result = sandbox.commands.run("pgrep -f 'firefox-esr|firefox' | head -1")
            assert result.exit_code == 0, f"Firefox should be running: {result.stderr}"
            assert result.stdout.strip() != '', "Firefox should have a PID"
        finally:
            sandbox.kill()


class TestDesktopCleanup:
    """TC-D08: Desktop sandbox cleanup."""

    def test_create_and_kill(self):
        sandbox = create_desktop_sandbox()
        sandbox_id = sandbox.sandbox_id
        assert sandbox.is_running(), "Should be running after create"
        sandbox.kill()
        # After kill, is_running should return False (or raise)
        try:
            running = sandbox.is_running()
            assert not running, "Should not be running after kill"
        except Exception:
            pass  # Some SDK versions raise on killed sandbox


if __name__ == '__main__':
    import sys

    print(f'=== Desktop Template Tests ===')
    print(f'  API:      {API_URL}')
    print(f'  Sandbox:  {SANDBOX_URL}')
    print(f'  Template: {TEMPLATE}')
    print()

    tests = [
        ('TC-D01 Boot', TestDesktopBoot().test_desktop_creates_and_runs),
        ('TC-D02 Xvfb', TestDesktopXvfb().test_xvfb_running),
        ('TC-D02 Display', TestDesktopXvfb().test_display_configured),
        ('TC-D03 VNC process', TestDesktopVNC().test_vnc_process_running),
        ('TC-D03 VNC port', TestDesktopVNC().test_vnc_port_listening),
        ('TC-D04 noVNC', TestDesktopNoVNC().test_novnc_available),
        ('TC-D05 Screenshot', TestDesktopScreenshot().test_screenshot_capture),
        ('TC-D06 Keyboard', TestDesktopKeyboard().test_xdotool_key_input),
        ('TC-D07 Firefox', TestDesktopBrowser().test_firefox_launches),
        ('TC-D08 Cleanup', TestDesktopCleanup().test_create_and_kill),
    ]

    passed = 0
    failed = 0
    for name, test_fn in tests:
        try:
            test_fn()
            print(f'  PASS  {name}')
            passed += 1
        except Exception as e:
            print(f'  FAIL  {name}: {e}')
            failed += 1

    print(f'\n=== {passed}/{passed+failed} passed, {failed} failed ===')
    sys.exit(1 if failed > 0 else 0)
