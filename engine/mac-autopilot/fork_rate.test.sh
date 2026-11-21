#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fail() { echo "fork_rate.test.sh: $*" >&2; exit 1; }
python3 - "$script_dir" "$test_env_root" <<'FORK_RATE' || fail 'process-tree fork-rate sampling failed'
import json, os, shutil, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1]); import node_health as n; import fork_rate
base = Path(sys.argv[2]) / "fork-rate"
manager = (100, "systemd", 1, "/user.slice/user-1000.slice/user@1000.service")
root = (200, "bash", 100, "/user.slice/user-1000.slice/user@1000.service/app.slice/factory-watch.service")

def write_proc(path, count, rows):
    path.mkdir(parents=True, exist_ok=True)
    (path / "stat").write_text(f"cpu 1 0 0 1\nprocesses {count}\n")
    for pid, comm, ppid, cgroup in rows:
        proc = path / str(pid); proc.mkdir(exist_ok=True)
        (proc / "stat").write_text(f"{pid} ({comm}) S {ppid} 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n")
        (proc / "cgroup").write_text(f"0::{cgroup}\n")

def status(value):
    metric = "host.fork_rate_root_max"
    return n.score({metric: value}, {metric: n.CRITERIA[metric]})[0][7]

for name, delta, expected, want in (("high", 660, 60.0, "UNHEALTHY"), ("low", 110, 10.0, "OK")):
    proc = base / name / "proc"; state = base / name / "node-health.json"
    os.environ["NODE_HEALTH_PROC_ROOT"] = str(proc)
    write_proc(proc, 10000, [manager, root])
    first, detail, score_value = fork_rate.sample(state, now=1000.0)
    assert first is None and score_value is None and status(score_value) == "NO-DATA", (first, detail, score_value)
    new_pids = [(300 + i, "fork", root[0], root[3]) for i in range(delta)]
    write_proc(proc, 10000 + delta, [manager, root, *new_pids])
    value, detail, score_value = fork_rate.sample(state, now=1011.0)
    assert value == expected and score_value == expected and status(score_value) == want, (value, score_value, status(score_value))
    if expected > 20:
        assert f"factory-watch.service (bash, 200): {expected:.1f}/s" in detail, detail
        assert "total_rate: 60.0/s" in detail and "unattributed: 0.0/s (0%)" in detail, detail
    else:
        assert "factory-watch.service" not in detail and "total_rate: 10.0/s" in detail, detail

stale = base / "stale"; proc = stale / "proc"; state = stale / "node-health.json"
os.environ["NODE_HEALTH_PROC_ROOT"] = str(proc)
write_proc(proc, 10000, [manager, root])
fork_rate.sample(state, now=1000.0)
write_proc(proc, 11800, [manager, root])
value, detail, score_value = fork_rate.sample(state, now=4600.0)
assert value is None and score_value is None and status(score_value) == "NO-DATA", (value, detail, score_value)
assert json.loads((stale / "node-health-fork-rate-state.json").read_text())["sampled_at"] == 4600.0

exited = base / "exited"; proc = exited / "proc"; state = exited / "node-health.json"
os.environ["NODE_HEALTH_PROC_ROOT"] = str(proc)
write_proc(proc, 10000, [manager, root])
fork_rate.sample(state, now=5000.0)
transient = [(300 + i, "fork", root[0], root[3]) for i in range(660)]
write_proc(proc, 10660, [manager, root, *transient])
for pid, *_ in transient:
    shutil.rmtree(proc / str(pid))
write_proc(proc, 11800, [manager, root])
value, detail, score_value = fork_rate.sample(state, now=5011.0)
assert value == 0.0 and score_value == 60.0 and status(score_value) == "UNHEALTHY", (value, score_value, status(score_value))
assert "total_rate: 60.0/s" in detail and "unattributed: 60.0/s (100%)" in detail, detail

sparse = base / "sparse"; proc = sparse / "proc"; state = sparse / "node-health.json"
os.environ["NODE_HEALTH_PROC_ROOT"] = str(proc)
write_proc(proc, 10000, [manager, root])
fork_rate.sample(state, now=6000.0)
write_proc(proc, 11800, [manager, root, (300, "fork", root[0], root[3])])
value, detail, score_value = fork_rate.sample(state, now=6011.0)
assert abs(value - 1 / 11) < 1e-9 and abs(score_value - 1799 / 11) < 1e-9, (value, score_value)
assert status(score_value) == "UNHEALTHY" and "factory-watch.service (bash, 200): 0.1/s" in detail, detail

multi = base / "multi"; proc = multi / "proc"; state = multi / "node-health.json"
os.environ["NODE_HEALTH_PROC_ROOT"] = str(proc)
service_roots = [(200 + i, f"worker-{i}", 100,
                  f"/user.slice/user-1000.slice/user@1000.service/app.slice/service-{i}.service") for i in range(6)]
session_roots = [(800, "session-a", 100, "/user.slice/user-1000.slice/user@1000.service/app.slice/session-a.scope"),
                 (801, "session-b", 100, "/user.slice/user-1000.slice/user@1000.service/app.slice/session-b.scope")]
previous = [manager, *service_roots, *session_roots]
write_proc(proc, 20000, previous)
first, _, _ = fork_rate.sample(state, now=2000.0)
assert first is None
new_pids = []
for i, service_root in enumerate(service_roots):
    new_pids += [(3000 + i * 330 + j, "fork", service_root[0], service_root[3]) for j in range(330)]
new_pids += [(6000 + i, "fork", session_roots[i // 330][0], session_roots[i // 330][3]) for i in range(660)]
write_proc(proc, 22640, [*previous, *new_pids])
value, detail, score_value = fork_rate.sample(state, now=2011.0)
assert value == 60.0 and score_value == 60.0 and status(score_value) == "UNHEALTHY", (value, score_value, status(score_value))
assert "non-systemd (session-a, 800): 60.0/s" in detail, detail
for i in range(6):
    assert f"service-{i}.service (worker-{i}, {200 + i}): 30.0/s" in detail, detail
assert "total_rate: 240.0/s" in detail and "unattributed: 0.0/s (0%)" in detail, detail
print("fork_rate attribution, stale sample, exited PID, and first-sample NO-DATA: PASS")
FORK_RATE
