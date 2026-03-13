"""
E2B SDK End-to-End Integration Tests (Phase 5)

These tests validate the full chain:
    SDK -> API Server -> Orchestrator -> Firecracker -> envd

They use the official E2B Python SDK pointed at a self-hosted infrastructure
via environment variables.

Required environment variables
------------------------------
E2B_API_KEY     API key for the self-hosted API (e2b_ prefix)
E2B_DOMAIN      Domain that resolves to the ALB / API server
                 (e.g. "e2b.example.com").
                 The SDK derives:
                     API URL        -> https://api.<E2B_DOMAIN>
                     Sandbox URL    -> https://<port>-<sandbox_id>.<sandbox_domain>

Optional environment variables
------------------------------
E2B_API_URL         Override the full API URL directly
                    (e.g. "https://api.e2b.example.com" or "http://localhost:3000")
E2B_SANDBOX_URL     Override the full envd URL directly
                    (e.g. "http://localhost:49983")
E2B_DEBUG           Set to "true" to use debug mode (localhost endpoints)
E2B_TEMPLATE        Template to use for tests (default: "base")
SANDBOX_TIMEOUT     Sandbox timeout in seconds (default: 120)

Running the tests
-----------------
    # Against self-hosted infrastructure:
    export E2B_API_KEY="e2b_..."
    export E2B_DOMAIN="e2b.example.com"
    pytest tests/test_sdk_e2e.py -v

    # With a specific API URL (e.g., local development):
    export E2B_API_KEY="e2b_..."
    export E2B_API_URL="http://localhost:3000"
    export E2B_SANDBOX_URL="http://localhost:49983"
    pytest tests/test_sdk_e2e.py -v

    # Selective test groups:
    pytest tests/test_sdk_e2e.py -v -k "TestLifecycle"
    pytest tests/test_sdk_e2e.py -v -k "TestCommands"
    pytest tests/test_sdk_e2e.py -v -k "TestFilesystem"
    pytest tests/test_sdk_e2e.py -v -m "not slow"
"""

import os
import sys
import time
import textwrap

import pytest

# ---------------------------------------------------------------------------
# Pre-flight: verify that the minimum configuration is present
# ---------------------------------------------------------------------------

_api_key = os.environ.get("E2B_API_KEY")
_domain = os.environ.get("E2B_DOMAIN")
_api_url = os.environ.get("E2B_API_URL")
_debug = os.environ.get("E2B_DEBUG", "").lower() == "true"

if not _api_key:
    pytest.skip(
        "E2B_API_KEY is not set — skipping SDK e2e tests. "
        "Set E2B_API_KEY and E2B_DOMAIN to run against self-hosted infrastructure.",
        allow_module_level=True,
    )

if not _domain and not _api_url and not _debug:
    pytest.skip(
        "Neither E2B_DOMAIN nor E2B_API_URL nor E2B_DEBUG is set — "
        "cannot determine which API server to target.",
        allow_module_level=True,
    )

# ---------------------------------------------------------------------------
# Imports — deferred until we know the test can actually run
# ---------------------------------------------------------------------------

from e2b import Sandbox, SandboxException, AuthenticationException  # noqa: E402
from e2b.exceptions import TimeoutException  # noqa: E402

try:
    from e2b.exceptions import CommandExitException  # noqa: E402
except ImportError:
    try:
        from e2b.sandbox.commands.command_handle import CommandExitException  # noqa: E402
    except ImportError:
        CommandExitException = None  # older SDK versions

# ---------------------------------------------------------------------------
# Configuration helpers
# ---------------------------------------------------------------------------

TEMPLATE = os.environ.get("E2B_TEMPLATE", "base")
SANDBOX_TIMEOUT = int(os.environ.get("SANDBOX_TIMEOUT", "120"))


def _describe_config() -> str:
    """Return a human-readable summary of the current SDK configuration."""
    lines = [
        f"  E2B_API_KEY   = {_api_key[:10]}...{_api_key[-4:] if len(_api_key) > 14 else '(short)'}",
        f"  E2B_DOMAIN    = {_domain or '(not set)'}",
        f"  E2B_API_URL   = {_api_url or '(derived from domain)'}",
        f"  E2B_DEBUG     = {_debug}",
        f"  template      = {TEMPLATE}",
        f"  timeout       = {SANDBOX_TIMEOUT}s",
    ]
    return "\n".join(lines)


# Print the configuration once at import time so it shows up in pytest output.
print(f"\n[test_sdk_e2e] Configuration:\n{_describe_config()}\n", file=sys.stderr)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(scope="module")
def sandbox():
    """Create a sandbox that is shared across all tests in this module.

    Using module scope avoids repeated create/kill overhead while still
    covering the full lifecycle.  Individual test classes that need their
    own sandbox can create one inline.
    """
    sb = Sandbox.create(TEMPLATE, timeout=SANDBOX_TIMEOUT)
    yield sb
    try:
        sb.kill()
    except Exception:
        pass  # Best-effort cleanup; sandbox may have already timed out.


@pytest.fixture
def fresh_sandbox():
    """Create a fresh sandbox for tests that need isolation."""
    sb = Sandbox.create(TEMPLATE, timeout=SANDBOX_TIMEOUT)
    yield sb
    try:
        sb.kill()
    except Exception:
        pass


# ===================================================================
# Test Group 1: Sandbox Lifecycle (S5-01, S5-04)
# ===================================================================

class TestLifecycle:
    """Tests for sandbox creation, health, and teardown."""

    def test_create_returns_sandbox_id(self, sandbox):
        """S5-01: Sandbox.create returns an object with a sandbox_id."""
        assert sandbox.sandbox_id is not None
        assert len(sandbox.sandbox_id) > 0
        print(f"  sandbox_id = {sandbox.sandbox_id}")

    def test_sandbox_is_running(self, sandbox):
        """The sandbox should report as running immediately after creation."""
        assert sandbox.is_running() is True

    def test_get_info(self, sandbox):
        """get_info returns metadata about the running sandbox."""
        info = sandbox.get_info()
        assert info.sandbox_id == sandbox.sandbox_id
        assert info.template_id == TEMPLATE
        assert info.started_at is not None
        assert info.end_at is not None
        print(f"  template_id = {info.template_id}")
        print(f"  started_at  = {info.started_at}")
        print(f"  end_at      = {info.end_at}")

    def test_create_and_kill(self):
        """S5-04: Sandbox can be created and then killed without error."""
        sb = Sandbox.create(TEMPLATE, timeout=60)
        sid = sb.sandbox_id
        assert sid is not None

        result = sb.kill()
        assert result is True
        print(f"  killed sandbox {sid}")

    def test_kill_returns_false_for_unknown(self):
        """Killing a non-existent sandbox returns False or raises."""
        # The SDK may raise SandboxException for invalid sandbox ID formats
        # or return False for valid-format but non-existent IDs.
        try:
            result = Sandbox.kill("nonexistent-sandbox-id-000000")
            assert result is False
        except SandboxException:
            pass  # acceptable — API rejects invalid sandbox ID format

    def test_set_timeout(self, sandbox):
        """set_timeout updates the sandbox timeout without error."""
        sandbox.set_timeout(SANDBOX_TIMEOUT + 60)
        # Verify the sandbox is still usable after the update.
        assert sandbox.is_running() is True


# ===================================================================
# Test Group 2: Command Execution (S5-02, S5-06, S5-07, S5-08)
# ===================================================================

class TestCommands:
    """Tests for running commands inside the sandbox."""

    def test_echo(self, sandbox):
        """S5-02: echo command returns expected stdout."""
        result = sandbox.commands.run("echo hello")
        assert result.exit_code == 0
        assert "hello" in result.stdout

    def test_exit_code_zero(self, sandbox):
        """Successful command has exit_code 0."""
        result = sandbox.commands.run("true")
        assert result.exit_code == 0

    def test_exit_code_nonzero(self, sandbox):
        """S5-06: Non-zero exit codes are propagated correctly."""
        # The SDK may raise CommandExitException for non-zero exit codes
        # or return the result with the exit code set.
        if CommandExitException is not None:
            try:
                result = sandbox.commands.run("exit 42")
                assert result.exit_code == 42
            except CommandExitException as e:
                assert e.exit_code == 42
        else:
            result = sandbox.commands.run("exit 42")
            assert result.exit_code == 42

    def test_stderr(self, sandbox):
        """stderr is captured separately from stdout."""
        result = sandbox.commands.run("echo err >&2")
        assert "err" in result.stderr

    def test_env_vars(self, sandbox):
        """S5-07: Custom environment variables are passed to the command."""
        result = sandbox.commands.run(
            "echo $MY_VAR",
            envs={"MY_VAR": "test_value_123"},
        )
        assert "test_value_123" in result.stdout

    def test_multiple_env_vars(self, sandbox):
        """Multiple environment variables are all available."""
        result = sandbox.commands.run(
            'echo "$A $B $C"',
            envs={"A": "alpha", "B": "beta", "C": "gamma"},
        )
        assert "alpha beta gamma" in result.stdout

    def test_python_execution(self, sandbox):
        """S5-08: Python 3 is available and can execute code."""
        result = sandbox.commands.run("python3 -c 'print(2 + 2)'")
        assert result.exit_code == 0
        assert "4" in result.stdout

    def test_python_multiline(self, sandbox):
        """Multi-line Python scripts work correctly."""
        script = textwrap.dedent("""\
            import json
            data = {"key": "value", "num": 42}
            print(json.dumps(data, sort_keys=True))
        """)
        result = sandbox.commands.run(f"python3 -c '{script}'")
        assert result.exit_code == 0
        assert '"key": "value"' in result.stdout

    def test_working_directory(self, sandbox):
        """cwd parameter changes the working directory of the command."""
        result = sandbox.commands.run("pwd", cwd="/tmp")
        assert result.exit_code == 0
        assert "/tmp" in result.stdout

    def test_long_output(self, sandbox):
        """Commands that produce large output complete correctly."""
        result = sandbox.commands.run("seq 1 1000")
        assert result.exit_code == 0
        lines = result.stdout.strip().split("\n")
        assert len(lines) == 1000
        assert lines[0] == "1"
        assert lines[-1] == "1000"

    def test_command_timeout(self, sandbox):
        """Commands that exceed their timeout are terminated."""
        # The SDK raises TimeoutException when the command exceeds its timeout.
        # Older SDKs may return a result with non-zero exit code instead.
        try:
            result = sandbox.commands.run("sleep 300", timeout=3)
            assert result.exit_code != 0 or result.error is not None
        except TimeoutException:
            pass  # expected — SDK raises on timeout

    def test_pipe(self, sandbox):
        """Shell pipes work correctly."""
        result = sandbox.commands.run("echo 'hello world' | tr 'a-z' 'A-Z'")
        assert result.exit_code == 0
        assert "HELLO WORLD" in result.stdout

    def test_list_processes(self, sandbox):
        """commands.list() returns a list of running processes."""
        # Start a background process so there is at least one.
        handle = sandbox.commands.run("sleep 30", background=True)
        try:
            processes = sandbox.commands.list()
            assert isinstance(processes, list)
            # There should be at least the sleep process.
            pids = [p.pid for p in processes]
            assert len(pids) > 0
        finally:
            sandbox.commands.kill(handle.pid)


# ===================================================================
# Test Group 3: Filesystem (S5-03, S5-09)
# ===================================================================

class TestFilesystem:
    """Tests for reading, writing, and listing files in the sandbox."""

    def test_write_and_read(self, sandbox):
        """S5-03: write + read roundtrip preserves content."""
        content = "hello from SDK e2e test"
        sandbox.files.write("/tmp/sdk_test.txt", content)

        read_back = sandbox.files.read("/tmp/sdk_test.txt")
        assert read_back == content

    def test_write_and_read_bytes(self, sandbox):
        """Binary data roundtrip works correctly."""
        data = b"\x00\x01\x02\xff\xfe\xfd"
        sandbox.files.write("/tmp/sdk_test_binary.bin", data)

        read_back = sandbox.files.read("/tmp/sdk_test_binary.bin", format="bytes")
        assert bytes(read_back) == data

    def test_write_creates_parent_dirs(self, sandbox):
        """Writing to a nested path creates intermediate directories."""
        path = "/tmp/sdk_deep/nested/dir/file.txt"
        sandbox.files.write(path, "nested content")

        read_back = sandbox.files.read(path)
        assert read_back == "nested content"

    def test_overwrite_file(self, sandbox):
        """Writing to an existing file overwrites its content."""
        path = "/home/user/sdk_overwrite.txt"
        sandbox.files.write(path, "version 1")
        sandbox.files.write(path, "version 2")

        read_back = sandbox.files.read(path)
        assert read_back == "version 2"

    def test_write_large_file(self, sandbox):
        """A moderately large file (100 KB) can be written and read."""
        content = "x" * 100_000
        sandbox.files.write("/tmp/sdk_large.txt", content)

        read_back = sandbox.files.read("/tmp/sdk_large.txt")
        assert len(read_back) == 100_000

    def test_list_directory(self, sandbox):
        """S5-09: Listing a directory returns the expected entries."""
        sandbox.files.write("/tmp/sdk_listdir/a.txt", "a")
        sandbox.files.write("/tmp/sdk_listdir/b.txt", "b")

        entries = sandbox.files.list("/tmp/sdk_listdir")
        names = [e.name for e in entries]
        assert "a.txt" in names
        assert "b.txt" in names

    def test_make_dir(self, sandbox):
        """S5-09: make_dir creates nested directories."""
        created = sandbox.files.make_dir("/tmp/sdk_mkdir/deep/nested")
        assert created is True

        entries = sandbox.files.list("/tmp/sdk_mkdir/deep")
        names = [e.name for e in entries]
        assert "nested" in names

    def test_make_dir_idempotent(self, sandbox):
        """make_dir on an existing directory returns False."""
        sandbox.files.make_dir("/tmp/sdk_mkdir_idem")
        created_again = sandbox.files.make_dir("/tmp/sdk_mkdir_idem")
        assert created_again is False

    def test_exists(self, sandbox):
        """files.exists reports correctly for files and missing paths."""
        sandbox.files.write("/tmp/sdk_exists.txt", "yes")

        assert sandbox.files.exists("/tmp/sdk_exists.txt") is True
        assert sandbox.files.exists("/tmp/sdk_does_not_exist.txt") is False

    def test_file_written_by_command(self, sandbox):
        """A file created by a command is readable via the filesystem API."""
        sandbox.commands.run("echo 'from command' > /tmp/sdk_cmd_file.txt")

        content = sandbox.files.read("/tmp/sdk_cmd_file.txt")
        assert "from command" in content


# ===================================================================
# Test Group 4: Integration — Commands + Filesystem combined
# ===================================================================

class TestIntegration:
    """Cross-cutting tests that exercise multiple SDK features together."""

    def test_python_file_roundtrip(self, sandbox):
        """Write a Python script via filesystem, execute it via commands."""
        script = textwrap.dedent("""\
            import sys
            with open("/tmp/sdk_result.txt", "w") as f:
                f.write("computed: " + str(7 * 6))
            sys.exit(0)
        """)
        sandbox.files.write("/tmp/sdk_script.py", script)

        result = sandbox.commands.run("python3 /tmp/sdk_script.py")
        assert result.exit_code == 0

        output = sandbox.files.read("/tmp/sdk_result.txt")
        assert output == "computed: 42"

    def test_command_reads_written_file(self, sandbox):
        """File written via SDK is visible to shell commands."""
        sandbox.files.write("/tmp/sdk_cat_me.txt", "SDK wrote this")

        result = sandbox.commands.run("cat /tmp/sdk_cat_me.txt")
        assert result.exit_code == 0
        assert "SDK wrote this" in result.stdout

    def test_disk_usage(self, sandbox):
        """df inside the sandbox reports a usable filesystem."""
        result = sandbox.commands.run("df -h /")
        assert result.exit_code == 0
        # Just verify df produces output with a "Filesystem" header.
        assert "Filesystem" in result.stdout or "filesystem" in result.stdout.lower()


# ===================================================================
# Test Group 5: Error Handling (S5-13, S5-14)
# ===================================================================

class TestErrorHandling:
    """Tests for expected error conditions."""

    def test_invalid_api_key(self):
        """S5-13: Using an invalid API key raises AuthenticationException."""
        with pytest.raises((AuthenticationException, SandboxException, Exception)) as exc_info:
            Sandbox.create(
                TEMPLATE,
                timeout=30,
                api_key="e2b_0000000000000000000000000000000000000000",
            )
        # Verify the error message is informative.
        error_msg = str(exc_info.value).lower()
        assert "auth" in error_msg or "401" in error_msg or "key" in error_msg or "unauthorized" in error_msg

    def test_invalid_template(self):
        """S5-14: Creating a sandbox with an unknown template raises an error."""
        with pytest.raises((SandboxException, Exception)):
            Sandbox.create(
                "nonexistent-template-that-does-not-exist-xyz",
                timeout=30,
            )


# ===================================================================
# Test Group 6: Domain and Connectivity (S5-05)
# ===================================================================

class TestConnectivity:
    """Tests that verify SDK configuration and connectivity."""

    def test_domain_is_configured(self):
        """S5-05: E2B_DOMAIN or E2B_API_URL is set."""
        domain = os.environ.get("E2B_DOMAIN")
        api_url = os.environ.get("E2B_API_URL")
        debug = os.environ.get("E2B_DEBUG", "").lower() == "true"
        assert domain or api_url or debug, (
            "At least one of E2B_DOMAIN, E2B_API_URL, or E2B_DEBUG must be set"
        )

    def test_get_host(self, sandbox):
        """get_host returns a non-empty host string for a port."""
        host = sandbox.get_host(8080)
        assert host is not None
        assert len(host) > 0
        print(f"  host for port 8080 = {host}")


# ===================================================================
# Test Group 7: Concurrent sandboxes (S5-10)
# ===================================================================

class TestConcurrency:
    """Tests for running multiple sandboxes in parallel."""

    @pytest.mark.slow
    def test_concurrent_sandboxes(self):
        """S5-10: Multiple sandboxes can operate independently."""
        count = 3
        sandboxes = []
        try:
            for _ in range(count):
                sb = Sandbox.create(TEMPLATE, timeout=SANDBOX_TIMEOUT)
                sandboxes.append(sb)

            assert len(sandboxes) == count

            for i, sb in enumerate(sandboxes):
                marker = f"sandbox-marker-{i}-{sb.sandbox_id[:8]}"
                result = sb.commands.run(f"echo {marker}")
                assert result.exit_code == 0
                assert marker in result.stdout

            # Verify filesystem isolation: write in one, should not appear in another.
            sandboxes[0].files.write("/tmp/isolation_test.txt", "from-sandbox-0")
            for sb in sandboxes[1:]:
                assert sb.files.exists("/tmp/isolation_test.txt") is False
        finally:
            for sb in sandboxes:
                try:
                    sb.kill()
                except Exception:
                    pass


# ===================================================================
# Test Group 8: Context manager usage
# ===================================================================

class TestContextManager:
    """Tests for the Sandbox context manager (with statement)."""

    def test_context_manager_kills_on_exit(self):
        """Sandbox used as a context manager is killed on exit."""
        with Sandbox.create(TEMPLATE, timeout=60) as sb:
            sid = sb.sandbox_id
            assert sb.is_running() is True
            result = sb.commands.run("echo context-manager-test")
            assert "context-manager-test" in result.stdout

        # After exiting the context, the sandbox should be killed.
        # Trying to connect or use it should fail or return not-running.
        killed = Sandbox.kill(sid)
        # kill returns False if sandbox was already killed (which is expected).
        assert killed is False


# ===================================================================
# Test Group 9: Sandbox timeout (S5-11) — slow tests
# ===================================================================

class TestTimeout:
    """Tests for sandbox auto-expiration."""

    @pytest.mark.slow
    def test_sandbox_expires_after_timeout(self):
        """S5-11: A sandbox with a very short timeout stops responding."""
        sb = Sandbox.create(TEMPLATE, timeout=10)
        sid = sb.sandbox_id
        assert sb.is_running() is True

        # Wait for the sandbox to expire.
        time.sleep(15)

        # The sandbox should no longer be running.
        try:
            running = sb.is_running()
            assert running is False
        except Exception:
            # An exception is also acceptable here — the sandbox is gone.
            pass

        # Cleanup is best-effort; it might already be gone.
        try:
            Sandbox.kill(sid)
        except Exception:
            pass


# ===================================================================
# Entrypoint for running directly (not via pytest)
# ===================================================================

if __name__ == "__main__":
    # Allow running as a standalone script for quick smoke tests.
    print("=" * 60)
    print("E2B SDK End-to-End Smoke Test")
    print("=" * 60)
    print(_describe_config())
    print()

    print("[1/5] Creating sandbox...")
    sb = Sandbox.create(TEMPLATE, timeout=SANDBOX_TIMEOUT)
    print(f"      sandbox_id = {sb.sandbox_id}")
    print(f"      is_running = {sb.is_running()}")

    print("[2/5] Running command...")
    result = sb.commands.run("echo 'Hello from self-hosted E2B!'")
    print(f"      exit_code  = {result.exit_code}")
    print(f"      stdout     = {result.stdout.strip()}")
    assert result.exit_code == 0
    assert "Hello" in result.stdout

    print("[3/5] Writing and reading file...")
    sb.files.write("/tmp/smoke.txt", "smoke-test-content")
    content = sb.files.read("/tmp/smoke.txt")
    print(f"      content    = {content}")
    assert content == "smoke-test-content"

    print("[4/5] Python execution...")
    result = sb.commands.run("python3 -c 'print(6 * 7)'")
    print(f"      stdout     = {result.stdout.strip()}")
    assert "42" in result.stdout

    print("[5/5] Killing sandbox...")
    killed = sb.kill()
    print(f"      killed     = {killed}")
    assert killed is True

    print()
    print("=" * 60)
    print("ALL SMOKE TESTS PASSED")
    print("=" * 60)
