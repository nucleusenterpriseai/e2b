# Phase 5: SDK Integration

**Duration**: 2 days
**Depends on**: Phase 3 (API), Phase 4 (templates)
**Status**: Not Started

---

## Objective

Verify the existing E2B Python/JS SDKs work against our self-hosted API by setting `E2B_DOMAIN` and `E2B_API_KEY`. Write integration tests.

## PRD (Phase 5)

### Strategy
Use the official E2B SDKs (`pip install e2b`, `npm i e2b`) pointed at our infrastructure. The SDKs support custom domains via environment variables. No SDK code changes needed.

### Configuration
```bash
export E2B_API_KEY="e2b_<our-generated-key>"
export E2B_DOMAIN="e2b.example.com"  # Points to our ALB
```

### What We're Delivering
- Verified SDK connectivity to self-hosted API
- Python integration test suite
- Documented SDK setup for internal users

### Success Criteria
- `Sandbox.create("base")` works
- `sandbox.commands.run("echo hello")` returns correct output
- `sandbox.files.write()` and `sandbox.files.read()` work
- `sandbox.kill()` cleans up
- Desktop sandbox accessible via SDK

## Dev Plan

### 5.1 Install SDKs (Day 1, 30 min)

```bash
pip install e2b
# or
npm install e2b
```

### 5.2 Basic Connectivity Test (Day 1, 2 hours)

```python
import os
os.environ["E2B_API_KEY"] = "<our-key>"
os.environ["E2B_DOMAIN"] = "e2b.example.com"

from e2b import Sandbox

# Test 1: Create + destroy
sandbox = Sandbox.create("base", timeout=60)
print(f"Sandbox ID: {sandbox.sandbox_id}")
sandbox.kill()
print("Basic lifecycle: PASS")
```

### 5.3 Write Full Test Suite (Day 1-2, 6 hours)

Create `/Users/mingli/projects/e2b/tests/test_sdk.py`:

```python
"""SDK integration tests for self-hosted E2B."""
import pytest
from e2b import Sandbox

@pytest.fixture
def sandbox():
    sb = Sandbox.create("base", timeout=120)
    yield sb
    sb.kill()

class TestProcessExecution:
    def test_echo(self, sandbox):
        result = sandbox.commands.run("echo hello")
        assert result.exit_code == 0
        assert "hello" in result.stdout

    def test_exit_code(self, sandbox):
        result = sandbox.commands.run("exit 42")
        assert result.exit_code == 42

    def test_env_vars(self, sandbox):
        result = sandbox.commands.run("echo $MY_VAR",
            env_vars={"MY_VAR": "test123"})
        assert "test123" in result.stdout

    def test_python(self, sandbox):
        result = sandbox.commands.run("python3 -c 'print(1+1)'")
        assert "2" in result.stdout

class TestFilesystem:
    def test_write_read(self, sandbox):
        sandbox.files.write("/tmp/test.txt", "hello world")
        content = sandbox.files.read("/tmp/test.txt")
        assert content == "hello world"

    def test_list_dir(self, sandbox):
        sandbox.files.write("/tmp/sdk-test/a.txt", "a")
        entries = sandbox.files.list("/tmp/sdk-test")
        names = [e.name for e in entries]
        assert "a.txt" in names

    def test_make_dir(self, sandbox):
        sandbox.files.make_dir("/tmp/nested/deep/dir")
        entries = sandbox.files.list("/tmp/nested/deep")
        names = [e.name for e in entries]
        assert "dir" in names

class TestLifecycle:
    def test_create_destroy(self):
        sb = Sandbox.create("base", timeout=30)
        assert sb.sandbox_id is not None
        sb.kill()

    def test_timeout(self):
        sb = Sandbox.create("base", timeout=5)
        import time
        time.sleep(10)
        with pytest.raises(Exception):
            sb.commands.run("echo should-fail")

    def test_concurrent(self):
        sandboxes = [Sandbox.create("base", timeout=60) for _ in range(3)]
        try:
            for i, sb in enumerate(sandboxes):
                result = sb.commands.run(f"echo sandbox-{i}")
                assert f"sandbox-{i}" in result.stdout
        finally:
            for sb in sandboxes:
                sb.kill()

class TestCustomDomain:
    def test_domain_set(self):
        import os
        assert os.environ.get("E2B_DOMAIN") is not None
        sb = Sandbox.create("base", timeout=30)
        assert sb.sandbox_id is not None
        sb.kill()
```

### 5.4 Desktop SDK Test (Day 2, 2 hours)

```python
class TestDesktop:
    def test_desktop_create(self):
        sb = Sandbox.create("desktop", timeout=120)
        try:
            # Verify VNC port accessible
            host = sb.get_host(6080)
            assert host is not None
        finally:
            sb.kill()

    def test_screenshot(self):
        sb = Sandbox.create("desktop", timeout=120)
        try:
            import time
            time.sleep(5)  # Wait for desktop to start
            screenshot = sb.screenshot()
            assert len(screenshot) > 0  # Valid PNG
        finally:
            sb.kill()
```

### 5.5 Document SDK Usage for Internal Users (Day 2, 2 hours)

Create internal user guide covering:
- How to get an API key
- How to set env vars
- Example scripts for common use cases
- Available templates and their capabilities

## Test Cases (Phase 5)

### P0 (Must Pass)

| ID | Test | Expected |
|---|---|---|
| S5-01 | `Sandbox.create("base")` | Returns sandbox object with ID |
| S5-02 | `sandbox.commands.run("echo hello")` | stdout contains "hello" |
| S5-03 | `sandbox.files.write + read` roundtrip | Content matches |
| S5-04 | `sandbox.kill()` | Sandbox destroyed, no error |
| S5-05 | Custom `E2B_DOMAIN` connects to our API | Sandbox created on our infra |

### P1 (Should Pass)

| ID | Test | Expected |
|---|---|---|
| S5-06 | Exit code propagation | Non-zero exit code returned |
| S5-07 | Environment variables | Vars available inside sandbox |
| S5-08 | Python execution | `python3 -c "print(1)"` works |
| S5-09 | Directory operations | mkdir, list work |
| S5-10 | Concurrent sandboxes (3) | All work independently |
| S5-11 | Sandbox timeout auto-cleanup | Sandbox gone after timeout |
| S5-12 | Desktop sandbox VNC | Port 6080 accessible |
| S5-13 | Invalid API key | Clear error message |
| S5-14 | Invalid template | Clear error message |

## Deliverables
- [ ] SDK connectivity verified
- [ ] Python test suite (15+ tests)
- [ ] Desktop SDK tests
- [ ] Internal user documentation
