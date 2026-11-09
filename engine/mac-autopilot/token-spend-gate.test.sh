#!/usr/bin/env bash
# Token spend gate: per-run fresh tokens recorded as the dashboard counts them, a soft park with one arbiter decision and one refill,
# a hard park no ruling lifts, and the supervisor.token_parks_24h metric.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/token-spend-gate"
sup="$fixture/supervisor"
mkdir -p "$sup/autopi/alerts" "$fixture/repo/engine/prompts" "$fixture/bin"
jq '.auto_merge = false | .advisor = false | .precheck = false | .supervisor_arbiter.enabled = true | .supervisor_arbiter.cap_triage = false' \
  "$script_dir/config.template.json" > "$sup/autopi/config.json"
echo '{"units":[]}' > "$sup/autopi/units.json"
echo '{"workers":[]}' > "$sup/autopi/workers.json"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$sup" MAC_AUTOPILOT_RUNTIME_DIR="$sup/autopi"
export ZF_CONFIG_ROOT="$fixture/repo/.zenoforge"
mkdir -p "$ZF_CONFIG_ROOT/prompts"
cp "$script_dir/../prompts/supervisor-arbiter.md" "$ZF_CONFIG_ROOT/prompts/supervisor-arbiter.md"
cp "$script_dir/../prompts/review-contract.md" "$ZF_CONFIG_ROOT/prompts/review-contract.md"
export CODEX_SESSIONS_DIR="$fixture/sessions" CLAUDE_PROJECTS_DIR="$fixture/claude-projects" ZCODE_DB="$fixture/none.sqlite"
export REQUIRED_PR_CHECKS_FILE="$fixture/required-pr-checks.json"
printf '%s\n' '{"required":[],"current_regression":"","legacy_regression":[]}' > "$REQUIRED_PR_CHECKS_FILE"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$script_dir/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY
SCHED_LOCK_HELD=true

fail() { echo "token-spend-gate.test.sh: $*" >&2; exit 1; }
field() { jq -r --arg id "$1" ".units[] | select(.id==\$id) | $2" "$UNITS"; }
cancel_unit_runs() { :; }
decision_eval_stages() { printf '\n'; }
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture/bin/codex"; chmod +x "$fixture/bin/codex"; export PATH="$fixture/bin:$PATH"
INBOX="$fixture/inbox"; : > "$INBOX"
SCHEDULER_AGENT_LIB="$fixture/agent-lib.sh"
printf 'supervisor_inbox_append_once() { grep -Fqx "$1" %q.keys 2>/dev/null || { echo "$1" >> %q.keys; echo "$2" >> %q; }; }\n' "$INBOX" "$INBOX" "$INBOX" > "$SCHEDULER_AGENT_LIB"
[[ "$TOKEN_PARK_SOFT_TOKENS:$TOKEN_PARK_HARD_TOKENS" == 1200000:2400000 ]] || fail "config defaults must be 1200000 and 2400000"

# ---- 1. every phase is recorded, and the total equals the dashboard's ----
codex_run() { # file input cached output
  printf '%s\n%s\n' '{"type":"thread.started","thread_id":"aaaaaaaa-0000-0000-0000-000000000001"}' \
    "{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":$2,\"cached_input_tokens\":$3,\"output_tokens\":$4}}" > "$sup/$1"
}
impl=impl-issue-1-20261105T100000Z.worker.log; rev=review-11-20261105T110000Z.worker.log
fix=impl-issue-1-fix-20261105T120000Z.worker.log; self=impl-issue-1-selfcheck1-fix-20261105T130000Z.worker.log
sv=supervise-issue-1-20261105T140000Z.worker.log; live=impl-issue-1-20261105T150000Z.worker.log
codex_run "$impl" 1000000 600000 50000
printf '%s\n' '{"type":"event"}' '{"type":"result","usage":{"input_tokens":100000,"cache_read_input_tokens":40000,"cache_creation_input_tokens":10000,"output_tokens":5000}}' > "$sup/$rev"
codex_run "$fix" 500000 200000 30000
printf 'codex\ntokens used\n300,000\ndone\n' > "$sup/$self"   # legacy footer: no cache split, so no fresh tokens
codex_run "$sv" 400000 250000 20000
codex_run "$live" 9000000 0 9000000                           # still running: never recorded
for f in "$impl" "$rev" "$fix" "$self" "$sv" "$live"; do touch -d 2026-11-05T16:00:00Z "$sup/$f"; done
jq -n --arg i "$impl" --arg f "$fix" --arg s "$self" --arg v "$sv" --arg l "$live" '{workers:[
 {pid:0,log:$i,unit:"issue-1",type:"implement",mode:"fresh",harvested:true,started:"2026-11-05T10:00:00Z"},
 {pid:0,log:$f,unit:"issue-1",type:"repair",mode:"fresh",harvested:true,started:"2026-11-05T12:00:00Z"},
 {pid:0,log:$s,unit:"issue-1",type:"repair",mode:"fresh",harvested:true,started:"2026-11-05T13:00:00Z"},
 {pid:0,log:$v,unit:"issue-1",type:"supervise",mode:"fresh",harvested:true,started:"2026-11-05T14:00:00Z"},
 {pid:0,log:$l,unit:"issue-1",type:"implement",mode:"fresh",harvested:false,started:"2026-11-05T15:00:00Z"}]}' > "$WORKERS"
jq -cn '{units:[{id:"issue-1",issue:1,pr:11,stage:"implement-pending",history:[{stage:"created",at:"2026-11-05T09:00:00Z"}]}]}' > "$UNITS"
record_run_spend
record_run_spend   # a second sweep adds nothing
[[ "$(field issue-1 '.spend_runs | length')" == 5 ]] || fail "five finished logs must be recorded once each: $(field issue-1 '.spend_runs | map(.log)')"
[[ "$(field issue-1 '[.spend_runs[].phase] | sort | join(",")')" == "implement,repair,review,self-fix,supervise" ]] \
  || fail "every phase must be recorded: $(field issue-1 '[.spend_runs[].phase]')"
gate_total="$(unit_fresh_tokens "$(jq -c '.units[0]' "$UNITS")")"
dash_total="$(python3 - "$script_dir" "$sup" "$UNITS" <<'PY'
import json, sys
from datetime import datetime, timezone
sys.path.insert(0, sys.argv[1])
import worker_cost, workorder_cost
units = json.load(open(sys.argv[3]))["units"]
rows = worker_cost.run_rows(sys.argv[2], finished_only=True)
worker_cost.attach_provider_usage(rows, units)
order = workorder_cost.work_orders(units, workorder_cost.unit_spend(rows), datetime(2026, 11, 6, tzinfo=timezone.utc))[0]
print(order["tokens"])
PY
)"
[[ "$gate_total" =~ ^[0-9]+$ && "$gate_total" -gt 900000 ]] || fail "recorded total looks wrong: $gate_total"
[[ "$gate_total" == "$dash_total" ]] || fail "gate total $gate_total != workorders tokens $dash_total"
[[ "$(field issue-1 '[.spend_runs[] | select(.phase == "self-fix")][0].fresh_tokens')" == 0 ]] || fail "a footer-only run adds no fresh tokens, as in unit_spend"

# ---- 2. the class comes from the unit's own history ----
cls() { token_park_class "$1"; }
[[ "$(cls '{"review_findings":[{"report":"incident-gate-a-T.md"},{"report":"engine-override-gate-a-T.md"}]}')" == report-gate-loop ]] || fail "two gate overrides = report-gate-loop"
[[ "$(cls '{"history":[{"stage":"merge-conflict","conflict_files":"engine/a.sh,engine/b.sh count=2"},{"stage":"merge-conflict","conflict_files":"engine/a.sh count=1"}]}')" == hot-file-churn ]] || fail "one file in two conflicts = hot-file-churn"
[[ "$(cls '{"history":[{"stage":"ci-test-red","tests":["engine/x.test.sh"]},{"stage":"merge-conflict","conflict_files":"engine/x.test.sh count=1"}]}')" == hot-file-churn ]] || fail "ci-test-red and merge-conflict on one file = hot-file-churn"
[[ "$(cls '{"history":[{"stage":"merge-conflict","conflict_files":"engine/a.sh count=1"},{"stage":"merge-conflict","conflict_files":"engine/b.sh count=1"}]}')" == unclassified ]] || fail "different files are not churn"
[[ "$(cls '{"history":[{"stage":"supervisor-escalated","result":"size admission: 900 changed lines"}]}')" == undersized ]] || fail "size escalation = undersized"
[[ "$(cls '{}')" == unclassified ]] || fail "no evidence = unclassified"

# ---- 3. soft line: park, exactly one arbiter dispatch with the table and class ----
run() { jq -cn --arg log "$1" --arg start "$2" --arg phase "$3" --argjson fresh "$4" '{log:$log,start:$start,phase:$phase,backend:"codex",minutes:12.5,fresh_tokens:$fresh}'; }
soft_unit() { # id fresh-a fresh-b
  jq -cn --arg id "$1" --argjson a "$(run a.log 2026-11-05T10:00:00Z implement "$2")" --argjson b "$(run b.log 2026-11-05T11:00:00Z repair "$3")" \
    '{id:$id,issue:2,pr:22,lane:"pr",branch:"agent/issue-2",stage:"repair-pending",spend_runs:[$a,$b],
      review_findings:[{round:1,report:"incident-gate-x-T.md",block:"ok"},{round:2,report:"incident-gate-x-U.md",block:"ok"}],
      history:[{stage:"review-request-changes",result:"s1",at:"2026-11-05T10:30:00Z"}]}'
}
echo "{\"units\":[$(soft_unit issue-2 700000 550000)]}" > "$UNITS"; echo '{"workers":[]}' > "$WORKERS"
[[ "$(token_spend_verdict "$(soft_unit issue-2 700000 499999)")" == ok ]] || fail "1199999 is under the soft line"
token_spend_gate issue-2 "$(jq -c '.units[0]' "$UNITS")" && fail "1.25M must park" || true
[[ "$(field issue-2 .stage)" == supervisor-review ]] || fail "soft park goes to supervisor-review: $(field issue-2 .stage)"
[[ "$(field issue-2 '[.history[] | select(.stage == "token-park")] | length')" == 1 ]] || fail "one token-park event"
[[ "$(field issue-2 .token_park.class)" == report-gate-loop ]] || fail "class stored: $(field issue-2 .token_park.class)"
dispatch_supervisor_arbiters
[[ "$(jq '[.workers[] | select(.type=="supervise" and .unit=="issue-2")] | length' "$WORKERS")" == 1 ]] || fail "exactly one arbiter dispatch"
q_file="$(ls -t "$sup"/supervise-issue-2-*.q.md | head -1)"
grep -q 'Class: report-gate-loop' "$q_file" || fail "prompt names the class"
grep -q '2026-11-05T10:00:00Z.implement.codex.12.5.700000' <(tr '\t' '.' < "$q_file") || fail "prompt carries the implement row of the spend table"
grep -q '2026-11-05T11:00:00Z.repair.codex.12.5.550000' <(tr '\t' '.' < "$q_file") || fail "prompt carries the repair row of the spend table"
dispatch_supervisor_arbiters
[[ "$(jq '[.workers[] | select(.type=="supervise" and .unit=="issue-2")] | length' "$WORKERS")" == 1 ]] || fail "no second arbiter dispatch while one is in flight"
token_spend_gate issue-2 "$(jq -c '.units[0]' "$UNITS")" check-only && fail "check-only holds a parked unit" || true

# ---- 4. one refill: the first return to dispatch after the ruling ----
set_unit issue-2 "$(hist supervisor-requeue 'arbiter: requeue') | .stage=\"repair-pending\""
token_spend_gate issue-2 "$(jq -c '.units[0]' "$UNITS")" || fail "the ruling refills once"
token_spend_gate issue-2 "$(jq -c '.units[0]' "$UNITS")" || fail "past the refill the unit keeps working up to the hard line"
[[ "$(field issue-2 '[.history[] | select(.stage == "token-refill")] | length')" == 1 ]] || fail "exactly one token-refill event"
[[ "$(field issue-2 '[.history[] | select(.stage == "token-park")] | length')" == 1 ]] || fail "no second soft park"
[[ "$(field issue-2 '.history[] | select(.stage == "token-refill") | .result')" == 'once, after supervisor-requeue;'* ]] || fail "the refill records the ruling"
[[ "$(field issue-2 '.token_park')" == null ]] || fail "the park record clears on refill, so a later arbiter prompt carries no stale table"

# ---- 5. hard line: no ruling kind refills, the head hears once ----
: > "$INBOX"; rm -f "$INBOX.keys"
for ruling in supervisor-requeue supervisor-approve supervisor-cap-budget-refill advisor-ruling arbiter-review supervisor-arbiter-round; do
  jq -cn --arg ruling "$ruling" --argjson a "$(run a.log 2026-11-05T10:00:00Z implement 1500000)" --argjson b "$(run b.log 2026-11-05T11:00:00Z repair 1000000)" \
    '{units:[{id:"issue-3",issue:3,pr:33,stage:"implement-pending",spend_runs:[$a,$b],
      history:[{stage:"token-park",result:"soft: x",at:"2026-11-05T12:00:00Z"},{stage:"token-refill",result:"once",at:"2026-11-05T12:10:00Z"},{stage:$ruling,result:"ruling",at:"2026-11-05T12:20:00Z"}]}]}' > "$UNITS"
  token_spend_gate issue-3 "$(jq -c '.units[0]' "$UNITS")" && fail "2.5M after $ruling must stay parked" || true
  [[ "$(field issue-3 .stage)" == parked && "$(field issue-3 .parked_reason)" == token-hard-park ]] || fail "$ruling: hard park expected, got $(field issue-3 .stage)"
  # The head requeues it by hand: the next dispatch parks it again, silently.
  set_unit issue-3 "$(hist supervisor-requeue 'head requeue') | .stage=\"implement-pending\""
  token_spend_gate issue-3 "$(jq -c '.units[0]' "$UNITS")" && fail "a requeue after $ruling must not lift the hard park" || true
  [[ "$(field issue-3 .stage)" == parked ]] || fail "$ruling: a requeue lifted the hard park"
done
[[ "$(field issue-3 '[.history[] | select(.stage == "token-park" and (.result | startswith("hard")))] | length')" == 1 ]] || fail "one hard park event per unit"
[[ "$(wc -l < "$INBOX")" == 1 ]] || fail "the inbox hears of the unit once: $(cat "$INBOX")"
grep -q 'token-hard-park unit=issue-3' "$INBOX" || fail "inbox entry names the unit"
dispatch_supervisor_arbiters
[[ "$(jq '[.workers[] | select(.unit=="issue-3")] | length' "$WORKERS")" == 0 ]] || fail "a hard-parked unit gets no arbiter run"
# Hard line also on a unit that never soft-parked (no refill yet).
jq -cn --argjson a "$(run a.log 2026-11-05T10:00:00Z implement 2400000)" '{units:[{id:"issue-4",stage:"repair-pending",spend_runs:[$a],history:[]}]}' > "$UNITS"
token_spend_gate issue-4 "$(jq -c '.units[0]' "$UNITS")" && fail "exactly the hard line parks" || true
[[ "$(field issue-4 .parked_reason)" == token-hard-park ]] || fail "straight to the hard park"

# ---- 6. the gate sits in dispatch, ahead of the stop-loss budget ----
grep -q 'token_spend_gate "$id" "$u" check-only' "$script_dir/scheduler.d/dispatch-queue.sh" || fail "refill must not dispatch past a token line"
[[ "$(grep -n 'token_spend_gate "\$id" "\$u" ||' "$script_dir/scheduler.d/dispatch-queue.sh" | cut -d: -f1)" -lt "$(grep -n 'budget="$(ticket_budget_reason' "$script_dir/scheduler.d/dispatch-queue.sh" | cut -d: -f1)" ]] \
  || fail "the token gate runs before the stop-loss budget"

# ---- 7. the metric counts parks in 24 h ----
python3 - "$script_dir" <<'PY' || fail "token_parks_24h wrong"
import datetime as dt, sys
sys.path.insert(0, sys.argv[1])
import node_health as n
now = n.ts("2026-11-07T12:00:00Z")
units = [
    {"id": "a", "history": [{"stage": "token-park", "result": "soft: x", "at": "2026-11-07T11:00:00Z"},
                            {"stage": "token-refill", "at": "2026-11-07T11:30:00Z"},
                            {"stage": "token-park", "result": "hard: y", "at": "2026-11-07T11:45:00Z"}]},
    {"id": "b", "history": [{"stage": "token-park", "result": "soft: x", "at": "2026-11-06T11:59:59Z"}]},
    {"id": "c", "history": [{"stage": "supervisor-park", "at": "2026-11-07T11:00:00Z"}]},
]
metrics = n.ledger_metrics(units, now - dt.timedelta(hours=5), now)
assert metrics["supervisor.token_parks_24h"] == 2, metrics   # refill and other parks do not count; the edge is outside 24 h
assert n.ledger_metrics([], now - dt.timedelta(hours=5), now)["supervisor.token_parks_24h"] == 0
crit = n.CRITERIA["supervisor.token_parks_24h"]
assert [n.status_of(v, crit[2], crit[3], crit[4]) for v in (0, 1, 5)] == ["OK", "UNHEALTHY", "UNHEALTHY"]
assert n.MEANING["supervisor.token_parks_24h"] and n.SOURCE["supervisor.token_parks_24h"]
PY
grep -q 'supervisor.token_parks_24h' "$script_dir/NODE-HEALTH.md" || fail "NODE-HEALTH.md lacks the metric row"

# ---- 8. a resumed run takes its baseline from the previous log: in start order, across sweep batches ----
# The resume log sorts BEFORE its predecessor by file name (fix < selfcheck1), and a batch of one cuts them apart.
first=impl-issue-7-selfcheck1-fix-20261105T100000Z.worker.log; second=impl-issue-7-fix-20261105T110000Z.worker.log
codex_run "$first" 1000000 600000 50000
codex_run "$second" 1500000 900000 80000
for f in "$first" "$second"; do touch -d 2026-11-05T16:00:00Z "$sup/$f"; done
jq -n --arg a "$first" --arg b "$second" '{workers:[
 {pid:0,log:$a,unit:"issue-7",type:"repair",mode:"fresh",harvested:true,started:"2026-11-05T10:00:00Z"},
 {pid:0,log:$b,unit:"issue-7",type:"repair",mode:"resume",harvested:true,started:"2026-11-05T11:00:00Z"}]}' > "$WORKERS"
echo '{"units":[{"id":"issue-7","issue":7,"stage":"repair-pending","history":[]}]}' > "$UNITS"
python3 - "$script_dir" "$sup" "$UNITS" <<'PY' || fail "a resumed run lost its baseline across batches"
import json, sys
sys.path.insert(0, sys.argv[1])
import spend_ledger
units = json.load(open(sys.argv[3]))["units"]
got = {}
for _ in range(2):  # one record per sweep, as a backlog larger than the limit is swept
    runs = spend_ledger.new_runs(sys.argv[2], units, 1)
    assert len(runs) == 1, runs
    got[runs[0][1]["log"]] = runs[0][1]["fresh_tokens"]
    units[0].setdefault("spend_runs", []).append(runs[0][1])
assert got["impl-issue-7-selfcheck1-fix-20261105T100000Z.worker.log"] == 450000, got
assert got["impl-issue-7-fix-20261105T110000Z.worker.log"] == 230000, got  # (500000-300000 uncached) + 30000 output; 0 without the baseline
PY

# ---- 9. the real write path: one ledger write for the sweep, a failed sweep says so, the refill records before it dispatches ----
: > "$fixture/writes"; : > "$LOG"
eval "$(declare -f write_state | sed '1s/^write_state/write_state_real/')"
write_state() { echo w >> "$fixture/writes"; write_state_real "$@"; }
record_run_spend
[[ "$(field issue-7 '.spend_runs | length')" == 2 ]] || fail "both runs recorded by one sweep: $(field issue-7 '.spend_runs | length')"
[[ "$(field issue-7 '[.spend_runs[].fresh_tokens] | add')" == 680000 ]] || fail "recorded total: $(field issue-7 '[.spend_runs[].fresh_tokens] | add')"
[[ "$(wc -l < "$fixture/writes")" == 1 ]] || fail "a sweep is one ledger write, not one per record: $(wc -l < "$fixture/writes")"
grep -q 'spend ledger recorded 2 run' "$LOG" || fail "a recording sweep logs its count"
unset -f write_state; eval "$(declare -f write_state_real | sed '1s/^write_state_real/write_state/')"
bad="$fixture/bad-engine"; mkdir -p "$bad"; printf 'import sys\nsys.exit(3)\n' > "$bad/spend_ledger.py"
: > "$LOG"; (HERE="$bad"; record_run_spend)
grep -q 'spend ledger sweep failed rc=3' "$LOG" || fail "a failed sweep must be logged, not swallowed: $(cat "$LOG")"
trace="$fixture/refill-trace"; : > "$trace"
(phase() { echo "$1" >> "$trace"; }; record_run_spend() { echo record >> "$trace"; }; paused_midrun() { return 1; }
 dep_delivered_snapshot() { :; }; tick_prs_changed() { :; }; INTAKE_ADDED=0; run_refill_intake_dispatch_phases)
[[ "$(head -n 2 "$trace" | tr '\n' ' ')" == "record dispatch_pending " ]] || fail "a refill records spend before it dispatches: $(tr '\n' ' ' < "$trace")"

# ---- 10. liveness: workers ran in the last 6 h and no unit holds a spend_runs record from that window ----
python3 - "$script_dir" <<'PY' || fail "supervisor.spend_ledger_blind wrong"
import sys
sys.path.insert(0, sys.argv[1])
import node_health as n
now = n.ts("2026-11-08T12:00:00Z")
ran = {"id": "a", "history": [{"stage": "pr-opened", "at": "2026-11-08T10:00:00Z"}]}
def blind(*units): return n.ledger_metrics(list(units), now - n.timedelta(hours=5), now)["supervisor.spend_ledger_blind"]
assert blind(ran) == 1, "workers ran and nothing was recorded"
assert blind({"id": "b", "history": [], "spend_runs": [{"log": "x", "start": "2026-11-08T09:00:00Z"}]}, ran) == 0
assert blind({"id": "b", "spend_runs": [{"log": "x", "start": "2026-11-08T05:59:00Z"}]}, ran) == 1, "an old record is not a live input"
assert blind({"id": "c", "history": [{"stage": "pr-opened", "at": "2026-11-08T05:00:00Z"}]}) == 0, "no worker in the window, nothing to record"
assert blind() == 0
crit = n.CRITERIA["supervisor.spend_ledger_blind"]
assert [n.status_of(v, crit[2], crit[3], crit[4]) for v in (0, 1)] == ["OK", "UNHEALTHY"]
assert n.MEANING["supervisor.spend_ledger_blind"] and n.SOURCE["supervisor.spend_ledger_blind"]
PY
grep -q 'supervisor.spend_ledger_blind' "$script_dir/NODE-HEALTH.md" || fail "NODE-HEALTH.md lacks the liveness row"

# ---- 11. an attempt is its write-start: dispatch estimate, model and the run's tokens share the attempt id; a recut names the attempt before it ----
att1=impl-issue-9-20261106T100000Z.worker.log; att2=impl-issue-9-20261106T120000Z.worker.log
codex_run "$att1" 1000000 600000 50000    # fresh 450000, raw 1050000
codex_run "$att2" 1500000 900000 80000    # fresh 680000, raw 1580000
for f in "$att1" "$att2"; do touch -d 2026-11-06T16:00:00Z "$sup/$f"; done
jq -n --arg a "$att1" --arg b "$att2" '{workers:[
 {pid:0,log:$a,unit:"issue-9",type:"implement",mode:"fresh",harvested:true,started:"2026-11-06T10:00:00Z"},
 {pid:0,log:$b,unit:"issue-9",type:"implement",mode:"fresh",harvested:true,started:"2026-11-06T12:00:00Z"}]}' > "$WORKERS"
echo '{"units":[{"id":"issue-9","issue":9,"stage":"implement-pending","history":[]}]}' > "$UNITS"
# The write-start entries carry the shape dispatch_if_room writes (dispatch_attempt_fields), spelled out here.
set_unit issue-9 "$(STAMP=2026-11-06T10:00:00Z hist write-start '[]') | .history[-1].attempt=\"$att1\" | .history[-1].model=\"gpt-6-luna\" | .history[-1].estimate_lines=420 | .history[-1].estimate_band=\"301-480\""
set_unit issue-9 "$(STAMP=2026-11-06T12:00:00Z hist write-start '[]') | .history[-1].attempt=\"$att2\" | .history[-1].model=\"gpt-6-luna\" | .history[-1].estimate_lines=700 | .history[-1].estimate_band=\"641-800\""
record_run_spend
ws='[.history[] | select(.stage == "write-start")]'
[[ "$(field issue-9 "$ws | map(.attempt) | join(\",\")")" == "$att1,$att2" ]] || fail "two attempts, each named by its log: $(field issue-9 "$ws | map(.attempt)")"
[[ "$(field issue-9 "$ws | map(.estimate_lines) | join(\",\")")" == "420,700" ]] || fail "each attempt keeps its dispatch estimate: $(field issue-9 "$ws | map(.estimate_lines)")"
[[ "$(field issue-9 "$ws | map(.fresh_tokens) | join(\",\")")" == "450000,680000" ]] || fail "each attempt carries its own fresh tokens: $(field issue-9 "$ws | map(.fresh_tokens)")"
[[ "$(field issue-9 "$ws | map(.raw_tokens) | join(\",\")")" == "1050000,1580000" ]] || fail "each attempt carries its own raw tokens: $(field issue-9 "$ws | map(.raw_tokens)")"
set_unit issue-9 "$(hist size-recut 'issue #9: 700 lines exceed 640; head=abc') | .stage=\"blocked-external\""
[[ "$(field issue-9 '.history[-1].attempt')" == "$att2" ]] || fail "the recut names the attempt before it: $(field issue-9 '.history[-1].attempt')"
# The helper that writes those fields: band edges, and no estimate is unknown, never zero.
band() { dispatch_attempt_fields x m "{\"estimated_changed_lines\":$1}"; }
[[ "$(band 300)" == *'estimate_band="<=300"'* && "$(band 301)" == *'estimate_band="301-480"'* && "$(band 640)" == *'estimate_band="481-640"'* \
  && "$(band 800)" == *'estimate_band="641-800"'* && "$(band 801)" == *'estimate_band=">800"'* ]] || fail "band edges 300/301/640/800/801"
[[ "$(dispatch_attempt_fields x m '{}')" == *'estimate_band="unknown"'* ]] || fail "no estimate = unknown band, not zero"

echo 'token-spend-gate.test.sh: PASS'
