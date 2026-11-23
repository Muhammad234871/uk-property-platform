"""Smoke tests: make sure the project installs and imports cleanly.

These are deliberately tiny. They exist so CI has something to run from day one,
and they catch the most basic breakage (bad install, missing package, syntax error).
"""

import importlib

import pytest


@pytest.mark.parametrize("module", ["ingestion", "ingestion.utils"])
def test_package_imports(module):
    assert importlib.import_module(module) is not None


def test_runtime_dependencies_installed():
    for dep in ("boto3", "requests", "dotenv"):
        assert importlib.import_module(dep) is not None
