#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fail() { echo "fork_rate.test.sh: $*" >&2; exit 1; }
python3 - "$script_dir" "$test_env_root" <<'FORK_RATE' || fail 'process-tree fork-rate sampling failed'
import os, sys
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

for name, delta, expected, want in (("high", 1800, 60.0, "UNHEALTHY"), ("low", 300, 10.0, "OK")):
    proc = base / name / "proc"; state = base / name / "node-health.json"
    os.environ["NODE_HEALTH_PROC_ROOT"] = str(proc)
    write_proc(proc, 10000, [manager, root])
    first, detail = fork_rate.sample(state, now=1000.0)
    assert first is None and status(first) == "NO-DATA", (first, detail)
    write_proc(proc, 10000 + delta, [manager, root, (300, "stat", 200, root[3])])
    value, detail = fork_rate.sample(state, now=1030.0)
    assert value == expected and status(value) == want, (value, status(value))
    assert detail == f"factory-watch.service (bash, 200): {expected:.1f}/s", detail

multi = base / "multi"; proc = multi / "proc"; state = multi / "node-health.json"
os.environ["NODE_HEALTH_PROC_ROOT"] = str(proc)
service_roots = [(200 + i, f"worker-{i}", 100,
                  f"/user.slice/user-1000.slice/user@1000.service/app.slice/service-{i}.service") for i in range(6)]
session_roots = [(800, "session-a", 100, "/user.slice/user-1000.slice/user@1000.service/app.slice/session-a.scope"),
                 (801, "session-b", 100, "/user.slice/user-1000.slice/user@1000.service/app.slice/session-b.scope")]
previous = [manager, *service_roots, *session_roots]
write_proc(proc, 20000, previous)
first, _ = fork_rate.sample(state, now=2000.0)
assert first is None
new_pids = [(300 + i, "fork", 200 + i, service_roots[i][3]) for i in range(6)]
new_pids += [(900, "fork", 800, session_roots[0][3]), (901, "fork", 801, session_roots[1][3])]
write_proc(proc, 27200, [*previous, *new_pids])
value, detail = fork_rate.sample(state, now=2030.0)
assert value == 60.0 and status(value) == "UNHEALTHY", (value, status(value))
assert detail.count(";") == 6 and "non-systemd (session-a, 800): 60.0/s" in detail, detail
for i in range(6):
    assert f"service-{i}.service (worker-{i}, {200 + i}): 30.0/s" in detail, detail
print("fork_rate attribution and first-sample NO-DATA: PASS")
FORK_RATE
