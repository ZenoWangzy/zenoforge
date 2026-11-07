"""Release age: hours since production last changed, read from production itself.

Ruling release-overdue-2026-11-07: no formal release for two batch cycles (4 h) is UNHEALTHY and raises
RELEASE-STOPPED from the engine, not from a supervisor session. The value comes from the GitHub production
Deployments through engine/production-deployment-read.sh (the newest status decides, as gen_dashboard reads
it), not from release-train.json released_at or release-train.log RELEASED lines, which go stale on a hand
release. NO-DATA (None) when that read fails or has no current record; it is never 0.

One alert per episode: the episode is the production record that has aged past the unhealthy bound. A PAUSE
file suppresses the alert but not the value, the way station_health treats a paused pipeline.
"""
import json, os, subprocess
from datetime import datetime, timezone

METRIC = "release.hours_since_release"
CRITERIA = {METRIC: ("release", "hours since production last changed (formal or hand release)", 2, 4, False)}
MEANING = {METRIC: "距上次生产变更（正式发版或手工发版）过去了多少小时；超过 4 小时，发版线就是停摆，必须报给主管。"}
SOURCE = {METRIC: "GitHub production Deployments（engine/production-deployment-read.sh：最新状态为 success 的记录的 success 时间）；不读 release-train.json 的 released_at，它在手工发版后会过期"}
READER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "production-deployment-read.sh")
STATE = "release-age-episode.json"


def _ts(value):
    try:
        return datetime.strptime(str(value)[:20], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def current_record(repo, reader=READER):
    """The newest production record (by success time) from the reader, or None when unreadable or empty."""
    if not repo:
        return None
    try:
        done = subprocess.run(["bash", reader, repo], capture_output=True, text=True, timeout=300)
        records = json.loads(done.stdout or "[]") if done.returncode == 0 else None
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None
    if not isinstance(records, list):
        return None
    timed = [(_ts(r.get("success_at") or r.get("created_at")), r) for r in records if isinstance(r, dict)]
    timed = [(at, r) for at, r in timed if at is not None]
    return max(timed, key=lambda pair: pair[0]) if timed else None


def collect(metrics, now, repo=None, reader=READER):
    """Score the metric; returns {"id", "hours", "sha"} for the current production record, or None (NO-DATA)."""
    if repo is None:
        repo = os.environ.get("RELEASE_TRAIN_REPO") or os.environ.get("ZF_REPO", "")
    found = current_record(repo, reader)
    if found is None:
        metrics[METRIC] = None
        return None
    at, record = found
    hours = max(0.0, (now - at).total_seconds() / 3600)
    metrics[METRIC] = hours
    return {"id": record.get("id"), "hours": hours, "sha": str(record.get("sha") or "")[:9]}


def _read_state(path):
    try:
        value = json.load(open(path))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def alert(runtime, agent_home, repo_root, now, found):
    """One RELEASE-STOPPED event and one supervisor inbox line per episode; silent while PAUSE is set."""
    if found is None or found["hours"] < CRITERIA[METRIC][3] or os.path.exists(os.path.join(agent_home, "PAUSE")):
        return
    state_path = os.path.join(runtime, STATE)
    if _read_state(state_path).get("record") == found["id"]:
        return
    text = f"hours={found['hours']:.1f} record={found['id']} sha={found['sha']}"
    lib = os.path.join(repo_root, "engine", "lib.sh")
    done = subprocess.run(
        ["bash", "-c", 'source "$1" && supervisor_inbox_append_once "$2" "$3"', "bash", lib,
         f"release-stopped:{found['id']}", f"release-stopped {text}"],
        capture_output=True, env={**os.environ, "AGENT_HOME": agent_home})
    if done.returncode != 0:
        return
    events = os.path.join(runtime, "alerts", "events.md")
    os.makedirs(os.path.dirname(events), exist_ok=True)
    with open(events, "a") as out:
        out.write(f"[{now:%Y-%m-%dT%H:%M:%SZ}] RELEASE-STOPPED {text}\n")
    tmp = state_path + ".tmp"
    with open(tmp, "w") as out:
        json.dump({"record": found["id"]}, out)
    os.replace(tmp, state_path)
