#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# live_workers.collect：只列 /proc 上还活着的 pipeline worker，owner 由单元名推断
python3 -I - "$script_dir" <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); import live_workers as L
import os, subprocess, tempfile, time
hd = tempfile.mkdtemp(); os.makedirs(hd + "/.scratch/hotfix/wt")
os.chdir(hd + "/.scratch/hotfix/wt")
os.makedirs(hd + "/cg/u"); open(hd + "/cg/u/cgroup.procs", "w").write(str(os.getpid()))
assert L._under_hotfix("/u", hd + "/cg") and not L._under_hotfix("/nope", hd + "/cg")
# 进程已退出时，.scratch/hotfix/wt-<key 去掉 -rN> 目录存在也算热修
os.makedirs(hd + "/.scratch/hotfix/wt-adr-x"); os.makedirs(hd + "/.scratch/luna")
slice_fixture = hd + "/slice-1"; os.makedirs(slice_fixture + "/luna-adr-x-r2-9.scope")
os.environ["LUNA_WORKER_SLICE_DIR"] = slice_fixture
L._active_units = lambda pats: ["luna-adr-x-r2-9.scope"]; L._unit_props = lambda names: {}
assert L.collect([], [], "example", hd + "/.scratch/luna", "/nonexistent")["items"][0]["owner"] == "hotfix"
slice_fixture = hd + "/slice-2"; os.makedirs(slice_fixture + "/luna-zc-opt-4779-9.scope"); os.makedirs(slice_fixture + "/luna-hotfix-x-3.scope")
os.environ["LUNA_WORKER_SLICE_DIR"] = slice_fixture
L._active_units = lambda pats: ["vecta-release-batch-1.service", "opt-feeder.service"]
L._unit_props = lambda names: {}
r = L.collect([{"alive": True, "unit": "u1", "type": "repair", "elapsed_min": 2}, {"alive": False, "unit": "u2"}],
              [{"id": "u1", "issue": 5, "title": "T", "pr": 9}], "example", "/nonexistent", "/nonexistent")
got = sorted((i["owner"], i["task"][:2]) for i in r["items"])
assert len(r["items"]) == 4 and got == [("hotfix", "ho"), ("opt", "op"), ("pipeline", "T"), ("release", "发布")], got
# 流量与 token：流水线 worker 用 wt:<工作树目录去掉 wt-> 取值，没见过的 worker 为 None
slice_fixture = hd + "/slice-3"; os.makedirs(slice_fixture + "/luna-zc-opt-i9-5.scope")
os.environ["LUNA_WORKER_SLICE_DIR"] = slice_fixture
L._active_units = lambda pats: ["luna-zc-opt-i9-5.scope", "opt-i9.service", "opt-i8.service"]
L._unit_props = lambda names: {}
assert sorted(i["tip"].split(" · ")[0] for i in L.collect([], [], "example", "/nonexistent", "/nonexistent")["items"]) == ["i8", "opt-i9"]
slice_fixture = hd + "/slice-4"; os.makedirs(slice_fixture + "/luna-t-1.scope")
os.environ["LUNA_WORKER_SLICE_DIR"] = slice_fixture
L._active_units = lambda pats: ["luna-t-1.scope"]
r = L.collect([{"alive": True, "unit": "u1", "type": "repair", "workdir": "/h/autopilot-wt/wt-issue-1", "tokens": 5}], [], "example", "/nonexistent", "/nonexistent", "",
              {"wt:issue-1": {"rx": 7, "tx": 3}, "unit:luna-t-1.scope": {"rx": 1, "tx": 2}})
got = {i["owner"]: (i["tokens"], i["rx"], i["tx"]) for i in r["items"]}
assert got == {"pipeline": (5, 7, 3), "opt": (None, 1, 2)}, got
assert L.collect([{"alive": True, "unit": "u9"}], [], "example", "/nonexistent", "/nonexistent")["items"][0]["rx"] is None
# 实时 token：codex rollout 末尾累计、ZCode events 逐请求累加；没有来源时 None
import json
rd = tempfile.mkdtemp(); os.makedirs(rd + "/2026/10/30")
open(rd + "/2026/10/30/rollout-t-sess1.jsonl", "w").write('{"payload":{"cwd":"/w"}}\n' + "".join(json.dumps({"type": "event_msg", "payload": {"type": "token_count", "info": {"total_token_usage": {"input_tokens": i * 100, "output_tokens": i}}}}) + "\n" for i in (1, 2)))
p = L._rollout_for(rd, session_id="sess1")
assert L._tail_total(p) == 202 and L._tail_total(rd + "/nope") is None and L._rollout_for(rd, cwd="/w") == p and L._rollout_for(rd, cwd="/x") is None
assert L._worker_tokens({"session_id": "sess1", "token_usage_start": {"raw": 100}}, rd) == 102 and L._worker_tokens({"session_id": "zz"}, rd) is None
open(rd + "/ev.jsonl", "w").write('{"type":"x"}\n' + "".join('{"payload":{"type": "model_request_completed", "usage": {"inputTokens": 1, "totalTokens": %d}}}\n' % n for n in (5, 7)))
assert L._zc_total(rd + "/ev.jsonl") == 12 and L._zc_total(rd + "/none") is None
# 步骤轨道按真实类型：repair 在第 3 步，supervise 单步
r = L.collect([{"alive": True, "unit": "a", "type": "repair"}, {"alive": True, "unit": "b", "type": "supervise"}], [], "example", "/nonexistent", "/nonexistent")
assert [(i["steps"][i["step"]], len(i["steps"])) for i in r["items"][:2]] == [("repair", 5), ("supervise", 1)], r["items"][:2]
slice_dir = tempfile.mkdtemp(); scratch = tempfile.mkdtemp(); luna_dir = scratch + "/luna"; slots = scratch + "/tmp/luna-slots"
os.makedirs(luna_dir); os.makedirs(slots)
repos = {"zen": ("ZenoWangzy/zenoforge", "luna-issue-1537-101.scope"), "other": ("example-maintainer/other-repo", "zc-issue-77-202.scope")}
children = []
try:
    for key, (slug, scope) in repos.items():
        clone = hd + "/clone-" + key; os.makedirs(clone)
        subprocess.run(["git", "init", "-q", clone], check=True)
        subprocess.run(["git", "-C", clone, "remote", "add", "origin", "https://github.com/" + slug + ".git"], check=True)
        child = subprocess.Popen(["sleep", "30"], cwd=clone); children.append(child)
        scope_dir = os.path.join(slice_dir, scope); os.makedirs(scope_dir)
        open(scope_dir + "/cgroup.procs", "w").write(str(child.pid))
    waiters = [("zen-wait", "normal", repos["zen"][0], int(time.time()) - 120),
               ("other-ahead", "hotfix", repos["other"][0], int(time.time()) - 60)]
    for key, priority, slug, ticket_time in waiters:
        clone = hd + "/wait-" + key; os.makedirs(clone)
        subprocess.run(["git", "init", "-q", clone], check=True)
        subprocess.run(["git", "-C", clone, "remote", "add", "origin", "https://github.com/" + slug + ".git"], check=True)
        child = subprocess.Popen(["sleep", "30"], cwd=clone); children.append(child)
        run_dir = os.path.join(luna_dir, key); os.makedirs(run_dir)
        open(run_dir + "/wrapper.pid", "w").write(str(child.pid))
        open(run_dir + "/gate-wait", "w").write(str(ticket_time))
        open(os.path.join(slots, f"wait-{priority}-{child.pid}"), "w").write(str(ticket_time))
    os.environ["LUNA_WORKER_SLICE_DIR"] = slice_dir
    os.environ["LUNA_SLOTS"] = slots
    os.environ["WORKER_SCRATCH_ROOT"] = scratch
    L._active_units = lambda pats: []
    uptime = float(open("/proc/uptime").read().split()[0])
    L._unit_props = lambda names: {name: {"Id": name, "ActiveEnterTimestampMonotonic": str(int((uptime - 300) * 1e6))} for name in names}
    rows = L.collect([], [], "example", luna_dir, "/nonexistent")["items"]
    actual = {(row.get("key"), row.get("repo"), row.get("waiting"), row.get("waiter_ahead")) for row in rows}
    assert ("issue-1537", "ZenoWangzy/zenoforge", False, None) in actual, actual
    assert ("issue-77", "example-maintainer/other-repo", False, None) in actual, actual
    assert ("zen-wait", "ZenoWangzy/zenoforge", True, "other-ahead") in actual, actual
    assert ("other-ahead", "example-maintainer/other-repo", True, None) in actual, actual
    assert all(isinstance(row.get("started_epoch"), int) for row in rows), rows
finally:
    for child in children:
        child.terminate(); child.wait()
PY
echo "live_workers.test.sh: PASS"
