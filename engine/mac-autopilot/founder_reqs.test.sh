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
# push: first run silent, later changes append once each and share one mail
home = tempfile.mkdtemp(); lib = home + "/lib.sh"; st = home + "/state.json"
os.environ["NOTIFY_LIB"] = os.path.join(sys.argv[1], "..", "notify.sh")
open(lib, "w").write(r'''source "$NOTIFY_LIB"
_maintainer_email() { printf 'founder@example.invalid\n'; }
supervisor_inbox_append_once() {
  [ "$1" != "${FAKE_INBOX_FAIL_KEY:-}" ] || return 1
  printf "%s\t%s\n" "$1" "$2" >> "$AGENT_HOME/inbox"
}
send_email_strict() {
  subject="$1"; body="$2"; shift 2
  printf '%s\0%s\0%s\0' "$subject" "$body" "$*" >> "$AGENT_HOME/mail-attempts"
  if [ "$(maintainer_mail_rejection_reason progress "$subject" "$body")" != "" ] || [ "$FAKE_MAIL_FAIL" = 1 ]; then return 1; fi
  printf '%s\0%s\0' "$subject" "$body" >> "$AGENT_HOME/mail-sent"
}
''')
items = r["items"]
repo = "example-maintainer/example-repo"
F.push_changes(items, st, lib, home, repo); assert not os.path.exists(home + "/inbox") and not os.path.exists(home + "/mail-sent") and json.load(open(st))["1"] == 2
F.push_changes(items, st, lib, home); assert not os.path.exists(home + "/inbox") and not os.path.exists(home + "/mail-sent")
items[2]["stage"] = 3; items.append({"issue": 9, "title": "new", "stage": 0})
F.push_changes(items, st, lib, home, repo)
lines = open(home + "/inbox").read().splitlines()
assert [l.split("\t")[0] for l in lines] == ["freq-1-3", "freq-9-0"] and "进 main → 上线" in lines[0] and "新增 → 提出" in lines[1], lines
def mail_records(path, fields):
    if not os.path.exists(path): return []
    parts = open(path, "rb").read().decode().split("\0")
    return [tuple(parts[i:i + fields]) for i in range(0, len(parts) - 1, fields)]
sent = mail_records(home + "/mail-sent", 2)
attempts = mail_records(home + "/mail-attempts", 3)
assert sent == [
    ("需求进展：2项有变化", "进展：进 main 到 上线\n- founder words\nhttps://github.com/example-maintainer/example-repo/issues/1\n\n"
     "进展：新增 到 提出\n- new\nhttps://github.com/example-maintainer/example-repo/issues/9")
], sent
assert len(attempts) == 1 and all(a[2] == "--maintainer-kind progress founder@example.invalid" for a in attempts), attempts
F.push_changes(items, st, lib, home, repo); assert len(open(home + "/inbox").read().splitlines()) == 2 and len(mail_records(home + "/mail-sent", 2)) == 1
# A title rejected by the readable-content gate is retried once without its bullet.
items[-1]["title"] = "pipeline details"; items[-1]["stage"] = 1
F.push_changes(items, st, lib, home, repo)
sent = mail_records(home + "/mail-sent", 2); attempts = mail_records(home + "/mail-attempts", 3)
assert len(sent) == 2 and sent[-1] == ("需求进展：热修生效", "进展：提出 到 热修生效\nhttps://github.com/example-maintainer/example-repo/issues/9"), sent
assert len(attempts) == 3 and attempts[-2][1].endswith("- pipeline details\nhttps://github.com/example-maintainer/example-repo/issues/9") and attempts[-1][1] == sent[-1][1], attempts
# A transport failure does not block the inbox append or stage-state update.
items[-1]["title"] = "new"; items[-1]["stage"] = 2
os.environ["FAKE_MAIL_FAIL"] = "1"
F.push_changes(items, st, lib, home, repo)
os.environ.pop("FAKE_MAIL_FAIL")
assert json.load(open(st))["9"] == 2 and len(open(home + "/inbox").read().splitlines()) == 4
assert len(mail_records(home + "/mail-attempts", 3)) == 4 and len(mail_records(home + "/mail-sent", 2)) == 2
# Three changes in one beat produce three inbox lines and one mail accepted by the real content gate.
batch_home = tempfile.mkdtemp(); batch_st = batch_home + "/state.json"
batch_items = [{"issue": n, "title": f"需求{n}", "stage": 0} for n in range(1, 4)]
batch_items[0]["text"] = "创始人的第一句话\n\n第二句话"
F.push_changes(batch_items, batch_st, lib, batch_home, repo)
for item, stage in zip(batch_items, (1, 2, 3)): item["stage"] = stage
F.push_changes(batch_items, batch_st, lib, batch_home, repo)
assert len(open(batch_home + "/inbox").read().splitlines()) == 3
assert mail_records(batch_home + "/mail-sent", 2) == [(
    "需求进展：3项有变化",
    "进展：提出 到 热修生效\n- 创始人的第一句话 第二句话\nhttps://github.com/example-maintainer/example-repo/issues/1\n\n"
    "进展：提出 到 进 main\n- 需求2\nhttps://github.com/example-maintainer/example-repo/issues/2\n\n"
    "进展：提出 到 上线\n- 需求3\nhttps://github.com/example-maintainer/example-repo/issues/3",
)]
assert len(mail_records(batch_home + "/mail-attempts", 3)) == 1
# A failed batch send still records every successfully appended stage.
batch_items[0]["stage"] = 2; batch_items[1]["stage"] = 3
os.environ["FAKE_MAIL_FAIL"] = "1"
F.push_changes(batch_items, batch_st, lib, batch_home, repo)
os.environ.pop("FAKE_MAIL_FAIL")
F.push_changes(batch_items, batch_st, lib, batch_home, repo)
assert json.load(open(batch_st)) == {"1": 2, "2": 3, "3": 3}
assert len(open(batch_home + "/inbox").read().splitlines()) == 5
assert len(mail_records(batch_home + "/mail-sent", 2)) == 1 and len(mail_records(batch_home + "/mail-attempts", 3)) == 2
# A large beat keeps every inbox line but limits the mail to 20 blocks.
large_home = tempfile.mkdtemp(); large_st = large_home + "/state.json"
large_items = [{"issue": n, "title": f"需求{n}", "stage": 0} for n in range(1, 26)]
F.push_changes(large_items, large_st, lib, large_home, repo)
for item in large_items: item["stage"] = 1
F.push_changes(large_items, large_st, lib, large_home, repo)
assert len(open(large_home + "/inbox").read().splitlines()) == 25
assert json.load(open(large_st)) == {str(n): 1 for n in range(1, 26)}
large_sent = mail_records(large_home + "/mail-sent", 2)
assert len(large_sent) == 1 and large_sent[0][0] == "需求进展：25项有变化", large_sent
large_blocks = large_sent[0][1].split("\n\n")
assert len(large_blocks) == 21 and large_blocks[-1] == "另有 5 项变化，见首页。", large_blocks
assert large_blocks[:-1] == [f"进展：提出 到 热修生效\n- 需求{n}\nhttps://github.com/example-maintainer/example-repo/issues/{n}"
                             for n in range(1, 21)]
assert len(mail_records(large_home + "/mail-attempts", 3)) == 1
large_items[9]["title"] = "pipeline details"
for item in large_items: item["stage"] = 2
F.push_changes(large_items, large_st, lib, large_home, repo)
large_sent = mail_records(large_home + "/mail-sent", 2)
assert len(open(large_home + "/inbox").read().splitlines()) == 50
assert len(mail_records(large_home + "/mail-attempts", 3)) == 3 and len(large_sent) == 2
assert large_sent[-1] == ("需求进展：25项有变化", "\n\n".join([
    *(f"进展：热修生效 到 进 main\nhttps://github.com/example-maintainer/example-repo/issues/{n}" for n in range(1, 21)),
    "另有 5 项变化，见首页。",
]))
# A rejected title drops every title from the one retry, for either content rejection.
for bad_title in ("pipeline details", "The customer has not received their order"):
    retry_home = tempfile.mkdtemp(); retry_st = retry_home + "/state.json"
    retry_items = [{"issue": n, "title": title, "stage": 0}
                   for n, title in enumerate(("安全标题", bad_title, "另一标题"), 1)]
    F.push_changes(retry_items, retry_st, lib, retry_home, repo)
    for item in retry_items: item["stage"] = 1
    F.push_changes(retry_items, retry_st, lib, retry_home, repo)
    retry_attempts = mail_records(retry_home + "/mail-attempts", 3)
    retry_sent = mail_records(retry_home + "/mail-sent", 2)
    assert len(retry_attempts) == 2 and len(retry_sent) == 1
    assert bad_title in retry_attempts[0][1] and retry_sent == [(
        "需求进展：3项有变化", "\n\n".join(
            f"进展：提出 到 热修生效\nhttps://github.com/example-maintainer/example-repo/issues/{n}" for n in range(1, 4)))], retry_sent
    assert retry_attempts[1][1] == retry_sent[0][1]
# A failed inbox append is excluded from the batch and retried on the next beat.
partial_home = tempfile.mkdtemp(); partial_st = partial_home + "/state.json"
partial_items = [{"issue": n, "title": f"需求{n}", "stage": 0} for n in range(1, 4)]
F.push_changes(partial_items, partial_st, lib, partial_home, repo)
for item in partial_items: item["stage"] = 1
os.environ["FAKE_INBOX_FAIL_KEY"] = "freq-2-1"
F.push_changes(partial_items, partial_st, lib, partial_home, repo)
os.environ.pop("FAKE_INBOX_FAIL_KEY")
partial_sent = mail_records(partial_home + "/mail-sent", 2)
assert json.load(open(partial_st)) == {"1": 1, "2": 0, "3": 1}
assert [line.split("\t")[0] for line in open(partial_home + "/inbox")] == ["freq-1-1", "freq-3-1"]
assert len(partial_sent) == 1 and partial_sent[0][0] == "需求进展：2项有变化"
assert "issues/1" in partial_sent[0][1] and "issues/2" not in partial_sent[0][1] and "issues/3" in partial_sent[0][1]
F.push_changes(partial_items, partial_st, lib, partial_home, repo)
assert json.load(open(partial_st)) == {"1": 1, "2": 1, "3": 1}
assert [line.split("\t")[0] for line in open(partial_home + "/inbox")] == ["freq-1-1", "freq-3-1", "freq-2-1"]
assert mail_records(partial_home + "/mail-sent", 2)[-1] == (
    "需求进展：热修生效", "进展：提出 到 热修生效\n- 需求2\nhttps://github.com/example-maintainer/example-repo/issues/2")
# A missing repo still records the change without attempting mail.
partial_items[0]["stage"] = 2
F.push_changes(partial_items, partial_st, lib, partial_home)
assert json.load(open(partial_st))["1"] == 2 and len(open(partial_home + "/inbox").read().splitlines()) == 4
assert len(mail_records(partial_home + "/mail-attempts", 3)) == 2
open(lib, "w").write("supervisor_inbox_append_once() { return 1; }\n")
items[2]["stage"] = 4; F.push_changes(items, st, lib, home, repo); assert json.load(open(st))["1"] == 3  # failed append is retried next beat
assert len(mail_records(home + "/mail-attempts", 3)) == 4
PY
echo "founder_reqs.test.sh: PASS"
