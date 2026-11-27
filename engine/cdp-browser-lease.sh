#!/usr/bin/env bash
set -euo pipefail
exec python3 - "$@" <<'PY'
import fcntl
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

args = sys.argv[1:]
nonblocking = args[:1] == ["--nonblocking"]
if nonblocking:
    args = args[1:]
if args[:1] == ["--"]:
    args = args[1:]
if not args:
    print("usage: cdp-browser-lease.sh [--nonblocking] [--] <command> [args...]", file=sys.stderr)
    sys.exit(64)

proof_path = None
for index, value in enumerate(args):
    if value == "--json" and index + 1 < len(args):
        proof_path = args[index + 1]
    elif value.startswith("--json="):
        proof_path = value.split("=", 1)[1]

agent_home = os.environ.get("AGENT_HOME") or os.environ.get("ZF_HOME")
if agent_home:
    default_lock = os.path.join(agent_home, "cdp-agent-browser.lock")
else:
    lock_root = os.environ.get("ZF_CONFIG_ROOT") or os.environ.get("TMPDIR") or tempfile.gettempdir()
    default_lock = os.path.join(lock_root, "cdp-agent-browser.lock")
lock_path = os.environ.get("WEB_SESSION_LEASE_FILE") or default_lock
Path(lock_path).parent.mkdir(parents=True, exist_ok=True)
wait_limit = float(os.environ.get("WEB_SESSION_LEASE_WAIT_SECONDS") or os.environ.get("MERGE_LOCK_WAIT_SECONDS") or "300")
wait_started = time.monotonic_ns()
lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
wait_seconds = max(0, wait_limit)
while True:
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        break
    except BlockingIOError:
        if nonblocking or (time.monotonic_ns() - wait_started) / 1_000_000_000 >= wait_seconds:
            print(f"CDP browser lease busy after {wait_limit:g}s", file=sys.stderr)
            sys.exit(75)
        time.sleep(0.01)
lock_wait_ms = round((time.monotonic_ns() - wait_started) / 1_000_000, 3)

runtime_dir = os.environ.get("MAC_AUTOPILOT_RUNTIME_DIR")
metrics_path = os.environ.get("ZF_CDP_BROWSER_LEASE_METRICS_FILE")
if not metrics_path and runtime_dir:
    metrics_path = os.path.join(runtime_dir, "proof-browser-runs.jsonl")
if not metrics_path:
    metrics_path = os.path.join(os.environ.get("AGENT_HOME") or os.path.dirname(lock_path), "logs", "proof-browser-runs.jsonl")
targets_path = os.environ.get("ZF_WEB_SESSION_LEASE_TARGETS_FILE")
if not targets_path:
    targets_root = runtime_dir or os.path.dirname(lock_path)
    targets_path = os.path.join(targets_root, "cdp-browser-lease-targets.txt")
Path(targets_path).parent.mkdir(parents=True, exist_ok=True)
Path(targets_path).touch(exist_ok=True)

def close_registered_pages():
    try:
        lines = Path(targets_path).read_text(encoding="utf-8").splitlines()
    except OSError:
        return
    port = os.environ.get("ZF_WEB_ADVISOR_PROVIDER_CDP_PORT") or "9224"
    keep = []
    for line in lines:
        retained = line.startswith("retained:")
        target = line[len("retained:"):] if retained else line
        if retained or not re.fullmatch(r"[0-9a-fA-F]{32}", target):
            if line:
                keep.append(line)
            continue
        url = f"http://127.0.0.1:{port}/json/close/{target}"
        try:
            with urllib.request.urlopen(url, timeout=2) as response:
                response.read()
        except urllib.error.HTTPError as error:
            if error.code not in (404, 410):
                keep.append(line)
        except (OSError, ValueError):
            keep.append(line)
    content = "".join(f"{line}\n" for line in keep)
    temporary = f"{targets_path}.{os.getpid()}.tmp"
    try:
        Path(temporary).write_text(content, encoding="utf-8")
        os.replace(temporary, targets_path)
    except OSError:
        try:
            os.unlink(temporary)
        except OSError:
            pass

close_registered_pages()
child_env = os.environ.copy()
child_env["ZF_WEB_SESSION_LEASE_TARGETS_FILE"] = targets_path
run_started = time.monotonic_ns()
try:
    result = subprocess.run(args, env=child_env, pass_fds=(lock_fd,))
    exit_code = result.returncode
except OSError as error:
    print(str(error), file=sys.stderr)
    exit_code = 127
run_ms = round((time.monotonic_ns() - run_started) / 1_000_000, 3)
close_registered_pages()
completed_at = datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
record = {"completed_at": completed_at, "lock_wait_ms": lock_wait_ms, "run_ms": run_ms}

if proof_path:
    try:
        proof = json.loads(Path(proof_path).read_text(encoding="utf-8"))
        if isinstance(proof, dict):
            proof.update({"lock_wait_ms": lock_wait_ms, "run_ms": run_ms})
            Path(proof_path).parent.mkdir(parents=True, exist_ok=True)
            descriptor, temporary = tempfile.mkstemp(dir=str(Path(proof_path).parent), prefix="proof-lease-")
            with os.fdopen(descriptor, "w", encoding="utf-8") as output:
                json.dump(proof, output, ensure_ascii=False)
                output.write("\n")
            os.replace(temporary, proof_path)
    except (OSError, ValueError, TypeError):
        pass

if proof_path:
    try:
        Path(metrics_path).parent.mkdir(parents=True, exist_ok=True)
        descriptor = os.open(metrics_path, os.O_CREAT | os.O_APPEND | os.O_WRONLY, 0o600)
        try:
            os.write(descriptor, (json.dumps(record, separators=(",", ":")) + "\n").encode("utf-8"))
        finally:
            os.close(descriptor)
    except OSError as error:
        print(f"CDP browser lease metrics write failed: {error}", file=sys.stderr)

sys.exit(exit_code)
PY
