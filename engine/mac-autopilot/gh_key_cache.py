import inspect
import json
import os
import subprocess
from pathlib import Path

import gh_caller

ENGINE_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = ENGINE_ROOT.parent


def read(kind, *arguments, timeout=60):
    helper = ENGINE_ROOT / "bin" / "gh-key-cache-read"
    frame = inspect.currentframe().f_back
    try:
        result = gh_caller.run_gh(
            ["bash", str(helper), kind, *map(str, arguments)],
            caller_frame=frame,
            capture_output=True,
            text=True,
            timeout=timeout,
            cwd=os.environ.get("MAC_AUTOPILOT_ROOT", str(REPO_ROOT)),
        )
    finally:
        del frame
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip()[:240] or f"GitHub cache read failed: {kind}")
    return json.loads(result.stdout)


def read_or_empty(kind, *arguments, timeout=60):
    try:
        return read(kind, *arguments, timeout=timeout)
    except Exception:
        return []
