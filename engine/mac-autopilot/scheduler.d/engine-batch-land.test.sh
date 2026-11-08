#!/usr/bin/env bash
# The engine batch lander (merge station, engine_batch_land.enabled): lands every ready Zenoforge PR through tools/merge-pr.sh, names and skips the ones that
# conflict, are drafts, have no green receipt or are refused, never merges one PR twice, and does nothing while its knob is off.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
engine_dir="$(cd -- "$script_dir/.." && pwd -P)"
fail() { printf 'engine-batch-land.test.sh: %s\n' "$*" >&2; exit 1; }

fixture="$test_env_root/engine-batch-land"
mkdir -p "$fixture/repo" "$fixture/supervisor/autopi/alerts" "$fixture/clones"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor" MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
export REQUIRED_PR_CHECKS_FILE="$engine_dir/mac-autopilot/required-pr-checks.json"
cp "$engine_dir/mac-autopilot/config.template.json" "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
printf '%s\n' '{"workers":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
printf '%s\n' '{"units":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY
A="$MAC_AUTOPILOT_RUNTIME_DIR"; LOG="$A/scheduler.log"; STAMP=T; : > "$LOG"
ENGINE_BATCH_LAND_UNKNOWN_WAIT=0

hd() { printf '%040d' "$1"; } # a 40-digit fake head per PR number
mkclone() { command git init -q "$fixture/clones/$1"; mkdir -p "$fixture/clones/$1/.git/zf-test-receipts"; }
receipt() { printf '%s\t%s\n' "$3" "bash engine/x.test.sh" >> "$fixture/clones/$1/.git/zf-test-receipts/$(hd "$2")"; } # clone pr rc
mkclone auth1; mkclone auth2
receipt auth1 1 0                                     # PR 1: green
receipt auth1 3 0; receipt auth1 3 1                  # PR 3: the last run is red
receipt auth1 5 0                                     # PR 5: green, but merge-pr refuses it
receipt auth2 6 0                                     # PR 6: green, receipt in the other clone, mergeability still UNKNOWN on the listing
receipt auth1 7 1; receipt auth1 7 0                  # PR 7: red, then green: the last run counts
receipt auth1 2 0; receipt auth2 8 0                  # PR 2 conflicts, PR 8 is a draft
PRS="$fixture/prs.json"
list_json() {
  jq -cn --arg h1 "$(hd 1)" --arg h2 "$(hd 2)" --arg h3 "$(hd 3)" --arg h4 "$(hd 4)" --arg h5 "$(hd 5)" --arg h6 "$(hd 6)" --arg h7 "$(hd 7)" --arg h8 "$(hd 8)" \
    '[{number:1,headRefOid:$h1,isDraft:false,mergeable:"MERGEABLE"},{number:2,headRefOid:$h2,isDraft:false,mergeable:"CONFLICTING"},
      {number:3,headRefOid:$h3,isDraft:false,mergeable:"MERGEABLE"},{number:4,headRefOid:$h4,isDraft:false,mergeable:"MERGEABLE"},
      {number:5,headRefOid:$h5,isDraft:false,mergeable:"MERGEABLE"},{number:6,headRefOid:$h6,isDraft:false,mergeable:"UNKNOWN"},
      {number:7,headRefOid:$h7,isDraft:false,mergeable:"MERGEABLE"},{number:8,headRefOid:$h8,isDraft:true,mergeable:"MERGEABLE"}]' > "$PRS"
}
gh() { # pr list -> the open PRs; pr view N --json mergeable -q .mergeable -> what GitHub settled on
  case "$1 $2" in
    "pr list") cat "$PRS" ;;
    "pr view") echo MERGEABLE ;;
    *) fail "unexpected gh call: $*" ;;
  esac
}
CALLS="$fixture/merge.calls"
cat > "$fixture/merge-pr.sh" <<SH
#!/usr/bin/env bash
# stands in for tools/merge-pr.sh: records the PR and the clone it ran in, refuses PR 5, and takes the PR off the open list like a real merge
printf '%s %s\n' "\$1" "\$(basename "\$PWD")" >> "$CALLS"
[[ "\${MERGE_SLEEP:-0}" == 0 ]] || sleep "\$MERGE_SLEEP"
if [[ "\$1" == 5 ]]; then echo "refusing to merge PR #5: PR body has no ## prior-art section" >&2; exit 1; fi
jq -c --argjson n "\$1" 'map(select(.number != \$n))' "$PRS" > "$PRS.new" && mv "$PRS.new" "$PRS"
SH
CFG="$(jq -c --arg script "$fixture/merge-pr.sh" --arg clones "$fixture/clones" '.engine_batch_land={enabled:true,merge_script:$script,clones_dir:$clones}' "$A/config.json")"

# Knob off (the template has no such key): nothing is listed or merged.
CFG_ON="$CFG"; CFG="$(jq -c . "$A/config.json")"; list_json; : > "$CALLS"
engine_batch_land; [[ ! -s "$CALLS" ]] || fail 'the lander ran with its knob off'
CFG="$(jq -c '.engine_batch_land.enabled=false' <<<"$CFG_ON")"; engine_batch_land; [[ ! -s "$CALLS" ]] || fail 'the lander ran with enabled=false'
# Enabled without a readable merge script: a named log line, nothing merged.
CFG="$(jq -c '.engine_batch_land.merge_script="/nonexistent/merge-pr.sh"' <<<"$CFG_ON")"; : > "$LOG"
engine_batch_land; [[ ! -s "$CALLS" ]] || fail 'the lander ran without a merge script'
grep -Fq 'engine batch land: merge_script /nonexistent/merge-pr.sh' "$LOG" || fail 'a missing merge script was not named'
CFG="$CFG_ON"

# One pass lands the ready PRs and names every skip with its reason.
: > "$LOG"; : > "$CALLS"; list_json
engine_batch_land
[[ "$(sort "$CALLS" | tr '\n' ';')" == '1 auth1;5 auth1;6 auth2;7 auth1;' ]] || fail "wrong set of merge-pr calls (conflicting, draft, red and receipt-less PRs must not reach it): $(tr '\n' ';' < "$CALLS")"
[[ "$(jq -c '[.[].number]' "$PRS")" == '[2,3,4,5,8]' ]] || fail "wrong PRs left open: $(cat "$PRS")"
for want in 'PR#1 merged' 'PR#6 merged' 'PR#7 merged' 'PR#2 skipped: mergeable=CONFLICTING' 'PR#3 skipped: no green test receipt' 'PR#4 skipped: no green test receipt' \
  'PR#5 skipped: merge-pr rc=1: refusing to merge PR #5: PR body has no ## prior-art section' 'PR#8 skipped: draft' 'done landed=3 skipped=5'; do
  grep -Fq "engine batch land $want" "$LOG" || fail "log lacks: $want ($(cat "$LOG"))"
done

# A second pass over what is left lands nothing more.
: > "$CALLS"; engine_batch_land; [[ "$(cat "$CALLS")" == '5 auth1' ]] || fail "a later pass retried something other than the refused PR: $(cat "$CALLS")"

# The per-pass cap: one PR, then the rest wait.
list_json; : > "$CALLS"; : > "$LOG"; CFG="$(jq -c '.engine_batch_land.max_per_pass=1' <<<"$CFG_ON")"
engine_batch_land; [[ "$(cat "$CALLS")" == '1 auth1' ]] || fail "max_per_pass=1 did not stop after the first merge: $(tr '\n' ';' < "$CALLS")"
grep -Fq 'pass limit reached before PR#' "$LOG" || fail 'the cap was not logged'
CFG="$CFG_ON"

# No double merge: two passes started together race for the same ready PRs; the flock lets one run and the other skips.
list_json; : > "$CALLS"; : > "$LOG"
( MERGE_SLEEP=1 engine_batch_land ) & p1=$!
( MERGE_SLEEP=1 engine_batch_land ) & p2=$!
wait "$p1" "$p2" || :
dups="$(sort "$CALLS" | uniq -d | tr '\n' ';')"
[[ -z "$dups" ]] || fail "a PR reached merge-pr twice: $dups"
[[ "$(sort -u "$CALLS" | wc -l)" == 4 ]] || fail "the racing passes did not land 1, 5 (refused), 6 and 7 once each: $(tr '\n' ';' < "$CALLS")"
grep -Fq 'engine batch land busy: pass skipped' "$LOG" || fail 'the second pass did not skip on the lock'
# Control: without the lock the same race calls merge-pr twice per PR, so the check above is the lock's doing.
list_json; : > "$CALLS"
eval "$(declare -f engine_batch_land | sed 's/flock -n "\$fd"/true/')"
( MERGE_SLEEP=1 engine_batch_land ) & p1=$!
( MERGE_SLEEP=1 engine_batch_land ) & p2=$!
wait "$p1" "$p2" || :
[[ -n "$(sort "$CALLS" | uniq -d)" ]] || fail 'control: two unlocked passes did not both reach merge-pr; the race fixture proves nothing'
printf 'ok - engine batch land: lands ready PRs, names skips, one lander at a time, off by default\n'
