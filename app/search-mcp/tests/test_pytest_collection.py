import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]


def test_server_pytests_collect_together_without_import_mismatch():
    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "pytest",
            str(REPO_ROOT / "app" / "codex-proxy" / "tests" / "test_server.py"),
            str(REPO_ROOT / "app" / "search-mcp" / "tests" / "test_server.py"),
            "--collect-only",
            "-q",
        ],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stdout + result.stderr
