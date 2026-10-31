#!/usr/bin/env bash
# waste_report.py: shared report window/source handling and token-owned report sections.
# Fixture only: no sleep, no clock, no network. Printed values are asserted at the report's CLI seam.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fail() { echo "waste_report.test.sh: $*" >&2; exit 1; }
a="$test_env_root/waste/autopi"; mkdir -p "$a/alerts"
audit="$test_env_root/waste/actions-run-cancellations.jsonl"
lesson_repo="$test_env_root/waste/repo"
mkdir -p "$lesson_repo/lessons"
printf '# Rules\n**V1** fixture rule\n' > "$lesson_repo/lessons/RULES.md"
export ZF_REPO_DIR="$lesson_repo"

# Shared scheduler logs set the default window; only the token report's common input sources remain here.
cat > "$a/scheduler.log.1" <<'LOG'
[2026-10-19T06:00:00Z] paused by /x/PAUSE: harvest/verify only, no dispatch or merge
[2026-10-19T07:40:00Z] tick done units=31 live=2 secs=200
LOG
cat > "$a/scheduler.log" <<'LOG'
[2026-10-20T01:00:00Z] tick done units=33 live=3 secs=300
[2026-10-20T03:00:00Z] tick done units=33 live=3 secs=500
[2026-10-21T06:00:00Z] paused by /x/PAUSE: harvest/verify only, no dispatch or merge
LOG
cat > "$audit" <<'JSON'
{"who":"u","when":"2026-10-20T01:10:00Z","run_id":"run-a","repo":"o/r","reason":"ci deferred"}
JSON
cat > "$a/ci-spend-cache.json" <<'JSON'
{"run-a":{"created":"2026-10-20T01:00:00Z","jobs":[["success",5.0]]}}
JSON

# Ledger rows feed the token-owned CI-repair and review sections.
cat > "$a/units.json" <<'JSON'
{"units":[
 {"id":"pr-1","pr":1,"branch":"agent/issue-11","stage":"merged","history":[
  {"stage":"pr-opened","result":"PR#1 aaa","at":"2026-10-19T05:00:00Z"},
  {"stage":"review-request-changes","at":"2026-10-19T06:00:00Z"},
  {"stage":"review-approve","at":"2026-10-19T07:00:00Z"},
  {"stage":"merge-issued","at":"2026-10-19T08:55:00Z"},
  {"stage":"merged","at":"2026-10-19T09:00:00Z"}]},
 {"id":"pr-2","pr":2,"branch":"agent/issue-12","stage":"landed","history":[
  {"stage":"orphan-registered","result":"open PR outside the ledger","at":"2026-10-19T05:30:00Z"},
  {"stage":"review-approve","at":"2026-10-19T10:00:00Z"},
  {"stage":"landed","at":"2026-10-19T10:30:00Z"}]},
 {"id":"pr-3","pr":3,"branch":"hand/x","stage":"merged","history":[
  {"stage":"review-approve","at":"2026-10-19T08:00:00Z"},
  {"stage":"review-request-changes","at":"2026-10-19T08:30:00Z"},
  {"stage":"review-approve","at":"2026-10-19T19:00:00Z"},
  {"stage":"merged","at":"2026-10-19T20:00:00Z"}]},
 {"id":"pr-4","pr":4,"branch":"agent/issue-13","stage":"ready-to-merge","history":[
  {"stage":"pr-reopened","result":"#3 -> #4 after merge revert","at":"2026-10-19T12:00:00Z"},
  {"stage":"review-approve","at":"2026-10-19T13:00:00Z"}]},
 {"id":"pr-5","pr":5,"branch":"agent/issue-14","stage":"review-pending","history":[
  {"stage":"pr-opened","at":"2026-10-20T00:00:00Z"}]},
 {"id":"pr-6","pr":6,"branch":"agent/issue-15","stage":"closed","history":[
  {"stage":"orphan-registered","result":"open PR outside the ledger","at":"2026-10-19T05:30:00Z"}]},
 {"id":"pr-7","pr":7,"branch":"hand/y","stage":"review-pending","history":[]},
 {"id":"pr-8","pr":8,"branch":"agent/issue-16","stage":"merged","history":[
  {"stage":"pr-opened","at":"2026-10-19T22:00:00Z"},
  {"stage":"review-approve","at":"2026-10-20T01:15:00Z"},
  {"stage":"merged","at":"2026-10-20T02:00:00Z"}]},
 {"id":"pr-9","pr":9,"branch":"agent/issue-17","stage":"merged","history":[
  {"stage":"pr-opened","at":"2026-10-19T22:00:00Z"},
  {"stage":"review-approve","at":"2026-10-20T03:30:00Z"},
  {"stage":"merged","at":"2026-10-20T05:00:00Z"}]},
 {"id":"pr-10","pr":10,"branch":"agent/issue-18","stage":"done","history":[
  {"stage":"pr-opened","at":"2026-10-20T03:00:00Z"}]},
 {"id":"issue-30","stage":"implement-pending","branch":"agent/issue-30","history":[]}]}
JSON

section() { awk -v h="$1" 'index($0,h)==1 && substr($0,length(h)+1,1) ~ /[ :]/ {p=1; print; next} /^[^ ]/ {p=0} p'; }
report() { python3 "$script_dir/waste_report.py" --runtime "$a" --audit "$audit" "$@"; }
expect_section() { # name metric-header expected-text [report args]: only that metric block must equal it
  local got; got="$(report "${@:4}" | section "$2")" || fail "$1: report failed"
  diff <(printf '%s\n' "$got") <(printf '%s\n' "$3") >&2 || fail "$1: $2 differs from the expected values (diff above: < got, > expected)"
}
# The retained command still reports the shared input window and token-owned T6/T7 sections.
base_report="$(report)" || fail 'report failed on the shared fixture'
grep -Fq 'window  2026-10-19T06:00:00Z .. 2026-10-21T06:00:00Z (2.00 days)' <<<"$base_report" || fail 'default window no longer spans both scheduler log files'
grep -Fq 'read    scheduler.log.1' <<<"$base_report" || fail 'rotated scheduler source not reported'
grep -Fq 'read    units.json' <<<"$base_report" || fail 'ledger source not reported'
grep -Fq 'read    audit' <<<"$base_report" || fail 'shared audit source not reported'
grep -Fq 'read    ci-spend-cache.json' <<<"$base_report" || fail 'T7 spend-cache source not reported'
grep -Fq 'T6 recorded baseline' <<<"$base_report" || fail 'recorded token baseline was removed'
grep -Fq 'T7 observed CI and review events' <<<"$base_report" || fail 'token-owned T7 section was removed'
! grep -Eq '^M(1|2|3|4|5|6|8|10|11|12|13) ' <<<"$base_report" || fail 'retired recurring CI metric section is still printed'

outcomes="$test_env_root/waste/outcomes"; mkdir -p "$outcomes/alerts"
cp -R "$a/alerts/." "$outcomes/alerts/"
repair_sessions="$test_env_root/waste/repair-sessions"; mkdir -p "$repair_sessions/2026/10/20"
cat > "$outcomes/scheduler.log" <<'LOG'
[2026-10-19T06:00:00Z] tick done units=3 live=1 secs=1
LOG
cat > "$outcomes/units.json" <<'JSON'
{"units":[
 {"id":"pr-1","pr":1,"stage":"merged","session_ids":{"repair":"11111111-2222-3333-4444-555555555555"},"history":[
  {"stage":"ci-red","result":"required check failed","at":"2026-10-19T06:10:00Z"},
  {"stage":"ci-red-update-branch","run_id":"run-a","at":"2026-10-19T06:11:00Z"},
  {"stage":"review-approve","at":"2026-10-19T07:00:00Z"},
  {"stage":"ci-red","result":"PR-owned failure","at":"2026-10-19T08:00:00Z"},
  {"stage":"repair-delivered","at":"2026-10-19T08:30:00Z"},
  {"stage":"review-request-changes","at":"2026-10-19T09:00:00Z"},
  {"stage":"review-approve","at":"2026-10-19T12:00:00Z"},
  {"stage":"merged","at":"2026-10-19T12:30:00Z"}],
  "review_findings":[{"at":"2026-10-19T09:00:00Z","block":"ok","findings":[]}]},
 {"id":"pr-2","pr":2,"stage":"merged","session_ids":{"repair":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"},"history":[
  {"stage":"review-request-changes","at":"2026-10-19T08:00:00Z"},
  {"stage":"review-request-changes","at":"2026-10-19T09:00:00Z"},
  {"stage":"review-request-changes","at":"2026-10-19T10:00:00Z"},
  {"stage":"advisor-ruling","at":"2026-10-19T10:05:00Z"},
  {"stage":"ci-red","result":"runner infrastructure timeout","at":"2026-10-19T10:30:00Z"},
  {"stage":"review-approve","at":"2026-10-19T11:00:00Z"},
  {"stage":"merged","at":"2026-10-19T11:30:00Z"}],
  "review_findings":[{"at":"2026-10-22T06:00:00Z","block":"missing","findings":[]}]},
 {"id":"pr-3","pr":3,"stage":"review-pending","session_ids":{"repair":"bbbbbbbb-cccc-dddd-eeee-ffffffffffff"},"history":[
  {"stage":"ci-red","result":"check failed","run_id":"run-b","at":"2026-10-19T13:00:00Z"},
  {"stage":"ci-red","result":"runner infrastructure timeout","at":"2026-10-19T13:10:00Z"},
  {"stage":"ci-red","result":"failing test log missing","at":"2026-10-19T13:20:00Z"},
  {"stage":"ci-red","result":"check failed","at":"2026-10-19T13:30:00Z"},
  {"stage":"review-request-changes","at":"2026-10-19T14:00:00Z"},
  {"stage":"review-request-changes","at":"2026-10-19T14:10:00Z"},
  {"stage":"review-request-changes","at":"2026-10-19T14:20:00Z"},
  {"stage":"advisor-unavailable","at":"2026-10-19T14:21:00Z"},
  {"stage":"arbiter-review","at":"2026-10-19T14:22:00Z"},
  {"stage":"review-request-changes","at":"2026-10-19T14:30:00Z"},
  {"stage":"review-request-changes","at":"2026-10-19T14:40:00Z"},
  {"stage":"review-request-changes","at":"2026-10-19T14:50:00Z"}]}
]}
JSON
python3 - "$repair_sessions/2026/10/20" <<'PY'
import json, os, sys

root = sys.argv[1]
sessions = [
    ("11111111-2222-3333-4444-555555555555", 800, 600, 300,
     {"type": "function_call", "name": "functions.apply_patch", "call_id": "patch-1", "arguments": "*** Begin Patch\n*** End Patch"}),
    ("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", 1800, 1300, 200,
     {"type": "function_call", "name": "functions.exec_command", "call_id": "shell-1", "arguments": json.dumps({"cmd": "printf 'fixed' > src/fix.ts"})}),
    ("bbbbbbbb-cccc-dddd-eeee-ffffffffffff", 2700, 2100, 300,
     {"type": "function_call", "name": "functions.exec_command", "call_id": "read-1", "arguments": json.dumps({"cmd": "rg -n '=>' src"})}),
]
for sid, input_tokens, cached, output, call in sessions:
    records = [
        {"type": "session_meta", "timestamp": "2026-10-20T02:40:00.000Z"},
        {"type": "event_msg", "timestamp": "2026-10-20T02:40:00.100Z", "payload": {"type": "task_started"}},
        {"type": "event_msg", "timestamp": "2026-10-20T02:40:00.200Z", "payload": {"type": "token_count", "info": {
            "last_token_usage": {"input_tokens": input_tokens, "cached_input_tokens": cached, "output_tokens": output},
            "total_token_usage": {"input_tokens": input_tokens, "cached_input_tokens": cached, "output_tokens": output}}}},
        {"type": "response_item", "timestamp": "2026-10-20T02:40:01.000Z", "payload": call},
    ]
    path = os.path.join(root, f"rollout-{sid}.jsonl")
    with open(path, "w", encoding="utf-8") as out:
        out.writelines(json.dumps(record) + "\n" for record in records)
PY
cat > "$outcomes/ci-spend-cache.json" <<'JSON'
{"run-a":{"created":"2026-10-19T06:00:00Z","jobs":[["success",5.0]]}}
JSON
cp "$audit" "$test_env_root/waste/outcomes-audit.jsonl"
printf '%s\n' '{"who":"u","when":"2026-10-19T13:00:00Z","run_id":"run-b","repo":"o/r","reason":"upstream workflow cancelled"}' >> "$test_env_root/waste/outcomes-audit.jsonl"
a_outcomes="$a"; audit_outcomes="$audit"
a="$outcomes"; audit="$test_env_root/waste/outcomes-audit.jsonl"
expect_section 'CI repair and review events come from the local ledger' T7 "$(cat <<'EXPECTED'
T7 observed CI and review events (2026-10-19T06:00:00Z .. 2026-10-23T00:00:00Z)
  CI repair events: 7; causes cancellation 1, stale-base 1, attributable 1, infrastructure 2, missing-log 1, unclassified 1 (fix-report pattern attribution is noisy)
  approvals: 3 events, 1 re-approvals across 2 units
  post-approval repair: 1 of 2 approved units; 0 needed three or more
  approve to merge: median 0.5h, p90 0.5h across 2 approvals
  review rejections: 10 across 3 units; six or more 1 of 3
  findings-block coverage: before Claude reviews 1/1 (100.0%); since Claude switch 0/1 (0.0%)
  verdicts: approve 3, request-changes 10, block 0; stale-base hops 1
  CI runner minutes: 5.0 across 1 of 2 linked runs
  third rejections: 3; advisor rulings 1, unavailable 1, arbiter fallbacks 1
EXPECTED
)" --since 2026-10-19T06:00:00Z --until 2026-10-23T00:00:00Z
expect_section 'Codex CI repair turns split patch calls from shell writes and no writes' 'T8 linked Codex CI-repair turns' "$(cat <<'EXPECTED'
T8 linked Codex CI-repair turns: 3 turns, 6,100 raw, 2,100 fresh (the ledger keeps one repair session per unit; an earlier session replaced by a fresh retry is not linked)
  no patch call: 2 turns, 5,000 raw, 1,600 fresh
  no write call observed: 1 turn, 3,000 raw, 900 fresh; shell writes among no-patch turns: 1
EXPECTED
)" --since 2026-10-19T06:00:00Z --until 2026-10-23T00:00:00Z --codex-sessions "$repair_sessions"
a="$a_outcomes"; audit="$audit_outcomes"

expect_section 'recorded CI repair, approval and review baseline' T6 "$(cat <<'EXPECTED'
T6 recorded baseline, 2026-10-20 through 2026-10-23 (fixed reference figures, not measured by this run; T7 and T8 below are measured)
  CI repairs: 346 turns, 2,425M raw, 91.7M fresh
  no patch call: 156 turns, 663M raw, 31.4M fresh; no write: 115 turns; about 41 wrote through the shell
  causes: cancellation, stale-base, attributable, infrastructure, missing-log, unclassified (fix-report pattern attribution is noisy)
  approval churn: 667 approvals, 473 re-approvals; 133 of 194 approved units needed another repair, 66 needed three or more
  approve to merge: median 13.3h, p90 39.9h
  review loop: six or more rejections 35 of 235 units; rounds after five 15.6% raw, 15.7% fresh
  findings-block coverage: 36% before Claude reviews, 19% since the Claude switch
EXPECTED
)"

# Explicit windows keep the shared source reads and narrow the token-owned event output.
narrow="$(report --since 2026-10-20T00:00:00Z --until 2026-10-20T02:30:00Z)" || fail 'report failed on an explicit window'
grep -Fq 'window  2026-10-20T00:00:00Z .. 2026-10-20T02:30:00Z (0.10 days)' <<<"$narrow" || fail 'explicit window was not applied'
grep -Fq 'read    scheduler.log.1' <<<"$narrow" || fail 'explicit window stopped reporting the common scheduler source'
grep -Fq 'read    ci-spend-cache.json' <<<"$narrow" || fail 'explicit window stopped reporting T7 spend-cache source'
grep -Fq 'T7 observed CI and review events (2026-10-20T00:00:00Z .. 2026-10-20T02:30:00Z)' <<<"$narrow" || fail 'T7 did not use the explicit window'

# Before the first rotation there is no scheduler.log.1: the report says so and uses the live file alone.
a_unrotated="$test_env_root/waste/unrotated"; mkdir -p "$a_unrotated"; cp -R "$a/." "$a_unrotated/"; rm "$a_unrotated/scheduler.log.1"
python3 "$script_dir/waste_report.py" --runtime "$a_unrotated" --audit "$audit" | grep -Fxq 'read    scheduler.log.1     absent' \
  || fail 'a missing rotated log is not reported as absent'
python3 "$script_dir/waste_report.py" --runtime "$a_unrotated" --audit "$audit" | grep -Fxq 'window  2026-10-20T01:00:00Z .. 2026-10-21T06:00:00Z (1.21 days)' \
  || fail 'the window does not start at the live log when there is no rotated one'

# The report only reads: against a read-only copy it succeeds and leaves every file as it was.
a_readonly="$test_env_root/waste/readonly"; mkdir -p "$a_readonly"; cp -R "$test_env_root/waste/autopi" "$a_readonly/autopi"; cp "$audit" "$a_readonly/audit.jsonl"
cp -R "$a_readonly" "$test_env_root/waste/pristine"
chmod -R a-w "$a_readonly"
python3 "$script_dir/waste_report.py" --runtime "$a_readonly/autopi" --audit "$a_readonly/audit.jsonl" > /dev/null || fail 'report failed on a read-only copy'
diff -r "$a_readonly" "$test_env_root/waste/pristine" || fail 'the report changed a file'
chmod -R u+w "$a_readonly"

# Poll and document measurements use the same Codex rollout reader as T1-T3. Empty writes are
# polls; nonempty stdin input does not belong in the poll count.
analytics="$test_env_root/waste/analytics"; sessions="$test_env_root/waste/codex-sessions"
mkdir -p "$analytics" "$sessions/2026/10/20"
cp -R "$a/." "$analytics/"
poll_session=11111111-2222-3333-4444-555555555555
python3 - "$sessions" "$analytics/units.json" "$poll_session" <<'PY'
import json, os, sys

sessions, units_path, sid = sys.argv[1:]
path = os.path.join(sessions, "2026", "10", "20", f"rollout-{sid}.jsonl")
direct_sid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

def token_count(at, input_tokens, cached, output):
    return {"type": "event_msg", "timestamp": at, "payload": {"type": "token_count", "info": {
        "last_token_usage": {"input_tokens": input_tokens, "cached_input_tokens": cached, "output_tokens": output},
        "total_token_usage": {"input_tokens": 300, "cached_input_tokens": 100, "output_tokens": 30}}}}

def call(at, call_id, args, custom=False):
    payload = {"type": "custom_tool_call", "name": "write_stdin", "call_id": call_id, "input": json.dumps(args)} \
        if custom else {"type": "function_call", "name": "functions.write_stdin", "call_id": call_id,
                        "arguments": json.dumps(args)}
    return {"type": "response_item", "timestamp": at, "payload": payload}

def result(at, call_id, session_id, custom=False):
    output = [{"type": "text", "text": f"Process running with session ID {session_id}"}] if custom \
        else {"output": "", "session_id": session_id}
    kind = "custom_tool_call_output" if custom else "function_call_output"
    return {"type": "response_item", "timestamp": at, "payload": {"type": kind, "call_id": call_id, "output": output}}

records = [
    {"type": "session_meta", "timestamp": "2026-10-20T02:40:00.000Z"},
    {"type": "event_msg", "timestamp": "2026-10-20T02:40:00.100Z", "payload": {"type": "task_started"}},
    call("2026-10-20T02:40:01.100Z", "poll-1", {"session_id": "bg-1", "chars": "", "yield_time_ms": 5000}),
    token_count("2026-10-20T02:40:01.200Z", 40, 10, 5),
    result("2026-10-20T02:40:06.100Z", "poll-1", "bg-1"),
    token_count("2026-10-20T02:40:07.000Z", 60, 20, 10),
    call("2026-10-20T02:40:07.100Z", "poll-2", {"session_id": "bg-1", "chars": "", "yield_time_ms": 10000}, custom=True),
    result("2026-10-20T02:40:17.100Z", "poll-2", "bg-1", custom=True),
    token_count("2026-10-20T02:40:18.000Z", 80, 30, 20),
    call("2026-10-20T02:40:18.100Z", "stdin-data", {"session_id": "bg-1", "chars": "input", "yield_time_ms": 1000}),
    result("2026-10-20T02:40:18.200Z", "stdin-data", "bg-1"),
    token_count("2026-10-20T02:40:19.000Z", 300, 100, 30),
]
for index, command in enumerate(("cat docs/agents/issue-tracker.md",
                                 "sed -n '1,20p' docs/agents/branch-delivery-preflight.md",
                                 "rg -n '^name:' .agents/skills/ask-matt/SKILL.md",
                                 "sed -n '1,20p' docs/agents/development-flow.md")):
    call_id = f"read-product-{index}"
    at_seconds = 20 + index
    records.append({"type": "response_item", "timestamp": f"2026-10-20T02:40:{at_seconds:02d}.000Z",
                    "payload": {"type": "function_call", "name": "functions.exec_command", "call_id": call_id,
                                "arguments": json.dumps({"cmd": command})}})
    records.append({"type": "response_item", "timestamp": f"2026-10-20T02:40:{at_seconds:02d}.100Z",
                    "payload": {"type": "function_call_output", "call_id": call_id, "output": "document text"}})
with open(path, "w", encoding="utf-8") as out:
    out.writelines(json.dumps(row) + "\n" for row in records)

direct_path = os.path.join(sessions, "2026", "10", "20", f"rollout-{direct_sid}.jsonl")
direct_records = [
    {"type": "session_meta", "timestamp": "2026-10-20T02:40:30.000Z"},
    {"type": "event_msg", "timestamp": "2026-10-20T02:40:30.100Z", "payload": {"type": "task_started"}},
    token_count("2026-10-20T02:40:31.000Z", 100, 40, 20),
    {"type": "response_item", "timestamp": "2026-10-20T02:40:32.000Z", "payload": {
        "type": "function_call", "name": "functions.exec_command", "call_id": "read-pipeline",
        "arguments": json.dumps({"cmd": "cat docs/agents/issue-pipeline.md"})}},
    {"type": "response_item", "timestamp": "2026-10-20T02:40:32.100Z", "payload": {
        "type": "function_call_output", "call_id": "read-pipeline", "output": "document text"}},
    token_count("2026-10-20T02:40:33.000Z", 140, 60, 25),
]
with open(direct_path, "w", encoding="utf-8") as out:
    out.writelines(json.dumps(row) + "\n" for row in direct_records)

with open(units_path, encoding="utf-8") as source:
    units = json.load(source)
units["units"].append({"id": "poll-fixture", "lane": "pr", "session_ids": {"repair": sid}})
units["units"].append({"id": "direct-fixture", "lane": "direct-main", "session_ids": {"repair": direct_sid}})
with open(units_path, "w", encoding="utf-8") as out:
    json.dump(units, out)
PY
tokens_json="$test_env_root/waste/tokens.json"
analytics_report="$(python3 "$script_dir/waste_report.py" --runtime "$analytics" --audit "$audit" \
  --codex-sessions "$sessions" --tokens-json "$tokens_json" --since 2026-10-20T02:40:00Z --until 2026-10-20T02:41:00Z)" \
  || fail 'report failed while reading Codex rollouts for poll metrics'
poll_section="$(awk '$0 ~ /^T4 / { printing = 1 } printing && /^[^ ]/ && $0 !~ /^T4 / { exit } printing { print }' <<<"$analytics_report")"
diff <(printf '%s\n' "$poll_section") <(cat <<'EXPECTED'
T4 empty-input polls: 2 filtered (historical unfiltered baseline 19,466)
  yield histogram: 5s 1, 10s 1
  under 30 seconds: 2 of 2 polls with recorded yields (100.0%)
  full-wait under 30 seconds: 2 polls, 0.00417 hours
  raw/fresh tokens resent: 115 / 85
  30-second counterfactuals: 2 full-wait polls become 1; 1 fewer, raw/fresh saved 70 / 50
EXPECTED
) >&2 || fail 'empty-input poll metrics differ from the Codex rollout fixture'
jq -e '.empty_input_polls == {
  "count":2,
  "historical_unfiltered":19466,
  "yield_histogram_ms":{"5000":1,"10000":1},
  "under_30_seconds":{"count":2,"eligible":2,"share":1.0},
  "full_wait_small_yield":{"count":2,"hours":0.004166666666666667,"raw":115,"fresh":85},
  "raw_resent":115,
  "fresh_resent":85,
  "priced_polls":2,
  "counterfactuals":{"30_seconds":{"polls":1,"avoided_polls":1,"raw_saved":70,"fresh_saved":50}}
}' "$tokens_json" >/dev/null || { jq '.empty_input_polls' "$tokens_json" >&2; fail 'poll metrics were not carried into tokens JSON'; }
document_section="$(awk '$0 ~ /^T5 / { printing = 1 } printing && /^[^ ]/ && $0 !~ /^T5 / { exit } printing { print }' <<<"$analytics_report")"
diff <(printf '%s\n' "$document_section") <(cat <<'EXPECTED'
T5 scoped document reads by lane (unique sessions / lane sessions)
  product (1 sessions)
    issue tracker                   1/1 (100.0%)
    branch delivery preflight       1/1 (100.0%)
    Matt entry skill                1/1 (100.0%)
    development flow                1/1 (100.0%)
    issue pipeline                  0/1 (0.0%)
  direct-main (1 sessions)
    issue tracker                   0/1 (0.0%)
    branch delivery preflight       0/1 (0.0%)
    Matt entry skill                0/1 (0.0%)
    development flow                0/1 (0.0%)
    issue pipeline                  1/1 (100.0%)
EXPECTED
) >&2 || fail 'scoped document reads were not reported by lane'
jq -e '.scoped_document_reads == {
  "product":{"sessions":1,"documents":{
    "docs/agents/issue-tracker.md":{"read_sessions":1,"share":1.0},
    "docs/agents/branch-delivery-preflight.md":{"read_sessions":1,"share":1.0},
    ".agents/skills/ask-matt/SKILL.md":{"read_sessions":1,"share":1.0},
    "docs/agents/development-flow.md":{"read_sessions":1,"share":1.0},
    "docs/agents/issue-pipeline.md":{"read_sessions":0,"share":0.0}
  }},
  "direct-main":{"sessions":1,"documents":{
    "docs/agents/issue-tracker.md":{"read_sessions":0,"share":0.0},
    "docs/agents/branch-delivery-preflight.md":{"read_sessions":0,"share":0.0},
    ".agents/skills/ask-matt/SKILL.md":{"read_sessions":0,"share":0.0},
    "docs/agents/development-flow.md":{"read_sessions":0,"share":0.0},
    "docs/agents/issue-pipeline.md":{"read_sessions":1,"share":1.0}
  }}
}' "$tokens_json" >/dev/null || fail 'document read metrics were not carried into tokens JSON'

echo 'waste_report.test.sh: PASS'
