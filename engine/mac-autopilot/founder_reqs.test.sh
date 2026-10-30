#!/usr/bin/env bash
# founder_reqs.py: words come from ruling references else the issue title; a stage advances only on unit history,
# the `released` label, a release-closer event or the hotfix lane's hotfix-live.jsonl; the first run is silent,
# later stage changes append one inbox line each.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
python3 -I - "$script_dir" <<'PY'
import sys, os, tempfile, time, json; sys.path.insert(0, sys.argv[1]); import founder_reqs as F
now = time.time(); iso = lambda d: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - d))
lab = lambda *n: [{"name": x} for x in n]
issues = [{"number": 1, "title": "t1", "state": "OPEN", "labels": lab("focus")},
          {"number": 2, "title": "t2", "state": "OPEN", "labels": lab("hotfix", "released")},
          {"number": 3, "title": "t3", "state": "CLOSED", "labels": lab("founder-test")},
          {"number": 4, "title": "t4", "state": "CLOSED", "labels": lab("focus")},
          {"number": 5, "title": "t5", "state": "CLOSED", "labels": lab("focus")}]
units = [{"id": "issue-1", "issue": 1, "stage": "merged", "handed_off_to": "vecta-29", "history": [{"stage": "merged", "at": iso(100)}]},
         {"id": "issue-7", "issue": "7", "title": "unit only", "stage": "blocked-external", "blocked_on": "9", "labels": ["focus"], "history": [{"stage": "write-end", "at": iso(5)}]},
         {"id": "issue-8", "issue": 8, "title": "closed unit", "stage": "closed", "labels": ["focus"]}]
rulings = [{"references": ["#1", "#4591–#4597", "memory:x.md"], "verbatim": "founder words"}]
acc = [{"issue": 3, "sha": "a" * 40, "at": iso(3600)}, {"issue": 5, "sha": "b" * 40, "at": iso(5 * 86400)}]
r = F.build(units, issues, rulings, acc, now)
got = {i["issue"]: (i["stage"], i["text"], i["owner"], i["blocker"]) for i in r["items"]}
assert got == {1: (2, "founder words", "vecta-29", ""), 2: (3, "t2", "热修值班", ""), 3: (4, "t3", "未接单", ""), 7: (0, "unit only", "pipeline", "等 #9")}, got
assert [i["issue"] for i in r["items"]] == [7, 2, 1, 3] and not r["partial"]  # accepted last, newest issue first
assert F.build(units, None, rulings, acc, now)["partial"]
# hotfix-live.jsonl: the hotfix lane's event file moves a hotfix item to 热修生效; garbage lines skip, a missing file changes nothing
tmp = tempfile.mkdtemp(); hl = tmp + "/hotfix-live.jsonl"
issues6 = [{"number": 6, "title": "t6", "state": "OPEN", "labels": lab("hotfix")}]
st6 = lambda live: next(i for i in F.build(units, issues6, [], [], now, live)["items"] if i["issue"] == 6)
assert st6(F._hotfix_live(hl))["stage"] == 0  # missing file changes nothing
open(hl, "w").write('{"kind":"hotfix-live","issue":6,"pr":79,"sha":"7b2f7828c4c5","at":"%s","accepted_by":"oncall"}\nnot-json\n' % iso(600))
six = st6(F._hotfix_live(hl))
assert (six["stage"], six["verified_epoch"], six["owner"]) == (1, F._epoch(iso(600)), "热修值班"), six
# push: first run silent, later changes append once each
home = tempfile.mkdtemp(); lib = home + "/lib.sh"; st = home + "/state.json"
open(lib, "w").write('supervisor_inbox_append_once() { printf "%s\\t%s\\n" "$1" "$2" >> "$AGENT_HOME/inbox"; }\n')
items = r["items"]
F.push_changes(items, st, lib, home); assert not os.path.exists(home + "/inbox") and json.load(open(st))["1"] == 2
F.push_changes(items, st, lib, home); assert not os.path.exists(home + "/inbox")
items[2]["stage"] = 3; items.append({"issue": 9, "title": "new", "stage": 0})
F.push_changes(items, st, lib, home)
lines = open(home + "/inbox").read().splitlines()
assert [l.split("\t")[0] for l in lines] == ["freq-1-3", "freq-9-0"] and "进 main → 上线" in lines[0] and "新增 → 提出" in lines[1], lines
F.push_changes(items, st, lib, home); assert len(open(home + "/inbox").read().splitlines()) == 2
open(lib, "w").write("supervisor_inbox_append_once() { return 1; }\n")
items[2]["stage"] = 4; F.push_changes(items, st, lib, home); assert json.load(open(st))["1"] == 3  # failed append is retried next beat
PY
echo "founder_reqs.test.sh: PASS"
