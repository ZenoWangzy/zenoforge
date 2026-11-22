"""Failure reasons for delivery census inputs used by node_health."""

import json
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, wait
from datetime import datetime, timedelta, timezone

LAST_GOOD = "delivery-rows-last-good.json"  # next to node-health.json; the last complete issue and PR census
MAX_AGE = timedelta(hours=24)


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


def _save_rows(path, now, rows):
    tmp = f"{path}.tmp"
    try:
        with open(tmp, "w") as out:
            json.dump({"at": f"{now.astimezone(timezone.utc):%Y-%m-%dT%H:%M:%SZ}", "issues": rows["issues"],
                       "prs": rows["prs"]}, out)
        os.replace(tmp, path)
    except OSError:
        pass


def _load_rows(path, now):
    """(fetch time, rows) of the last complete census when it is under 24 h old and well formed, else None."""
    try:
        with open(path) as src:
            saved = json.load(src)
        at = datetime.strptime(saved["at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        rows = {"issues": saved["issues"], "prs": saved["prs"]}
        if (all(isinstance(rows[name], list) and all(isinstance(row, dict) for row in rows[name]) for name in rows)
                and timedelta(0) <= now - at < MAX_AGE):
            return at, rows
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return None


def last_good_rows(rows, now, path, unavailable, served):
    """Store a complete census; a refused list falls back to the stored one and is labelled with its fetch time."""
    if not path:
        return rows["issues"], rows["prs"]
    if rows["issues"] is not None and rows["prs"] is not None:
        _save_rows(path, now, rows)
        return rows["issues"], rows["prs"]
    loaded = _load_rows(path, now)
    if loaded is None:
        return rows["issues"], rows["prs"]
    at, stored = loaded
    label = f"{at:%Y-%m-%dT%H:%MZ}"
    for name in ("issues", "prs"):
        if rows[name] is None:
            rows[name] = stored[name]
            print(f"node_health: delivery input {name} unavailable: {unavailable.get(name, 'unknown')}; "
                  f"using rows from {label}", file=sys.stderr)
    if served is not None:
        served["rows_from"] = label
    return rows["issues"], rows["prs"]
