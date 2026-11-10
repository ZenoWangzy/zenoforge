#!/usr/bin/env python3
"""Shared live-deployment evidence and delivery health helpers."""
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

SHA_RE = re.compile(r"^[0-9a-f]{40}(?:[0-9a-f]{24})?$")
NONPRODUCT_PATHS_RE = re.compile(r"^(scripts|lessons|docs|ops|[.]agents|[.]trellis|[.]github)/|^[^/]+[.]md$")
NO_DATA_UNHEALTHY = frozenset(("delivery.merged_not_live",))
CRITERIA = {
    "delivery.merged_not_live": ("delivery", "merged product commits not in production", 6, 12, False),
    "delivery.oldest_merged_not_live_hours": ("delivery", "age of oldest merged product commit not in production hours", 24, 72, False),
}
MEANING = {
    "delivery.merged_not_live": "origin/main 首父链上，尚未包含在生产 SHA 中的产品提交数。",
    "delivery.oldest_merged_not_live_hours": "origin/main 首父链上，最早尚未进入生产的产品提交年龄。",
}
SOURCE = {
    "delivery.merged_not_live": "production deployment record (release_age.production_deploy), else $AGENT_HOME/state/live-sha.json, plus first-parent origin/main history classified by the merge-lane NONPRODUCT_PATHS_RE",
    "delivery.oldest_merged_not_live_hours": "production deployment record (release_age.production_deploy), else $AGENT_HOME/state/live-sha.json, plus first-parent origin/main commit times classified by the merge-lane NONPRODUCT_PATHS_RE",
}


def valid_sha(value):
    return isinstance(value, str) and SHA_RE.fullmatch(value) is not None


def _valid_time(value):
    if not isinstance(value, str) or not value:
        return False
    try:
        datetime.fromisoformat(value.replace("Z", "+00:00"))
        return True
    except ValueError:
        return False


def read_live_sha(agent_home):
    """Read the deployed commit proof; absent or malformed state is unavailable."""
    try:
        record = json.loads((Path(agent_home) / "state" / "live-sha.json").read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError):
        return None
    if (not isinstance(record, dict) or not valid_sha(record.get("sha"))
            or not _valid_time(record.get("at")) or not isinstance(record.get("source"), str)
            or not record["source"].strip()):
        return None
    return {key: record[key] for key in ("sha", "at", "source")}


def write_live_sha(agent_home, sha, source, at=None):
    """Atomically publish the SHA proven by a successful post-deploy check."""
    record = {"sha": sha, "at": at or datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
              "source": source}
    if (not valid_sha(record["sha"]) or not _valid_time(record["at"])
            or not isinstance(record["source"], str) or not record["source"].strip()):
        raise ValueError("invalid live SHA record")
    path = Path(agent_home) / "state" / "live-sha.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent,
                                         prefix=path.name + ".", suffix=".tmp", delete=False) as stream:
            temporary = stream.name
            json.dump(record, stream, separators=(",", ":"))
            stream.write("\n")
        os.replace(temporary, path)
    except OSError:
        if temporary:
            try:
                os.unlink(temporary)
            except OSError:
                pass
        raise
    return record


def repository_root():
    return (os.environ.get("MAC_AUTOPILOT_ROOT") or os.environ.get("ZF_REPO_DIR")
            or str(Path(__file__).resolve().parents[2]))


def ancestor_shas(repo_root, live_sha):
    """Return all commits reachable from live SHA with one git process for a batch."""
    if not valid_sha(live_sha):
        return set()
    try:
        result = subprocess.run(["git", "-C", os.fspath(repo_root), "rev-list", live_sha],
                                capture_output=True, text=True, check=False)
    except OSError:
        return set()
    if result.returncode:
        return set()
    return set(result.stdout.splitlines())


def collect_health_metrics(agent_home, now, repo=None, reader=None):
    """Production's own deployment record decides the live sha; live-sha.json (written after a deploy proof) covers an unreadable one.

    release-train.json and deployed.json are never read: a hand release leaves them on an older sha.
    """
    if reader is None:
        import release_age  # engine/mac-autopilot/release_age.py, landed by #635
        reader = release_age.production_deploy
    deploy = reader(repo if repo is not None else os.environ.get("RELEASE_TRAIN_REPO") or os.environ.get("ZF_REPO", ""))
    record = None
    if isinstance(deploy, dict) and valid_sha(deploy.get("sha")) and isinstance(deploy.get("at"), datetime):
        record = {"sha": deploy["sha"], "at": deploy["at"].strftime("%Y-%m-%dT%H:%M:%SZ"), "source": "production-deployments"}
    return health_metrics(repository_root(), record or read_live_sha(agent_home), now.timestamp())


def is_product_change(paths):
    """Match the merge lane's rule: any path outside NONPRODUCT_PATHS_RE is product."""
    return any(NONPRODUCT_PATHS_RE.search(path) is None for path in paths)


def _parse_rev_list(data):
    records = []
    for line in data.decode("ascii", errors="ignore").splitlines():
        try:
            at, sha = line.split(" ", 1)
            if not valid_sha(sha):
                return None
            records.append({"sha": sha, "at": int(at), "paths": []})
        except (ValueError, TypeError):
            return None
    return records


def _add_diff_paths(data, records):
    by_sha = {record["sha"]: record for record in records}
    tokens = data.decode("utf-8", errors="surrogateescape").split("\0")
    current, index = None, 0
    status_re = re.compile(r"^[ACDMRTUXB][0-9]*$")
    while index < len(tokens):
        token = tokens[index]
        index += 1
        if not token:
            continue
        if valid_sha(token):
            current = by_sha.get(token)
            if current is None:
                return False
            continue
        if current is None or not status_re.fullmatch(token):
            return False
        count = 2 if token[0] in "RC" else 1
        if index + count > len(tokens):
            return False
        current["paths"].extend(tokens[index:index + count])
        index += count
    return True


def health_metrics(repo_root, live_record, now=None):
    """Count product commits in live..origin/main using the merge lane's classifier."""
    empty = {"delivery.merged_not_live": None, "delivery.oldest_merged_not_live_hours": None}
    live_sha = live_record.get("sha") if isinstance(live_record, dict) else None
    if not valid_sha(live_sha):
        return empty
    root = os.fspath(repo_root)
    try:
        ancestor = subprocess.run(["git", "-C", root, "merge-base", "--is-ancestor", live_sha, "origin/main"],
                                  capture_output=True, check=False)
        if ancestor.returncode:
            return empty
        commit_range = f"{live_sha}..origin/main"
        result = subprocess.run(["git", "-C", root, "rev-list", "--first-parent", "--reverse",
                                 "--timestamp", commit_range], capture_output=True, check=False)
        if result.returncode:
            return empty
        records = _parse_rev_list(result.stdout)
        if records is None:
            return empty
        if records:
            changed = subprocess.run(["git", "-C", root, "diff-tree", "--root", "-r", "--first-parent", "--diff-merges=first-parent",
                                      "--name-status", "--find-renames", "-z", "--stdin"],
                                     input="".join(f"{record['sha']}\n" for record in records),
                                     capture_output=True, text=True, check=False)
            if changed.returncode or not _add_diff_paths(changed.stdout.encode("utf-8", errors="surrogateescape"), records):
                return empty
        products = [commit for commit in records if is_product_change(commit["paths"])]
    except OSError:
        return empty
    count = len(products)
    if not count:
        return {"delivery.merged_not_live": 0, "delivery.oldest_merged_not_live_hours": 0}
    oldest_at = min(commit["at"] for commit in products)
    current = float(now if now is not None else time.time())
    return {"delivery.merged_not_live": count,
            "delivery.oldest_merged_not_live_hours": max(0, (current - oldest_at) / 3600)}


def no_data_status(metric_id, value):
    return "UNHEALTHY" if metric_id in NO_DATA_UNHEALTHY and value is None else None


def display_value(value):
    return "NO-DATA" if value is None else f"{value:.0f}"


def main(argv=None):
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) != 3 or args[0] != "write-live-sha":
        print("usage: live_delivery.py write-live-sha <sha> <source>", file=sys.stderr)
        return 2
    try:
        write_live_sha(os.environ.get("AGENT_HOME") or os.environ.get("ZF_HOME") or Path.home() / ".zenoforge",
                       args[1], args[2])
    except (OSError, ValueError) as error:
        print(f"live_delivery: could not write live SHA: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
