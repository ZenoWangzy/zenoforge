import inspect
import os
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]


def run_gh(command, caller_frame=None, **options):
    frame = caller_frame or inspect.currentframe().f_back
    try:
        source = Path(frame.f_code.co_filename).resolve().relative_to(REPO_ROOT).as_posix()
        caller = f"{source}:{frame.f_lineno}"
    finally:
        del frame
    env = options.get("env")
    env = os.environ.copy() if env is None else env.copy()
    env["ZF_GH_CALLER"] = caller
    options["env"] = env
    return subprocess.run(command, **options)
