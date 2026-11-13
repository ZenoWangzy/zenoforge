"""Failure reasons for delivery census inputs used by node_health."""

import json
import re
import subprocess
from concurrent.futures import ThreadPoolExecutor, wait
from datetime import datetime, timezone


def _error_text(stderr):
    return " ".join(str(stderr or "").split())[:160]


def gh_json(command, timeout, on_unavailable=None):
    """Run one gh JSON read, reporting why its result could not be used."""
    def unavailable(reason):
        if on_unavailable:
            on_unavailable(reason)

    try:
        result = subprocess.run(["gh", *command], capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        unavailable(f"timeout {timeout:g}s")
        return None
    except OSError as exc:
        unavailable(f"os error: {_error_text(exc)}")
        return None
    if result.returncode != 0:
        unavailable(f"rc {result.returncode}: {_error_text(result.stderr)}")
        return None
    try:
        value = json.loads(result.stdout or "null")
    except ValueError:
        unavailable("invalid json")
        return None
    if value is None:
        unavailable("invalid json")
    return value


def parallel_gh_json(commands, timeout, fanout, batch_timeout, run_json, on_unavailable=None):
    """Run independent gh reads with bounded concurrency and retain each failure reason."""
    if not commands:
        return []
    pool = ThreadPoolExecutor(max_workers=min(fanout, len(commands)))
    futures = {}
    for index, command in enumerate(commands):
        if on_unavailable:
            report = lambda reason, index=index: on_unavailable(index, reason)
            future = pool.submit(run_json, command, timeout, report)
        else:
            future = pool.submit(run_json, command, timeout)
        futures[future] = index
    done, pending = wait(futures, timeout=batch_timeout)
    results = [None] * len(commands)
    for future in done:
        results[futures[future]] = future.result()
    for future in pending:
        future.cancel()
    pool.shutdown(wait=False, cancel_futures=True)
    return results


def git_revert_times(root, tip="HEAD", on_unavailable=None):
    """Map reverted merge SHAs to their newest revert commit time on a Git tip."""
    timeout = 20
    def unavailable(reason):
        if on_unavailable:
            on_unavailable(reason)

    try:
        result = subprocess.run(
            ["git", "-C", root, "log", "--format=%ct%x00%B%x1e", "--grep=This reverts commit", tip],
            capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        unavailable(f"timeout {timeout}s")
        return None
    except OSError as exc:
        unavailable(f"os error: {_error_text(exc)}")
        return None
    if result.returncode != 0:
        unavailable(f"rc {result.returncode}: {_error_text(result.stderr)}")
        return None
    reverted = {}
    for record in result.stdout.split("\x1e"):
        epoch, separator, message = record.partition("\x00")
        if not separator:
            continue
        try:
            at = datetime.fromtimestamp(int(epoch.strip()), timezone.utc)
        except (ValueError, OverflowError, OSError):
            continue
        for merge_sha in re.findall(r"This reverts commit ([0-9a-f]{40})\.", message):
            if merge_sha not in reverted or at > reverted[merge_sha]:
                reverted[merge_sha] = at
    return reverted
