#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
export ZF_REPO=test/repo
export ZF_REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
export AGENT_DRY_RUN=0
export ZF_WORKTREE_ROOT="$test_env_root/worktrees"
jq '.switches["roadmap-order"] = false | .roles.advisor.disabled = false' "$SCRIPT_DIR/model-policy.default.json" > "$AGENT_HOME/model-policy.json"
source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/night/outcomes-audit.sh"

FAKE_GH_ROOT="$test_env_root/gh"
FAKE_GH_LOG="$test_env_root/gh.log"
FAKE_PR_LIST_RESPONSE='[]'
export FAKE_PR_LIST_RESPONSE
export FAKE_GH_ROOT FAKE_GH_LOG
mkdir -p "$FAKE_GH_ROOT/issues"
cat > "$test_env_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
command="${1:-}"
subcommand="${2:-}"
shift 2 || true
case "$command:$subcommand" in
  variable:get)
    case "${1:-}" in AGENT_PIPELINE) printf 'triage\n' ;; AGENT_PHASE) printf 'implement\n' ;; *) exit 1 ;; esac
    ;;
  api:*)
    case "$subcommand" in
      */sub_issues?per_page=100|*/dependencies/blocked_by)
        if [[ "$subcommand" =~ /issues/([0-9]+)/dependencies/blocked_by$ ]]; then
          number="${BASH_REMATCH[1]}"
          if [ -f "$FAKE_GH_ROOT/blocker-replacement-$number.json" ]; then
            cp "$FAKE_GH_ROOT/blocker-replacement-$number.json" "$AGENT_HOME/state/$number.json"
            rm "$FAKE_GH_ROOT/blocker-replacement-$number.json"
          fi
        fi
        printf '[]\n' ;;
      *) echo "unexpected fake gh API call: $subcommand $*" >&2; exit 64 ;;
    esac
    ;;
  issue:list)
    if [[ " $* " == *' -q '* ]]; then
      for file in "$FAKE_GH_ROOT"/issues/*.json; do
        [ -f "$file" ] || continue
        jq -r 'select(.state == "OPEN" and any(.labels[]?; .name == "on-hold")) | .number' "$file"
      done
    else
      printf 'list\n' >> "$FAKE_GH_LOG"
      if [ "${FAKE_HOLD_ISSUE_LIST_FAILURE:-0}" = 1 ]; then
        echo "fixture issue snapshot failure" >&2
        exit 1
      fi
      for file in "$FAKE_GH_ROOT"/issues/*.json; do
        [ -f "$file" ] || continue
        jq -c 'select(.state == "OPEN" and any(.labels[]?; .name == "on-hold"))' "$file"
      done | jq -s '.'
    fi
    ;;
  issue:view)
    number="${1:-}"
    printf 'view %s\n' "$number" >> "$FAKE_GH_LOG"
    if [[ " ${FAKE_GH_VIEW_FAILURES:-} " == *" $number "* ]]; then
      echo "fixture issue read failed for #$number" >&2
      exit 1
    fi
    if [ -f "$FAKE_GH_ROOT/replacement-$number.json" ]; then
      cp "$FAKE_GH_ROOT/replacement-$number.json" "$AGENT_HOME/state/$number.json"
      rm "$FAKE_GH_ROOT/replacement-$number.json"
    fi
    cat "$FAKE_GH_ROOT/issues/$number.json"
    ;;
  issue:reopen)
    number="${1:-}"
    jq '.state="OPEN"' "$FAKE_GH_ROOT/issues/$number.json" > "$FAKE_GH_ROOT/issues/$number.tmp"
    mv "$FAKE_GH_ROOT/issues/$number.tmp" "$FAKE_GH_ROOT/issues/$number.json"
    ;;
  pr:list)
    if [[ " $* " == *' --state merged '* ]]; then
      if [[ " $* " =~ \ --head\ agent/issue-([0-9]+)\  ]]; then
        number="${BASH_REMATCH[1]}"
        if [ -f "$FAKE_GH_ROOT/merged-replacement-$number.json" ]; then
          cp "$FAKE_GH_ROOT/merged-replacement-$number.json" "$AGENT_HOME/state/$number.json"
          rm "$FAKE_GH_ROOT/merged-replacement-$number.json"
        fi
      fi
      printf '%s\n' "${FAKE_HOLD_MERGED_PRS:-[]}"
    elif [ -n "${FAKE_HOLD_OPEN_PRS:-}" ]; then
      printf '%s\n' "$FAKE_HOLD_OPEN_PRS"
    else
      printf '%s\n' "${FAKE_PR_LIST_RESPONSE:-[]}"
    fi
    ;;
  pr:checks) printf '%s\n' "${FAKE_HOLD_PR_CHECKS:-[]}"; exit "${FAKE_HOLD_PR_CHECKS_STATUS:-0}" ;;
  issue:edit)
    number="${1:-}"
    [ "${FAKE_HOLD_EDIT_FAILURE:-0}" != 1 ] || exit 1
    shift || true
    removed=()
    added=()
    while (($#)); do
      case "$1" in
        --remove-label) removed+=("$2"); shift 2 ;;
        --add-label) added+=("$2"); shift 2 ;;
        --repo) shift 2 ;;
        *) shift ;;
      esac
    done
    file="$FAKE_GH_ROOT/issues/$number.json"
    remove_json="$(printf '%s\n' "${removed[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
    add_json="$(printf '%s\n' "${added[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
    printf 'edit %s\n' "$number" >> "$FAKE_GH_LOG"
    jq --argjson remove "$remove_json" --argjson add "$add_json" '
      .labels = (
        ((.labels // []) | map(select(.name as $name | ($remove | index($name)) == null)))
        + [$add[] | {name:.}]
        | reduce .[] as $label_item ([]; if any(.[]; .name == $label_item.name) then . else . + [$label_item] end)
      )
    ' "$file" > "$file.tmp"
    mv "$file.tmp" "$file"
    ;;
  issue:comment)
    number="${1:-}"
    [ "${FAKE_HOLD_COMMENT_FAILURE:-0}" != 1 ] || exit 1
    shift || true
    body=""
    while (($#)); do
      case "$1" in
        --body) body="$2"; shift 2 ;;
        --body-file) body="$(cat "$2")"; shift 2 ;;
        --repo) shift 2 ;;
        *) shift ;;
      esac
    done
    file="$FAKE_GH_ROOT/issues/$number.json"
    printf 'comment %s\n' "$number" >> "$FAKE_GH_LOG"
    jq --arg body "$body" '.comments = ((.comments // []) + [{body:$body}])' "$file" > "$file.tmp"
    mv "$file.tmp" "$file"
    ;;
  *)
    echo "unexpected fake gh call: $command $subcommand $*" >&2
    exit 64
    ;;
esac
EOF
chmod +x "$test_env_bin/gh"
printf '#!/bin/bash\nexit 0\n' > "$test_env_bin/git"
chmod +x "$test_env_bin/git"
export ZF_GH_REAL_CLI="$test_env_bin/gh"
export PATH="$SCRIPT_DIR/gh-shim:$PATH"
# These fixtures exercise issue transitions with an empty, isolated ref set.
git_fetch_hand_bounded() { return 0; }
git() { return 0; }

FAILURES=0
LAST_STATUS=0
reset_fixture() {
  rm -rf -- "$FAKE_GH_ROOT" "$AGENT_HOME/state" "$AGENT_HOME/locks" "$AGENT_HOME/night" "$AGENT_HOME/logs" "$AGENT_HOME/land-queue" "$ZF_WORKTREE_ROOT"
  rm -f -- "$AGENT_HOME/supervisor-inbox"
  mkdir -p "$FAKE_GH_ROOT/issues" "$AGENT_HOME/state" "$AGENT_HOME/locks" "$AGENT_HOME/night" "$ZF_WORKTREE_ROOT"
  : > "$AGENT_HOME/supervisor-inbox"
  FAKE_PR_LIST_RESPONSE='[]'
  unset FAKE_HOLD_OPEN_PRS FAKE_HOLD_MERGED_PRS FAKE_HOLD_PR_CHECKS FAKE_HOLD_PR_CHECKS_STATUS FAKE_HOLD_ISSUE_LIST_FAILURE FAKE_HOLD_VIEW_FAILURES FAKE_GH_VIEW_FAILURES FAKE_HOLD_EDIT_FAILURE FAKE_HOLD_COMMENT_FAILURE
  : > "$FAKE_GH_LOG"
}
write_issue() {
  local number="$1" labels="$2" comments="$3" title="${4:-}" body="${5:-}"
  jq -cn --argjson number "$number" --argjson labels "$labels" --argjson comments "$comments" --arg title "$title" --arg body "$body" \
    '{number:$number,state:"OPEN",labels:$labels,comments:$comments,title:$title,body:$body}' \
    > "$FAKE_GH_ROOT/issues/$number.json"
}
write_state() {
  jq -c '
    if (.hold | type) == "object" and (.hold.holder // "") != "unknown" and (.hold.kind // "") != "backfill" then
      .hold.holder //= "fixture-holder"
      | .hold.release_condition //= "fixture release condition"
      | .hold.expires_at //= (now + 86400 | todate)
      | .hold.stage_before //= "ready-for-agent"
      | .hold.kind //= "manual"
      | .hold.created_at //= (now | todate)
      | .hold.durable_record = true
    else . end
  ' <<< "$2" > "$AGENT_HOME/state/$1.json"
}
write_state_unmarked() {
  printf '%s\n' "$2" > "$AGENT_HOME/state/$1.json"
}
run_sweep() {
  if bash "$SCRIPT_DIR/hold.sh" --sweep > "$test_env_root/hold.out" 2>&1; then LAST_STATUS=0; else LAST_STATUS=$?; cat "$test_env_root/hold.out" >&2; fi
}
run_hold_cli() {
  if bash "$SCRIPT_DIR/hold.sh" "$@" > "$test_env_root/hold.out" 2>&1; then LAST_STATUS=0; else LAST_STATUS=$?; fi
}
fail() {
  printf '  assertion failed: %s\n' "$1" >&2
  FAILURES=$((FAILURES + 1))
}
assert_eq() {
  local description="$1" expected="$2" actual="$3"
  [ "$expected" = "$actual" ] || fail "$description (expected '$expected', got '$actual')"
}
assert_contains() {
  local description="$1" text="$2" needle="$3"
  [[ "$text" == *"$needle"* ]] || fail "$description (missing '$needle')"
}
assert_not_contains() {
  local description="$1" text="$2" needle="$3"
  [[ "$text" != *"$needle"* ]] || fail "$description (unexpected '$needle')"
}
run_case() {
  local name="$1" body="$2" before="$FAILURES"
  if ! "$body"; then fail "$name test body exited early"; fi
  if [ "$FAILURES" = "$before" ]; then printf 'PASS %s\n' "$name"
  else printf 'FAIL %s\n' "$name"; fi
}

test_no_direct_hold_label_writers() {
  local output status=0
  # grep, not rg: landing preflights run with the systemd PATH, which has no rg.
  output="$(grep -rEn --include='*.sh' --exclude='*.test.sh' --exclude='hold.sh' \
    -- '--add-label[[:space:]]+on-hold' "$SCRIPT_DIR" 2>&1)" || status=$?
  assert_eq "static hold-label guard finds no bypass writers" 1 "$status"
  assert_eq "static hold-label guard has no matches" "" "$output"
}

test_existing_tick_runs_hold_sweep() {
  local status=0
  grep -q 'hold_sweep' "$SCRIPT_DIR/issue-pipeline.sh" || status=$?
  assert_eq "existing issue tick invokes hold sweep" 0 "$status"
  status=0
  grep -q 'supervisor_hold_sweep' "$SCRIPT_DIR/issue-pipeline.sh" || status=$?
  assert_eq "same issue tick invokes supervisor hold sweep" 0 "$status"
}

test_guarded_recut_sweep_queues_once() {
  local created labels comments
  reset_fixture
  created="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
  write_issue 4120 '[{"name":"on-hold"}]' '[]' 'guarded repeat'
  write_state 4120 "$(jq -cn --arg created "$created" '{state:"on-hold",brief_md:"original brief",hold:{holder:"supervisor",kind:"guarded-recut-repeat",created_at:$created,release_condition:"dispatch",expires_at:(now+604800|todate)}}')"
  supervisor_hold_sweep 4120
  supervisor_hold_sweep 4120
  labels="$(jq -r '[.labels[].name] | join(",")' "$FAKE_GH_ROOT/issues/4120.json")"
  comments="$(jq -r '[.comments[].body] | join("\n")' "$FAKE_GH_ROOT/issues/4120.json")"
  assert_contains "guarded repeat returns to scheduler" "$labels" ready-for-agent
  assert_not_contains "guarded repeat is no longer held" "$labels" on-hold
  assert_eq "one handoff comment across repeated ticks" 1 "$(grep -c 'vecta-scheduler-handoff issue=4120' <<< "$comments")"
  assert_contains "handoff retains the hold release condition" "$comments" dispatch
  assert_eq "requeue clears the held state" ready-for-agent "$(state_read 4120 | jq -r '.state')"
}
test_orphaned_hand_dispatch_hold_requeues_named_owner_once() {
  local created labels
  reset_fixture
  created="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
  write_issue 4158 '[{"name":"on-hold"}]' '[]' 'orphaned hand-dispatch hold'
  write_state 4158 "$(jq -cn --arg created "$created" '{state:"on-hold",hold:{holder:"hand-4158",kind:"hand-dispatch",created_at:$created,release_condition:"hand owns ticket",expires_at:(now+604800|todate)}}')"
  supervisor_hold_sweep 4158
  supervisor_hold_sweep 4158
  labels="$(jq -r '[.labels[].name] | join(",")' "$FAKE_GH_ROOT/issues/4158.json")"
  assert_contains "orphaned hand returns to scheduler" "$labels" ready-for-agent
  assert_not_contains "orphaned hand releases hold" "$labels" on-hold
  assert_eq "orphan handoff is recorded once" 1 "$(jq '[.comments[] | select(.body | contains("vecta-scheduler-handoff issue=4158"))] | length' "$FAKE_GH_ROOT/issues/4158.json")"
}
test_supervisor_holds_uses_batch_issue_snapshot() {
  local created output
  reset_fixture
  created="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
  write_issue 4155 '[{"name":"on-hold"}]' '[]' 'held issue with failed point read' 'fixture body'
  write_state 4155 "$(jq -cn --arg created "$created" '{state:"on-hold",hold:{holder:"supervisor-inbox",kind:"blocked-on-resolution",created_at:$created,release_condition:"verify blocker"}}')"
  export FAKE_GH_VIEW_FAILURES=4155
  supervisor_hold_sweep 4155 > "$test_env_root/batch-snapshot.out" 2>&1
  output="$(cat "$test_env_root/batch-snapshot.out")"
  assert_eq "held issues are read in one batch" 1 "$(grep -c '^list$' "$FAKE_GH_LOG")"
  assert_not_contains "batch handoff avoids per-issue GitHub reads" "$(cat "$FAKE_GH_LOG")" 'view 4155'
  assert_contains "batch row re-enters ready queue" "$(jq -r '[.labels[].name]|join(",")' "$FAKE_GH_ROOT/issues/4155.json")" ready-for-agent
  assert_not_contains "valid batch row creates no unreadable error" "$output" 'issue state unreadable'
}
test_supervisor_holds_snapshot_failure_preserves_hold() {
  local created output status=0
  reset_fixture
  created="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
  write_issue 4156 '[{"name":"on-hold"}]' '[]' 'held issue remains on source failure'
  write_state 4156 "$(jq -cn --arg created "$created" '{state:"on-hold",hold:{holder:"supervisor-inbox",kind:"blocked-on-resolution",created_at:$created,release_condition:"verify blocker"}}')"
  export FAKE_HOLD_ISSUE_LIST_FAILURE=1
  supervisor_hold_sweep 4156 > "$test_env_root/batch-snapshot-failure.out" 2>&1 || status=$?
  output="$(cat "$test_env_root/batch-snapshot-failure.out")"
  assert_eq "snapshot source failure is surfaced" 1 "$status"
  assert_contains "snapshot failure names source" "$output" 'issue snapshot read failed at gh issue list'
  assert_eq "snapshot failure leaves hold label unchanged" true "$(jq -r 'any(.labels[]?; .name == "on-hold")' "$FAKE_GH_ROOT/issues/4156.json")"
  assert_eq "snapshot failure posts no handoff" 0 "$(jq '.comments|length' "$FAKE_GH_ROOT/issues/4156.json")"
}
test_supervisor_hold_alert_dedupes_until_hold_changes() {
  local first second
  reset_fixture
  first="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
  second="$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
  write_state 4157 "$(jq -cn --arg created "$first" '{state:"on-hold",hold:{holder:"supervisor",kind:"guarded-recut-repeat",created_at:$created,release_condition:"review"}}')"
  supervisor_hold_alert_once 4157 guarded-recut-repeat 3600 'owner state unreadable; left unchanged'
  supervisor_hold_alert_once 4157 guarded-recut-repeat 3600 'owner state unreadable; left unchanged'
  write_state 4157 "$(jq -cn --arg created "$second" '{state:"on-hold",hold:{holder:"supervisor",kind:"guarded-recut-repeat",created_at:$created,release_condition:"review"}}')"
  supervisor_hold_alert_once 4157 guarded-recut-repeat 3600 'owner state unreadable; left unchanged'
  assert_eq "same hold failure is emitted once" 1 "$(grep -c 'issue=#4157' "$AGENT_HOME/supervisor-inbox")"
  assert_eq "changed hold record gets one new alert" 2 "$(grep -Fc 'supervisor-hold-without-owner:4157:guarded-recut-repeat:' "$AGENT_HOME/supervisor-inbox.once")"
}

test_blocked_on_resolution_sweep_assigns_owner() {
  local created labels comments
  reset_fixture
  created="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
  write_issue 4140 '[{"name":"on-hold"}]' '[]' 'closed blocker needs verification'
  write_state 4140 "$(jq -cn --arg created "$created" '{state:"on-hold",hold:{holder:"supervisor-inbox",kind:"blocked-on-resolution",created_at:$created,release_condition:"verify dependency",expires_at:(now+86400|todate)}}')"
  supervisor_hold_sweep 4140
  supervisor_hold_sweep 4140
  labels="$(jq -r '[.labels[].name]|join(",")' "$FAKE_GH_ROOT/issues/4140.json")"
  comments="$(jq -r '[.comments[].body]|join("\n")' "$FAKE_GH_ROOT/issues/4140.json")"
  assert_contains "verification returns to ready queue" "$labels" ready-for-agent
  assert_not_contains "verification releases hold" "$labels" on-hold
  assert_contains "verification context survives handoff" "$comments" 'verify dependency'
  assert_eq "verification handoff is idempotent" 1 "$(grep -c 'vecta-scheduler-handoff issue=4140' <<< "$comments")"
}
test_blocked_on_resolution_replaces_stale_blocked_owner() {
  local created labels
  reset_fixture
  created="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
  write_issue 4142 '[{"name":"on-hold"}]' '[]' 'closed blocker needs verification'
  write_state 4142 "$(jq -cn --arg created "$created" '{state:"on-hold",hold:{holder:"supervisor-inbox",kind:"blocked-on-resolution",created_at:$created,release_condition:"verify dependency",expires_at:(now+86400|todate)}}')"
  jq -n '[{name:"hand-4142",owned_issues:"4142",dependency:"issue 4143"}]' > "$AGENT_HOME/night/blocked-hand-agents.json"
  supervisor_hold_owner_state 4142
  assert_eq "verification does not inherit stale blocked owner" none "$SUPERVISOR_HOLD_OWNER_STATE"
  supervisor_hold_sweep 4142
  labels="$(jq -r '[.labels[].name]|join(",")' "$FAKE_GH_ROOT/issues/4142.json")"
  assert_contains "closed-blocker verifier returns to scheduler" "$labels" ready-for-agent
  assert_not_contains "stale blocked owner no longer holds issue" "$labels" on-hold
}
test_blocked_on_resolution_pending_pr_waits() {
  local created
  reset_fixture
  created="$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
  write_issue 4141 '[{"name":"on-hold"}]' '[]' 'blocked resolution with pending PR'
  write_state 4141 "$(jq -cn --arg created "$created" '{state:"on-hold",hold:{holder:"supervisor-inbox",kind:"blocked-on-resolution",created_at:$created,release_condition:"verify dependency"}}')"
  export FAKE_HOLD_OPEN_PRS='[{"number":44141,"headRefName":"agent/issue-4141"}]'
  export FAKE_HOLD_PR_CHECKS='[{"name":"fixture","bucket":"pending"}]'
  supervisor_hold_sweep 4141
  assert_eq "pending PR keeps hold" on-hold "$(state_read 4141 | jq -r '.state')"
  assert_eq "pending PR posts no handoff" 0 "$(jq '.comments|length' "$FAKE_GH_ROOT/issues/4141.json")"
}
test_guarded_pending_pr_is_waiting() {
  local created rows
  reset_fixture
  created="$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
  write_issue 4131 '[{"name":"on-hold"}]' '[]' 'guarded repeat with pending PR'
  write_state 4131 "$(jq -cn --arg created "$created" '{state:"on-hold",hold:{holder:"supervisor",kind:"guarded-recut-repeat",created_at:$created,release_condition:"dispatch"}}')"
  export FAKE_HOLD_OPEN_PRS='[{"number":44131,"headRefName":"agent/issue-4131"}]'
  export FAKE_HOLD_PR_CHECKS='[{"name":"fixture","bucket":"pending"}]'
  export FAKE_HOLD_PR_CHECKS_STATUS=8
  supervisor_hold_owner_state 4131
  assert_eq "pending guarded PR is waiting" waiting "$SUPERVISOR_HOLD_OWNER_STATE"
  rows="$(supervisor_holds_snapshot 4131)"
  assert_eq "snapshot counts pending guarded PR as waiting" waiting "$(jq -r '.[0].owner' <<< "$rows")"
  supervisor_hold_sweep 4131
  assert_eq "pending guarded PR remains held" on-hold "$(state_read 4131 | jq -r '.state')"
}
test_guarded_failed_pr_dispatches_repair() {
  local created
  reset_fixture
  created="$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
  write_issue 4132 '[{"name":"on-hold"}]' '[]' 'guarded repeat with failed PR'
  write_state 4132 "$(jq -cn --arg created "$created" '{state:"on-hold",hold:{holder:"supervisor",kind:"guarded-recut-repeat",created_at:$created,release_condition:"repair failed PR"}}')"
  export FAKE_HOLD_OPEN_PRS='[{"number":44132,"headRefName":"agent/issue-4132"}]'
  export FAKE_HOLD_PR_CHECKS='[{"name":"fixture","bucket":"fail"}]'
  export FAKE_HOLD_PR_CHECKS_STATUS=1
  supervisor_hold_sweep 4132
  assert_eq "failed guarded PR is handed back to scheduler" ready-for-agent "$(state_read 4132 | jq -r '.state')"
  assert_contains "failed PR handoff preserves repair condition" "$(jq -r '.comments[-1].body' "$FAKE_GH_ROOT/issues/4132.json")" 'repair failed PR'
}
test_blocked_hand_owns_held_ticket() {
  local created
  reset_fixture
  created="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
  write_issue 4126 '[{"name":"on-hold"}]' '[]' 'blocked hand'
  write_state 4126 "$(jq -cn --arg created "$created" '{state:"on-hold",hold:{holder:"supervisor",kind:"guarded-recut-repeat",created_at:$created,release_condition:"dispatch",expires_at:(now+604800|todate)}}')"
  jq -n '[{name:"hand-4126",owned_issues:"4126",dependency:"issue 4127",dependency_satisfied:false}]' > "$AGENT_HOME/night/blocked-hand-agents.json"
  supervisor_hold_owner_state 4126
  assert_eq "unresolved dependency remains blocked" blocked "$SUPERVISOR_HOLD_OWNER_STATE"
  assert_contains "owner detail names dependency" "$SUPERVISOR_HOLD_OWNER_DETAIL" 'issue 4127'
  supervisor_hold_sweep 4126
  assert_eq "unresolved dependency keeps hold" on-hold "$(state_read 4126 | jq -r '.state')"
  printf '[]\n' > "$AGENT_HOME/night/blocked-hand-agents.json"
  supervisor_hold_owner_state 4126
  assert_eq "resolved dependency releases blocked ownership" none "$SUPERVISOR_HOLD_OWNER_STATE"
}
test_paused_implement_dispatches_no_guarded_hand() {
  local created
  reset_fixture
  created="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
  write_issue 4127 '[{"name":"on-hold"}]' '[]' 'held while paused'
  write_state 4127 "$(jq -cn --arg created "$created" '{state:"on-hold",hold:{holder:"supervisor",kind:"guarded-recut-repeat",created_at:$created,release_condition:"dispatch",expires_at:(now+604800|todate)}}')"
  AGENT_IMPLEMENT_CAP=0 supervisor_hold_sweep 4127
  assert_eq "handoff makes ticket ready even when dispatch is paused" ready-for-agent "$(state_read 4127 | jq -r '.state')"
  [ ! -s "$AGENT_HOME/night/supervisor-dispatch-queue.tsv" ] || fail "paused sweep wrote retired hand queue"
}
test_guarded_hand_dispatch_recovers_from_stale_name_collisions() {
  local old_path="$ZF_WORKTREE_ROOT/hand-4125" created
  reset_fixture
  mkdir -p "$old_path"
  printf 'preserve stale work\n' > "$old_path/keep.txt"
  created="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
  write_issue 4125 '[{"name":"on-hold"}]' '[]' 'stale hand worktree'
  write_state 4125 "$(jq -cn --arg created "$created" '{state:"on-hold",last_failure_reason:"prior review finding",hold:{holder:"supervisor",kind:"guarded-recut-repeat",created_at:$created,release_condition:"recover work"}}')"
  supervisor_hold_sweep 4125
  assert_eq "stale worktree stays untouched" 'preserve stale work' "$(cat "$old_path/keep.txt")"
  assert_eq "unusable stale worktree stays held for recovery" on-hold "$(state_read 4125 | jq -r '.state')"
  assert_contains "unusable stale worktree is reported to supervisor" "$(cat "$AGENT_HOME/supervisor-inbox")" 'handoff-worktree-unusable issue=#4125'
}
test_merged_hand_hold_concludes() {
  local now original_requeue original_conclude calls="$test_env_root/merged-conclude-calls"
  reset_fixture
  now="$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
  write_issue 4121 '[{"name":"on-hold"}]' '[]' 'hand dispatch'
  write_state 4121 "$(jq -cn --arg created "$now" '{state:"on-hold",hold:{holder:"supervisor",kind:"hand-dispatch",created_at:$created,release_condition:"hand owner or merged PR",expires_at:(now+604800|todate)}}')"
  export FAKE_HOLD_MERGED_PRS='[{"number":44121,"headRefName":"agent/issue-4121","baseRefName":"main","state":"MERGED","mergedAt":"2026-10-08T00:00:00Z"}]'
  : > "$calls"
  original_requeue="$(declare -f state_requeue)"
  original_conclude="$(declare -f conclude_merged_run)"
  state_requeue() { printf 'requeue %s %s\n' "$1" "${2:-}" >> "$calls"; }
  conclude_merged_run() { printf 'conclude %s %s\n' "$1" "$2" >> "$calls"; }
  supervisor_hold_sweep 4121
  eval "$original_requeue"
  eval "$original_conclude"
  assert_eq "merged PR hold concludes without a requeue stamped after the merge" 'conclude 4121 44121' "$(cat "$calls")"
}

test_guarded_no_diff_hold_concludes_newest_merged_pr() {
  local now original_requeue original_conclude calls="$test_env_root/guarded-merged-conclude-calls" detail
  reset_fixture
  now="$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
  write_issue 4124 '[{"name":"on-hold"}]' '[]' 'guarded no diff'
  write_state 4124 "$(jq -cn --arg created "$now" '{state:"on-hold",hold:{holder:"supervisor",kind:"guarded-recut-repeat",created_at:$created,release_condition:"dispatch",expires_at:(now+604800|todate)}}')"
  export FAKE_HOLD_MERGED_PRS='[{"number":44124,"headRefName":"agent/issue-4124","baseRefName":"main","state":"MERGED","mergedAt":"2026-10-08T02:00:00Z"},{"number":44125,"headRefName":"agent/issue-4124","baseRefName":"main","state":"MERGED","mergedAt":"2026-10-08T03:00:00Z"}]'
  : > "$calls"
  original_requeue="$(declare -f state_requeue)"
  original_conclude="$(declare -f conclude_merged_run)"
  state_requeue() { printf 'requeue %s %s\n' "$1" "${2:-}" >> "$calls"; }
  conclude_merged_run() { printf 'conclude %s %s\n' "$1" "$2" >> "$calls"; }
  supervisor_hold_sweep 4124
  eval "$original_requeue"
  eval "$original_conclude"
  assert_eq "guarded no-diff hold uses newest merged main PR" 'conclude 4124 44125' "$(cat "$calls")"
  detail="$(cat "$AGENT_HOME/night/supervisor-holds-sweep.latest")"
  assert_contains "guarded merged conclusion is retained for snapshot detail" "$detail" 'issue=#4124 kind=guarded-recut-repeat merged-pr=#44125'
}

test_green_hand_pr_uses_shared_merge_gate() {
  local kind now original_requeue original_merge original_conclude original_checks calls="$test_env_root/green-merge-calls"
  for kind in supervisor-hand guarded-recut-repeat; do
    reset_fixture
    now="$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
    write_issue 4123 '[{"name":"on-hold"}]' '[]' 'hand dispatch'
    write_state 4123 "$(jq -cn --arg created "$now" --arg kind "$kind" '{state:"on-hold",hold:{holder:"supervisor",kind:$kind,created_at:$created,release_condition:"hand owner or merged PR",expires_at:(now+604800|todate)}}')"
    export FAKE_HOLD_OPEN_PRS='[{"number":44123,"headRefName":"agent/issue-4123","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","isDraft":false}]'
    export FAKE_HOLD_PR_CHECKS='[{"name":"fixture","bucket":"pass"}]'
    : > "$calls"
    original_requeue="$(declare -f state_requeue)"
    original_merge="$(declare -f merge_agent_pr)"
    original_conclude="$(declare -f conclude_merged_run)"
    original_checks="$(declare -f pr_checks_outcome)"
    state_requeue() { printf 'requeue %s %s\n' "$1" "${2:-}" >> "$calls"; }
    merge_agent_pr() { printf 'merge %s %s unattended=%s grace=%s\n' "$1" "$2" "$4" "$5" >> "$calls"; }
    conclude_merged_run() { printf 'conclude %s %s\n' "$1" "$2" >> "$calls"; }
    pr_checks_outcome() { echo pass; }
    supervisor_hold_sweep 4123
    eval "$original_requeue"
    eval "$original_merge"
    eval "$original_conclude"
    eval "$original_checks"
    assert_eq "green $kind PR follows shared unattended merge gate" \
      $'requeue 4123 release-hold\nmerge 4123 44123 unattended=1 grace=0\nconclude 4123 44123' "$(cat "$calls")"
  done
}

test_carried_hotpatch_hold_uses_shared_merge_gate() {
  local now original_requeue original_merge original_conclude original_checks original_carried
  local calls="$test_env_root/carried-merge-calls"
  reset_fixture
  now="$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
  write_issue 4154 '[{"name":"on-hold"}]' '[]' 'carried hotpatch'
  write_state 4154 "$(jq -cn --arg created "$now" '{state:"on-hold",hold:{holder:"supervisor",kind:"supervisor-hand",created_at:$created,release_condition:"hand owner or merged PR",expires_at:(now+604800|todate)}}')"
  export FAKE_HOLD_OPEN_PRS='[{"number":44154,"headRefName":"agent/issue-4154","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","isDraft":false}]'
  export FAKE_HOLD_PR_CHECKS='[{"name":"Touched packages PR gate","bucket":"fail"}]'
  : > "$calls"
  original_requeue="$(declare -f state_requeue)"
  original_merge="$(declare -f merge_agent_pr)"
  original_conclude="$(declare -f conclude_merged_run)"
  original_checks="$(declare -f pr_checks_outcome)"
  original_carried="$(declare -f main_fix_forward_carried_exception_for_pr)"
  state_requeue() { printf 'requeue %s %s\n' "$1" "$2" >> "$calls"; }
  merge_agent_pr() { printf 'merge %s %s unattended=%s grace=%s\n' "$1" "$2" "$4" "$5" >> "$calls"; }
  conclude_merged_run() { printf 'conclude %s %s\n' "$1" "$2" >> "$calls"; }
  pr_checks_outcome() { echo fail; }
  main_fix_forward_carried_exception_for_pr() { printf 'carried-candidate %s\n' "$1" >> "$calls"; return 0; }
  supervisor_hold_sweep 4154
  eval "$original_requeue"
  eval "$original_merge"
  eval "$original_conclude"
  eval "$original_checks"
  eval "$original_carried"
  assert_eq "approved carried PR reaches shared merge and conclude path without passing raw check" \
    $'carried-candidate 44154\nrequeue 4154 release-hold\nmerge 4154 44154 unattended=1 grace=0\nconclude 4154 44154' "$(cat "$calls")"
}

test_time_waiting_supervisor_hold_is_untouched() {
  local now before_issue before_state
  reset_fixture
  now="$(date -u -d '3 days ago' +%Y-%m-%dT%H:%M:%SZ)"
  write_issue 4122 '[{"name":"on-hold"}]' '[]' 'await recurrence'
  write_state 4122 "$(jq -cn --arg created "$now" '{state:"on-hold",hold:{holder:"supervisor",kind:"await-recurrence",created_at:$created,release_condition:"recurrence evidence",expires_at:(now+604800|todate)}}')"
  before_issue="$(jq -S '.' "$FAKE_GH_ROOT/issues/4122.json")"
  before_state="$(jq -S '.' "$AGENT_HOME/state/4122.json")"
  supervisor_hold_sweep 4122
  assert_eq "time-waiting hold leaves issue untouched" "$before_issue" "$(jq -S '.' "$FAKE_GH_ROOT/issues/4122.json")"
  assert_eq "time-waiting hold leaves state untouched" "$before_state" "$(jq -S '.' "$AGENT_HOME/state/4122.json")"
  assert_eq "time-waiting hold creates no inbox alert" '' "$(cat "$AGENT_HOME/supervisor-inbox" 2>/dev/null || true)"
}

test_explicit_decision_holds_are_waiting() {
  local now expiry rows
  reset_fixture
  now="$(date -u -d '3 days ago' +%Y-%m-%dT%H:%M:%SZ)"
  expiry="$(date -u -d '+1 day' +%Y-%m-%dT%H:%M:%SZ)"
  write_issue 4127 '[{"name":"on-hold"}]' '[]' 'manual decision hold'
  write_state 4127 "$(jq -cn --arg created "$now" --arg expires "$expiry" '{state:"on-hold",hold:{holder:"supervisor",kind:"manual",created_at:$created,release_condition:"release decision",expires_at:$expires}}')"
  write_issue 4128 '[{"name":"on-hold"}]' '[]' 'no reachable path hold'
  write_state 4128 "$(jq -cn --arg created "$now" --arg expires "$expiry" '{state:"on-hold",hold:{holder:"supervisor",kind:"no-reachable-path",created_at:$created,release_condition:"reachable path exists",expires_at:$expires}}')"

  rows="$(supervisor_holds_snapshot $'4127\n4128')"
  assert_eq "manual and no-path holds are waiting, not ownerless" 'waiting,waiting' \
    "$(jq -r '[.[].owner] | join(",")' <<< "$rows")"
  supervisor_hold_sweep $'4127\n4128'
  assert_eq "explicit decision holds create no ownerless alert" '' \
    "$(cat "$AGENT_HOME/supervisor-inbox" 2>/dev/null || true)"
}

test_durable_waits_are_distinct_from_missing_and_expired_owners() {
  local now created expiry past rows checks checks_failed checks_pending prs
  local impl_blocker_graph_json='[{"number":4164,"state":"OPEN"}]'
  reset_fixture
  now="$(date -u +%s)"
  created="$(date -u -d '3 days ago' +%Y-%m-%dT%H:%M:%SZ)"
  expiry="$(date -u -d '+1 day' +%Y-%m-%dT%H:%M:%SZ)"
  past="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"

  write_issue 4161 '[{"name":"on-hold"}]' '[]' 'dependency wait'
  write_state 4161 "$(jq -cn --arg created "$created" --arg expiry "$expiry" \
    '{state:"on-hold",hold:{holder:"issue-4164",kind:"dependency",created_at:$created,release_condition:"issue #4164 delivers the prerequisite",expires_at:$expiry}}')"
  write_issue 4162 '[{"name":"on-hold"}]' '[]' 'supervisor decision wait'
  write_state 4162 "$(jq -cn --arg created "$created" --arg expiry "$expiry" \
    '{state:"on-hold",hold:{holder:"supervisor-inbox",kind:"conclusion",created_at:$created,release_condition:"supervisor reviews the conclusion",expires_at:$expiry}}')"
  write_issue 4163 '[{"name":"on-hold"}]' '[]' 'awaiting PR'
  write_state 4163 "$(jq -cn --arg created "$created" --arg expiry "$expiry" \
    '{state:"on-hold",hold:{holder:"pr-44163",kind:"awaiting-pr",created_at:$created,release_condition:"PR #44163 passes checks and caretaker merges",expires_at:$expiry}}')"
  write_issue 4165 '[{"name":"on-hold"}]' '[]' 'missing hand owner'
  write_state 4165 "$(jq -cn --arg created "$created" --arg expiry "$expiry" \
    '{state:"on-hold",hold:{holder:"hand-4165",kind:"hand-dispatch",created_at:$created,release_condition:"a hand owns this ticket",expires_at:$expiry}}')"
  write_issue 4166 '[{"name":"on-hold"}]' '[]' 'resolved dependency reference'
  write_state 4166 "$(jq -cn --arg created "$created" --arg expiry "$expiry" \
    '{state:"on-hold",hold:{holder:"issue-4167",kind:"dependency",created_at:$created,release_condition:"issue #4167 delivers the prerequisite",expires_at:$expiry}}')"
  checks='[
    {"__typename":"CheckRun","name":"Enforce branch delivery policy","status":"COMPLETED","conclusion":"SUCCESS"},
    {"__typename":"CheckRun","name":"Required CI gates","status":"COMPLETED","conclusion":"SUCCESS"},
    {"__typename":"CheckRun","name":"Required contract gates","status":"COMPLETED","conclusion":"SUCCESS"},
    {"__typename":"CheckRun","name":"Optional documentation check","status":"COMPLETED","conclusion":"SKIPPED"}
  ]'
  prs="$(jq -cn --argjson checks "$checks" '[{number:44163,headRefName:"agent/issue-4163",statusCheckRollup:$checks}]')"
  rows="$(supervisor_holds_snapshot $'4161\n4162\n4163\n4165\n4166' "$now" "$prs")"
  assert_eq "durable dependencies and inbox decisions are waiting" 'waiting,waiting' \
    "$(jq -r '[.[] | select(.issue == 4161 or .issue == 4162) | .owner] | join(",")' <<< "$rows")"
  assert_eq "matching green PR wait is waiting" waiting \
    "$(jq -r '.[] | select(.issue == 4163) | .owner' <<< "$rows")"
  assert_eq "valid record without active hand stays alertable" none \
    "$(jq -r '.[] | select(.issue == 4165) | .owner' <<< "$rows")"
  assert_eq "dependency whose referenced issue is no longer open stays alertable" none \
    "$(jq -r '.[] | select(.issue == 4166) | .owner' <<< "$rows")"

  checks_pending="$(jq -c 'map(if .name == "Required CI gates" then .status="IN_PROGRESS" | .conclusion=null else . end)' <<< "$checks")"
  prs="$(jq -cn --argjson checks "$checks_pending" '[{number:44163,headRefName:"agent/issue-4163",statusCheckRollup:$checks}]')"
  rows="$(supervisor_holds_snapshot 4163 "$now" "$prs")"
  assert_eq "matching PR with pending checks remains waiting" waiting "$(jq -r '.[0].owner' <<< "$rows")"

  checks_failed="$(jq -c 'map(if .name == "Required CI gates" then .conclusion="FAILURE" else . end)' <<< "$checks")"
  prs="$(jq -cn --argjson checks "$checks_failed" '[{number:44163,headRefName:"agent/issue-4163",statusCheckRollup:$checks}]')"
  rows="$(supervisor_holds_snapshot 4163 "$now" "$prs")"
  assert_eq "failed PR does not get hidden as a wait" none "$(jq -r '.[0].owner' <<< "$rows")"

  jq --arg past "$past" '.hold.expires_at=$past' "$AGENT_HOME/state/4161.json" > "$AGENT_HOME/state/4161.json.tmp"
  mv "$AGENT_HOME/state/4161.json.tmp" "$AGENT_HOME/state/4161.json"
  rows="$(supervisor_holds_snapshot 4161 "$now")"
  assert_eq "expired dependency hold returns to missing-owner alert state" none "$(jq -r '.[0].owner' <<< "$rows")"
}

test_pipeline_system_fastlane_hold_requeues_hand() {
  local created holder
  for holder in supervisor hand-4152 hand-custom; do
    reset_fixture
    created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    write_issue 4152 '[{"name":"pipeline-system"},{"name":"on-hold"}]' '[]' 'pipeline hold'
    write_state 4152 "$(jq -cn --arg created "$created" --arg holder "$holder" '{state:"on-hold",hold:{holder:$holder,kind:"pipeline-system-fastlane",created_at:$created,release_condition:"pipeline work",expires_at:(now+604800|todate)}}')"
    supervisor_hold_sweep 4152
    supervisor_hold_sweep 4152
    assert_eq "fastlane hold returns to scheduler ($holder)" ready-for-agent "$(state_read 4152 | jq -r '.state')"
    assert_eq "fastlane handoff is recorded once ($holder)" 1 "$(jq '[.comments[] | select(.body | contains("vecta-scheduler-handoff issue=4152"))] | length' "$FAKE_GH_ROOT/issues/4152.json")"
  done
}
test_named_queued_hand_owns_fastlane_issue() {
  reset_fixture
  write_issue 4153 '[{"name":"pipeline-system"},{"name":"on-hold"}]' '[]' 'retired queue row'
  write_state 4153 '{"state":"on-hold","hold":{"holder":"hand-4153","kind":"pipeline-system-fastlane"}}'
  printf 'hand-main-gates\twt\tbrief\tnote\twork\t0\treport\t4153 4154\t\n' > "$AGENT_HOME/night/supervisor-dispatch-queue.tsv"
  supervisor_hold_owner_state 4153
  assert_eq "retired queue row is not a live owner" none "$SUPERVISOR_HOLD_OWNER_STATE"
  supervisor_hold_sweep 4153
  assert_eq "stale queued issue returns to scheduler" ready-for-agent "$(state_read 4153 | jq -r '.state')"
  assert_eq "retired queue is not mutated" 1 "$(wc -l < "$AGENT_HOME/night/supervisor-dispatch-queue.tsv" | tr -d ' ')"
}
test_queued_sweep_owns_fastlane_issues() {
  local brief="$AGENT_HOME/night/briefs/hand-sweep.md"
  reset_fixture
  mkdir -p "$AGENT_HOME/night/briefs"
  printf 'Owned issues: 4156 4157\n\nSweep these tickets.\n' > "$brief"
  printf 'hand-sweep\tworktree\t%s\tnote\twork\t0\treport\t4156 4158\t\toptimization\n' "$brief" > "$AGENT_HOME/night/supervisor-dispatch-queue.tsv"
  supervisor_hold_owner_state 4158
  assert_eq "retired explicit queue ownership is ignored" none "$SUPERVISOR_HOLD_OWNER_STATE"
  supervisor_hold_owner_state 4157
  assert_eq "retired brief ownership is ignored" none "$SUPERVISOR_HOLD_OWNER_STATE"
}
test_expired_hold_restores_original_stage() {
  local now past labels comments state created
  reset_fixture
  now="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
  write_issue 4101 '[{"name":"on-hold"}]' '[]' 'plain title'
  write_state 4101 "$(jq -cn --arg expires "$now" '{state:"on-hold",state_changed_from:"ready-for-agent",hold:{holder:"agent-red",release_condition:"review window finishes",expires_at:$expires,stage_before:"ready-for-agent",kind:"hotfix-lane"}}')"
  created="$(jq -r '.hold.created_at' "$AGENT_HOME/state/4101.json")"
  run_sweep
  assert_eq "expired hold sweep succeeds" 0 "$LAST_STATUS"
  labels="$(jq -r '[.labels[].name] | join(",")' "$FAKE_GH_ROOT/issues/4101.json")"
  assert_contains "expired hold resumes its prior stage" "$labels" ready-for-agent
  assert_not_contains "expired hold label is removed" "$labels" on-hold
  comments="$(jq -r '[.comments[].body] | join("\n")' "$FAKE_GH_ROOT/issues/4101.json")"
  assert_contains "expiry comment names holder" "$comments" agent-red
  assert_contains "expiry comment names unmet release condition" "$comments" 'review window finishes'
  state="$(state_read 4101)"
  assert_eq "released hold record is cleared" null "$(jq -c '.hold' <<< "$state")"
  assert_eq "ordinary expiry records a scheduler handoff" "hold-$created" "$(jq -r '.scheduler_handoff.episode' <<< "$state")"
}

test_expired_unknown_backfill_stays_ownerless() {
  local expired release before_issue before_state inbox
  reset_fixture
  expired="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
  release='No complete durable hold record existed; inspect or resolve within this 24-hour backfill window.'
  write_issue 4120 '[{"name":"on-hold"}]' '[{"body":"Backfilled hold record; holder unknown. <!-- vecta-hold-backfill issue=4120 -->"}]' 'unknown held issue'
  write_state 4120 "$(jq -cn --arg expires "$expired" --arg release "$release" '{state:"on-hold",attempts:3,state_changed_from:"ready-for-agent",hold:{holder:"unknown",release_condition:$release,expires_at:$expires,stage_before:"ready-for-agent",kind:"backfill",explained:true,created_at:(now|todate)}}')"
  before_issue="$(jq -S '.' "$FAKE_GH_ROOT/issues/4120.json")"
  before_state="$(jq -S '.' "$(state_file 4120)")"

  run_sweep
  assert_eq "ownerless hold sweep succeeds without inventing metadata" 0 "$LAST_STATUS"
  assert_eq "expired unknown backfill remains on hold" on-hold "$(state_read 4120 | jq -r '.state')"
  assert_eq "expired unknown backfill preserves attempts" 3 "$(state_read 4120 | jq -r '.attempts')"
  assert_eq "expired unknown backfill preserves original stage" ready-for-agent "$(state_read 4120 | jq -r '.hold.stage_before')"
  assert_eq "expired unknown backfill preserves unmet release condition" "$release" "$(state_read 4120 | jq -r '.hold.release_condition')"
  assert_eq "expired unknown backfill expiry is not treated as authoritative" null "$(state_read 4120 | jq -r '.hold.durable_record // null')"
  after_state="$(jq -S '.' "$(state_file 4120)")"
  assert_eq "ownerless sweep leaves GitHub labels and comments unchanged" "$before_issue" "$(jq -S '.' "$FAKE_GH_ROOT/issues/4120.json")"
  assert_eq "ownerless sweep leaves synthetic local record unchanged" "$before_state" "$after_state"
  inbox="$(cat "$AGENT_HOME/supervisor-inbox")"
  assert_contains "ownerless inbox names the issue and unknown holder" "$inbox" 'issue=#4120 kind=backfill holder=unknown'
  assert_contains "ownerless inbox gives evidence-backed recovery action" "$inbox" 'restore-an-exact-GitHub-hold-record-or-verify-metadata-before-release'

  : > "$FAKE_GH_LOG"
  run_sweep
  assert_eq "ownerless hold remains held on later tick" 0 "$LAST_STATUS"
  assert_eq "later tick preserves its state and attempt budget" "$after_state" "$(jq -S '.' "$(state_file 4120)")"
  assert_contains "ownerless hold is reread for a later durable record" "$(cat "$FAKE_GH_LOG")" 'view 4120'
  assert_eq "ownerless inbox message is recorded once" 1 "$(grep -Fc 'ownerless-hold issue=#4120' "$AGENT_HOME/supervisor-inbox" || true)"
  assert_eq "ownerless idempotency key is recorded once" 1 "$(grep -Fc $'\townerless-hold:#4120' "$AGENT_HOME/supervisor-inbox.once" || true)"
}

test_manual_hold_release_reconciles_persisted_state() {
  local expiry labels state conflict_before advisor_hold_before
  reset_fixture
  expiry="$(date -u -d '+1 day' +%Y-%m-%dT%H:%M:%SZ)"
  write_issue 4191 '[{"name":"ready-for-agent"}]' '[]'
  write_state 4191 "$(jq -cn --arg expires "$expiry" '{state:"on-hold",hold:{holder:"unknown",release_condition:"maintainer decision",expires_at:$expires,stage_before:"needs-triage"}}')"
  write_issue 4192 '[]' '[]'
  write_state 4192 "$(jq -cn --arg expires "$expiry" '{state:"on-hold",hold:{holder:"unknown",release_condition:"maintainer decision",expires_at:$expires,stage_before:"ready-for-agent"}}')"
  write_issue 4193 '[{"name":"needs-advisor"},{"name":"ready-for-agent"}]' '[]'
  write_state 4193 "$(jq -cn --arg expires "$expiry" '{state:"on-hold",hold:{holder:"unknown",release_condition:"maintainer decision",expires_at:$expires,stage_before:"ready-for-agent"}}')"
  conflict_before="$(jq -S '.' "$FAKE_GH_ROOT/issues/4193.json")"
  write_issue 4194 '[]' '[]'
  write_state 4194 "$(jq -cn --arg expires "$expiry" '{state:"on-hold",hold:{holder:"advisor",kind:"supervisor-inbox",release_condition:"advisor escalation",expires_at:$expires,stage_before:"ready-for-agent"}}')"
  advisor_hold_before="$(jq -S '.' "$FAKE_GH_ROOT/issues/4194.json")"

  run_sweep
  assert_eq "ambiguous manual-release sweep fails closed" 1 "$LAST_STATUS"
  labels="$(jq -r '[.labels[].name] | join(",")' "$FAKE_GH_ROOT/issues/4191.json")"
  assert_contains "manual release adopts the one live stage label" "$labels" ready-for-agent
  assert_not_contains "manual release removes no-longer-live hold" "$labels" on-hold
  state="$(state_read 4191)"
  assert_eq "adopted live stage is persisted" ready-for-agent "$(jq -r '.state' <<< "$state")"
  assert_eq "adopted live stage clears hold record" null "$(jq -c '.hold' <<< "$state")"
  labels="$(jq -r '[.labels[].name] | join(",")' "$FAKE_GH_ROOT/issues/4192.json")"
  assert_contains "manual release without live stage restores recorded stage" "$labels" ready-for-agent
  assert_eq "fallback stage is persisted" ready-for-agent "$(state_read 4192 | jq -r '.state')"
  assert_eq "ambiguous live stages remain untouched" "$conflict_before" "$(jq -S '.' "$FAKE_GH_ROOT/issues/4193.json")"
  assert_eq "ambiguous hold state remains held" on-hold "$(state_read 4193 | jq -r '.state')"
  assert_contains "ambiguous release is reported" "$(cat "$test_env_root/hold.out")" 'ambiguous live stage labels for released #4193'
  assert_eq "advisor escalation hold stays untouched" "$advisor_hold_before" "$(jq -S '.' "$FAKE_GH_ROOT/issues/4194.json")"
  assert_eq "advisor escalation state stays held" on-hold "$(state_read 4194 | jq -r '.state')"
}

test_durable_hold_release_uses_recorded_stage_when_labels_conflict() {
  local expired labels state source_block
  source_block="$(sed -n '/^hold_sweep() {/,/^}/p' "$SCRIPT_DIR/lib.d/holds.sh")"
  assert_contains "state-only release checks durable record before resolving conflicting labels" \
    "$source_block" '.durable_record == true'
  assert_contains "state-only release validates durable record before using its saved stage" \
    "$source_block" 'hold_durable_record_valid "$hold_json"'
  assert_contains "state-only release restores the exact saved stage" "$source_block" '.stage_before'
  reset_fixture
  expired="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
  write_issue 4197 '[{"name":"needs-advisor"},{"name":"ready-for-agent"}]' '[]' 'expired spend hold with stale labels'
  write_state 4197 "$(jq -cn --arg expires "$expired" \
    '{state:"on-hold",hold:{holder:"issue-spend-budget",kind:"spend-budget",release_condition:"budget window ended",expires_at:$expires,stage_before:"ready-for-agent"}}')"

  run_sweep
  assert_eq "durable release reconciliation succeeds with stale labels" 0 "$LAST_STATUS"
  labels="$(jq -r '[.labels[].name] | join(",")' "$FAKE_GH_ROOT/issues/4197.json")"
  assert_eq "durable original stage replaces conflicting labels" ready-for-agent "$labels"
  state="$(state_read 4197)"
  assert_eq "durable original stage is persisted" ready-for-agent "$(jq -r '.state' <<< "$state")"
  assert_eq "reconciled hold metadata is cleared" null "$(jq -c '.hold' <<< "$state")"
  assert_contains "sweep records exact durable recovery source" "$(cat "$test_env_root/hold.out")" 'from durable stage=ready-for-agent'
}

test_closed_holds_reconcile_once_by_github_reason() {
  local completed_before_comments not_planned_before_comments completed_state not_planned_state unknown_state labels
  reset_fixture
  write_issue 4195 '[{"name":"on-hold"}]' '[{"body":"keep completed comment"}]' 'completed hold'
  jq '.state = "CLOSED" | .stateReason = "COMPLETED" | .closedAt = "2026-10-10T12:00:00Z"' \
    "$FAKE_GH_ROOT/issues/4195.json" > "$FAKE_GH_ROOT/issues/4195.tmp"
  mv "$FAKE_GH_ROOT/issues/4195.tmp" "$FAKE_GH_ROOT/issues/4195.json"
  write_state 4195 '{"state":"on-hold","hold":{"holder":"hand-4195","release_condition":"fix merged","expires_at":"2026-10-12T00:00:00Z","stage_before":"ready-for-agent"}}'
  write_issue 4196 '[{"name":"on-hold"}]' '[{"body":"keep not-planned comment"}]' 'not planned hold'
  jq '.state = "CLOSED" | .stateReason = "NOT_PLANNED" | .closedAt = "2026-10-10T13:00:00Z"' \
    "$FAKE_GH_ROOT/issues/4196.json" > "$FAKE_GH_ROOT/issues/4196.tmp"
  mv "$FAKE_GH_ROOT/issues/4196.tmp" "$FAKE_GH_ROOT/issues/4196.json"
  write_state 4196 '{"state":"on-hold","hold":{"holder":"supervisor","kind":"supervisor-inbox","release_condition":"maintainer declined","expires_at":"2026-10-12T00:00:00Z","stage_before":"needs-triage"}}'
  write_issue 4198 '[{"name":"on-hold"}]' '[{"body":"keep unknown-reason comment"}]' 'closed hold without reason'
  jq '.state = "CLOSED" | .stateReason = null | .closedAt = "2026-10-10T14:00:00Z"' \
    "$FAKE_GH_ROOT/issues/4198.json" > "$FAKE_GH_ROOT/issues/4198.tmp"
  mv "$FAKE_GH_ROOT/issues/4198.tmp" "$FAKE_GH_ROOT/issues/4198.json"
  write_state 4198 '{"state":"on-hold","hold":{"holder":"manual","release_condition":"legacy close reason missing","expires_at":"2026-10-12T00:00:00Z","stage_before":"ready-for-human"}}'
  completed_before_comments="$(jq -c '.comments' "$FAKE_GH_ROOT/issues/4195.json")"
  not_planned_before_comments="$(jq -c '.comments' "$FAKE_GH_ROOT/issues/4196.json")"

  run_sweep
  assert_eq "closed-hold reconciliation succeeds" 0 "$LAST_STATUS"
  completed_state="$(state_read 4195)"
  not_planned_state="$(state_read 4196)"
  unknown_state="$(state_read 4198)"
  assert_eq "completed GitHub closure becomes concluded" concluded "$(jq -r '.state' <<< "$completed_state")"
  assert_eq "not-planned GitHub closure becomes wontfix" wontfix "$(jq -r '.state' <<< "$not_planned_state")"
  assert_eq "completed hold metadata is cleared" null "$(jq -c '.hold' <<< "$completed_state")"
  assert_eq "not-planned hold metadata is cleared" null "$(jq -c '.hold' <<< "$not_planned_state")"
  assert_eq "completed close reason and timestamp stay auditable" 'COMPLETED|2026-10-10T12:00:00Z' \
    "$(jq -r '[.closed_issue_reconciliation.state_reason,.closed_issue_reconciliation.closed_at] | join("|")' <<< "$completed_state")"
  assert_eq "not-planned close reason and timestamp stay auditable" 'NOT_PLANNED|2026-10-10T13:00:00Z' \
    "$(jq -r '[.closed_issue_reconciliation.state_reason,.closed_issue_reconciliation.closed_at] | join("|")' <<< "$not_planned_state")"
  assert_eq "missing close reason converges to concluded" concluded "$(jq -r '.state' <<< "$unknown_state")"
  assert_eq "missing close reason is recorded as UNKNOWN" UNKNOWN "$(jq -r '.closed_issue_reconciliation.state_reason' <<< "$unknown_state")"
  assert_eq "missing-reason hold metadata is cleared" null "$(jq -c '.hold' <<< "$unknown_state")"
  labels="$(jq -r '[.labels[].name] | join(",")' "$FAKE_GH_ROOT/issues/4195.json")"
  assert_contains "completed issue gets concluded label" "$labels" concluded
  assert_not_contains "completed issue drops stale on-hold label" "$labels" on-hold
  labels="$(jq -r '[.labels[].name] | join(",")' "$FAKE_GH_ROOT/issues/4196.json")"
  assert_contains "not-planned issue gets wontfix label" "$labels" wontfix
  assert_not_contains "not-planned issue drops stale on-hold label" "$labels" on-hold
  assert_eq "GitHub closed status is preserved" CLOSED "$(jq -r '.state' "$FAKE_GH_ROOT/issues/4195.json")"
  assert_eq "GitHub comments are preserved" "$completed_before_comments" "$(jq -c '.comments' "$FAKE_GH_ROOT/issues/4195.json")"
  assert_eq "not-planned GitHub closed status is preserved" CLOSED "$(jq -r '.state' "$FAKE_GH_ROOT/issues/4196.json")"
  assert_eq "not-planned GitHub comments are preserved" "$not_planned_before_comments" "$(jq -c '.comments' "$FAKE_GH_ROOT/issues/4196.json")"

  : > "$FAKE_GH_LOG"
  run_sweep
  assert_eq "reconciled closed holds stay complete on later sweep" 0 "$LAST_STATUS"
  assert_not_contains "completed issue is not reread after reconciliation" "$(cat "$FAKE_GH_LOG")" 'view 4195'
  assert_not_contains "not-planned issue is not reread after reconciliation" "$(cat "$FAKE_GH_LOG")" 'view 4196'
  assert_not_contains "unknown-reason issue is not reread after reconciliation" "$(cat "$FAKE_GH_LOG")" 'view 4198'
}

test_closed_hold_read_failure_preserves_evidence() {
  local before_issue before_state
  reset_fixture
  write_issue 4197 '[{"name":"on-hold"}]' '[{"body":"preserve me"}]' 'closed hold read failure'
  jq '.state = "CLOSED" | .stateReason = "COMPLETED" | .closedAt = "2026-10-10T14:00:00Z"' \
    "$FAKE_GH_ROOT/issues/4197.json" > "$FAKE_GH_ROOT/issues/4197.tmp"
  mv "$FAKE_GH_ROOT/issues/4197.tmp" "$FAKE_GH_ROOT/issues/4197.json"
  write_state 4197 '{"state":"on-hold","hold":{"holder":"manual","release_condition":"review","expires_at":"2026-10-12T00:00:00Z","stage_before":"ready-for-human"}}'
  before_issue="$(jq -S '.' "$FAKE_GH_ROOT/issues/4197.json")"
  before_state="$(jq -S '.' "$AGENT_HOME/state/4197.json")"
  FAKE_GH_VIEW_FAILURES=4197 run_sweep
  assert_eq "failed GitHub read fails the sweep" 1 "$LAST_STATUS"
  assert_eq "failed GitHub read leaves closed issue untouched" "$before_issue" "$(jq -S '.' "$FAKE_GH_ROOT/issues/4197.json")"
  assert_eq "failed GitHub read preserves local hold evidence" "$before_state" "$(jq -S '.' "$AGENT_HOME/state/4197.json")"
  assert_contains "failed read is reported without provider response data" "$(cat "$test_env_root/hold.out")" \
    'could not inspect state-only held #4197; leaving state untouched'
  assert_not_contains "failed read output omits credential sentinel" "$(cat "$test_env_root/hold.out")" 'token='
}

test_unexpired_hold_is_untouched() {
  local expiry before_issue before_state
  reset_fixture
  expiry="$(date -u -d '1 hour' +%Y-%m-%dT%H:%M:%SZ)"
  write_issue 4102 '[{"name":"on-hold"}]' '[]'
  write_state 4102 "$(jq -cn --arg expires "$expiry" '{state:"on-hold",hold:{holder:"agent-blue",release_condition:"approval arrives",expires_at:$expires,stage_before:"needs-advisor"}}')"
  before_issue="$(jq -S '.' "$FAKE_GH_ROOT/issues/4102.json")"
  before_state="$(jq -S '.' "$AGENT_HOME/state/4102.json")"
  run_sweep
  assert_eq "unexpired hold sweep succeeds" 0 "$LAST_STATUS"
  assert_eq "unexpired issue is unchanged" "$before_issue" "$(jq -S '.' "$FAKE_GH_ROOT/issues/4102.json")"
  assert_eq "unexpired hold state is unchanged" "$before_state" "$(jq -S '.' "$AGENT_HOME/state/4102.json")"
  assert_eq "unexpired hold causes no GitHub mutations" 0 "$(grep -Ec '^(edit|comment) ' "$FAKE_GH_LOG" || true)"
}

test_missing_hold_record_stays_ownerless() {
  local state first_comments before_issue
  reset_fixture
  write_issue 4103 '[{"name":"on-hold"}]' '[]'
  write_state 4103 '{"state":"on-hold","state_changed_from":"needs-advisor"}'
  before_issue="$(jq -S '.' "$FAKE_GH_ROOT/issues/4103.json")"
  run_sweep
  assert_eq "missing-record sweep succeeds" 0 "$LAST_STATUS"
  state="$(state_read 4103)"
  assert_eq "missing record does not invent a holder" null "$(jq -r '.hold.holder // null' <<< "$state")"
  assert_eq "missing record does not invent an expiry" null "$(jq -r '.hold.expires_at // null' <<< "$state")"
  assert_eq "missing record preserves parked stage" needs-advisor "$(jq -r '.state_changed_from' <<< "$state")"
  first_comments="$(jq -r '[.comments[].body] | join("\n")' "$FAKE_GH_ROOT/issues/4103.json")"
  assert_eq "missing record leaves GitHub comments unchanged" '' "$first_comments"
  assert_eq "missing record leaves on-hold label unchanged" "$before_issue" "$(jq -S '.' "$FAKE_GH_ROOT/issues/4103.json")"
  assert_contains "missing record is explicitly ownerless" "$(cat "$AGENT_HOME/supervisor-inbox")" 'ownerless-hold issue=#4103'
  run_hold_cli --restore 4103
  [ "$LAST_STATUS" -ne 0 ] || fail "targeted restore refuses missing durable source"
  assert_contains "targeted restore explains missing source" "$(cat "$test_env_root/hold.out")" 'no exact durable hold record'
  run_sweep
  assert_eq "second ownerless sweep succeeds" 0 "$LAST_STATUS"
  assert_eq "ownerless recovery alert stays single" 1 "$(grep -Fc 'ownerless-hold issue=#4103' "$AGENT_HOME/supervisor-inbox" || true)"
}

test_marked_hold_without_record_stays_ownerless() {
  local state comments
  reset_fixture
  write_issue 4110 '[{"name":"on-hold"}]' '[]' '[热修] missing hold metadata'
  write_state 4110 '{"state":"on-hold","state_changed_from":"needs-triage"}'
  run_sweep
  assert_eq "marked missing-record sweep succeeds" 0 "$LAST_STATUS"
  state="$(state_read 4110)"
  assert_eq "marked hold gets no inferred kind" null "$(jq -r '.hold.kind // null' <<< "$state")"
  assert_eq "marked hold gets no inferred expiry" null "$(jq -r '.hold.expires_at // null' <<< "$state")"
  comments="$(jq -r '[.comments[].body] | join("\n")' "$FAKE_GH_ROOT/issues/4110.json")"
  assert_eq "marked hold does not get an invented backfill comment" '' "$comments"
  assert_contains "marked hold routes safe recovery" "$(cat "$AGENT_HOME/supervisor-inbox")" 'ownerless-hold issue=#4110'
}

test_expired_hotfix_hold_renews_only_while_marked() {
  local now renewed comments labels sweep_started
  reset_fixture
  now="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
  write_issue 4111 '[{"name":"on-hold"}]' '[]' '[hotfix] keep held'
  write_state 4111 "$(jq -cn --arg expires "$now" '{state:"on-hold",hold:{holder:"hot-fix supervisor",release_condition:"hotfix-issues-go-to-hotfix-supervisor: supervisor owns marked issue until mark is removed.",expires_at:$expires,stage_before:"needs-triage",kind:"hotfix-lane"}}')"
  # Compare with the clock before the sweep: measured after it, the bound moved by however long the sweep
  # took, and a loaded host made the renewal look short (2026-10-03 landing).
  sweep_started="$(date -u +%s)"
  run_sweep
  assert_eq "expired marked hotfix hold renewal succeeds" 0 "$LAST_STATUS"
  renewed="$(state_read 4111 | jq -r '.hold.expires_at')"
  [ "$(agent_epoch "$renewed" 2>/dev/null || echo 0)" -ge "$((sweep_started + 168 * 3600))" ] || fail "renewed hotfix hold expires at least 168 hours ahead"
  labels="$(jq -r '[.labels[].name] | join(",")' "$FAKE_GH_ROOT/issues/4111.json")"
  assert_contains "renewed hotfix hold stays held" "$labels" on-hold
  assert_not_contains "renewed hotfix hold keeps stage label removed" "$labels" needs-triage
  comments="$(jq -r '[.comments[].body] | join("\n")' "$FAKE_GH_ROOT/issues/4111.json")"
  assert_eq "renewal comment appears once for expiry" 1 "$(grep -cF "<!-- vecta-hold-renewed issue=4111 expires=$now -->" <<< "$comments" || true)"
  run_sweep
  comments="$(jq -r '[.comments[].body] | join("\n")' "$FAKE_GH_ROOT/issues/4111.json")"
  assert_eq "later sweep does not repeat completed renewal comment" 1 "$(grep -cF "<!-- vecta-hold-renewed issue=4111 expires=$now -->" <<< "$comments" || true)"

  reset_fixture
  write_issue 4112 '[{"name":"on-hold"}]' '[]' 'plain title'
  write_state 4112 "$(jq -cn --arg expires "$now" '{state:"on-hold",hold:{holder:"hot-fix supervisor",release_condition:"hotfix-issues-go-to-hotfix-supervisor: supervisor owns marked issue until mark is removed.",expires_at:$expires,stage_before:"needs-triage",kind:"hotfix-lane"}}')"
  run_sweep
  assert_eq "expired unmarked hotfix hold releases" 0 "$LAST_STATUS"
  labels="$(jq -r '[.labels[].name] | join(",")' "$FAKE_GH_ROOT/issues/4112.json")"
  assert_contains "unmarked expired hold restores stage" "$labels" needs-triage
  assert_not_contains "unmarked expired hotfix hold is released" "$labels" on-hold
  assert_eq "unmarked expired hold state clears" null "$(state_read 4112 | jq -c '.hold')"
}

test_expired_loop_hold_renews_while_hand_agent_owns_ticket() {
  local now sweep_started expiry labels comments
  reset_fixture
  now="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
  write_issue 4113 '[{"name":"on-hold"}]' '[]' 'loop-held issue'
  write_state 4113 "$(jq -cn --arg expires "$now" '{state:"on-hold",hold:{holder:"detect-label-churn",release_condition:"hand PR flow completes",expires_at:$expires,stage_before:"ready-for-agent",kind:"label-churn"}}')"
  mkdir -p "$AGENT_HOME/land-queue/requests"
  jq -n --arg wt "$ZF_WORKTREE_ROOT/hand-4113" '{ticket:"00000000000000004113",owner:"hand-4113",worktree:$wt,state:"queued"}' > "$AGENT_HOME/land-queue/requests/00000000000000004113.json"
  sweep_started="$(date -u +%s)"
  run_sweep
  assert_eq "active hand owner renewal succeeds" 0 "$LAST_STATUS"
  expiry="$(state_read 4113 | jq -r '.hold.expires_at')"
  [ "$(agent_epoch "$expiry" 2>/dev/null || echo 0)" -ge "$((sweep_started + 168 * 3600))" ] || fail "active-owner hold expires at least 168 hours ahead"
  labels="$(jq -r '[.labels[].name] | join(",")' "$FAKE_GH_ROOT/issues/4113.json")"
  assert_contains "active hand owner keeps loop hold" "$labels" on-hold
  assert_not_contains "active hand owner does not restore lane label" "$labels" ready-for-agent
  comments="$(jq -r '[.comments[].body] | join("\n")' "$FAKE_GH_ROOT/issues/4113.json")"
  assert_contains "active owner renewal is explained" "$comments" 'while the hand agent owns the ticket'
}

test_expired_repeat_cap_hold_renews_while_hand_agent_owns_ticket() {
  local now sweep_started expiry labels comments
  reset_fixture
  now="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
  write_issue 4116 '[{"name":"on-hold"}]' '[]' 'repeat-cap-held issue'
  write_state 4116 "$(jq -cn --arg expires "$now" '{state:"on-hold",hold:{holder:"implement-repeat-cap",release_condition:"review repeated failure signature",expires_at:$expires,stage_before:"ready-for-agent",kind:"repeat-cap"}}')"
  mkdir -p "$AGENT_HOME/land-queue/requests"
  jq -n --arg wt "$ZF_WORKTREE_ROOT/hand-4116" '{ticket:"00000000000000004116",owner:"hand-4116",worktree:$wt,state:"queued"}' > "$AGENT_HOME/land-queue/requests/00000000000000004116.json"
  sweep_started="$(date -u +%s)"
  run_sweep
  assert_eq "repeat-cap hand owner renewal succeeds" 0 "$LAST_STATUS"
  expiry="$(state_read 4116 | jq -r '.hold.expires_at')"
  [ "$(agent_epoch "$expiry" 2>/dev/null || echo 0)" -ge "$((sweep_started + 168 * 3600))" ] || fail "renewed repeat-cap hold expires at least 168 hours ahead"
  labels="$(jq -r '[.labels[].name] | join(",")' "$FAKE_GH_ROOT/issues/4116.json")"
  assert_contains "repeat-cap hand owner keeps hold active" "$labels" on-hold
  assert_not_contains "repeat-cap hand owner does not restore lane label" "$labels" ready-for-agent
  comments="$(jq -r '[.comments[].body] | join("\n")' "$FAKE_GH_ROOT/issues/4116.json")"
  assert_contains "repeat-cap owner renewal is explained" "$comments" 'while the hand agent owns the ticket'
}

test_expired_loop_hold_releases_for_open_hand_pr() {
  local now labels
  reset_fixture
  now="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
  write_issue 4114 '[{"name":"on-hold"}]' '[]' 'loop-held issue'
  write_state 4114 "$(jq -cn --arg expires "$now" '{state:"on-hold",hold:{holder:"detect-label-churn",release_condition:"hand PR flow completes",expires_at:$expires,stage_before:"needs-triage",kind:"label-churn"}}')"
  FAKE_PR_LIST_RESPONSE='[{"number":501}]'
  export FAKE_PR_LIST_RESPONSE
  run_sweep
  assert_eq "open hand PR expiry succeeds" 0 "$LAST_STATUS"
  labels="$(jq -r '[.labels[].name] | join(",")' "$FAKE_GH_ROOT/issues/4114.json")"
  assert_contains "open PR restores triage stage" "$labels" needs-triage
  assert_not_contains "open PR no longer renews an ownerless hold" "$labels" on-hold
  FAKE_PR_LIST_RESPONSE='[]'
  export FAKE_PR_LIST_RESPONSE
}

test_expired_loop_implement_handoff_keeps_open_pr() {
  local now kind holder n pr labels state
  for kind in label-churn repeat-cap; do
    reset_fixture
    now="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
    n=4114; holder=detect-label-churn
    if [ "$kind" = repeat-cap ]; then n=4116; holder=implement-repeat-cap; fi
    pr=$((n + 100))
    write_issue "$n" '[{"name":"on-hold"}]' '[]' 'implement hold with open PR'
    write_state "$n" "$(jq -cn --arg expires "$now" --arg kind "$kind" --arg holder "$holder" '{state:"on-hold",hold:{holder:$holder,release_condition:"finish the change",expires_at:$expires,stage_before:"ready-for-agent",kind:$kind}}')"
    FAKE_PR_LIST_RESPONSE="$(jq -cn --argjson pr "$pr" --arg branch "agent/issue-$n" '[{number:$pr,headRefName:$branch}]')"
    export FAKE_PR_LIST_RESPONSE
    export FAKE_HOLD_PR_CHECKS='[{"name":"ci","bucket":"pass"}]'
    run_sweep
    assert_eq "$kind open PR handoff succeeds" 0 "$LAST_STATUS"
    labels="$(jq -r '[.labels[].name] | join(",")' "$FAKE_GH_ROOT/issues/$n.json")"
    assert_contains "$kind returns to scheduler" "$labels" ready-for-agent
    assert_not_contains "$kind releases expired hold" "$labels" on-hold
    state="$(state_read "$n")"
    assert_eq "$kind preserves the open PR" "$pr" "$(jq -r '.scheduler_handoff.open_pr // empty' <<< "$state")"
    assert_contains "$kind records the handoff comment" "$(jq -r '[.comments[].body] | join("\n")' "$FAKE_GH_ROOT/issues/$n.json")" 'The scheduler will resume this issue'
  done
}

test_replaced_hold_is_not_released_or_notified() {
  local kind holder now state
  for kind in external-deliverable ops-acceptance-after-release label-churn; do
    reset_fixture
    now="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
    write_issue 4117 '[{"name":"on-hold"}]' '[]' 'hold changed during sweep'
    holder=supervisor; [[ "$kind" != label-churn ]] || holder=detect-label-churn
    write_state 4117 "$(jq -cn --arg expires "$now" --arg kind "$kind" --arg holder "$holder" '{state:"on-hold",attempts:9,hold:{holder:$holder,release_condition:"old work",expires_at:$expires,stage_before:"ready-for-agent",kind:$kind}}')"
    if [[ "$kind" == label-churn ]]; then
      mkdir -p "$AGENT_HOME/land-queue/requests"
      jq -n --arg wt "$ZF_WORKTREE_ROOT/hand-4117" '{ticket:"00000000000000004117",owner:"hand-4117",worktree:$wt,state:"queued"}' > "$AGENT_HOME/land-queue/requests/00000000000000004117.json"
    fi
    jq '.hold={holder:"supervisor",kind:"manual",release_condition:"new decision",created_at:(now|todate),expires_at:(now+86400|todate),stage_before:"ready-for-agent",durable_record:true}' \
      "$AGENT_HOME/state/4117.json" > "$FAKE_GH_ROOT/replacement-4117.json"
    run_sweep
    assert_eq "$kind replaced hold causes a safe retry" 1 "$LAST_STATUS"
    state="$(state_read 4117)"
    assert_eq "$kind leaves replacement on hold" on-hold "$(jq -r .state <<< "$state")"
    assert_eq "$kind retains new hold" 'new decision' "$(jq -r .hold.release_condition <<< "$state")"
    assert_eq "$kind does not reset replacement attempts" 9 "$(jq -r .attempts <<< "$state")"
    assert_eq "$kind leaves GitHub on hold" true "$(jq -r 'any(.labels[]; .name=="on-hold")' "$FAKE_GH_ROOT/issues/4117.json")"
    assert_eq "$kind does not post a stale handoff" 0 "$(jq '.comments|length' "$FAKE_GH_ROOT/issues/4117.json")"
    assert_not_contains "$kind does not notify for the replaced hold" "$(cat "$AGENT_HOME/supervisor-inbox")" 'ops-acceptance-after-release issue=#4117'
  done
}

test_supervisor_snapshot_does_not_release_replacement() {
  local created state
  reset_fixture
  created="$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
  write_issue 4118 '[{"name":"on-hold"}]' '[]' 'hold changed after snapshot'
  write_state 4118 "$(jq -cn --arg created "$created" '{state:"on-hold",hold:{holder:"supervisor",kind:"external-deliverable",release_condition:"old work",created_at:$created,expires_at:(now+3600|todate),stage_before:"ready-for-agent"}}')"
  jq '.hold.release_condition="new work" | .hold.created_at=(now|todate) | .hold.expires_at=(now+86400|todate)' \
    "$AGENT_HOME/state/4118.json" > "$FAKE_GH_ROOT/blocker-replacement-4118.json"
  supervisor_hold_sweep 4118
  state="$(state_read 4118)"
  assert_eq "supervisor snapshot preserves replacement" 'new work' "$(jq -r .hold.release_condition <<< "$state")"
  assert_eq "supervisor snapshot keeps replacement on hold" on-hold "$(jq -r .state <<< "$state")"
  assert_eq "supervisor snapshot does not post a stale handoff" 0 "$(jq '.comments|length' "$FAKE_GH_ROOT/issues/4118.json")"
}

test_merged_hold_does_not_release_replacement() {
  local created state status=0
  reset_fixture
  created="$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
  write_issue 4119 '[{"name":"on-hold"}]' '[]' 'merged while hold changes'
  write_state 4119 "$(jq -cn --arg created "$created" '{state:"on-hold",hold:{holder:"supervisor",kind:"guarded-recut-repeat",release_condition:"old work",created_at:$created,expires_at:(now+86400|todate),stage_before:"ready-for-agent"}}')"
  jq '.hold={holder:"supervisor",kind:"ops-acceptance-after-release",release_condition:"verify new deployment",created_at:(now|todate),expires_at:(now+86400|todate),stage_before:"awaiting-release",durable_record:true}' \
    "$AGENT_HOME/state/4119.json" > "$FAKE_GH_ROOT/merged-replacement-4119.json"
  export FAKE_HOLD_MERGED_PRS='[{"number":44119,"headRefName":"agent/issue-4119","baseRefName":"main","state":"MERGED","mergedAt":"2026-10-28T00:00:00Z"}]'
  supervisor_hold_sweep 4119 || status=$?
  assert_eq "merged reconciliation rejects replacement hold" 1 "$status"
  state="$(state_read 4119)"
  assert_eq "merged reconciliation preserves ops hold" ops-acceptance-after-release "$(jq -r .hold.kind <<< "$state")"
  assert_eq "merged reconciliation keeps on-hold label" true "$(jq -r 'any(.labels[]; .name=="on-hold")' "$FAKE_GH_ROOT/issues/4119.json")"
}

test_mark_awaiting_release_rejects_replacement_hold() {
  local expected status=0
  reset_fixture
  write_issue 4122 '[{"name":"on-hold"}]' '[]' 'release transition race'
  write_state 4122 '{"state":"on-hold","hold":{"holder":"supervisor","kind":"guarded-recut-repeat","release_condition":"old work"}}'
  expected="$(jq -c .hold "$AGENT_HOME/state/4122.json")"
  jq '.hold={holder:"supervisor",kind:"ops-acceptance-after-release",release_condition:"verify new deployment",created_at:(now|todate),expires_at:(now+86400|todate),stage_before:"awaiting-release",durable_record:true}' \
    "$AGENT_HOME/state/4122.json" > "$AGENT_HOME/state/4122.tmp"
  mv "$AGENT_HOME/state/4122.tmp" "$AGENT_HOME/state/4122.json"
  mark_awaiting_release 4122 44122 "$expected" || status=$?
  assert_eq "merged transition rejects replacement hold" 1 "$status"
  assert_eq "merged transition preserves ops hold" ops-acceptance-after-release "$(jq -r .hold.kind "$AGENT_HOME/state/4122.json")"
  assert_eq "merged transition keeps on-hold label" true "$(jq -r 'any(.labels[]; .name=="on-hold")' "$FAKE_GH_ROOT/issues/4122.json")"
}

test_pipeline_close_does_not_close_replacement_hold() (
  local expected status=0 close_log="$test_env_root/race-close.log"
  reset_fixture
  write_issue 4120 '[{"name":"on-hold"}]' '[]' 'pipeline close race'
  write_state 4120 "$(jq -cn --arg sha "$(printf '%040x' 20)" '{state:"on-hold",pipeline_system:{enabled:true,commit_sha:$sha},hold:{holder:"supervisor",kind:"guarded-recut-repeat",release_condition:"old work",expires_at:(now+86400|todate),stage_before:"ready-for-agent"}}')"
  expected="$(jq -c .hold "$AGENT_HOME/state/4120.json")"
  issue_closure_evidence_valid() { return 0; }
  web_advisor_provider_clear_job_state() { return 0; }
  gh() { if [[ "$1 $2" == 'issue view' ]]; then printf 'OPEN\n'; else return 1; fi; }
  guarded_issue_comment() {
    jq '.hold={holder:"supervisor",kind:"ops-acceptance-after-release",release_condition:"verify new deployment",created_at:(now|todate),expires_at:(now+86400|todate),stage_before:"awaiting-release",durable_record:true}' \
      "$AGENT_HOME/state/4120.json" > "$AGENT_HOME/state/4120.tmp"
    mv "$AGENT_HOME/state/4120.tmp" "$AGENT_HOME/state/4120.json"
  }
  guarded_write() { printf 'close\n' >> "$close_log"; }
  conclude_run 4120 pipeline-system 'merged' "" "$expected" || status=$?
  [[ "$status" == 1 && ! -s "$close_log" ]] || { echo 'replacement ops hold did not prevent pipeline close' >&2; exit 1; }
  [[ "$(jq -r .hold.kind "$AGENT_HOME/state/4120.json")" == ops-acceptance-after-release ]] \
    || { echo 'pipeline close replaced the new ops hold' >&2; exit 1; }
)

test_pipeline_close_accepts_unchanged_hold() (
  local expected close_log="$test_env_root/unchanged-close.log"
  reset_fixture
  write_issue 4120 '[{"name":"on-hold"}]' '[]' 'pipeline close unchanged hold'
  write_state 4120 "$(jq -cn --arg sha "$(printf '%040x' 20)" '{state:"on-hold",pipeline_system:{enabled:true,commit_sha:$sha},hold:{holder:"supervisor",kind:"guarded-recut-repeat",release_condition:"old work",expires_at:(now+86400|todate),stage_before:"ready-for-agent"}}')"
  expected="$(jq -c .hold "$AGENT_HOME/state/4120.json")"
  issue_closure_evidence_valid() { return 0; }
  web_advisor_provider_clear_job_state() { return 0; }
  ensure_state_labels() { return 0; }
  gh() { if [[ "$1 $2" == 'issue view' ]]; then printf 'OPEN\n'; else return 1; fi; }
  guarded_issue_comment() { return 0; }
  guarded_write() { if [[ "$1 $2 $3" == 'gh issue close' ]]; then printf 'close\n' >> "$close_log"; fi; return 0; }
  conclude_run 4120 pipeline-system 'merged' "" "$expected"
  [[ "$(cat "$close_log")" == close && "$(jq -r .state "$AGENT_HOME/state/4120.json")" == concluded ]] \
    || { echo 'unchanged hold did not allow the verified pipeline close' >&2; exit 1; }
)

test_expired_loop_hold_releases_without_hand_owner_or_pr() {
  local now labels
  reset_fixture
  now="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
  write_issue 4115 '[{"name":"on-hold"}]' '[]' 'loop-held issue'
  write_state 4115 "$(jq -cn --arg expires "$now" '{state:"on-hold",hold:{holder:"detect-label-churn",release_condition:"hand PR flow completes",expires_at:$expires,stage_before:"needs-triage",kind:"label-churn"}}')"
  run_sweep
  assert_eq "unowned loop hold expiry succeeds" 0 "$LAST_STATUS"
  labels="$(jq -r '[.labels[].name] | join(",")' "$FAKE_GH_ROOT/issues/4115.json")"
  assert_contains "unowned loop hold restores prior stage" "$labels" needs-triage
  assert_not_contains "unowned loop hold releases on expiry" "$labels" on-hold
}

test_spend_budget_hold_expires_and_repeats_next_window() {
  local hold labels status repeated
  reset_fixture
  write_issue 4104 '[{"name":"ready-for-agent"}]' '[]'
  write_state 4104 '{"state":"ready-for-agent"}'
  if route_issue_spend_budget 4104 10 1100; then status=0; else status=$?; fi
  assert_eq "first spend-budget route succeeds" 0 "$status"
  hold="$(jq -c '.hold' "$(state_file 4104)")"
  assert_eq "spend-budget expiry matches budget window end" "$(jq -r '.issue_spend_budget.window_end // empty' "$(state_file 4104)")" "$(jq -r '.expires_at // empty' <<< "$hold")"
  assert_eq "spend-budget hold names its process owner" issue-spend-budget "$(jq -r '.holder // empty' <<< "$hold")"
  assert_contains "spend-budget hold rings the supervisor" "$(cat "$AGENT_HOME/supervisor-inbox" 2>/dev/null)" "spend-budget-hold issue=#4104"
  state_merge 4104 '.hold = ((.hold // {}) + {kind:"spend-budget",holder:"issue-spend-budget",release_condition:"spend window ends",stage_before:"ready-for-agent",expires_at:(now - 1 | todate)}) | .issue_spend_budget.routed_at = ((now - 86401) | todate) | .issue_spend_budget.window_end = ((now - 1) | todate)'
  run_sweep
  assert_eq "expired spend-budget sweep succeeds" 0 "$LAST_STATUS"
  labels="$(jq -r '[.labels[].name] | join(",")' "$FAKE_GH_ROOT/issues/4104.json")"
  assert_contains "spend-budget expiry restores previous stage" "$labels" ready-for-agent
  assert_not_contains "spend-budget expiry lifts hold" "$labels" on-hold
  if route_issue_spend_budget 4104 12 1300; then status=0; else status=$?; fi
  assert_eq "second spend-budget route succeeds" 0 "$status"
  repeated="$(state_read 4104)"
  assert_eq "second spend-budget trip records repeat" true "$(jq -r '.issue_spend_budget.repeated // false' <<< "$repeated")"
  assert_eq "second spend-budget trip increments repeat count" 1 "$(jq -r '.issue_spend_budget.repeat_count // 0' <<< "$repeated")"
  assert_eq "second spend-budget trip stays held" issue-spend-budget "$(jq -r '.hold.holder // empty' <<< "$repeated")"
  assert_contains "repeat route comment says it repeated" "$(jq -r '[.comments[].body] | join("\n")' "$FAKE_GH_ROOT/issues/4104.json")" '重复触发'
}

test_spend_budget_window_leaves_existing_hold_unchanged() {
  local routed_at window_end before_issue before_state status
  reset_fixture
  routed_at="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
  window_end="$(date -u -d '23 hours' +%Y-%m-%dT%H:%M:%SZ)"
  write_issue 4109 '[{"name":"on-hold"}]' '[]'
  write_state 4109 "$(jq -cn --arg routed "$routed_at" --arg window_end "$window_end" \
    '{state:"on-hold",hold:{holder:"operator",release_condition:"review",expires_at:$window_end,stage_before:"ready-for-agent",kind:"manual"},issue_spend_budget:{routed_at:$routed,window_end:$window_end,repeat_count:0}}')"
  before_issue="$(jq -S '.' "$FAKE_GH_ROOT/issues/4109.json")"
  before_state="$(jq -S '.' "$AGENT_HOME/state/4109.json")"
  if route_issue_spend_budget 4109 11 1200; then status=0; else status=$?; fi
  assert_eq "in-window spend route keeps existing hold" 0 "$status"
  assert_eq "existing held issue is unchanged" "$before_issue" "$(jq -S '.' "$FAKE_GH_ROOT/issues/4109.json")"
  assert_eq "existing hold and spend state are unchanged" "$before_state" "$(jq -S '.' "$AGENT_HOME/state/4109.json")"
  assert_not_contains "existing hold is not rewritten" "$(cat "$FAKE_GH_LOG")" 'edit 4109'
  assert_not_contains "in-window route posts no comment" "$(cat "$FAKE_GH_LOG")" 'comment 4109'
}

test_cli_requires_complete_hold_metadata() {
  reset_fixture
  run_hold_cli 4105 --holder operator --release 'approval arrives'
  [ "$LAST_STATUS" -ne 0 ] || fail "hold CLI rejects missing expiry"
  assert_contains "hold CLI explains required arguments" "$(cat "$test_env_root/hold.out")" 'expires'
}

test_cli_rejects_unknown_holder() {
  reset_fixture
  write_issue 4105 '[{"name":"ready-for-agent"}]' '[]'
  write_state 4105 '{"state":"ready-for-agent"}'
  run_hold_cli 4105 --holder unknown --release 'review hold' --expires 24h
  [ "$LAST_STATUS" -ne 0 ] || fail "hold CLI rejects unknown holder"
  assert_contains "unknown holder refusal is explicit" "$(cat "$test_env_root/hold.out")" 'unknown holder is not valid'
  assert_not_contains "unknown holder refusal applies no label" "$(jq -r '[.labels[].name] | join(",")' "$FAKE_GH_ROOT/issues/4105.json")" on-hold
}

test_cli_records_and_applies_hold() {
  local state labels comments
  reset_fixture
  write_issue 4106 '[{"name":"ready-for-agent"}]' '[]'
  run_hold_cli --hold 4106 --holder operator --release 'approval arrives' --expires 24h
  assert_eq "valid hold CLI succeeds" 0 "$LAST_STATUS"
  labels="$(jq -r '[.labels[].name] | join(",")' "$FAKE_GH_ROOT/issues/4106.json")"
  assert_contains "valid hold CLI adds hold label" "$labels" on-hold
  state="$(state_read 4106)"
  assert_eq "valid hold CLI records holder" operator "$(jq -r '.hold.holder // empty' <<< "$state")"
  assert_eq "valid hold CLI records release condition" 'approval arrives' "$(jq -r '.hold.release_condition // empty' <<< "$state")"
  assert_eq "valid hold CLI records original stage" ready-for-agent "$(jq -r '.hold.stage_before // empty' <<< "$state")"
  assert_eq "valid hold CLI marks durable record" true "$(jq -r '.hold.durable_record' <<< "$state")"
  comments="$(jq -r '[.comments[].body] | join("\n")' "$FAKE_GH_ROOT/issues/4106.json")"
  assert_contains "valid hold CLI writes durable GitHub marker" "$comments" '<!-- vecta-hold-record-v1 issue=4106 record='
}

test_out_of_tick_cli_hold_fetches_and_cleans_roadmap_cache() {
  local original status=0 output labels
  reset_fixture
  jq '.switches["roadmap-order"] = true | .roles.advisor.disabled = false' "$SCRIPT_DIR/model-policy.default.json" > "$AGENT_HOME/model-policy.json"
  write_issue 4110 '[{"name":"ready-for-agent"}]' '[]' 'out-of-tick hold'
  write_state 4110 '{"state":"ready-for-agent"}'
  unset ZF_ROADMAP_TREE_CACHE_FILE
  original="$(declare -f roadmap_fetch_tree)"
  roadmap_fetch_tree() {
    printf '%s\n' "$2" >> "$AGENT_HOME/night/roadmap-fetch.log"
    cat > "$1" <<'JSON'
{"roots":[{"number":1,"title":"Roadmap","state":"open","labels":["roadmap"],"children":[{"number":2,"title":"Hold epic","state":"open","labels":["roadmap-epic"],"children":[{"number":4110,"title":"out-of-tick hold","state":"open","labels":["ready-for-agent"],"children":[]}]}]}]}
JSON
  }
  if output="$(hold_cli_main --hold 4110 --holder supervisor --release 'hand owns' --expires 24h 2>&1)"; then
    status=0
  else
    status=$?
  fi
  eval "$original"
  jq '.switches["roadmap-order"] = false | .roles.advisor.disabled = false' "$SCRIPT_DIR/model-policy.default.json" > "$AGENT_HOME/model-policy.json"
  assert_eq "out-of-tick --hold succeeds without a cache env" 0 "$status"
  assert_not_contains "out-of-tick hold avoids the old cache refusal" "$output" 'roadmap: no per-tick tree cache'
  assert_eq "out-of-tick hold fetches one roadmap tree" 'test/repo' "$(cat "$AGENT_HOME/night/roadmap-fetch.log" 2>/dev/null || true)"
  labels="$(jq -r '[.labels[].name] | join(",")' "$FAKE_GH_ROOT/issues/4110.json")"
  assert_contains "out-of-tick --hold applies on-hold" "$labels" on-hold
  assert_eq "out-of-tick hold removes scratch cache" 0 "$(find "$AGENT_HOME/night" -maxdepth 1 -type d -name '.roadmap-parent.*' | wc -l | tr -d '[:space:]')"
}

test_cli_rebuilds_ownerless_hold_with_verified_stage() {
  local state labels comments
  reset_fixture
  write_issue 4108 '[{"name":"on-hold"}]' '[]' 'ownerless hold'
  write_state_unmarked 4108 '{"state":"on-hold"}'
  run_hold_cli 4108 --holder operator --release 'maintainer approval' --expires 24h --kind manual --stage-before needs-advisor
  assert_eq "ownerless repair command succeeds" 0 "$LAST_STATUS"
  state="$(state_read 4108)"
  assert_eq "repair records verified prior stage" needs-advisor "$(jq -r '.hold.stage_before' <<< "$state")"
  assert_eq "repair records real holder" operator "$(jq -r '.hold.holder' <<< "$state")"
  assert_eq "repaired hold is durable" true "$(jq -r '.hold.durable_record' <<< "$state")"
  labels="$(jq -r '[.labels[].name] | join(",")' "$FAKE_GH_ROOT/issues/4108.json")"
  assert_contains "repair keeps issue on hold" "$labels" on-hold
  comments="$(jq -r '[.comments[].body] | join("\n")' "$FAKE_GH_ROOT/issues/4108.json")"
  assert_contains "repair writes durable source comment" "$comments" '<!-- vecta-hold-record-v1 issue=4108 record='
}

test_durable_hold_restores_deleted_local_state() {
  local original original_hold restored restored_hold comments
  reset_fixture
  write_issue 4107 '[{"name":"ready-for-agent"}]' '[]'
  write_state 4107 '{"state":"ready-for-agent"}'
  run_hold_cli 4107 --holder operator --release 'approval arrives' --expires 36h --kind manual
  assert_eq "durable restoration fixture hold succeeds" 0 "$LAST_STATUS"
  original="$(state_read 4107)"
  original_hold="$(jq -S '.hold | del(.durable_record)' <<< "$original")"
  assert_eq "fixture has archived complete hold" true "$(jq -r '.hold.durable_record' <<< "$original")"

  rm -f -- "$(state_file 4107)"
  run_hold_cli --restore 4107
  assert_eq "targeted restore rebuilds lost local state" 0 "$LAST_STATUS"
  restored="$(state_read 4107)"
  restored_hold="$(jq -S '.hold | del(.durable_record)' <<< "$restored")"
  assert_eq "restored hold matches original metadata" "$original_hold" "$restored_hold"
  assert_eq "restored issue stage remains on hold" on-hold "$(jq -r '.state' <<< "$restored")"
  assert_eq "restored hold has durable marker" true "$(jq -r '.hold.durable_record' <<< "$restored")"
  assert_not_contains "restoration never writes unknown holder" "$(jq -c '.hold' <<< "$restored")" 'unknown'
  assert_not_contains "restoration never writes backfill kind" "$(jq -c '.hold' <<< "$restored")" 'backfill'
  comments="$(jq -r '[.comments[].body] | join("\n")' "$FAKE_GH_ROOT/issues/4107.json")"
  assert_not_contains "restoration does not invent an expiry comment" "$comments" 'vecta-hold-backfill'

  rm -f -- "$(state_file 4107)"
  run_sweep
  assert_eq "scheduled sweep uses the same durable recovery" 0 "$LAST_STATUS"
  assert_eq "scheduled sweep restores the same record" "$original_hold" "$(jq -S '.hold | del(.durable_record)' "$(state_file 4107)")"
}

test_durable_hold_restore_clears_stale_prior_stage_label() {
  local labels snapshot drift state original_hold restored_hold
  reset_fixture
  write_issue 4200 '[{"name":"needs-triage"}]' '[]' 'held issue with stale prior-stage label'
  write_state 4200 '{"state":"needs-triage"}'
  run_hold_cli 4200 --holder operator --release 'verified recovery' --expires 24h --kind manual
  assert_eq "hold fixture records the prior stage" needs-triage "$(state_read 4200 | jq -r '.hold.stage_before')"
  original_hold="$(jq -S '.hold | del(.durable_record)' "$(state_file 4200)")"
  jq '.labels += [{name:"needs-triage"}]' "$FAKE_GH_ROOT/issues/4200.json" > "$FAKE_GH_ROOT/issues/4200.tmp"
  mv "$FAKE_GH_ROOT/issues/4200.tmp" "$FAKE_GH_ROOT/issues/4200.json"
  write_state 4200 '{"state":"needs-triage"}'
  snapshot="$(jq -c '[{number,labels}]' "$FAKE_GH_ROOT/issues/4200.json")"
  assert_eq "stale stage plus hold reproduces reported outcomes drift" \
    'state-label-drift=1 (#4200(state=needs-triage labels=needs-triage,on-hold))' \
    "$(outcomes_state_label_drift "$AGENT_HOME" "$snapshot")"

  run_hold_cli --restore 4200
  assert_eq "exact prior-stage label permits durable restore" 0 "$LAST_STATUS"
  state="$(state_read 4200)"
  restored_hold="$(jq -S '.hold | del(.durable_record)' <<< "$state")"
  assert_eq "restore aligns persisted state with hold label" on-hold "$(jq -r '.state' <<< "$state")"
  assert_eq "restore preserves all durable hold fields" "$original_hold" "$restored_hold"
  assert_eq "restored metadata keeps exact stage" needs-triage "$(jq -r '.hold.stage_before' <<< "$state")"
  assert_eq "restore preserves original holder" operator "$(jq -r '.hold.holder' <<< "$state")"
  assert_eq "restore preserves original release condition" 'verified recovery' "$(jq -r '.hold.release_condition' <<< "$state")"
  assert_eq "restore preserves the original expiry" "$(jq -r '.expires_at' <<< "$original_hold")" "$(jq -r '.hold.expires_at' <<< "$state")"
  labels="$(jq -r '[.labels[].name] | join(",")' "$FAKE_GH_ROOT/issues/4200.json")"
  assert_contains "restore preserves the existing hold label" "$labels" on-hold
  assert_not_contains "restore removes the stale prior-stage label" "$labels" needs-triage
  snapshot="$(jq -c '[{number,labels}]' "$FAKE_GH_ROOT/issues/4200.json")"
  assert_eq "restored hold no longer produces outcomes drift" 'state-label-drift=0' \
    "$(outcomes_state_label_drift "$AGENT_HOME" "$snapshot")"

  rm -f -- "$(state_file 4200)"
  jq '.labels = [.labels[] | select(.name != "needs-triage")] + [{name:"needs-advisor"}]' \
    "$FAKE_GH_ROOT/issues/4200.json" > "$FAKE_GH_ROOT/issues/4200.tmp"
  mv "$FAKE_GH_ROOT/issues/4200.tmp" "$FAKE_GH_ROOT/issues/4200.json"
  : > "$FAKE_GH_LOG"
  run_hold_cli --restore 4200
  assert_eq "different stage label still blocks durable restore" 1 "$LAST_STATUS"
  assert_eq "mismatched stage does not create local hold state" false "$(test -e "$(state_file 4200)" && echo true || echo false)"
  assert_not_contains "mismatched stage does not write GitHub labels" "$(cat "$FAKE_GH_LOG")" 'edit 4200'
  assert_not_contains "mismatched stage does not write GitHub comments" "$(cat "$FAKE_GH_LOG")" 'comment 4200'
}

test_complete_hold_without_created_at_is_durable() {
  local expires state comments
  reset_fixture
  expires="$(date -u -d '12 hours' +%Y-%m-%dT%H:%M:%SZ)"
  write_issue 4194 '[{"name":"on-hold"}]' '[]' 'legacy complete hold'
  write_state_unmarked 4194 "$(jq -cn --arg expires "$expires" \
    '{state:"on-hold",hold:{holder:"operator",release_condition:"approval arrives",expires_at:$expires,stage_before:"ready-for-agent",kind:"manual"}}')"

  run_sweep
  assert_eq "complete legacy hold sweep succeeds" 0 "$LAST_STATUS"
  state="$(state_read 4194)"
  assert_eq "legacy hold is durable without synthetic creation time" true "$(jq -r '.hold.durable_record' <<< "$state")"
  assert_eq "legacy hold preserves absent creation time" null "$(jq -r '.hold.created_at // null' <<< "$state")"
  comments="$(jq -r '[.comments[].body] | join("\n")' "$FAKE_GH_ROOT/issues/4194.json")"
  assert_contains "legacy hold archives exact fields to GitHub" "$comments" '<!-- vecta-hold-record-v1 issue=4194 record='
}

run_case "direct hold-label guard" test_no_direct_hold_label_writers
test_settled_holds_skip_issue_reads() {
  local expiry
  reset_fixture
  expiry="$(date -u -d '+1 day' +%Y-%m-%dT%H:%M:%SZ)"
  write_issue 4107 '[{"name":"on-hold"}]' '[]'
  write_state 4107 "$(jq -cn --arg expires "$expiry" '{state:"on-hold",hold:{holder:"supervisor",release_condition:"fix lands",expires_at:$expires,stage_before:"ready-for-agent",kind:"manual"}}')"
  write_issue 4108 '[{"name":"on-hold"}]' '[]'
  write_state 4108 '{"state":"on-hold","state_changed_from":"ready-for-agent"}'
  run_sweep
  assert_eq "first sweep succeeds" 0 "$LAST_STATUS"
  assert_not_contains "an unexpired owned hold is not read from GitHub" "$(cat "$FAKE_GH_LOG")" 'view 4107'
  assert_contains "ownerless record is read to find durable source" "$(cat "$FAKE_GH_LOG")" 'view 4108'
  : > "$FAKE_GH_LOG"
  run_sweep
  assert_eq "second sweep succeeds" 0 "$LAST_STATUS"
  assert_contains "ownerless record is rechecked for later durable source" "$(cat "$FAKE_GH_LOG")" 'view 4108'
}

test_supervisor_holds_scans_live_worktrees_once() {
  local first_issue=42000 last_issue=42039 now numbers='' state_index_json scan_log
  local original_owner_probe original_worktree_snapshot rows
  reset_fixture
  now="$(date -u +%s)"
  scan_log="$test_env_root/supervisor-holds-worktree-scans"
  : > "$scan_log"
  for ((issue = first_issue; issue <= last_issue; issue++)); do
    numbers+="$issue"$'\n'
  done
  state_index_json="$(python3 - "$now" "$first_issue" "$last_issue" <<'PY'
import json
import sys
from datetime import datetime, timezone

now, first, last = map(int, sys.argv[1:])
hold = {
    "holder": "supervisor",
    "kind": "manual",
    "release_condition": "review hold",
    "created_at": datetime.fromtimestamp(now - 3600, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "expires_at": datetime.fromtimestamp(now + 86400, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "stage_before": "ready-for-agent",
    "durable_record": True,
}
print(json.dumps({"holds": {str(issue): hold for issue in range(first, last + 1)}}))
PY
)"
  original_owner_probe="$(declare -f hand_agent_worktree_pid)"
  original_worktree_snapshot="$(declare -f hand_codex_worktrees 2>/dev/null || true)"
  hand_codex_worktrees() {
    printf 'snapshot\n' >> "$scan_log"
    printf '%s/hand-%s\n' "$ZF_WORKTREE_ROOT" "$first_issue"
  }
  hand_agent_worktree_pid() { printf 'per-hold\n' >> "$scan_log"; return 1; }

  rows="$(supervisor_holds_snapshot "$numbers" "$now" '[]' "$state_index_json")"

  eval "$original_owner_probe"
  if [[ -n "$original_worktree_snapshot" ]]; then eval "$original_worktree_snapshot"; else unset -f hand_codex_worktrees; fi
  assert_eq "large hold cohort remains fully represented" "$((last_issue - first_issue + 1))" "$(jq 'length' <<< "$rows")"
  assert_eq "one held issue still sees its live Codex worktree" running "$(jq -r --argjson issue "$first_issue" '[.[] | select(.issue == $issue)][0].owner' <<< "$rows")"
  assert_eq "other holds remain unowned after one scan" "$((last_issue - first_issue))" \
    "$(jq -r '[.[] | select(.owner == "waiting")] | length' <<< "$rows")"
  assert_eq "large hold cohort scans process table once" 1 "$(wc -l < "$scan_log" | tr -d '[:space:]')"
}

test_routed_ops_dispatch_respects_blockers_and_live_owner() {
  local created labels comments
  reset_fixture
  created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  write_issue 4140 '[{"name":"on-hold"}]' '[]' 'routed external task'
  write_state 4140 "$(jq -cn --arg created "$created" '{state:"on-hold",external_deliverable:{required:true,location:"host report",reason:"Write report"},hold:{holder:"supervisor",kind:"external-deliverable",created_at:$created,release_condition:"ops complete",expires_at:(now+604800|todate)}}')"
  has_open_blocker() { OPEN_BLOCKER_IDS="${FAKE_OPS_BLOCKER_IDS:-}"; OPEN_BLOCKER_QUERY_FAILED=0; [ -n "$OPEN_BLOCKER_IDS" ]; }
  export FAKE_OPS_BLOCKER_IDS=4149
  supervisor_hold_sweep 4140
  assert_eq "native blocker preserves hold" on-hold "$(state_read 4140 | jq -r '.state')"
  export FAKE_OPS_BLOCKER_IDS=''
  supervisor_hold_sweep 4140
  supervisor_hold_sweep 4140
  labels="$(jq -r '[.labels[].name]|join(",")' "$FAKE_GH_ROOT/issues/4140.json")"
  comments="$(jq -r '[.comments[].body]|join("\n")' "$FAKE_GH_ROOT/issues/4140.json")"
  assert_contains "unblocked external hold returns to scheduler" "$labels" ready-for-agent
  assert_not_contains "unblocked external hold is cleared" "$labels" on-hold
  assert_contains "handoff carries external evidence requirement" "$comments" 'host report'
  assert_eq "external handoff is recorded once" 1 "$(grep -c 'vecta-scheduler-handoff issue=4140' <<< "$comments")"
}
test_scheduler_handoff_retries_failed_writes() {
  local created status failing
  for failing in comment edit; do
    reset_fixture
    created="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
    write_issue 4168 '[{"name":"on-hold"}]' '[]' 'handoff retry'
    write_state 4168 "$(jq -cn --arg created "$created" '{state:"on-hold",last_failure_reason:"repair evidence",hold:{holder:"supervisor",kind:"guarded-recut-repeat",created_at:$created,release_condition:"resolve finding"}}')"
    if [ "$failing" = comment ]; then export FAKE_HOLD_COMMENT_FAILURE=1; else export FAKE_HOLD_EDIT_FAILURE=1; fi
    status=0
    supervisor_hold_sweep 4168 || status=$?
    assert_eq "$failing failure is surfaced" 1 "$status"
    assert_eq "$failing failure leaves hold in place" on-hold "$(state_read 4168 | jq -r '.state')"
    assert_eq "$failing failure leaves remote hold in place" true "$(jq -r 'any(.labels[]; .name=="on-hold")' "$FAKE_GH_ROOT/issues/4168.json")"
    unset FAKE_HOLD_COMMENT_FAILURE FAKE_HOLD_EDIT_FAILURE
    supervisor_hold_sweep 4168
    assert_eq "$failing retry requeues" ready-for-agent "$(state_read 4168 | jq -r '.state')"
    assert_eq "$failing retry posts one handoff" 1 "$(jq '[.comments[] | select(.body | contains("vecta-scheduler-handoff issue=4168"))] | length' "$FAKE_GH_ROOT/issues/4168.json")"
    assert_contains "$failing retry preserves failure evidence" "$(jq -r '.comments[-1].body' "$FAKE_GH_ROOT/issues/4168.json")" 'repair evidence'
  done
}

test_scheduler_handoff_does_not_release_replacement_hold() {
  local created status original
  reset_fixture
  created="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
  write_issue 4185 '[{"name":"on-hold"}]' '[]' 'replacement hold race'
  write_state 4185 "$(jq -cn --arg created "$created" '{state:"on-hold",hold:{holder:"supervisor",kind:"guarded-recut-repeat",created_at:$created,release_condition:"repair"}}')"
  original="$(declare -f guarded_issue_comment)"
  eval "$(declare -f guarded_issue_comment | sed '1s/guarded_issue_comment/hold_test_original_comment/')"
  guarded_issue_comment() {
    hold_test_original_comment "$@" || return
    state_merge "$1" '.hold = {holder:"supervisor",kind:"ops-acceptance-after-release",created_at:"new",release_condition:"verify SHA"}'
  }
  status=0
  supervisor_hold_sweep 4185 || status=$?
  eval "$original"
  assert_eq "changed hold makes stale handoff retry" 1 "$status"
  assert_eq "replacement ops hold stays held" ops-acceptance-after-release "$(state_read 4185 | jq -r '.hold.kind')"
  assert_contains "replacement hold keeps its label" "$(jq -r '[.labels[].name]|join(",")' "$FAKE_GH_ROOT/issues/4185.json")" on-hold
}

test_expired_retired_hand_hold_returns_to_scheduler() {
  local created expiry
  reset_fixture
  created="$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
  expiry="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
  write_issue 4169 '[{"name":"on-hold"}]' '[]' 'expired external hold'
  write_state 4169 "$(jq -cn --arg created "$created" --arg expiry "$expiry" '{state:"on-hold",external_deliverable:{location:"host evidence",reason:"report needed"},hold:{holder:"supervisor",kind:"external-deliverable",created_at:$created,expires_at:$expiry,release_condition:"report ready"}}')"
  run_sweep
  assert_eq "expired external hold sweep succeeds" 0 "$LAST_STATUS"
  assert_eq "expired external hold is ready" ready-for-agent "$(state_read 4169 | jq -r '.state')"
  assert_contains "expiry comment carries external brief" "$(jq -r '.comments[-1].body' "$FAKE_GH_ROOT/issues/4169.json")" 'host evidence'
}

test_ops_acceptance_holds_notify_supervisor() {
  local mode n created expiry holder sha
  sha=0123456789abcdef0123456789abcdef01234567
  printf '#!/bin/bash\nexit 0\n' > "$test_env_bin/systemctl"
  chmod +x "$test_env_bin/systemctl"
  for mode in expired dead ownerless; do
    reset_fixture
    created="$(date -u -d '3 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
    expiry="$(date -u -d '1 day' +%Y-%m-%dT%H:%M:%SZ)"
    case "$mode" in
      expired) n=4181; holder=supervisor; expiry="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" ;;
      dead) n=4182; holder=hand-4182 ;;
      ownerless) n=4183; holder=supervisor ;;
    esac
    write_issue "$n" '[{"name":"on-hold"}]' '[]' 'verify deployed release'
    write_state "$n" "$(jq -cn --arg created "$created" --arg expiry "$expiry" --arg holder "$holder" --arg sha "$sha" \
      '{state:"on-hold",deployed_sha:$sha,ops_acceptance_after_release:{required:true,status:"pending",location:"production"},hold:{holder:$holder,kind:"ops-acceptance-after-release",created_at:$created,expires_at:$expiry,stage_before:"awaiting-release",release_condition:"verify deployed SHA",durable_record:true}}')"
    if [ "$mode" = ownerless ]; then
      supervisor_hold_sweep "$n"
      supervisor_hold_sweep "$n"
    else
      run_sweep
      assert_eq "$mode ops hold sweep succeeds" 0 "$LAST_STATUS"
      run_sweep
      assert_eq "$mode ops hold retry succeeds" 0 "$LAST_STATUS"
    fi
    assert_eq "$mode ops acceptance remains on hold" on-hold "$(state_read "$n" | jq -r '.state')"
    assert_contains "$mode keeps the on-hold label" "$(jq -r '[.labels[].name]|join(",")' "$FAKE_GH_ROOT/issues/$n.json")" on-hold
    assert_not_contains "$mode does not schedule implementation" "$(jq -r '[.labels[].name]|join(",")' "$FAKE_GH_ROOT/issues/$n.json")" ready-for-agent
    assert_eq "$mode emits one supervisor event" 1 "$(grep -c "ops-acceptance-after-release issue=#$n" "$AGENT_HOME/supervisor-inbox")"
    assert_contains "$mode event names the deployed SHA" "$(cat "$AGENT_HOME/supervisor-inbox")" "$sha"
    if [ "$mode" = expired ]; then
      sha=abcdef0123456789abcdef0123456789abcdef01
      state_merge "$n" ".deployed_sha = \"$sha\""
      run_sweep
      assert_eq "new deployment creates a second supervisor event" 2 "$(grep -c "ops-acceptance-after-release issue=#$n" "$AGENT_HOME/supervisor-inbox")"
      assert_contains "new supervisor event names the new SHA" "$(cat "$AGENT_HOME/supervisor-inbox")" "$sha"
    fi
  done
  reset_fixture
  mkdir -p "$AGENT_HOME/logs" "$AGENT_HOME/night"
  for n in $(seq 1 21); do printf '%s\tops-acceptance-after-release\tissue=#%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$n"; done > "$AGENT_HOME/logs/supervisor-wakes.log"
  jq -n --arg day "$(date -u +%Y-%m-%d)" '{date:$day,demoted_classes:["ops-acceptance-after-release"]}' > "$AGENT_HOME/night/supervisor-alert-policy.json"
  supervisor_ops_acceptance_handoff 4186 "$(jq -cn --arg sha "$sha" '{deployed_sha:$sha,hold:{release_condition:"verify deployed SHA"}}')" 'fixture'
  assert_contains "budget and demotion do not suppress required ops handoff" "$(cat "$AGENT_HOME/supervisor-inbox")" 'issue=#4186'
  reset_fixture
  rm -f "$AGENT_HOME/supervisor-inbox"
  mkdir -p "$AGENT_HOME/supervisor-inbox"
  if supervisor_ops_acceptance_handoff 4187 "$(jq -cn --arg sha "$sha" '{deployed_sha:$sha}')" 'fixture' 2>/dev/null; then
    echo 'not ok - failed supervisor append returned success' >&2
    exit 1
  fi
  assert_not_contains "failed append does not mark delivery" "$(cat "$AGENT_HOME/supervisor-inbox.once" 2>/dev/null || true)" 'issue=#4187'
  rmdir "$AGENT_HOME/supervisor-inbox"
  supervisor_ops_acceptance_handoff 4187 "$(jq -cn --arg sha "$sha" '{deployed_sha:$sha}')" 'fixture'
  assert_contains "failed supervisor append can be retried" "$(cat "$AGENT_HOME/supervisor-inbox")" 'issue=#4187'
}

test_closed_handoff_is_not_reopened() {
  reset_fixture
  write_issue 4170 '[{"name":"on-hold"}]' '[]' 'already closed'
  write_state 4170 '{"state":"on-hold","hold":{"holder":"supervisor","kind":"external-deliverable"}}'
  scheduler_requeue_issue 4170 'stale handoff' '{"state":"CLOSED","comments":[]}'
  assert_eq "closed issue state is not requeued" on-hold "$(state_read 4170 | jq -r '.state')"
  assert_eq "closed issue receives no handoff" 0 "$(jq '.comments|length' "$FAKE_GH_ROOT/issues/4170.json")"
}

test_reverted_landing_reopens_before_handoff() {
  local request
  reset_fixture
  write_issue 4172 '[{"name":"pipeline-system"},{"name":"on-hold"}]' '[]' 'reverted pipeline issue'
  jq '.state="CLOSED"' "$FAKE_GH_ROOT/issues/4172.json" > "$FAKE_GH_ROOT/issues/4172.tmp"
  mv "$FAKE_GH_ROOT/issues/4172.tmp" "$FAKE_GH_ROOT/issues/4172.json"
  write_state 4172 '{"state":"on-hold","hold":{"holder":"supervisor","kind":"external-deliverable","release_condition":"repair reverted change"}}'
  mkdir -p "$AGENT_HOME/land-queue/requests"
  request="$AGENT_HOME/land-queue/requests/00000000000000004172.json"
  jq -n '{ticket:"00000000000000004172",state:"landed",landed_sha:("1"*40),post_land_verdict:{outcome:"culprit-reverted"},owner:"hand-4172",owned_issues:""}' > "$request"
  pipeline_system_finish_direct_landing "$request" culprit-reverted
  assert_eq "reverted issue was reopened" OPEN "$(jq -r '.state' "$FAKE_GH_ROOT/issues/4172.json")"
  assert_eq "reverted issue is schedulable" ready-for-agent "$(state_read 4172 | jq -r '.state')"
  assert_contains "reverted issue receives the handoff reason" "$(jq -r '[.comments[].body]|join("\n")' "$FAKE_GH_ROOT/issues/4172.json")" 'direct-main landing reverted'
  jq '.ticket="00000000000000004173" | .landed_sha=("2"*40)' "$request" > "$request.next"
  mv "$request.next" "$request"
  pipeline_system_finish_direct_landing "$request" culprit-reverted
  assert_eq "a second reverted landing produces a separate handoff" 2 "$(jq '[.comments[] | select(.body | contains("vecta-scheduler-handoff issue=4172"))] | length' "$FAKE_GH_ROOT/issues/4172.json")"
  assert_contains "second landing ticket identifies the episode" "$(state_read 4172 | jq -r '.scheduler_handoff.episode')" '00000000000000004173'
}

test_maintenance_tick_requeues_ownerless_hold() {
  local created status=0
  reset_fixture
  created="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
  write_issue 4171 '[{"name":"on-hold"}]' '[]' 'ownerless external task'
  write_state 4171 "$(jq -cn --arg created "$created" '{state:"on-hold",external_deliverable:{location:"fixture report",reason:"collect evidence"},hold:{holder:"supervisor",kind:"external-deliverable",created_at:$created,release_condition:"report ready",expires_at:(now+604800|todate)}}')"
  printf '#!/bin/bash\nexit 0\n' > "$test_env_bin/codex"
  printf '#!/bin/bash\nexit 0\n' > "$test_env_bin/systemctl"
  chmod +x "$test_env_bin/codex" "$test_env_bin/systemctl"
  ZF_PIPELINE_ROADMAP_SWITCH=false bash "$SCRIPT_DIR/issue-pipeline.sh" --stage maintenance > "$test_env_root/tick.log" 2>&1 || status=$?
  if [[ "$(state_read 4171 | jq -r '.state')" != ready-for-agent ]]; then cat "$test_env_root/tick.log" >&2; fi
  assert_eq "maintenance tick exits successfully" 0 "$status"
  assert_eq "maintenance tick makes issue ready" ready-for-agent "$(state_read 4171 | jq -r '.state')"
  assert_contains "maintenance tick publishes the external brief" "$(jq -r '[.comments[].body]|join("\n")' "$FAKE_GH_ROOT/issues/4171.json")" 'fixture report'
}

run_case "scheduler handoff retries comment and label failures" test_scheduler_handoff_retries_failed_writes
run_case "stale handoff preserves a replacement hold" test_scheduler_handoff_does_not_release_replacement_hold
run_case "expired retired-hand hold returns to scheduler" test_expired_retired_hand_hold_returns_to_scheduler
run_case "expired and ownerless ops acceptance stays held for supervisor" test_ops_acceptance_holds_notify_supervisor
run_case "closed handoff stays closed" test_closed_handoff_is_not_reopened
run_case "reverted landing reopens before publishing handoff" test_reverted_landing_reopens_before_handoff
run_case "maintenance tick requeues ownerless external hold" test_maintenance_tick_requeues_ownerless_hold
run_case "existing ticket tick sweeps holds" test_existing_tick_runs_hold_sweep
run_case "guarded recut hold sweep queues once" test_guarded_recut_sweep_queues_once
run_case "orphaned hand-dispatch hold requeues its named owner once" test_orphaned_hand_dispatch_hold_requeues_named_owner_once
run_case "supervisor hold sweep uses one current issue snapshot" test_supervisor_holds_uses_batch_issue_snapshot
run_case "supervisor issue snapshot failure preserves holds" test_supervisor_holds_snapshot_failure_preserves_hold
run_case "supervisor hold alert repeats only after hold changes" test_supervisor_hold_alert_dedupes_until_hold_changes
run_case "blocked-on-resolution hold assigns verification owner" test_blocked_on_resolution_sweep_assigns_owner
run_case "blocked-on-resolution supersedes stale BLOCKED-ON owner" test_blocked_on_resolution_replaces_stale_blocked_owner
run_case "blocked-on-resolution pending PR waits" test_blocked_on_resolution_pending_pr_waits
run_case "pending guarded PR waits for its existing checks" test_guarded_pending_pr_is_waiting
run_case "failed guarded PR queues a repair hand" test_guarded_failed_pr_dispatches_repair
run_case "blocked hand owns its held ticket" test_blocked_hand_owns_held_ticket
run_case "guarded hand retries stale worktree collisions safely" test_guarded_hand_dispatch_recovers_from_stale_name_collisions
run_case "paused implement dispatches no guarded hand" test_paused_implement_dispatches_no_guarded_hand
run_case "merged hand hold concludes" test_merged_hand_hold_concludes
run_case "guarded no-diff hold concludes newest merged PR" test_guarded_no_diff_hold_concludes_newest_merged_pr
run_case "green held PR uses shared merge gate" test_green_hand_pr_uses_shared_merge_gate
run_case "carried hotpatch with shared check failure uses shared merge gate" test_carried_hotpatch_hold_uses_shared_merge_gate
run_case "time-waiting supervisor hold stays untouched" test_time_waiting_supervisor_hold_is_untouched
run_case "explicit decision holds stay waiting" test_explicit_decision_holds_are_waiting
run_case "durable waits stay distinct from missing and expired owners" test_durable_waits_are_distinct_from_missing_and_expired_owners
run_case "fastlane holds immediately requeue an out-of-band hand" test_pipeline_system_fastlane_hold_requeues_hand
run_case "named queued hand owns fastlane issue" test_named_queued_hand_owns_fastlane_issue
run_case "queued sweep owns fastlane issues from row and brief" test_queued_sweep_owns_fastlane_issues
run_case "expired hold resumes original stage" test_expired_hold_restores_original_stage
run_case "unknown backfill remains ownerless and unreleased" test_expired_unknown_backfill_stays_ownerless
run_case "manual hold release reconciles persisted state" test_manual_hold_release_reconciles_persisted_state
run_case "durable hold release resolves conflicting labels" test_durable_hold_release_uses_recorded_stage_when_labels_conflict
run_case "closed holds reconcile once by GitHub reason" test_closed_holds_reconcile_once_by_github_reason
run_case "closed-hold GitHub read failure preserves evidence" test_closed_hold_read_failure_preserves_evidence
run_case "unexpired hold stays untouched" test_unexpired_hold_is_untouched
run_case "missing hold record remains ownerless" test_missing_hold_record_stays_ownerless
run_case "marked hold without metadata remains ownerless" test_marked_hold_without_record_stays_ownerless
run_case "expired hotfix hold renews only while marked" test_expired_hotfix_hold_renews_only_while_marked
run_case "expired loop hold renews while hand agent owns ticket" test_expired_loop_hold_renews_while_hand_agent_owns_ticket
run_case "expired repeat-cap hold renews while hand agent owns ticket" test_expired_repeat_cap_hold_renews_while_hand_agent_owns_ticket
run_case "expired loop hold with open hand PR returns to triage" test_expired_loop_hold_releases_for_open_hand_pr
run_case "expired implement loop hold hands open PR to scheduler" test_expired_loop_implement_handoff_keeps_open_pr
run_case "sweep leaves a concurrently replaced hold untouched" test_replaced_hold_is_not_released_or_notified
run_case "supervisor snapshot leaves a replacement hold untouched" test_supervisor_snapshot_does_not_release_replacement
run_case "merged reconciliation leaves a replacement hold untouched" test_merged_hold_does_not_release_replacement
run_case "merged release transition rejects a replacement hold" test_mark_awaiting_release_rejects_replacement_hold
run_case "pipeline close leaves a replacement ops hold open" test_pipeline_close_does_not_close_replacement_hold
run_case "pipeline close completes with the unchanged hold" test_pipeline_close_accepts_unchanged_hold
run_case "expired loop hold releases without hand owner or PR" test_expired_loop_hold_releases_without_hand_owner_or_pr
run_case "spend-budget hold expires and records repeat" test_spend_budget_hold_expires_and_repeats_next_window
run_case "spend-budget window leaves existing hold unchanged" test_spend_budget_window_leaves_existing_hold_unchanged
run_case "CLI refuses incomplete hold" test_cli_requires_complete_hold_metadata
run_case "CLI rejects unknown holder" test_cli_rejects_unknown_holder
run_case "CLI creates owned expiring hold" test_cli_records_and_applies_hold
run_case "out-of-tick CLI hold fetches and cleans roadmap cache" test_out_of_tick_cli_hold_fetches_and_cleans_roadmap_cache
run_case "CLI rebuilds ownerless hold with verified stage" test_cli_rebuilds_ownerless_hold_with_verified_stage
run_case "deleted local hold state restores exact durable record" test_durable_hold_restores_deleted_local_state
run_case "durable hold restore clears stale prior-stage label" test_durable_hold_restore_clears_stale_prior_stage_label
run_case "complete old holds need no fabricated creation time" test_complete_hold_without_created_at_is_durable
run_case "settled holds skip per-issue GitHub reads" test_settled_holds_skip_issue_reads
run_case "supervisor-holds shares one live worktree scan across held issues" test_supervisor_holds_scans_live_worktrees_once
run_case "routed ops dispatch waits for blockers and skips owned hand" test_routed_ops_dispatch_respects_blockers_and_live_owner

if [ "$FAILURES" -eq 0 ]; then
  echo "ALL PASSED"
else
  echo "FAILURES: $FAILURES"
  exit 1
fi
