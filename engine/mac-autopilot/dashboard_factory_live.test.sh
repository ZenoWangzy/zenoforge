#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
python3 -I - "$script_dir" <<'PY'
import json, os, sys, tempfile
from datetime import datetime, timezone
sys.path.insert(0, sys.argv[1])
import dashboard_factory_live as live
import dashboard_repos

now = datetime(2026, 11, 27, 18, 0, tzinfo=timezone.utc).timestamp()
today = "2026-11-27"
with tempfile.TemporaryDirectory() as agent_home:
    luna = os.path.join(agent_home, "scratch", "luna")
    os.makedirs(luna)
    waiting = os.path.join(luna, "issue-2713-example")
    running = os.path.join(luna, "issue-2714-example")
    finished = os.path.join(luna, "issue-2715-example")
    for path in (waiting, running, finished):
        os.makedirs(path)
    for path, pid, age in ((waiting, 1234, 600), (running, 5678, 90), (finished, 9012, 1200)):
        pid_file = os.path.join(path, "wrapper.pid")
        with open(pid_file, "w", encoding="utf-8") as target:
            target.write(str(pid) + "\n")
        stamp = now - age
        os.utime(pid_file, (stamp, stamp))
    open(os.path.join(waiting, "gate-wait"), "w", encoding="utf-8").close()
    with open(os.path.join(finished, "rc"), "w", encoding="utf-8") as target:
        target.write("0\n")
    codex_only = os.path.join(luna, "issue-2718-codex-only")
    os.makedirs(codex_only)
    codex_pid = os.path.join(codex_only, "codex.pid")
    with open(codex_pid, "w", encoding="utf-8") as target:
        target.write("1122\n")
    os.utime(codex_pid, (now - 30, now - 30))
    log = os.path.join(agent_home, "zenoforge-dispatch.log")
    with open(log, "w", encoding="utf-8") as target:
        target.write("[2026-11-27T17:30:00Z] issue #2713 skipped: capacity detail\n")
        target.write("[2026-11-27T17:31:00Z] issue #2714 dispatched to worker\n")
    units = [
        {"id": "issue-2714", "pr": 321, "history": [{"at": "2026-11-27T17:45:00Z", "stage": "merged"}]},
        {"id": "issue-2716", "pr": 321, "history": [{"at": "2026-11-27T17:50:00Z", "stage": "merged"}]},
        {"id": "issue-2717", "pr": 320, "history": [{"at": "2026-11-26T23:50:00Z", "stage": "merged"}]},
    ]
    result = live.read_live(agent_home, units, now, today, lambda value: value[:10], lambda pid: int(pid) in {1234, 5678, 1122})
    version_engine = os.path.join(agent_home, "engine-versions", "6da8c7285e8b", "engine")
    os.makedirs(version_engine)
    os.symlink(version_engine, os.path.join(agent_home, "engine-live"))
    engine_pin = live.engine_live_pin(agent_home)
    line_pause = os.path.join(agent_home, "line-pause")
    with open(line_pause, "w", encoding="utf-8") as target:
        json.dump({"timestamp": "2026-11-27T17:00:00Z", "reason": "line maintenance"}, target)
    pause_states = live.read_pause_states(line_pause, os.path.join(agent_home, "factory-home", "PAUSE"), now)
    factory_pause = os.path.join(agent_home, "factory-home", "PAUSE")
    os.makedirs(os.path.dirname(factory_pause))
    with open(factory_pause, "w", encoding="utf-8") as target:
        json.dump({"timestamp": "2026-11-27T17:30:00Z", "reason": "factory maintenance"}, target)
    reverse_pauses = live.read_pause_states(os.path.join(agent_home, "missing-line-pause"), factory_pause, now)

workers = {row["key"]: row for row in result["luna_workers"]}
assert set(workers) == {"issue-2713-example", "issue-2714-example", "issue-2718-codex-only"}, workers
assert workers["issue-2713-example"]["issue"] == 2713, workers
assert workers["issue-2713-example"]["age_s"] == 600, workers
assert workers["issue-2713-example"]["state"] == "gate-wait", workers
assert workers["issue-2713-example"]["rc"] is None, workers
assert workers["issue-2714-example"]["state"] == "running", workers
assert workers["issue-2714-example"]["age_s"] == 90, workers
assert workers["issue-2714-example"]["started_at"] == "2026-11-27T17:58:30Z", workers
assert workers["issue-2718-codex-only"]["age_s"] == 30, workers
assert workers["issue-2718-codex-only"]["rc"] is None, workers
assert workers["issue-2718-codex-only"]["started_at"] == "2026-11-27T17:59:30Z", workers
assert result["fetched_at"] == "2026-11-27T18:00:00Z", result
assert [row["decision"] for row in result["dispatch_decisions"]] == ["skipped", "dispatched"], result
assert result["dispatch_decisions"][0]["at"] == "2026-11-27T17:30:00Z", result
assert result["dispatch_decisions"][0]["issue"] == 2713, result
assert "capacity detail" not in json.dumps(result), result
assert result["merge_lane_today"] == [321], result
assert engine_pin == "6da8c7285e8b"
assert pause_states["vecta_line"]["paused"] is True, pause_states
assert pause_states["vecta_line"]["since"] == "2026-11-27T17:00:00Z", pause_states
assert pause_states["zenoforge_factory"]["paused"] is False, pause_states
assert reverse_pauses["vecta_line"]["paused"] is False, reverse_pauses
assert reverse_pauses["zenoforge_factory"]["paused"] is True, reverse_pauses
front = {"search_counts": {"issues_open": 1, "stages": {"ready-for-agent": 1}, "prs_open": 1, "prs_merged_24h": 1}, "github": {"fetched_at": "2026-11-27T17:59:00Z"}}
sections = dashboard_repos.sections("public/example", "public/example", "public/example", [], front, lambda repo: ({}, {}, {}), result)
assert sections[0]["factory_live"] == result, sections
assert sections[0]["fetched_at"] == "2026-11-27T17:59:00Z", sections
print("dashboard_factory_live.test.sh: PASS")
PY
