#!/usr/bin/env bash
# release_age.py: release.hours_since_release reads production deployments (the live sha's earliest real record);
# healthy under 2 h, unhealthy at 4 h, NO-DATA (not 0) when a read fails, RELEASE-STOPPED at most once an hour while
# unhealthy and silent once production moves or PAUSE is set. The CLI prints the same deploy time and sha.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fail() { echo "release-age.test.sh: $*" >&2; exit 1; }

work="$test_env_root/release-age"
rm -rf "$work"
mkdir -p "$work/repo/engine" "$work/agent" "$work/runtime/alerts" "$work/fakebin" "$work/gh"
printf 'supervisor_inbox_append_once() { printf "%%s|%%s\\n" "$1" "$2" >> "$AGENT_HOME/inbox.txt"; }\n' > "$work/repo/engine/lib.sh"
# Fake gh: serves the deployment list and each record's statuses from FAKE_GH_DIR; FAKE_GH_FAIL=1 makes it fail.
cat > "$work/fakebin/gh" <<'SH'
#!/usr/bin/env bash
[[ "${FAKE_GH_FAIL:-}" != 1 ]] || exit 1
[[ "$1" == api ]] || exit 1
path="$2"
case "$path" in
  repos/*/deployments/*/statuses) id="${path#*/deployments/}"; id="${id%/statuses}"; cat "$FAKE_GH_DIR/status-$id.json" ;;
  repos/*/deployments\?*) cat "$FAKE_GH_DIR/deployments.json" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$work/fakebin/gh"

PYTHONPATH="$script_dir" WORK="$work" PATH="$work/fakebin:$PATH" python3 - <<'PY' || fail "python checks failed"
import json, os, subprocess, sys
from datetime import datetime, timedelta, timezone
import release_age

work = os.environ["WORK"]
os.environ["FAKE_GH_DIR"] = os.path.join(work, "gh")
now = datetime(2026, 11, 7, 13, 0, tzinfo=timezone.utc)
iso = lambda dt: dt.strftime("%Y-%m-%dT%H:%M:%SZ")
ago = lambda hours: iso(now - timedelta(hours=hours))
SHA_LIVE = "8866f3996" + "0" * 31
SHA_NEW = "2d75caf3a" + "0" * 31
REPO = "maintainer/example"
reader = os.path.join(os.path.dirname(os.path.abspath(release_age.__file__)), "..", "production-deployment-read.sh")

def fixture(rows):
    """rows: (id, sha, created_at, reconciled). Every record's newest status is success."""
    gh = os.path.join(work, "gh")
    for f in os.listdir(gh):
        os.remove(os.path.join(gh, f))
    deployments = []
    for rid, sha, created, reconciled in rows:
        deployments.append({"id": rid, "sha": sha, "created_at": created,
                            "payload": {"reconciled": True} if reconciled else {}})
        with open(os.path.join(gh, f"status-{rid}.json"), "w") as out:
            json.dump([{"state": "success", "created_at": created}], out)
    with open(os.path.join(gh, "deployments.json"), "w") as out:
        json.dump(sorted(deployments, key=lambda d: d["created_at"], reverse=True), out)

agent = os.path.join(work, "agent")
runtime = os.path.join(work, "runtime")
events = os.path.join(runtime, "alerts", "events.md")
inbox = os.path.join(agent, "inbox.txt")
repo_root = os.path.join(work, "repo")

def check(cond, msg):
    if not cond:
        print("release-age.test.sh: " + msg, file=sys.stderr)
        sys.exit(1)

def stopped():
    return [l for l in open(events).read().splitlines() if "RELEASE-STOPPED" in l] if os.path.exists(events) else []

def inbox_lines():
    return open(inbox).read().splitlines() if os.path.exists(inbox) else []

def score(at, repo=REPO):
    metrics = {}
    found = release_age.collect(metrics, at, repo=repo, reader=reader)
    return metrics[release_age.METRIC], found

# Healthy: one hour since the live deployment is under the 2 h bound.
fixture([(101, SHA_LIVE, ago(1), False)])
v, found = score(now)
check(v is not None and 0.9 < v < 1.1, f"healthy value {v}")
release_age.alert(runtime, agent, repo_root, now, found)
check(stopped() == [] and inbox_lines() == [], "healthy must not alert")

# Unhealthy: five hours is past the 4 h bound. First alert now; none within the hour; one more after it.
fixture([(102, SHA_LIVE, ago(5), False)])
v, found = score(now)
check(v is not None and 4.9 < v < 5.1, f"unhealthy value {v}")
release_age.alert(runtime, agent, repo_root, now, found)
check(len(stopped()) == 1 and len(inbox_lines()) == 1, "first unhealthy hour must alert once")
t30 = now + timedelta(minutes=30)
v, found = score(t30)
release_age.alert(runtime, agent, repo_root, t30, found)
check(len(stopped()) == 1 and len(inbox_lines()) == 1, "no second alert within the hour")
t61 = now + timedelta(minutes=61)
v, found = score(t61)
release_age.alert(runtime, agent, repo_root, t61, found)
check(len(stopped()) == 2 and len(inbox_lines()) == 2, "alert again after an hour while unhealthy")
keys = [l.split("|")[0] for l in inbox_lines()]
check(keys[0] != keys[1] and keys[1].endswith(f"{t61:%Y-%m-%dT%H}"), f"inbox keys must carry the hour bucket: {keys}")

# A reconciled record of the same sha, later than the real deploy, does not move the time.
fixture([(102, SHA_LIVE, ago(5), False), (103, SHA_LIVE, ago(0.5), True)])
v, _ = score(now)
check(4.9 < v < 5.1, f"reconciled same-sha record moved the time: {v}")

# Production moves: a newer sha whose earliest real deploy is recent is healthy and stops the alerts.
fixture([(102, SHA_LIVE, ago(5), False), (104, SHA_NEW, ago(0.5), False)])
t_moved = now + timedelta(hours=2)
v, found = score(t_moved)
check(v is not None and 2.4 < v < 2.6, f"newer sha must move the time, got {v}")
release_age.alert(runtime, agent, repo_root, t_moved, found)
check(len(stopped()) == 2 and len(inbox_lines()) == 2, "a healthy newer record must not alert")

# A later unhealthy record is a new episode and alerts at once.
fixture([(105, SHA_NEW, ago(4.5), False)])
v, found = score(now)
release_age.alert(runtime, agent, repo_root, now, found)
check(len(stopped()) == 3, "a new unhealthy episode should alert at once")

# Unreadable source: NO-DATA, never 0, and no alert.
os.environ["FAKE_GH_FAIL"] = "1"
metrics = {}
found = release_age.collect(metrics, now, repo=REPO, reader=reader)
check(release_age.METRIC in metrics and metrics[release_age.METRIC] is None, f"unreadable must be None: {metrics}")
check(found is None, "unreadable must return no record")
release_age.alert(runtime, agent, repo_root, now, found)
check(len(stopped()) == 3, "NO-DATA must not alert")
del os.environ["FAKE_GH_FAIL"]

# Paused: the value still reads, but PAUSE raises no alert.
open(os.path.join(agent, "PAUSE"), "w").write('{"caller":"operator"}')
fixture([(106, SHA_NEW, ago(6), False)])
v, found = score(now)
check(v is not None and v > 5.9, "paused must still report the value")
release_age.alert(runtime, agent, repo_root, now + timedelta(hours=3), found)
check(len(stopped()) == 3, "PAUSE must suppress the alert")
os.remove(os.path.join(agent, "PAUSE"))

# CLI: prints the earliest real deploy time and sha of the live sha, ignoring a later reconciled record.
fixture([(201, SHA_LIVE, "2026-10-31T04:02:59Z", False), (202, SHA_LIVE, "2026-11-01T09:46:18Z", True)])
env = {**os.environ, "ZF_REPO": REPO}
cli = [sys.executable, os.path.join(os.path.dirname(os.path.abspath(release_age.__file__)), "release_age.py")]
done = subprocess.run(cli, capture_output=True, text=True, env=env)
check(done.returncode == 0 and done.stdout == f"2026-10-31T04:02:59Z {SHA_LIVE[:9]}\n", f"cli output {done.stdout!r}")
done = subprocess.run(cli, capture_output=True, text=True, env={**env, "FAKE_GH_FAIL": "1"})
check(done.returncode != 0 and done.stdout == "", "cli must print nothing and fail when unreadable")
PY

echo "release-age.test.sh: ok"
