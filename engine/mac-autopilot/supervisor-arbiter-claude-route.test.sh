#!/usr/bin/env bash
# Supervisor arbiter routing on codex_week_stopped (codex-budget.sh): under the stop the dispatch is unchanged (codex exec -p
# <profile>); over it the arbiter runs on the hand-claude role, defers when Claude is unavailable, and its report parses as before.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/sup-arbiter-route"
sup="$fixture/supervisor"
mkdir -p "$sup/autopi/alerts" "$fixture/repo/engine/prompts" "$fixture/bin"
export ZF_ROADMAP_TREE_CACHE_FILE="$fixture/roadmap-tree.json"
echo '{"roots":[]}' > "$ZF_ROADMAP_TREE_CACHE_FILE"
jq '.auto_merge = false | .advisor = false | .precheck = false | .supervisor_arbiter.enabled = true' "$script_dir/config.template.json" > "$sup/autopi/config.json"
echo '{"units":[]}' > "$sup/autopi/units.json"
echo '{"workers":[]}' > "$sup/autopi/workers.json"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$sup" MAC_AUTOPILOT_RUNTIME_DIR="$sup/autopi"
export ZF_CONFIG_ROOT="$fixture/repo/.zenoforge"
mkdir -p "$ZF_CONFIG_ROOT/prompts"
cp "$script_dir/../prompts/supervisor-arbiter.md" "$ZF_CONFIG_ROOT/prompts/"
cp "$script_dir/../prompts/supervisor-arbiter.md" "$script_dir/../prompts/supervisor-cap-triage.md" "$fixture/repo/engine/prompts/"
export CODEX_SESSIONS_DIR="$fixture/sessions"
export CODEX_QUOTA_SNAPSHOT_FILE="$fixture/codex-quota.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$script_dir/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY
decision_eval_stages() { printf '\n'; }
fail() { echo "supervisor-arbiter-claude-route.test.sh: $*" >&2; exit 1; }
field() { jq -r --arg id "$1" ".units[] | select(.id==\$id) | $2" "$UNITS"; }
gh() { return 0; }
export -f gh

# Stubs record argv and write a fixed reply: codex to --output-last-message, claude to stdout.
printf '#!/usr/bin/env bash\necho "codex $*" >> "$FIXTURE/codex.calls"\nout=""; prev=""\nfor a in "$@"; do [[ "$prev" == --output-last-message ]] && out="$a"; prev="$a"; done\n[[ -z "$out" ]] || cat "$FIXTURE/reply" > "$out"\n' > "$fixture/bin/codex"
printf '#!/usr/bin/env bash\nprintf "claude " >> "$FIXTURE/claude.calls"; printf "%%q " "$@" >> "$FIXTURE/claude.calls"; echo >> "$FIXTURE/claude.calls"\ncat > "$FIXTURE/claude.stdin"\ncat "$FIXTURE/reply"\n' > "$fixture/bin/claude"
chmod +x "$fixture/bin/codex" "$fixture/bin/claude"
export FIXTURE="$fixture" PATH="$fixture/bin:$PATH"

stop() { jq -n --argjson r "$(( $(date +%s) + 3600 ))" '{week_pct:98,week_reset:$r}' > "$CODEX_QUOTA_SNAPSHOT_FILE"; }
nostop() { jq -n '{week_pct:10,week_reset:0}' > "$CODEX_QUOTA_SNAPSHOT_FILE"; }
reset() { # unit-json
  printf '%s\n' "$1" > "$UNITS"; echo '{"workers":[]}' > "$WORKERS"; rm -f "$fixture"/*.calls "$fixture/claude.stdin"
}
wait_for() { local i; for i in $(seq 50); do [[ -e "$1" ]] && return 0; sleep 0.1; done; fail "timed out waiting for $1"; }
unit() { jq -cn --arg id "$1" --argjson hist "${2:-[]}" '{units:[{id:$id,issue:701,pr:701,lane:"pr",stage:"supervisor-review",
  history:([{stage:"supervisor-escalated",result:"no VERDICT",at:"2026-10-27T00:01:00Z"}] + $hist)}]}'; }
printf 'ACTION: requeue\nREASON: r\nGUIDANCE: g\n' > "$fixture/reply"

# ---- under the stop: codex exec -p <profile>, no claude call, worker model profile:<profile> ----
nostop; reset "$(unit pr-701)"
dispatch_supervisor_arbiters
wait_for "$fixture/codex.calls"
grep -q -- "exec -p $SUPERVISOR_ARBITER_PROFILE " "$fixture/codex.calls" || fail "under the stop the arbiter must call codex exec -p $SUPERVISOR_ARBITER_PROFILE"
[[ ! -e "$fixture/claude.calls" ]] || fail "under the stop claude must not be called"
jq -e --arg m "profile:$SUPERVISOR_ARBITER_PROFILE" 'any(.workers[]; .type=="supervise" and .model==$m)' "$WORKERS" >/dev/null || fail "under the stop the worker model must stay the profile"

# ---- over the stop: hand-claude role, no codex call, same report file and parser ----
stop; reset "$(unit pr-702)"
dispatch_supervisor_arbiters
wait_for "$fixture/claude.calls"
[[ ! -e "$fixture/codex.calls" ]] || fail "over the stop codex must not be called"
role_model="$(model_policy_role_fields hand-claude 2>/dev/null | cut -f2 || true)"; [[ -n "$role_model" ]] || fail "hand-claude role has no model"
grep -q -- "--model $role_model " "$fixture/claude.calls" || fail "claude must run the hand-claude role model $role_model"
role_effort="$(model_policy_role_fields hand-claude 2>/dev/null | cut -f3 || true)"
grep -q -- "--effort $role_effort " "$fixture/claude.calls" || fail "claude must run the hand-claude role effort $role_effort"
grep -q -- "--tools '' " "$fixture/claude.calls" || fail "claude arbiter must run with no tools"
grep -q -- "--safe-mode " "$fixture/claude.calls" && grep -q -- "--setting-sources '' " "$fixture/claude.calls" \
  || fail "claude arbiter must not load project CLAUDE.md or settings (--safe-mode --setting-sources '')"
jq -e --arg m "profile:$role_model" 'any(.workers[]; .type=="supervise" and .unit=="pr-702" and .model==$m)' "$WORKERS" >/dev/null || fail "worker must record the claude role model"
[[ "$(field pr-702 '.history[-1].stage')" == supervisor-arbiter ]] || fail "dispatch must consume one arbitration slot"
grep -q '"unitId":"pr-702"' "$fixture/claude.stdin" || fail "claude prompt must carry the frozen record"
report="$sup/$(jq -r '.units[0].supervise_report' "$UNITS")"
for _ in $(seq 50); do [[ -s "$report" ]] && break; sleep 0.1; done
[[ "$(supervisor_action_of "$report")" == requeue ]] || fail "claude report must parse through supervisor_action_of"

# ---- over the stop, empty role effort: --effort is omitted, the run still dispatches ----
eval "orig_$(declare -f pick_claude_implementer)"
pick_claude_implementer() { orig_pick_claude_implementer && PICK_EFFORT=""; }
stop; reset "$(unit pr-705)"
dispatch_supervisor_arbiters
wait_for "$fixture/claude.calls"
grep -q -- '--model ' "$fixture/claude.calls" || fail "empty effort must still dispatch claude"
grep -q -- '--effort' "$fixture/claude.calls" && fail "empty effort must omit --effort"
eval "$(declare -f orig_pick_claude_implementer | sed '1s/orig_//')"
printf 'ACTION: requeue\nREASON: r\nGUIDANCE: g\n' > "$fixture/reply"

# ---- over the stop, final cap triage: the verdict parses through supervisor_cap_verdict_of ----
printf 'REASON: one rule settles it\nEVIDENCE: twice\nVERDICT: RULE\n' > "$fixture/reply"
stop; reset "$(unit pr-703 '[{"stage":"supervisor-arbiter","result":"a","at":"2026-10-27T00:02:00Z"},{"stage":"supervisor-arbiter","result":"b","at":"2026-10-27T00:03:00Z"}]')"
dispatch_supervisor_arbiters
wait_for "$fixture/claude.calls"
jq -e 'any(.workers[]; .type=="supervise" and .cap_triage==true)' "$WORKERS" >/dev/null || fail "third entry must dispatch a cap triage worker"
grep -q '"capTriage":true' "$fixture/claude.stdin" || fail "cap triage prompt must reach claude"
report="$sup/$(jq -r '.units[0].supervise_report' "$UNITS")"
for _ in $(seq 50); do [[ -s "$report" ]] && break; sleep 0.1; done
[[ "$(supervisor_cap_verdict_of "$report")" == RULE ]] || fail "claude cap report must parse through supervisor_cap_verdict_of"
printf 'ACTION: requeue\nREASON: r\nGUIDANCE: g\n' > "$fixture/reply"

# ---- over the stop, Claude unavailable: defer, nothing dispatched, unit untouched; a later tick dispatches ----
defer_check() { # label
  dispatch_supervisor_arbiters
  [[ ! -e "$fixture/claude.calls" && ! -e "$fixture/codex.calls" ]] || fail "$1: no CLI may run"
  [[ "$(jq '.workers | length' "$WORKERS")" == 0 ]] || fail "$1: no worker may be recorded"
  [[ "$(field pr-704 .stage)" == supervisor-review && "$(field pr-704 '.history | length')" == 1 ]] || fail "$1: the unit must stay in supervisor-review, unspent"
}
stop; reset "$(unit pr-704)"
saved_cfg="$CFG"
CFG="$(jq '.models.implement_share.claude=0' <<<"$CFG")"
defer_check "claude share 0"
CFG="$saved_cfg"
marker="$(_quota_marker_file claude)"; mkdir -p "$(dirname "$marker")"
echo "$(( $(date +%s) + 3600 ))" > "$marker"
defer_check "claude quota hold"
rm -f "$marker"
dispatch_supervisor_arbiters
wait_for "$fixture/claude.calls"
jq -e 'any(.workers[]; .type=="supervise" and .unit=="pr-704")' "$WORKERS" >/dev/null || fail "a later tick must dispatch the deferred unit"

echo 'ok - supervisor arbiter: codex under the stop, hand-claude over it, defer when Claude is unavailable'
