#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# live_workers.collect：只列 /proc 上还活着的 pipeline worker，owner 由单元名推断
python3 -I - "$script_dir" <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); import live_workers as L
import os, tempfile
hd = tempfile.mkdtemp(); os.makedirs(hd + "/.scratch/hotfix/wt")
os.chdir(hd + "/.scratch/hotfix/wt")
os.makedirs(hd + "/cg/u"); open(hd + "/cg/u/cgroup.procs", "w").write(str(os.getpid()))
assert L._under_hotfix("/u", hd + "/cg") and not L._under_hotfix("/nope", hd + "/cg")
# 进程已退出时，.scratch/hotfix/wt-<key 去掉 -rN> 目录存在也算热修
os.makedirs(hd + "/.scratch/hotfix/wt-adr-x"); os.makedirs(hd + "/.scratch/luna")
L._active_units = lambda pats: ["luna-adr-x-r2-9.scope"]; L._unit_props = lambda names: {}
assert L.collect([], [], "example", hd + "/.scratch/luna", "/nonexistent")["items"][0]["owner"] == "hotfix"
L._active_units = lambda pats: ["luna-zc-opt-4779-9.scope", "vecta-release-batch-1.service", "opt-feeder.service", "luna-hotfix-x-3.scope"]
L._unit_props = lambda names: {}
L._active_units = lambda pats: ["luna-zc-opt-4779-9.scope", "vecta-release-batch-1.service", "opt-feeder.service", "luna-hotfix-x-3.scope"]
r = L.collect([{"alive": True, "unit": "u1", "type": "repair", "elapsed_min": 2}, {"alive": False, "unit": "u2"}],
              [{"id": "u1", "issue": 5, "title": "T", "pr": 9}], "example", "/nonexistent", "/nonexistent")
got = sorted((i["owner"], i["task"][:2]) for i in r["items"])
assert len(r["items"]) == 4 and got == [("hotfix", "ho"), ("opt", "op"), ("pipeline", "T"), ("release", "发布")], got
# 流量与 token：流水线 worker 用 wt:<工作树目录去掉 wt-> 取值，没见过的 worker 为 None
L._active_units = lambda pats: ["luna-zc-opt-i9-5.scope", "opt-i9.service", "opt-i8.service"]
L._unit_props = lambda names: {}
assert sorted(i["tip"].split(" · ")[0] for i in L.collect([], [], "example", "/nonexistent", "/nonexistent")["items"]) == ["i8", "opt-i9"]
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
PY
echo "live_workers.test.sh: PASS"
