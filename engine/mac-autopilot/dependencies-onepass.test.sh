#!/usr/bin/env bash
# release_dependency_blocks is one pass: ledger reads and writes stay constant as blocked units grow, and every outcome
# (freed, still blocked, dead blocker routed, cache hit) leaves the same ledger, log and gh calls as the row-by-row version did.
# The expected file was written by the row-by-row version (origin/main at 992ed0d) on this fixture; DEP_ONEPASS_WRITE_EXPECTED=1 rewrites it.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/.." && pwd -P)"
fail() { printf 'dependencies-onepass.test.sh: %s\n' "$*" >&2; exit 1; }

fixture="$test_env_root/dependencies-onepass"
mkdir -p "$fixture/repo" "$fixture/supervisor/autopi/alerts" "$fixture/shim"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor" MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
export REQUIRED_PR_CHECKS_FILE="$engine_dir/mac-autopilot/required-pr-checks.json"
cp "$engine_dir/mac-autopilot/config.template.json" "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY
UNITS="$MAC_AUTOPILOT_RUNTIME_DIR/units.json"; LOG="$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log"; A="$MAC_AUTOPILOT_RUNTIME_DIR"
STAMP=2026-11-08T10:47:12Z; NOW_EPOCH=1794221232
real_jq="$(command -v jq)"
reads="$fixture/jq-reads"; writes="$fixture/writes"; ghlog="$fixture/gh-calls"

# A shim counts the jq runs that read the ledger or a history view (a file argument or a process substitution); hist/js build small strings and do not count.
cat > "$fixture/shim/jq" <<SHIM
#!/usr/bin/env bash
last="\${*: -1}"
case "\$last" in "$UNITS"|/dev/fd/*|/proc/self/fd/*) echo r >> "$reads" ;; esac
echo all >> "$reads.all"
exec "$real_jq" "\$@"
SHIM
chmod +x "$fixture/shim/jq"

cancel_unit_runs() { :; }
tick_prs() { printf '%s' "${PRS:-[]}"; }
scheduler_issue_state() { # the dead-blocker cases name their state by predecessor number
  case "$1" in
    108) printf '{"state":"ready-for-agent","recut_children":[109]}' ;;
    110) printf '{"state":"tracker"}' ;;
    111) printf '{"state":"ready-for-agent"}' ;;
    140) printf '{"state":"tracker"}' ;;
    *) printf '{"state":"ready-for-agent"}' ;;
  esac
}
dep_states() { # number → state<TAB>labels<TAB>issue state<TAB>reason, from the table the case fills
  local d row
  for d in "$@"; do
    row="${CACHE_ROWS[$d]:-}"
    [[ -z "$row" ]] || printf '%s\t%s\n' "$d" "$row"
  done
}
gh() {
  printf '%s\n' "$*" >> "$ghlog"
  case "$*" in
    "pr close"*) return 0 ;;
    *sub_issues*) return 0 ;;
    *git/ref/heads/*) printf 'abcdef0123456789\n'; return 0 ;;
  esac
  return 1
}
orig_write_state="$(declare -f write_state)"; eval "orig_$orig_write_state"
write_state() { echo w >> "$writes"; orig_write_state "$@"; }
unit() { # id issue stage [jq edits]
  jq -cn --arg id "$1" --argjson issue "$2" --arg stage "$3" '{id:$id,issue:$issue,stage:$stage,task:"t",branch:"agent/issue-\($issue)",history:[]}' | jq -c "${4:-.}"
}
declare -A CACHE_ROWS=()
reset_run() { rm -f "$reads" "$reads.all" "$writes" "$ghlog" "$A/dep-check.epoch" "$A/dep-check.cache.json"; : > "$LOG"; : > "$ghlog"; : > "$reads"; : > "$reads.all"; : > "$writes"; rm -f "$A/alerts/events.md"; }
count() { wc -l < "$1" | tr -d ' '; }
run_counted() { PATH="$fixture/shim:$PATH" release_dependency_blocks || :; } # || : as the other suites: the function reads a missing epoch file

# ---- scaling: N blocked units, one blocker each ----
scale_fixture() { # N state: N waiters, blocker i is a live unit whose GitHub state is $2
  local n="$1" i rows=""
  CACHE_ROWS=()
  for ((i = 1; i <= n; i++)); do
    rows+="$(unit "issue-$((1000 + i))" "$((1000 + i))" implement-pending)"$'\n'
    rows+="$(unit "issue-$((2000 + i))" "$((2000 + i))" blocked-external ".blocked_on=$((1000 + i)) | .body_blocked_by=[]")"$'\n'
    CACHE_ROWS[$((1000 + i))]="$2"$'\t'
  done
  printf '%s' "$rows" | jq -cs '{units: .}' > "$UNITS"
  printf '{"workers":[]}\n' > "$A/workers.json"
  DEP_DELIVERED_CACHE=()
}
measure() { # N state → "<ledger reads> <writes> <all jq>"
  scale_fixture "$1" "$2"; reset_run
  run_counted
  printf '%s %s %s' "$(count "$reads")" "$(count "$writes")" "$(count "$reads.all")"
}
if [[ "${DEP_ONEPASS_WRITE_EXPECTED:-}" != 1 ]]; then
for st in OPEN MERGED; do
  small="$(measure 5 "$st")"; large="$(measure 20 "$st")"
  printf 'scale %s: N=5 [%s] N=20 [%s] (ledger-reads writes all-jq)\n' "$st" "$small" "$large"
  [[ "${small%% *}" == "${large%% *}" ]] || fail "$st: ledger reads must not grow with blocked units: N=5 '${small}', N=20 '${large}' (reads writes alljq)"
  s="${small#* }"; l="${large#* }"
  [[ "${s%% *}" == "${l%% *}" ]] || fail "$st: ledger writes must not grow with blocked units: N=5 '${small}', N=20 '${large}'"
  [[ "$st" != OPEN ]] || [[ "${small##* }" == "${large##* }" ]] || fail "OPEN: jq runs must not grow with still-blocked units: N=5 '${small}', N=20 '${large}'"
done
scale_fixture 20 MERGED; reset_run; run_counted
[[ "$(jq '[.units[] | select(.stage == "implement-pending" and (.id | startswith("issue-2")))] | length' "$UNITS")" == 20 ]] || fail 'all 20 delivered waiters must be freed'
grep -q 'dep detail steps .*release_row=' "$LOG" || fail 'the pass must log its per-step seconds: dep detail steps'
fi

# ---- equivalence: one ledger with every outcome ----
mixed_fixture() {
  local -a rows=()
  add() { rows+=("$1"); }
  W() { unit "issue-$1" "$1" blocked-external ".blocked_on=$2 | .body_blocked_by=[$2]${3:+ | $3}"; }
  add "$(unit issue-100 100 merged)"; add "$(W 1 100)"                                    # delivered in the ledger
  add "$(unit issue-101 101 implement-pending)"; add "$(W 2 101)"                       # blocker MERGED on GitHub
  add "$(W 3 102)"                                                                       # blocker CLOSED on GitHub, no unit
  add "$(unit issue-103 103 implement-pending)"; add "$(W 4 103)"                        # still blocked
  add "$(W 105 106)"; add "$(W 106 105)"                                                 # mutual wait
  add "$(unit issue-107 107 parked)"; add "$(W 7 107)"                                   # parked blocker: stop waiting
  add "$(W 8 107 '.history=[{stage:"unblocked",result:"stopped waiting on #107: x"}]')" # ... a second block goes to the supervisor
  add "$(unit issue-108 108 closed)"; add "$(W 9 108 '.issue=9')"                        # dead blocker with a recut child
  add "$(unit issue-110 110 closed)"; add "$(W 10 110)"                                  # dead blocker: tracker parent
  add "$(unit issue-111 111 closed)"; add "$(W 11 111)"                                  # dead blocker: nobody to wait for
  add "$(W 12 112)"; add "$(W 13 112 '.history=[{stage:"epic-not-predecessor",result:"#112"}]')" # roadmap epic, first and second time
  add "$(W 14 113 '.stacked_on="issue-9" | .body_blocked_by=[]')"                        # stacked, not declared: skipped
  add "$(W 15 113 '.stacked_on="issue-9"')"                                              # stacked, declared: judged
  add "$(W 16 113 '.size_recut_pending=true')"                                           # size recut: skipped
  add "$(W 17 114)"                                                                      # no cached state: skipped
  add "$(unit issue-115 115 implement)"; add "$(W 18 115 '.dep_wait_delivery=115')"      # marker, closed on GitHub, live unit
  add "$(W 19 116 '.dep_wait_delivery=116')"                                             # marker, closed on GitHub, no unit
  add "$(W 20 117 'del(.body_blocked_by) | .task="x\n--- issue 正文（任务数据）---\n## Blocked by\n- #117\n--- 正文结束 ---"')" # older unit, no stored list
  add "$(unit issue-118 118 implement-pending)"; add "$(W 21 118 '.labels=["stack-pilot"]')" # stack pilot with no ready predecessor
  add "$(unit issue-119 119 merged)"; add "$(unit issue-22 22 parked '.blocked_on=119 | .parked_reason="waiting-predecessor"')" # parked on a delivered blocker
  add "$(unit issue-120 120 implement)"; add "$(unit issue-23 23 parked '.blocked_on=120 | .dep_wait_delivery=120 | .parked_reason="waiting-predecessor"')" # marked, live blocker
  add "$(unit issue-24 24 parked '.blocked_on=121 | .parked_reason="waiting-predecessor"')" # parked on a closed blocker
  add "$(W 130 131)"; add "$(W 132 133 '.pr=900')"                                       # own issue closed / closed as not planned
  add "$(unit issue-150 150 parked '.blocked_on=119 | .parked_reason="waiting-predecessor" | .pr=901')"  # freed first ...
  add "$(unit issue-27 27 parked '.blocked_on=150 | .dep_wait_delivery=150 | .parked_reason="waiting-predecessor"')" # ... so this marked waiter sees a live row, not the parked one the index read
  add "$(unit issue-25 25 blocked-external)"                                             # no predecessor named
  add "$(unit issue-140 140 closed)"; add "$(W 26 140 '.dep_wait_delivery=140')"         # dead predecessor reaches the arbiter
  printf '%s\n' "${rows[@]}" | jq -cs '{units: .}' > "$UNITS"
  printf '{"workers":[]}\n' > "$A/workers.json"
  DEP_DELIVERED_CACHE=()
  CACHE_ROWS=([102]=$'CLOSED\t' [101]=$'MERGED\t' [103]=$'OPEN\t' [106]=$'OPEN\t' [105]=$'OPEN\t' [107]=$'OPEN\t' [108]=$'OPEN\t' [110]=$'OPEN\t'
    [111]=$'OPEN\t' [112]=$'OPEN\troadmap-epic' [113]=$'OPEN\t' [115]=$'CLOSED\t' [116]=$'CLOSED\t' [117]=$'OPEN\t' [118]=$'OPEN\t' [119]=$'MERGED\t'
    [120]=$'OPEN\t' [121]=$'CLOSED\t' [131]=$'OPEN\t' [140]=$'OPEN\t' [130]=$'CLOSED\t' [133]=$'CLOSED\t' [132]=$'CLOSED\t\tCLOSED\tNOT_PLANNED' [150]=$'CLOSED\t')
}
snapshot() { # normalised ledger, log without the timing line, and gh calls
  printf '== ledger\n'; jq -S . "$UNITS"
  printf '== log\n'; grep -v 'dep detail steps' "$LOG" | sed 's/ secs=[0-9]*s//'
  printf '== gh\n'; cat "$ghlog"
  printf '== cache\n'; jq -S . "$A/dep-check.cache.json"
}
mixed_fixture; reset_run; PRS='[{"number":900}]'
run_counted
out="$(snapshot)"
reset_log() { : > "$LOG"; : > "$ghlog"; }; reset_log
run_counted
out+=$'\n== cache hit\n'"$(snapshot)"
expected="$script_dir/dependencies-onepass.expected"
if [[ "${DEP_ONEPASS_WRITE_EXPECTED:-}" == 1 ]]; then printf '%s\n' "$out" > "$expected"; echo "wrote $expected"; exit 0; fi
printf '%s\n' "$out" > "$fixture/actual"
cmp -s "$fixture/actual" "$expected" || { diff "$expected" "$fixture/actual" | head -40 >&2; fail 'ledger, log or gh calls differ from the row-by-row version'; }
echo 'dependencies-onepass.test.sh: ok'
