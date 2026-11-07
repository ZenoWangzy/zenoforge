"""Release age: hours since production last changed, read from production itself.

Ruling release-overdue-2026-11-07: no formal release for two batch cycles (4 h) is UNHEALTHY and raises
RELEASE-STOPPED from the engine, which repeats every hour until production moves. The value comes from the GitHub
production Deployments, not from release-train.json released_at or the RELEASED lines, which go stale on a hand
release. Live sha: the newest success record the reader returns (engine/production-deployment-read.sh). Time: the
earliest deployment record of that sha that is not a reconciliation, so a later reconciled record does not move it
and a newer sha does. NO-DATA (None) when a read fails; it is never 0.

CLI: `python3 release_age.py` prints "<deploy time> <sha>" for the same source, or exits 1 with no output.
"""
import json, os, subprocess, sys
from datetime import datetime, timezone

METRIC = "release.hours_since_release"
CRITERIA = {METRIC: ("release", "hours since production last changed (formal or hand release)", 2, 4, False)}
MEANING = {METRIC: "距上次生产变更（正式发版或手工发版）过去了多少小时；超过 4 小时，发版线就是停摆，必须报给主管。"}
SOURCE = {METRIC: "GitHub production Deployments：最新 success 记录的 sha，取该 sha 最早的非对账部署记录时间（engine/production-deployment-read.sh）；不读 release-train.json 的 released_at，它在手工发版后会过期"}
READER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "production-deployment-read.sh")
STATE = "release-age-episode.json"
HOUR = 3600


def _ts(value):
    try:
        return datetime.strptime(str(value)[:20], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def _reader_records(repo, reader):
    """Current production records (newest status success) from the reader, or None when unreadable."""
    try:
        done = subprocess.run(["bash", reader, repo], capture_output=True, text=True, timeout=300)
        records = json.loads(done.stdout or "[]") if done.returncode == 0 else None
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None
    return records if isinstance(records, list) else None


def _deployment_list(repo):
    """All production deployment records (no statuses), newest first, or None when unreadable."""
    try:
        done = subprocess.run(["gh", "api", f"repos/{repo}/deployments?environment=production&per_page=100"],
                              capture_output=True, text=True, timeout=120)
        records = json.loads(done.stdout or "[]") if done.returncode == 0 else None
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None
    return records if isinstance(records, list) else None


def production_deploy(repo, reader=READER):
    """{"id", "sha", "at"} for the live sha's earliest real deployment record, or None when unreadable."""
    if not repo:
        return None
    current = _reader_records(repo, reader)
    if not current:
        return None
    timed = [(_ts(r.get("success_at") or r.get("created_at")), r) for r in current if isinstance(r, dict)]
    timed = [pair for pair in timed if pair[0] is not None]
    if not timed:
        return None
    live = max(timed, key=lambda pair: pair[0])[1].get("sha")
    listing = _deployment_list(repo)
    if listing is None:
        return None
    same = [d for d in listing if isinstance(d, dict) and d.get("sha") == live and _ts(d.get("created_at"))]
    if not same:
        return None
    real = [d for d in same if not (d.get("payload") or {}).get("reconciled")] or same
    first = min(real, key=lambda d: _ts(d["created_at"]))
    return {"id": first.get("id"), "sha": live, "at": _ts(first["created_at"])}


def collect(metrics, now, repo=None, reader=READER):
    """Score the metric; returns {"id", "hours", "sha"} for the live deployment, or None (NO-DATA)."""
    if repo is None:
        repo = os.environ.get("RELEASE_TRAIN_REPO") or os.environ.get("ZF_REPO", "")
    found = production_deploy(repo, reader)
    if found is None:
        metrics[METRIC] = None
        return None
    hours = max(0.0, (now - found["at"]).total_seconds() / 3600)
    metrics[METRIC] = hours
    return {"id": found["id"], "hours": hours, "sha": str(found["sha"] or "")[:9]}


def _read_state(path):
    try:
        value = json.load(open(path))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def alert(runtime, agent_home, repo_root, now, found):
    """RELEASE-STOPPED at most once an hour while the episode lasts; silent while PAUSE is set.

    The episode is the live deployment record. The state file keeps that record and the epoch of the last
    alert; the inbox key carries the hour bucket, so a repeat within the hour is a no-op either way.
    """
    if found is None or found["hours"] < CRITERIA[METRIC][3] or os.path.exists(os.path.join(agent_home, "PAUSE")):
        return
    state_path = os.path.join(runtime, STATE)
    state = _read_state(state_path)
    last = state.get("alerted_at")
    if state.get("record") == found["id"] and isinstance(last, (int, float)) and now.timestamp() - last < HOUR:
        return
    text = f"hours={found['hours']:.1f} record={found['id']} sha={found['sha']}"
    lib = os.path.join(repo_root, "engine", "lib.sh")
    hour = f"{now:%Y-%m-%dT%H}"
    done = subprocess.run(
        ["bash", "-c", 'source "$1" && supervisor_inbox_append_once "$2" "$3"', "bash", lib,
         f"release-stopped:{found['id']}:{hour}", f"release-stopped {text}"],
        capture_output=True, env={**os.environ, "AGENT_HOME": agent_home})
    if done.returncode != 0:
        return
    events = os.path.join(runtime, "alerts", "events.md")
    os.makedirs(os.path.dirname(events), exist_ok=True)
    with open(events, "a") as out:
        out.write(f"[{now:%Y-%m-%dT%H:%M:%SZ}] RELEASE-STOPPED {text}\n")
    tmp = state_path + ".tmp"
    with open(tmp, "w") as out:
        json.dump({"record": found["id"], "alerted_at": now.timestamp()}, out)
    os.replace(tmp, state_path)


def main():
    repo = os.environ.get("RELEASE_TRAIN_REPO") or os.environ.get("ZF_REPO", "")
    found = production_deploy(repo)
    if found is None:
        return 1
    print(f"{found['at']:%Y-%m-%dT%H:%M:%SZ} {str(found['sha'])[:9]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
