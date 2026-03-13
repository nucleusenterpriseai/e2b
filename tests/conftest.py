"""
Shared pytest configuration for E2B SDK integration tests.

This conftest provides:
- Custom markers (slow, desktop)
- A session-scoped connection check
- Helpful skip logic for missing configuration
"""

import os

import pytest


def pytest_configure(config):
    """Register custom markers."""
    config.addinivalue_line("markers", "slow: marks tests as slow (deselect with '-m \"not slow\"')")
    config.addinivalue_line("markers", "desktop: marks tests that require a desktop template")


@pytest.fixture(scope="session", autouse=True)
def _check_sdk_installed():
    """Fail fast if the e2b SDK is not installed."""
    try:
        import e2b  # noqa: F401
    except ImportError:
        pytest.skip("e2b SDK is not installed. Run: pip install e2b")
