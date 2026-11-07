#!/usr/bin/env bash
# founder_reqs.py: words come from ruling references else the issue title; a stage advances only on unit history,
# `released` plus live merge ancestry, a release-closer event or hotfix-live.jsonl; the first run is silent,
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
         {"id": "issue-2", "issue": 2, "stage": "merged", "merge_sha": "d" * 40, "history": []},
         {"id": "issue-7", "issue": "7", "title": "unit only", "stage": "blocked-external", "blocked_on": "9", "labels": ["focus"], "history": [{"stage": "write-end", "at": iso(5)}]},
         {"id": "issue-8", "issue": 8, "title": "closed unit", "stage": "closed", "labels": ["focus"]}]
rulings = [{"references": ["#1", "#4591–#4597", "memory:x.md"], "verbatim": "founder words"}]
acc = [{"issue": 3, "sha": "a" * 40, "at": iso(3600)}, {"issue": 5, "sha": "b" * 40, "at": iso(5 * 86400)}]
r = F.build(units, issues, rulings, acc, now, live_merge_shas={"d" * 40})
got = {i["issue"]: (i["stage"], i["text"], i["owner"], i["blocker"]) for i in r["items"]}
assert got == {1: (2, "founder words", "vecta-29", ""), 2: (3, "t2", "热修值班", ""), 3: (4, "t3", "未接单", ""), 7: (0, "unit only", "pipeline", "等 #9")}, got
assert [i["issue"] for i in r["items"]] == [7, 2, 1, 3] and not r["partial"]  # accepted last, newest issue first
assert F.build(units, None, rulings, acc, now)["partial"]
released_sha = "c" * 40
release_unit = {"id": "issue-2", "issue": 2, "stage": "merged", "merge_sha": released_sha, "history": []}
release_units = units + [release_unit]
not_live = F.build(release_units, issues, rulings, acc, now, live_merge_shas=set())
is_live = F.build(release_units, issues, rulings, acc, now, live_merge_shas={released_sha})
assert next(i for i in not_live["items"] if i["issue"] == 2)["stage"] == 2, "released label without live merge ancestry must stay at 进 main"
assert next(i for i in is_live["items"] if i["issue"] == 2)["stage"] == 3, "released label plus live merge ancestry reaches 上线"
# Auto-filed tickets leave the founder ledger even when they carry a founder label.
config_root = tempfile.mkdtemp()
os.makedirs(config_root, exist_ok=True)
json.dump({"anomaly_rules": {"production_logs": {"issue_title_prefix": "Configured anomaly: "}}},
          open(config_root + "/night.json", "w"))
os.environ["ZF_CONFIG_ROOT"] = config_root
auto_issues = [
    {"number": 20, "title": "founder requirement", "state": "OPEN", "labels": lab("founder-test")},
    {"number": 21, "title": "Incident: machine report", "state": "OPEN", "labels": lab("founder-test")},
    {"number": 22, "title": "factory-f1 machine report", "state": "OPEN", "labels": lab("focus")},
    {"number": 23, "title": "Configured anomaly: machine report", "state": "OPEN", "labels": lab("focus")},
    {"number": 24, "title": "machine report", "state": "OPEN", "labels": lab("founder-test", "auto-filed")},
    {"number": 25, "title": "machine report", "state": "OPEN", "labels": lab("focus", "incident")},
    {"number": 26, "title": "machine report", "state": "OPEN", "labels": lab("focus", "prod-anomaly")},
]
auto_units = [{"id": "issue-27", "issue": 27, "title": "Incident: unit-only machine report",
               "stage": "implement-pending", "labels": ["founder-test"]}]
auto_items = F.build(auto_units, auto_issues, [], [], now)["items"]
assert [item["issue"] for item in auto_items] == [20], auto_items
# hotfix-live.jsonl: the hotfix lane's event file moves a hotfix item to 热修生效; garbage lines skip, a missing file changes nothing
tmp = tempfile.mkdtemp(); hl = tmp + "/hotfix-live.jsonl"
issues6 = [{"number": 6, "title": "t6", "state": "OPEN", "labels": lab("hotfix")}]
st6 = lambda live: next(i for i in F.build(units, issues6, [], [], now, live)["items"] if i["issue"] == 6)
assert st6(F._hotfix_live(hl))["stage"] == 0  # missing file changes nothing
open(hl, "w").write('{"kind":"hotfix-live","issue":6,"pr":79,"sha":"7b2f7828c4c5","at":"%s","accepted_by":"oncall"}\nnot-json\n' % iso(600))
six = st6(F._hotfix_live(hl))
assert (six["stage"], six["verified_epoch"], six["owner"]) == (1, F._epoch(iso(600)), "热修值班"), six
# push: first run silent, later changes append once each. A stage change never mails the founder.
home = tempfile.mkdtemp(); lib = home + "/lib.sh"; st = home + "/state.json"
open(lib, "w").write(r'''supervisor_inbox_append_once() {
  [ "$1" != "${FAKE_INBOX_FAIL_KEY:-}" ] || return 1
  printf "%s\t%s\n" "$1" "$2" >> "$AGENT_HOME/inbox"
}
send_email_strict() { printf 'x\n' >> "$AGENT_HOME/mail-attempts"; }
send_email() { printf 'x\n' >> "$AGENT_HOME/mail-attempts"; }
''')
items = r["items"]
F.push_changes(items, st, lib, home); assert not os.path.exists(home + "/inbox")
items[2]["stage"] = 3; items.append({"issue": 9, "title": "new", "stage": 0})
F.push_changes(items, st, lib, home)
lines = open(home + "/inbox").read().splitlines()
assert [l.split("\t")[0] for l in lines] == ["freq-1-3", "freq-9-0"] and "进 main → 上线" in lines[0] and "新增 → 提出" in lines[1]
F.push_changes(items, st, lib, home); assert len(open(home + "/inbox").read().splitlines()) == 2
# A failed inbox append keeps the old stage and retries on the next beat.
partial_home = tempfile.mkdtemp(); partial_st = partial_home + "/state.json"
partial_items = [{"issue": n, "title": f"需求{n}", "stage": 0} for n in range(1, 4)]
F.push_changes(partial_items, partial_st, lib, partial_home)
for item in partial_items: item["stage"] = 1
os.environ["FAKE_INBOX_FAIL_KEY"] = "freq-2-1"
F.push_changes(partial_items, partial_st, lib, partial_home)
os.environ.pop("FAKE_INBOX_FAIL_KEY")
assert json.load(open(partial_st)) == {"1": 1, "2": 0, "3": 1}
F.push_changes(partial_items, partial_st, lib, partial_home)
assert json.load(open(partial_st)) == {"1": 1, "2": 1, "3": 1}
assert [line.split("\t")[0] for line in open(partial_home + "/inbox")] == ["freq-1-1", "freq-3-1", "freq-2-1"]
assert not os.path.exists(home + "/mail-attempts") and not os.path.exists(partial_home + "/mail-attempts")
# Founder ruling 2026-11-07: this file must not grow a mail path back.
source = open(os.path.join(sys.argv[1], "founder_reqs.py")).read()
assert not any(word in source for word in ("send_email", "需求进展", "PushNotification"))
PY
echo "founder_reqs.test.sh: PASS"
