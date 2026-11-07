#!/usr/bin/env bash
# release_age.py: release.hours_since_release reads production deployments; healthy under 2 h, unhealthy at 4 h,
# NO-DATA (not 0) when the read fails, and one RELEASE-STOPPED per episode, silent while PAUSE is set.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fail() { echo "release-age.test.sh: $*" >&2; exit 1; }

work="$test_env_root/release-age"
mkdir -p "$work/repo/engine" "$work/agent/alerts" "$work/runtime/alerts"
printf 'supervisor_inbox_append_once() { printf "%%s|%%s\\n" "$1" "$2" >> "$AGENT_HOME/inbox.txt"; }\n' > "$work/repo/engine/lib.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$work/unreadable-reader.sh"
printf '#!/usr/bin/env bash\ncat "$RELEASE_AGE_FIXTURE"\n' > "$work/fixture-reader.sh"

PYTHONPATH="$script_dir" WORK="$work" python3 - <<'PY' || fail "python checks failed"
import json, os, sys
from datetime import datetime, timedelta, timezone
import release_age

work = os.environ["WORK"]
now = datetime(2026, 11, 7, 13, 0, tzinfo=timezone.utc)
stamp = lambda hours_ago: (now - timedelta(hours=hours_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")
reader = os.path.join(work, "fixture-reader.sh")
os.environ["RELEASE_AGE_FIXTURE"] = os.path.join(work, "records.json")

def records(hours_ago, record_id):
    with open(os.environ["RELEASE_AGE_FIXTURE"], "w") as out:
        json.dump([{"id": record_id, "sha": "8866f3996" + "0" * 31, "created_at": stamp(hours_ago),
                    "success_at": stamp(hours_ago)}], out)

def check(cond, msg):
    if not cond:
        print("release-age.test.sh: " + msg, file=sys.stderr)
        sys.exit(1)

agent = os.path.join(work, "agent")
runtime = os.path.join(work, "runtime")
events = os.path.join(runtime, "alerts", "events.md")
inbox = os.path.join(agent, "inbox.txt")
repo_root = os.path.join(work, "repo")

def stopped_lines():
    return [l for l in open(events).read().splitlines() if "RELEASE-STOPPED" in l] if os.path.exists(events) else []

def inbox_lines():
    return open(inbox).read().splitlines() if os.path.exists(inbox) else []

# Healthy: one hour since production changed is under the 2 h bound.
records(1, 101)
metrics = {}
found = release_age.collect(metrics, now, repo="maintainer/example", reader=reader)
v = metrics[release_age.METRIC]
check(v is not None and 0.9 < v < 1.1, f"healthy value {v}")
check(v < release_age.CRITERIA[release_age.METRIC][2], "1 h should be healthy")
release_age.alert(runtime, agent, repo_root, now, found)
check(stopped_lines() == [] and inbox_lines() == [], "healthy must not alert")

# Unhealthy: five hours without a production change is past the 4 h bound; one alert per episode.
records(5, 102)
metrics = {}
found = release_age.collect(metrics, now, repo="maintainer/example", reader=reader)
v = metrics[release_age.METRIC]
check(v is not None and 4.9 < v < 5.1 and v >= release_age.CRITERIA[release_age.METRIC][3], f"unhealthy value {v}")
release_age.alert(runtime, agent, repo_root, now, found)
release_age.alert(runtime, agent, repo_root, now + timedelta(hours=1), found)
check(len(stopped_lines()) == 1, f"episode should alert once, got {len(stopped_lines())}")
check(len(inbox_lines()) == 1, f"inbox should get once, got {len(inbox_lines())}")

# A new production record starts a new episode, so it alerts again.
records(4.5, 103)
metrics = {}
found = release_age.collect(metrics, now, repo="maintainer/example", reader=reader)
release_age.alert(runtime, agent, repo_root, now, found)
check(len(stopped_lines()) == 2, "new episode should alert again")

# Unreadable source: NO-DATA, never 0, and no alert.
metrics = {}
found = release_age.collect(metrics, now, repo="maintainer/example", reader=os.path.join(work, "unreadable-reader.sh"))
check(release_age.METRIC in metrics and metrics[release_age.METRIC] is None, f"unreadable must be None, got {metrics}")
check(found is None, "unreadable must return no record")
release_age.alert(runtime, agent, repo_root, now, found)
check(len(stopped_lines()) == 2, "NO-DATA must not alert")

# Paused: the value still reads, but PAUSE raises no alert.
open(os.path.join(agent, "PAUSE"), "w").write('{"caller":"operator"}')
records(6, 104)
metrics = {}
found = release_age.collect(metrics, now, repo="maintainer/example", reader=reader)
check(metrics[release_age.METRIC] > 5.9, "paused must still report the value")
release_age.alert(runtime, agent, repo_root, now, found)
check(len(stopped_lines()) == 2, "PAUSE must suppress the alert")
PY

echo "release-age.test.sh: ok"
