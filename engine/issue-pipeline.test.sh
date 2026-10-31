#!/usr/bin/env bash
# issue-pipeline.test.sh -- batch-only fresh advisor questions, sent-job
# polling, and stored-verdict recovery.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_SRC="$SCRIPT_DIR/issue-pipeline.sh"
ISSUE_PIPELINE_TEST_AGENT_HOME="$(mktemp -d)"
export AGENT_HOME="$ISSUE_PIPELINE_TEST_AGENT_HOME"
trap 'rm -rf -- "$ISSUE_PIPELINE_TEST_AGENT_HOME"' EXIT
jq '.switches["roadmap-order"] = false | .roles.advisor.disabled = false' "$SCRIPT_DIR/model-policy.default.json" \
  > "$AGENT_HOME/model-policy.json"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/issue-pipeline-slices.sh"
eval "$(sed -n '/^fastlane_scan_order() {/,/^}/p' "$PIPELINE_SRC")"
eval "$(sed -n '/^ensure_issue_roadmap_parent_for_dispatch() {/,/^}/p' "$PIPELINE_SRC")"
# Most scheduler cases exercise state transitions only; checks-blocked restores the real guard.
ROADMAP_ENSURE_ISSUE_PARENT_FN="$(declare -f roadmap_ensure_issue_parent)"
roadmap_ensure_issue_parent() { return 0; }
NIGHT="$AGENT_HOME/night"
source "$SCRIPT_DIR/night/hand-agent-watchdog.sh"
eval "$(sed -n '/^fastlane_snapshot_candidates() {/,/^}/p; /^fastlane_read_path_contexts() {/,/^}/p' "$PIPELINE_SRC")"
ROUTE_PIPELINE_SYSTEM_CANDIDATES_FN="$(sed -n '/^pipeline_system_factory_infra_paths_valid() {/,/^}/p; /^pipeline_system_external_pr_check_state() {/,/^}/p; /^pipeline_system_external_pr_to_product() {/,/^}/p; /^pipeline_system_hand_external_pr_conclusion() {/,/^}/p; /^pipeline_system_hand_report_conclusion() {/,/^}/p; /^route_pipeline_fastlane_issue() {/,/^}/p; /^route_nonproduct_path_issue_rows() {/,/^}/p; /^route_nonproduct_path_candidates() {/,/^}/p' "$PIPELINE_SRC")"
ROUTE_PIPELINE_SYSTEM_CANDIDATES_FN+=$'\n'"$(sed -n '/^fastlane_scan_order() {/,/^}/p; /^fastlane_snapshot_candidates() {/,/^}/p; /^fastlane_read_path_contexts() {/,/^}/p' "$PIPELINE_SRC")"
ROUTE_PIPELINE_SYSTEM_CANDIDATES_FN+=$'\n'"$(sed -n '/^ensure_issue_roadmap_parent_for_dispatch() {/,/^}/p' "$PIPELINE_SRC")"
eval "$(sed -n '/^read_needs_info_email_replies() {/,/^}/p; /^reconcile_needs_info_issues() {/,/^}/p; /^run_post_dispatch_maintenance() {/,/^}/p' "$PIPELINE_SRC")"
eval "$(sed -n '/^reconcile_pipeline_system_delivery() {/,/^}/p' "$PIPELINE_SRC")"

FAILED=0
# Default-cap fixtures must ignore the operator's configured concurrency.
unset AGENT_TRIAGE_CAP

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok - $desc"
  else
    echo "not ok - $desc (expected [$expected], got [$actual])"
    FAILED=1
  fi
}

assert_eq 'fastlane admits a ticket whose only sub-issues are closed' '991100' \
  "$(fastlane_snapshot_candidates '[{"number":991100,"subIssuesSummary":{"total":1,"completed":1}}]' | jq -r '.[0].number')"
assert_eq 'fastlane blocks a ticket with an open sub-issue' '0' \
  "$(fastlane_snapshot_candidates '[{"number":991101,"subIssuesSummary":{"total":1,"completed":0}}]' | jq 'length')"

assert_cond() {
  local desc="$1" cond="$2"
  if [ "$cond" = "1" ]; then
    echo "ok - $desc"
  else
    echo "not ok - $desc"
    FAILED=1
  fi
}

ROADMAP_ORDER_ENABLED=false
ROADMAP_PARENT_CALL=''
roadmap_ensure_issue_parent() {
  ROADMAP_PARENT_CALL="$(printf '%s\t%s\t%s' "$1" "$2" "${3:-}")"
  return "${ROADMAP_PARENT_STATUS:-0}"
}
ensure_issue_roadmap_parent_for_dispatch 910901 needs-triage '{"number":910901}'
assert_eq 'disabled roadmap ordering skips dispatch placement' '' "$ROADMAP_PARENT_CALL"
ROADMAP_ORDER_ENABLED=true
ensure_issue_roadmap_parent_for_dispatch 910900 internal
assert_eq 'non-stage operation skips dispatch placement' '' "$ROADMAP_PARENT_CALL"
ensure_issue_roadmap_parent_for_dispatch 910902 needs-triage '{"number":910902}'
assert_eq 'dispatch placement passes issue, stage, and cached issue data' \
  $'910902\tneeds-triage\t{"number":910902}' "$ROADMAP_PARENT_CALL"
ROADMAP_PARENT_STATUS=1
if ensure_issue_roadmap_parent_for_dispatch 910903 ready-for-agent 2>"$AGENT_HOME/roadmap-parent-failure.log"; then
  assert_cond 'dispatch placement failure blocks dispatch' 0
else
  assert_cond 'dispatch placement failure blocks dispatch' 1
fi
assert_eq 'dispatch placement failure names queued issue and stage' true \
  "$(grep -Fq 'failed for #910903 before ready-for-agent dispatch' "$AGENT_HOME/roadmap-parent-failure.log" && echo true || echo false)"
unset ROADMAP_PARENT_STATUS
ROADMAP_ORDER_ENABLED=false
roadmap_ensure_issue_parent() { return 0; }
for dispatch_gate in \
  'ensure_issue_roadmap_parent_for_dispatch "$n" "$queue_label"' \
  'ensure_issue_roadmap_parent_for_dispatch "$n" needs-advisor' \
  'ensure_issue_roadmap_parent_for_dispatch "$n" needs-triage "$issue_json"' \
  'ensure_issue_roadmap_parent_for_dispatch "$next_triage" needs-triage' \
  'ensure_issue_roadmap_parent_for_dispatch "$next_measure" ready-for-agent' \
  'ensure_issue_roadmap_parent_for_dispatch "$next_poll" needs-advisor' \
  'ensure_issue_roadmap_parent_for_dispatch "$next_orphan" needs-advisor' \
  'ensure_issue_roadmap_parent_for_dispatch "$n" awaiting-release'; do
  assert_eq "pipeline dispatch route has roadmap gate: $dispatch_gate" true \
    "$(grep -Fq -- "$dispatch_gate" "$PIPELINE_SRC" && echo true || echo false)"
done

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "ok - $desc"
  else
    echo "not ok - $desc (expected to find [$needle])"
    FAILED=1
  fi
}

assert_contains "the refresh unit forwards stage diagnostics to its journal" \
  "$(sed -n '/^dispatch_gitnexus_refresh() {/,/^}/p' "$PIPELINE_SRC")" "GITNEXUS_REFRESH_OUTPUT"

CHECKS_BLOCKED_GH_LOG="$AGENT_HOME/checks-blocked-sweep-writes.log"
run_checks_blocked_sweep() (
  local n="$1" sandbox="$2" held_number="${3:-}"
  CODEX_SANDBOX_MODE="$sandbox"
  DRY_RUN=0
  REPO=test/repo
  CHECKS_BLOCKED_SWEEP_NUMBER="$n"
  CHECKS_BLOCKED_HELD_NUMBER="$held_number"
  export CHECKS_BLOCKED_SWEEP_NUMBER
  eval "$ROADMAP_ENSURE_ISSUE_PARENT_FN"
  ZF_OPEN_ISSUES_CACHE_FILE="$AGENT_HOME/open-issues.json"
  ZF_ROADMAP_TREE_CACHE_FILE="$(roadmap_cache_path "$ZF_OPEN_ISSUES_CACHE_FILE")"
  export ZF_OPEN_ISSUES_CACHE_FILE ZF_ROADMAP_TREE_CACHE_FILE
  jq -cn --argjson number "$n" '{roots:[{number:990000,title:"Test roadmap",state:"open",labels:["roadmap"],children:[{number:990001,title:"Test epic",state:"open",labels:["roadmap-epic"],children:[{number:$number,title:"Checks-blocked fixture",state:"open",labels:[],children:[]}]}]}]}' \
    > "$ZF_ROADMAP_TREE_CACHE_FILE"
  OPEN_ISSUE_BLOCKER_GRAPH_JSON='[]'
  gh() {
    if [ "$1" = issue ] && [ "${2:-}" = list ]; then
      case " $* " in
        *" --label checks-blocked "*) printf '%s\n' "$CHECKS_BLOCKED_SWEEP_NUMBER" ;;
        *" --label on-hold "*)
          [ "$CHECKS_BLOCKED_HELD_NUMBER" != "$CHECKS_BLOCKED_SWEEP_NUMBER" ] \
            || printf '%s\n' "$CHECKS_BLOCKED_SWEEP_NUMBER"
          ;;
        *) : ;;
      esac
    else
      return 2
    fi
  }
  ensure_state_labels() { :; }
  recut_parent_has_open_child() { return 1; }
  guarded_write() { printf '%s\n' "$*" >> "$CHECKS_BLOCKED_GH_LOG"; }
  checks_blocked_sweep
)

CHECKS_BLOCKED_HEAD=0123456789abcdef0123456789abcdef01234567
CHECKS_BLOCKED_RECENT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
CHECKS_BLOCKED_OLD_AT="$(date -u -d '7 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
CHECKS_BLOCKED_RECENT=910601
CHECKS_BLOCKED_OLD=910602
CHECKS_BLOCKED_REPEAT=910603
CHECKS_BLOCKED_HELD=910604
for checks_issue in "$CHECKS_BLOCKED_RECENT" "$CHECKS_BLOCKED_OLD" "$CHECKS_BLOCKED_REPEAT" "$CHECKS_BLOCKED_HELD"; do
  mkdir -p "$AGENT_HOME/state"
done
jq -cn --arg head "$CHECKS_BLOCKED_HEAD" --arg at "$CHECKS_BLOCKED_RECENT_AT" \
  --arg summary 'blocked by the sandbox policy' \
  '{attempts:1,state:"checks-blocked",run:{outcome:"checks-blocked",evidence:{mandatory_checks:{status:"blocked",head_sha:$head,summary:$summary,recorded_at:$at}}}}' \
  > "$AGENT_HOME/state/$CHECKS_BLOCKED_RECENT.json"
jq -cn --arg head "$CHECKS_BLOCKED_HEAD" --arg at "$CHECKS_BLOCKED_OLD_AT" \
  --arg summary 'required suite could not reach loopback service' \
  '{attempts:1,state:"checks-blocked",run:{outcome:"checks-blocked",evidence:{mandatory_checks:{status:"blocked",head_sha:$head,summary:$summary,recorded_at:$at}}}}' \
  > "$AGENT_HOME/state/$CHECKS_BLOCKED_OLD.json"
jq -cn --arg head "$CHECKS_BLOCKED_HEAD" --arg at "$CHECKS_BLOCKED_OLD_AT" \
  --arg summary 'required suite could not reach loopback service' \
  --arg auto "$CHECKS_BLOCKED_HEAD" \
  '{attempts:1,state:"checks-blocked",checks_blocked:{auto_requeued_head_sha:$auto},run:{outcome:"checks-blocked",evidence:{mandatory_checks:{status:"blocked",head_sha:$head,summary:$summary,recorded_at:$at}}}}' \
  > "$AGENT_HOME/state/$CHECKS_BLOCKED_REPEAT.json"
jq -cn --arg head "$CHECKS_BLOCKED_HEAD" --arg at "$CHECKS_BLOCKED_RECENT_AT" \
  --arg summary 'blocked by the sandbox policy' \
  '{attempts:1,state:"checks-blocked",run:{outcome:"checks-blocked",evidence:{mandatory_checks:{status:"blocked",head_sha:$head,summary:$summary,recorded_at:$at}}}}' \
  > "$AGENT_HOME/state/$CHECKS_BLOCKED_HELD.json"

run_checks_blocked_sweep "$CHECKS_BLOCKED_RECENT" danger-full-access
assert_eq 'sandbox-only receipt is auto-requeued once sandbox is removed' ready-for-agent \
  "$(state_read "$CHECKS_BLOCKED_RECENT" | jq -r '.state')"
assert_eq 'sandbox recovery preserves blocked receipt fields' 'blocked' \
  "$(state_read "$CHECKS_BLOCKED_RECENT" | jq -r '.run.evidence.mandatory_checks.status')"
assert_eq 'sandbox recovery records the auto-requeued head' "$CHECKS_BLOCKED_HEAD" \
  "$(state_read "$CHECKS_BLOCKED_RECENT" | jq -r '.checks_blocked.auto_requeued_head_sha')"

run_checks_blocked_sweep "$CHECKS_BLOCKED_OLD" workspace-write
assert_eq 'ticket parked over six hours is requeued' ready-for-agent \
  "$(state_read "$CHECKS_BLOCKED_OLD" | jq -r '.state')"
assert_eq 'age retry records the same-head guard' "$CHECKS_BLOCKED_HEAD" \
  "$(state_read "$CHECKS_BLOCKED_OLD" | jq -r '.checks_blocked.auto_requeued_head_sha')"

run_checks_blocked_sweep "$CHECKS_BLOCKED_REPEAT" workspace-write
assert_eq 'same head is not auto-requeued twice' checks-blocked \
  "$(state_read "$CHECKS_BLOCKED_REPEAT" | jq -r '.state')"

POST_DISPATCH_MAINTENANCE_FN="$(sed -n '/^run_post_dispatch_maintenance() {/,/^}/p' "$PIPELINE_SRC")"
assert_cond 'checks-blocked owner sweep is routed through post-dispatch maintenance' \
  "$(grep -qF 'checks_blocked_sweep' <<< "$POST_DISPATCH_MAINTENANCE_FN" && echo 1 || echo 0)"
run_checks_blocked_sweep "$CHECKS_BLOCKED_HELD" danger-full-access "$CHECKS_BLOCKED_HELD"
assert_eq 'held checks-blocked ticket stays parked' checks-blocked \
  "$(state_read "$CHECKS_BLOCKED_HELD" | jq -r '.state')"
assert_eq 'held checks-blocked ticket keeps its retry eligible' null \
  "$(state_read "$CHECKS_BLOCKED_HELD" | jq -r '.checks_blocked.auto_requeued_head_sha // null')"
assert_eq 'held checks-blocked ticket receives no state-label write' 0 \
  "$(grep -cF "issue edit $CHECKS_BLOCKED_HELD" "$CHECKS_BLOCKED_GH_LOG" || true)"


LANE_LABELS_JSON="$(pipeline_system_issue_labels_json)"
assert_eq "pipeline-system membership labels come from rulings state" \
  '["pipeline-system"]' "$LANE_LABELS_JSON"
assert_eq "configured pipeline-system label matches issue snapshot" yes \
  "$(pipeline_system_issue_matches '{"labels":[{"name":"pipeline-system"}]}' && echo yes || echo no)"
assert_eq "ordinary issue does not match pipeline-system label set" no \
  "$(pipeline_system_issue_matches '{"labels":[{"name":"ready-for-agent"}]}' && echo yes || echo no)"
PIPELINE_SYSTEM_LABELS_JSON="$LANE_LABELS_JSON"
unset PIPELINE_SYSTEM_LABELS_JSON

# 2026-09-27: re-preparing every already-prepared lane issue each tick took 11+ min
# and timed out the scheduler before release. An already-prepared issue is a no-op.
IDEM_LOG="$(mktemp)"
(
  state_read() { printf '%s\n' '{"pipeline_system":{"enabled":true},"state":"ready-for-agent"}'; }
  state_merge() { printf 'state:%s\n' "$1" >> "$IDEM_LOG"; }
  guarded_write() { printf 'gh:%s\n' "$*" >> "$IDEM_LOG"; }
  gh() { printf '%s\n' '{"number":991003,"labels":[{"name":"pipeline-system"},{"name":"ready-for-agent"}]}' ; }
  prepare_pipeline_system_issue 991003 '{"labels":[{"name":"pipeline-system"},{"name":"ready-for-agent"}]}' ""
)
assert_eq "already-prepared lane issue writes nothing" "" "$(cat "$IDEM_LOG")"
: > "$IDEM_LOG"
(
  state_read() { printf '%s\n' '{"pipeline_system":{"enabled":true},"state":"ready-for-agent"}'; }
  state_merge() { printf 'state:%s\n' "$1" >> "$IDEM_LOG"; }
  guarded_write() { printf 'gh:%s\n' "$*" >> "$IDEM_LOG"; }
  gh() {
    if [ "${1:-}" = api ]; then echo '[]'; return 0; fi
    printf '%s\n' '{"number":991004,"labels":[{"name":"pipeline-system"},{"name":"ready-for-agent"},{"name":"needs-triage"}]}'
  }
  prepare_pipeline_system_issue 991004 '{"labels":[{"name":"pipeline-system"},{"name":"ready-for-agent"},{"name":"needs-triage"}]}' needs-triage
)
assert_contains "lane issue with a stale stage label is still cleaned" "$(cat "$IDEM_LOG")" '--remove-label needs-triage'
rm -f "$IDEM_LOG"

ROUTE_LOG="$(mktemp)"
(
  state_merge() { printf 'state:%s:%s\n' "$1" "$2" >> "$ROUTE_LOG"; }
  guarded_write() { printf 'gh:%s\n' "$*" >> "$ROUTE_LOG"; }
  gh() {
    if [ "${1:-}" = api ]; then echo '[]'; return 0; fi
    case "${3:-}" in
      991001) printf '%s\n' '{"number":991001,"labels":[{"name":"pipeline-system"}]}' ;;
      991003) printf '%s\n' '{"number":991003,"labels":[]}' ;;
      *) printf '%s\n' '{"labels":[]}' ;;
    esac
  }
  prepare_pipeline_system_issue 991001 '{"labels":[{"name":"pipeline-system"}]}' needs-triage
)
assert_contains "pipeline-system needs-triage issue gets lightweight ready state" \
  "$(cat "$ROUTE_LOG")" 'state:991001:'
assert_contains "pipeline-system routing retires orphan advisor state" \
  "$(cat "$ROUTE_LOG")" 'del(.pipeline_system.product_ruling, .needs_info_origin, .advisor_ruled_at, .pending_advisor_verdict'
assert_contains "pipeline-system reconciliation resets stale advisor policy step" \
  "$(cat "$ROUTE_LOG")" '.model_policy.step'
assert_contains "pipeline-system reconciliation removes needs-triage" \
  "$(cat "$ROUTE_LOG")" '--remove-label needs-triage'
assert_contains "pipeline-system reconciliation removes needs-advisor" \
  "$(cat "$ROUTE_LOG")" '--remove-label needs-advisor'
assert_contains "pipeline-system reconciliation removes unsupported routing labels" \
  "$(cat "$ROUTE_LOG")" '--remove-label needs-info'
assert_contains "pipeline-system reconciliation removes needs-recut" \
  "$(cat "$ROUTE_LOG")" '--remove-label needs-recut'
assert_contains "pipeline-system reconciliation removes ready-for-human" \
  "$(cat "$ROUTE_LOG")" '--remove-label ready-for-human'
assert_contains "pipeline-system reconciliation returns issue to implementation" \
  "$(cat "$ROUTE_LOG")" '--add-label ready-for-agent'
rm -f "$ROUTE_LOG"

PRODUCT_ROUTE_LOG="$(mktemp)"
(
  state_merge() { printf 'state:%s:%s\n' "$1" "$2" >> "$PRODUCT_ROUTE_LOG"; }
  guarded_write() { printf 'gh:%s\n' "$*" >> "$PRODUCT_ROUTE_LOG"; }
  pipeline_system_issue_labels_json() { printf '%s\n' '["pipeline-system"]'; }
  REPO=test/repo
  pipeline_system_return_to_product 991009
)
assert_contains "product-path classification removes non-product membership" \
  "$(cat "$PRODUCT_ROUTE_LOG")" 'gh:gh issue edit 991009 --repo test/repo --remove-label pipeline-system'
assert_contains "product-path classification preserves evidence and clears lane marker" \
  "$(cat "$PRODUCT_ROUTE_LOG")" 'state:991009:.pipeline_system.product_ruling'
assert_contains "product-path classification disables non-product routing" \
  "$(cat "$PRODUCT_ROUTE_LOG")" 'del(.pipeline_system.enabled)'
rm -f "$PRODUCT_ROUTE_LOG"

FASTLANE_HOME="$(mktemp -d)"
FASTLANE_LOG="$FASTLANE_HOME/writes.log"
FASTLANE_REPO="$FASTLANE_HOME/repo"
git init -q -b main "$FASTLANE_REPO"
git -C "$FASTLANE_REPO" -c user.name=Fixture -c user.email=test@example.invalid \
  commit --allow-empty -qm fixture
FASTLANE_VALID_REPORT_SHA="$(git -C "$FASTLANE_REPO" rev-parse HEAD)"
git -C "$FASTLANE_REPO" update-ref refs/remotes/origin/main "$FASTLANE_VALID_REPORT_SHA"
if ! FASTLANE_OUTPUT="$(AGENT_HOME="$FASTLANE_HOME" FASTLANE_LOG="$FASTLANE_LOG" \
  FASTLANE_HOME="$FASTLANE_HOME" FASTLANE_REPO="$FASTLANE_REPO" VALID_REPORT_SHA="$FASTLANE_VALID_REPORT_SHA" \
  REPO=test/repo ZF_REPO=test/repo ZF_WORKTREE_ROOT="$FASTLANE_HOME/wt" bash -c '
    set -euo pipefail
    source "$1/lib.sh"
    source "$1/night/hand-agent-watchdog.sh"
    eval "$(declare -f supervisor_hold_owner_state | sed '1s/supervisor_hold_owner_state/supervisor_hold_owner_state_real/')"
    eval "$2"
    NIGHT="$AGENT_HOME/night"
    REPO_DIR="$FASTLANE_REPO"
    mkdir -p "$NIGHT" "$AGENT_HOME/state"
    node() {
      if [ "$1" = "$REPO_DIR/scripts/branch-delivery-policy.mjs" ]; then
        shift
        command node "$MODEL_POLICY_TEST_REPO/scripts/branch-delivery-policy.mjs" "$@"
      else
        command node "$@"
      fi
    }
    git() {
      if [[ " $* " == *" log origin/main "* ]]; then
        printf "%s\n" "$VALID_REPORT_SHA"
      else
        command git "$@"
      fi
    }
    git_fetch_bounded() { printf "fetch:%s:%s\n" "$1" "$2" >> "$FASTLANE_LOG"; }
    pipeline_system_close_comment_valid() {
      local issue="$2" body="$3" candidate
      if [[ "$issue" == 991013 ]]; then
        candidate="$(grep -Eo "[[:xdigit:]]{7,64}" <<< "$body" | head -n1)"
        [[ "$candidate" == "$VALID_REPORT_SHA" ]] \
          && command git -C "$REPO_DIR" merge-base --is-ancestor "$candidate" origin/main
      else
        [[ "$issue" == 991015 && "$body" == *"issue-linked close commit $VALID_REPORT_SHA"* ]]
      fi
    }
    conclude_run() {
      printf "close:%s:%s:%s\n" "$1" "$2" "$3" >> "$FASTLANE_LOG"
      mkdir -p "$AGENT_HOME/closed"
      printf "%s\n" "$1" > "$AGENT_HOME/closed/$1"
    }
    supervisor_inbox_append_once() {
      if ! grep -Fq "inbox:$1:" "$FASTLANE_LOG"; then
        printf "inbox:%s:%s\n" "$1" "$2" >> "$FASTLANE_LOG"
      fi
    }
    hand_agent_issue_is_live_owned() { return 1; }
    # No scheduler runtime ledgers exist in this fixture; the census sees no live worker.
    coord_issue_live_worker() { return 1; }
    supervisor_hold_owner_state() {
      if [[ "$1" == 991018 || "$1" == 991019 ]]; then
        supervisor_hold_owner_state_real "$@"
        return $?
      fi
      if [ -r "$AGENT_HOME/night/supervisor-dispatch-queue.tsv" ] \
        && grep -Fxq "hand-$1" "$AGENT_HOME/night/supervisor-dispatch-queue.tsv"; then
        SUPERVISOR_HOLD_OWNER_STATE=queued
        SUPERVISOR_HOLD_OWNER_DETAIL="queued fixture owner"
        return 0
      fi
      SUPERVISOR_HOLD_OWNER_STATE=none
      return 1
    }
    scheduler_requeue_issue() {
      printf "dispatch:%s:scheduler:%s:%s\n" "$1" "$(jq -r .body <<< "$3")" \
        "$(jq -r ".comments[0].body // \"\"" <<< "$3")" >> "$FASTLANE_LOG"
    }
    guarded_write() { printf "write:%s\n" "$*" >> "$FASTLANE_LOG"; }
    hold_issue() { printf "hold:%s:%s\n" "$1" "$*" >> "$FASTLANE_LOG"; }
    gh() {
      if [ "$1 $2" = "issue view" ]; then
        if [ "$3" != 991008 ]; then
          gh issue list --label needs-triage | jq -c --argjson n "$3" ".[] | select(.number == \$n)"
          return
        fi
        printf "%s\n" '\''{"number":991008,"title":"Fast lane fixture","body":"Change engine/lib.sh","comments":[{"createdAt":"2026-10-11T00:00:00Z","author":{"login":"fixture"},"body":"Keep owner visible."}],"labels":[{"name":"pipeline-system"}],"state":"OPEN"}'\''
      elif [ "$1 $2" = "issue list" ] && [[ " $* " == *" --label needs-triage "* ]]; then
        printf "%s\n" '\''[{"number":991009,"title":"Path-only infrastructure","body":"Fix paths:\n- engine/lib.sh","comments":[{"body":"Keep direct lane."}],"labels":[{"name":"needs-triage"}],"state":"OPEN"},{"number":991010,"title":"Mixed product change","body":"Fix paths:\n- engine/lib.sh\n- packages/example-service/src/app.ts","comments":[],"labels":[{"name":"needs-triage"}],"state":"OPEN"},{"number":991011,"title":"Parent tracker","body":"Fix paths:\n- engine/lib.sh","comments":[],"labels":[{"name":"needs-triage"}],"state":"OPEN","blockedBy":{"nodes":[{"number":2911,"state":"OPEN"}]}}]'\''
      elif [ "$1 $2" = "issue list" ]; then
        printf "%s\n" "[]"
      elif [ "$1 $2" = "pr list" ]; then
        printf "%s\n" "[]"
      elif [ "$1" = "api" ] && [[ "$2" == repos/test/repo/issues/*/sub_issues\?per_page=100 ]]; then
        printf "%s\n" "[]"
      fi
    }
    route_pipeline_fastlane_issue 991016 \
      '\''{"number":991016,"title":"Held fastlane fixture","body":"Wait for external evidence.","comments":[],"labels":[{"name":"pipeline-system"},{"name":"on-hold"}],"state":"OPEN"}'\'' \
      "fastlane fixture"
    route_pipeline_fastlane_issue 991017 \
      '\''{"number":991017,"title":"Unreadable labels fixture","body":"Wait for label readback.","comments":[],"labels":[{}],"state":"OPEN"}'\'' \
      "fastlane fixture" || true
    route_nonproduct_path_candidates
    route_pipeline_fastlane_issue 991012 \
      '\''{"number":991012,"title":"Product path bypass","body":"packages/example-pack/src/query-runtime.ts","comments":[],"labels":[]} '\'' \
      "fastlane fixture"
    printf "STATUS: DONE\nAlready on origin/main at %s\n" "$VALID_REPORT_SHA" > "$NIGHT/hand-991013.report"
    route_pipeline_fastlane_issue 991013 \
      '\''{"number":991013,"title":"Verified fastlane fix","body":"engine/lib.sh","comments":[],"labels":[{"name":"pipeline-system"}]}'\'' \
      "fastlane fixture"
    printf "STATUS: DONE\nVerified, no change: %s\n" "$VALID_REPORT_SHA" > "$NIGHT/hand-991015.report"
    route_pipeline_fastlane_issue 991015 \
      '\''{"number":991015,"title":"No-diff existing-main fixture","body":"engine/lib.sh","comments":[],"labels":[{"name":"pipeline-system"}]}'\'' \
      "fastlane fixture"
    printf "STATUS: DONE\nVerified, no change; commit SHA unavailable\n" > "$NIGHT/hand-991014.report"
    route_pipeline_fastlane_issue 991014 \
      '\''{"number":991014,"title":"No SHA fixture","body":"engine/lib.sh","comments":[],"labels":[{"name":"pipeline-system"}]}'\'' \
      "fastlane fixture"
    route_pipeline_fastlane_issue 991014 \
      '\''{"number":991014,"title":"No SHA fixture","body":"engine/lib.sh","comments":[],"labels":[{"name":"pipeline-system"}]}'\'' \
      "fastlane fixture"
    mkdir -p "$NIGHT/briefs"
    printf '\''Owned issues: 991019\n'\'' > "$NIGHT/briefs/hand-sweep-fixture.md"
    printf '\''hand-sweep-fixture\t%s\t%s\tnote\twork\t0\t\t991018\t\toptimization\n'\'' \
      "$FASTLANE_HOME/wt/hand-sweep-fixture" "$NIGHT/briefs/hand-sweep-fixture.md" \
      >> "$NIGHT/supervisor-dispatch-queue.tsv"
    route_pipeline_fastlane_issue 991018 \
      '\''{"number":991018,"title":"Folded explicit owner","body":"engine/lib.sh","comments":[],"labels":[{"name":"pipeline-system"}]}'\'' \
      "fastlane fixture"
    route_pipeline_fastlane_issue 991019 \
      '\''{"number":991019,"title":"Folded brief owner","body":"engine/lib.sh","comments":[],"labels":[{"name":"pipeline-system"}]}'\'' \
      "fastlane fixture"
  ' _ "$SCRIPT_DIR" "$ROUTE_PIPELINE_SYSTEM_CANDIDATES_FN" 2>&1)"; then
  printf '%s\n' "$FASTLANE_OUTPUT" | tail -n 100 >&2
  exit 1
fi
assert_eq "on-hold pipeline issue is not dispatched" '' \
  "$(grep 'dispatch:991016:' "$FASTLANE_LOG" || true)"
assert_eq "malformed issue labels fail closed without dispatch" '' \
  "$(grep 'dispatch:991017:' "$FASTLANE_LOG" || true)"
assert_eq "mixed product path stays in product triage" '' \
  "$(grep 'dispatch:991010:' "$FASTLANE_LOG" || true)"
assert_eq "parent tracker with factory-path mention stays out of fastlane" '' \
  "$(grep 'dispatch:991011:' "$FASTLANE_LOG" || true)"
assert_contains "product scope also returns to scheduler" "$(cat "$FASTLANE_LOG")" 'dispatch:991012:scheduler:'
assert_eq "product scope does not receive pipeline-system label" '' \
  "$(grep '^write:gh issue edit 991012 ' "$FASTLANE_LOG" || true)"
assert_contains "retired queue explicit row no longer blocks scheduling" "$(cat "$FASTLANE_LOG")" 'dispatch:991018:scheduler:'
assert_contains "retired queue brief no longer blocks scheduling" "$(cat "$FASTLANE_LOG")" 'dispatch:991019:scheduler:'
# Deterministically advance only the fixture ref between report creation and assertions.
git -C "$FASTLANE_REPO" -c user.name=Fixture -c user.email=test@example.invalid \
  commit --allow-empty -qm 'peer main advance'
git -C "$FASTLANE_REPO" update-ref refs/remotes/origin/main HEAD
assert_eq "fixture main moved without changing the verified report SHA" false \
  "$([ "$(git -C "$FASTLANE_REPO" rev-parse origin/main)" = "$FASTLANE_VALID_REPORT_SHA" ] && echo true || echo false)"
assert_contains "DONE no-diff report closes through pipeline conclusion with verified main SHA" \
  "$(cat "$FASTLANE_LOG")" "close:991013:pipeline-system:Already on origin/main at $FASTLANE_VALID_REPORT_SHA"
assert_eq "DONE no-diff report is not redispatched after conclusion" '' \
  "$(grep '^dispatch:991013:' "$FASTLANE_LOG" || true)"
assert_contains "unlinked report SHA uses issue-linked main close evidence" \
  "$(cat "$FASTLANE_LOG")" "close:991015:pipeline-system:Already on origin/main at $FASTLANE_VALID_REPORT_SHA"
assert_eq "issue-linked close evidence does not redispatch hand" '' \
  "$(grep '^dispatch:991015:' "$FASTLANE_LOG" || true)"
assert_eq "DONE no-diff report without SHA writes one inbox line and skips dispatch" 1 \
  "$(grep -c '^inbox:hand-done-no-diff-close issue=991014:' "$FASTLANE_LOG" || true)"
assert_eq "missing-SHA report does not enter fastlane dispatch loop" '' \
  "$(grep '^dispatch:991014:' "$FASTLANE_LOG" || true)"

FASTLANE_EXTERNAL_HOME="$(mktemp -d)"
FASTLANE_EXTERNAL_LOG="$FASTLANE_EXTERNAL_HOME/external.log"
cat > "$FASTLANE_EXTERNAL_HOME/run.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$1"
ROUTE_FN="$2"
source "$SCRIPT_DIR/lib.sh"
eval "$ROUTE_FN"
NIGHT="$AGENT_HOME/night"
REPO=test/repo
INFRA=example-org/example-infra
REPO_DIR="$MODEL_POLICY_TEST_REPO"
mkdir -p "$NIGHT"
pipeline_system_issue_matches() { return 0; }
pipeline_system_finish_external_landing() {
  printf "close:%s:%s:%s:%s\n" "$FASTLANE_EXTERNAL_MODE" "$2" "$3" "$4" >> "$FASTLANE_EXTERNAL_LOG"
}
pipeline_system_return_to_product() { printf "product:%s\n" "$1" >> "$FASTLANE_EXTERNAL_LOG"; }
state_requeue() { printf "requeue:%s:%s\n" "$1" "$2" >> "$FASTLANE_EXTERNAL_LOG"; }
gh() {
  case "$1 $2" in
    "repo view") printf "main\n" ;;
    "pr view")
      local paths checks state merge='null' merged_at='null'
      state="${FASTLANE_EXTERNAL_STATE:-OPEN}"
      case "${FASTLANE_EXTERNAL_MODE:-green}" in
        product) paths='[{"path":"cihost/agent/Dockerfile"}]'; checks='[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]' ;;
        product-after-merge)
          if [ "$state" = MERGED ]; then paths='[{"path":"cihost/agent/Dockerfile"}]'; else paths='[{"path":"scripts/sync-cihost-nexus-images.sh"}]'; fi
          checks='[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]' ;;
        pending) paths='[{"path":"scripts/sync-cihost-nexus-images.sh"}]'; checks='[{"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":null}]' ;;
        red) paths='[{"path":"scripts/sync-cihost-nexus-images.sh"}]'; checks='[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"}]' ;;
        *) paths='[{"path":"scripts/sync-cihost-nexus-images.sh"},{"path":"scripts/test_build_cihost_images_contract.py"},{"path":"scripts/test_sync_cihost_nexus_images_contract.py"}]'; checks='[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]' ;;
      esac
      if [ "$state" = MERGED ]; then
        merge="{\"oid\":\"$FASTLANE_EXTERNAL_MERGE_SHA\"}"
        merged_at='"2026-10-12T00:00:00Z"'
      fi
      jq -cn --arg state "$state" --arg body "Refs $REPO#$FASTLANE_EXTERNAL_ISSUE" \
        --argjson files "$paths" --argjson checks "$checks" --argjson merge "$merge" \
        --argjson mergedAt "$merged_at" \
        '{number:991113,state:$state,baseRefName:"main",headRefName:("agent/issue-" + (env.FASTLANE_EXTERNAL_ISSUE // "991016")),headRefOid:"0123456789abcdef0123456789abcdef01234567",mergeable:"MERGEABLE",mergeStateStatus:"CLEAN",isDraft:false,mergedAt:$mergedAt,mergeCommit:$merge,body:$body,changedFiles:($files|length),files:$files,statusCheckRollup:$checks}'
      ;;
    "pr merge")
      printf "merge:%s:%s\n" "${FASTLANE_EXTERNAL_MODE:-green}" "$*" >> "$FASTLANE_EXTERNAL_LOG"
      FASTLANE_EXTERNAL_STATE=MERGED
      export FASTLANE_EXTERNAL_STATE
      ;;
  esac
}
for mode in green pending red product product-after-merge manual-merged; do
  FASTLANE_EXTERNAL_ISSUE=991016
  FASTLANE_EXTERNAL_STATE=OPEN
  FASTLANE_EXTERNAL_MODE="$mode"
  if [ "$mode" = manual-merged ]; then FASTLANE_EXTERNAL_STATE=MERGED; FASTLANE_EXTERNAL_MODE=green; fi
  export FASTLANE_EXTERNAL_ISSUE FASTLANE_EXTERNAL_STATE FASTLANE_EXTERNAL_MODE
  FASTLANE_EXTERNAL_MERGE_SHA=abcdef0123456789abcdef0123456789abcdef01
  export FASTLANE_EXTERNAL_MERGE_SHA
  printf "STATUS: DONE\nUpdated PR: https://github.com/example-org/example-infra/pull/991113\n" > "$NIGHT/hand-$FASTLANE_EXTERNAL_ISSUE.report"
  status=0
  pipeline_system_hand_report_conclusion "$FASTLANE_EXTERNAL_ISSUE" \
    '{"number":991016,"title":"External factory work","body":"pipeline-system","comments":[],"labels":[{"name":"pipeline-system"},{"name":"on-hold"}],"state":"OPEN"}' || status=$?
  printf "status:%s:%s\n" "$mode" "$status" >> "$FASTLANE_EXTERNAL_LOG"
done
EOF
chmod +x "$FASTLANE_EXTERNAL_HOME/run.sh"
FASTLANE_EXTERNAL_OUTPUT="$(AGENT_HOME="$FASTLANE_EXTERNAL_HOME" FASTLANE_EXTERNAL_LOG="$FASTLANE_EXTERNAL_LOG" \
  REPO=test/repo INFRA=example-org/example-infra ZF_WORKTREE_ROOT="$FASTLANE_EXTERNAL_HOME/wt" \
  bash "$FASTLANE_EXTERNAL_HOME/run.sh" "$SCRIPT_DIR" "$ROUTE_PIPELINE_SYSTEM_CANDIDATES_FN" 2>&1)"
assert_contains "green factory-only infra PR merges with exact hand head and closes on merge SHA" \
  "$(cat "$FASTLANE_EXTERNAL_LOG")" 'close:green:991016:991113:abcdef0123456789abcdef0123456789abcdef01'
assert_contains "factory PR merge pins observed head commit" \
  "$(cat "$FASTLANE_EXTERNAL_LOG")" '--match-head-commit 0123456789abcdef0123456789abcdef01234567'
assert_contains "pending external PR checks defer without merging" \
  "$(cat "$FASTLANE_EXTERNAL_LOG")" 'status:pending:0'
assert_eq "pending external PR is not merged" '' \
  "$(grep '^merge:pending:' "$FASTLANE_EXTERNAL_LOG" || true)"
assert_contains "red external PR checks return to hand repair" \
  "$(cat "$FASTLANE_EXTERNAL_LOG")" 'status:red:1'
assert_contains "image-content PR returns to product lane without fastlane merge" \
  "$(cat "$FASTLANE_EXTERNAL_LOG")" 'product:991016'
assert_contains "image-content PR releases hold for product implementation" \
  "$(cat "$FASTLANE_EXTERNAL_LOG")" 'requeue:991016:release-hold'
assert_contains "image-content pushed before merge is reclassified to product" \
  "$(cat "$FASTLANE_EXTERNAL_LOG")" 'product:991016'
assert_contains "image-content pushed during merge is reclassified after merge" \
  "$(cat "$FASTLANE_EXTERNAL_LOG")" 'status:product-after-merge:0'
assert_eq "raced image-content PR is not closed as factory work" '' \
  "$(grep '^close:product-after-merge:' "$FASTLANE_EXTERNAL_LOG" || true)"
assert_contains "already-merged factory PR closes without another merge" \
  "$(cat "$FASTLANE_EXTERNAL_LOG")" 'status:manual-merged:0'
assert_eq "only open green factory PR is merged by caretaker" 1 \
  "$(grep '^merge:green:pr merge' "$FASTLANE_EXTERNAL_LOG" | wc -l | tr -d ' ')"
rm -rf "$FASTLANE_EXTERNAL_HOME"
rm -rf "$FASTLANE_HOME"

FASTLANE_RACE_HOME="$(mktemp -d)"
FASTLANE_RACE_LOG="$FASTLANE_RACE_HOME/race.log"
FASTLANE_RACE_OUTPUT="$(AGENT_HOME="$FASTLANE_RACE_HOME/agent" FASTLANE_RACE_LOG="$FASTLANE_RACE_LOG" \
  FASTLANE_RACE_ROOT="$FASTLANE_RACE_HOME/repos" REPO=test/repo \
  bash -c '
    set -euo pipefail
    source "$1/lib.sh"
    eval "$2"
    root="$FASTLANE_RACE_ROOT"
    origin="$root/origin.git"
    seed="$root/seed"
    work="$root/work"
    mkdir -p "$root"
    git init -q --bare "$origin"
    git init -q "$seed"
    git -C "$seed" checkout -q -b main
    git -C "$seed" config user.name "Pipeline Fixture"
    git -C "$seed" config user.email "pipeline-fixture@example.invalid"
    printf "base\n" > "$seed/base.txt"
    git -C "$seed" add base.txt
    git -C "$seed" commit -q -m "fixture base"
    git -C "$seed" remote add origin "$origin"
    git -C "$seed" push -q -u origin main
    git clone -q --branch main "$origin" "$work"
    printf "reported main head\n" > "$seed/report.txt"
    git -C "$seed" add report.txt
    git -C "$seed" commit -q -m "fixture report head"
    report_sha="$(git -C "$seed" rev-parse HEAD)"
    git -C "$seed" push -q origin main
    printf "linked refs commit\n" > "$seed/refs.txt"
    git -C "$seed" add refs.txt
    git -C "$seed" commit -q -m "fixture issue fix" -m "Refs: #991016"
    refs_sha="$(git -C "$seed" rev-parse HEAD)"
    git -C "$seed" push -q origin main
    printf "linked issue commit\n" > "$seed/issue.txt"
    git -C "$seed" add issue.txt
    git -C "$seed" commit -q -m "fixture issue fix" -m "issue 991017"
    issue_sha="$(git -C "$seed" rev-parse HEAD)"
    git -C "$seed" push -q origin main
    stale_main="$(git -C "$work" rev-parse origin/main)"
    [[ "$stale_main" != "$report_sha" ]]
    REPO_DIR="$work"
    NIGHT="$FASTLANE_RACE_ROOT/night"
    mkdir -p "$NIGHT"
    pipeline_system_issue_matches() { return 0; }
    state_merge() { :; }
    conclude_run() { printf "close:%s:%s:%s\n" "$1" "$2" "$3" >> "$FASTLANE_RACE_LOG"; }
    supervisor_inbox_append_once() { printf "inbox:%s:%s\n" "$1" "$2" >> "$FASTLANE_RACE_LOG"; }
    printf "STATUS: DONE\nAlready on origin/main at \`%s\`; trace deadbeefdeadbeef\n" "$report_sha" > "$NIGHT/hand-991016.report"
    pipeline_system_hand_report_conclusion 991016 \
      '\''{"number":991016,"labels":[{"name":"pipeline-system"}]}'\''
    printf "STATUS: DONE\nVerified, no change: %s\n" "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" > "$NIGHT/hand-991017.report"
    pipeline_system_hand_report_conclusion 991017 \
      '\''{"number":991017,"labels":[{"name":"pipeline-system"}]}'\''
    printf "heads:%s:%s:%s:%s:%s\n" "$stale_main" "$report_sha" "$refs_sha" "$issue_sha" \
      "$(git -C "$work" rev-parse origin/main)" >> "$FASTLANE_RACE_LOG"
  ' _ "$SCRIPT_DIR" "$ROUTE_PIPELINE_SYSTEM_CANDIDATES_FN" 2>&1)"
FASTLANE_RACE_HEADS="$(grep '^heads:' "$FASTLANE_RACE_LOG")"
FASTLANE_RACE_REPORT_SHA="$(cut -d: -f3 <<< "$FASTLANE_RACE_HEADS")"
FASTLANE_RACE_REFS_SHA="$(cut -d: -f4 <<< "$FASTLANE_RACE_HEADS")"
FASTLANE_RACE_ISSUE_SHA="$(cut -d: -f5 <<< "$FASTLANE_RACE_HEADS")"
FASTLANE_RACE_REFRESHED_SHA="$(cut -d: -f6 <<< "$FASTLANE_RACE_HEADS")"
if git -C "$FASTLANE_RACE_HOME/repos/work" merge-base --is-ancestor "$FASTLANE_RACE_REPORT_SHA" "$FASTLANE_RACE_REFS_SHA" \
  && ! git -C "$FASTLANE_RACE_HOME/repos/work" merge-base --is-ancestor "$FASTLANE_RACE_REFS_SHA" "$FASTLANE_RACE_REPORT_SHA"; then
  echo 'ok - stale report SHA is a strict ancestor of the issue-linked fix'
else
  echo 'not ok - race fixture does not place the issue-linked fix after the reported SHA'
  FAILED=1
fi
assert_eq "a later issue-linked commit cannot replace the SHA reported as already landed" '' \
  "$(grep '^close:991016:' "$FASTLANE_RACE_LOG" || true)"
assert_contains "reported main SHA predates the issue-linked commit and is handed off" \
  "$(cat "$FASTLANE_RACE_LOG")" 'inbox:hand-done-no-diff-close issue=991016:'
assert_contains "later issue-linked commit remains outside report closure proof" \
  "$(cat "$FASTLANE_RACE_LOG")" 'no issue-linked close commit is at or before that SHA'
assert_eq "an issue-linked main commit cannot replace an unverifiable report SHA" '' \
  "$(grep '^close:991017:' "$FASTLANE_RACE_LOG" || true)"
assert_eq "race fixture refreshes stale origin/main to latest linked commit" "$FASTLANE_RACE_ISSUE_SHA" \
  "$FASTLANE_RACE_REFRESHED_SHA"
assert_eq "stale and unverifiable report SHAs both route to the supervisor" 2 \
  "$(grep -c '^inbox:' "$FASTLANE_RACE_LOG" || true)"
assert_contains "unverifiable report SHA handoff is executable" \
  "$(cat "$FASTLANE_RACE_LOG")" 'supervisor must verify evidence before closure'
rm -rf "$FASTLANE_RACE_HOME"

# Exercise report completion prose together with the real issue-linked
# origin/main close validator. The test also leaves unrelated SHA prose,
# multiple same-line candidates, off-main commits, and another ticket's commit
# on the same path.
FASTLANE_CONCLUSION_HOME="$(mktemp -d)"
FASTLANE_CONCLUSION_ORIGIN="$FASTLANE_CONCLUSION_HOME/origin.git"
FASTLANE_CONCLUSION_SEED="$FASTLANE_CONCLUSION_HOME/seed"
FASTLANE_CONCLUSION_REPO="$FASTLANE_CONCLUSION_HOME/work"
FASTLANE_CONCLUSION_LOG="$FASTLANE_CONCLUSION_HOME/outcomes.log"
git init -q --bare "$FASTLANE_CONCLUSION_ORIGIN"
git init -q -b main "$FASTLANE_CONCLUSION_SEED"
git -C "$FASTLANE_CONCLUSION_SEED" config user.name "Pipeline Fixture"
git -C "$FASTLANE_CONCLUSION_SEED" config user.email "pipeline-fixture@example.invalid"
printf 'base\n' > "$FASTLANE_CONCLUSION_SEED/base.txt"
git -C "$FASTLANE_CONCLUSION_SEED" add base.txt
git -C "$FASTLANE_CONCLUSION_SEED" commit -q -m 'fixture base'
git -C "$FASTLANE_CONCLUSION_SEED" remote add origin "$FASTLANE_CONCLUSION_ORIGIN"
git -C "$FASTLANE_CONCLUSION_SEED" push -q -u origin main
git clone -q --branch main "$FASTLANE_CONCLUSION_ORIGIN" "$FASTLANE_CONCLUSION_REPO"
cat > "$FASTLANE_CONCLUSION_HOME/run.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$1"
ROUTE_FN="$2"
SEED="$3"
FIXTURE_REPO="$4"
LOG="$5"
source "$SCRIPT_DIR/lib.sh"
eval "$ROUTE_FN"
REPO_DIR="$FIXTURE_REPO"
REPO=test/repo
INFRA=example-org/example-infra
NIGHT="$AGENT_HOME/night"
mkdir -p "$NIGHT"

git_fetch_bounded() { git -C "$1" fetch -q origin "$2"; }
state_merge() { :; }
conclude_run() { printf 'close:%s:%s:%s\n' "$1" "$2" "$3" >> "$LOG"; }
supervisor_inbox_append_once() {
  grep -Fq "inbox:$1:" "$LOG" 2>/dev/null || printf 'inbox:%s:%s\n' "$1" "$2" >> "$LOG"
}
scheduler_requeue_issue() {
  printf 'dispatch:%s\n' "$1" >> "$LOG"
}
guarded_write() { :; }

commit_evidence() {
  local issue="$1" subject="$2" body="$3"
  printf '%s\n' "$issue" > "$SEED/issue-$issue.txt"
  git -C "$SEED" add "issue-$issue.txt"
  git -C "$SEED" commit -q -m "$subject" -m "$body"
  git -C "$SEED" push -q origin main
  git -C "$SEED" rev-parse HEAD
}
issue_json() {
  jq -cn --argjson number "$1" \
    '{number:$number,state:"OPEN",labels:[{name:"pipeline-system"}]}'
}
route_report() {
  local issue="$1" evidence="$2"
  REPO_DIR="$FIXTURE_REPO"
  printf 'STATUS: DONE\n%s\n' "$evidence" > "$NIGHT/hand-$issue.report"
  route_pipeline_fastlane_issue "$issue" "$(issue_json "$issue")" 'conclusion fixture'
}
route_report_without_final_newline() {
  local issue="$1" evidence="$2"
  REPO_DIR="$FIXTURE_REPO"
  printf 'STATUS: DONE\n%s' "$evidence" > "$NIGHT/hand-$issue.report"
  route_pipeline_fastlane_issue "$issue" "$(issue_json "$issue")" 'conclusion fixture'
}

sha="$(commit_evidence 991201 'fix: prior landed fix' 'issue 991201')"
route_report 991201 "Already on origin/main at $sha"
sha="$(commit_evidence 991202 'fix: prior no-change result' 'Refs: #991202')"
route_report 991202 "Verified, no change: $sha"
sha="$(commit_evidence 991203 'chore: record prior landed work' 'Refs #991203')"
route_report 991203 "Implementation already landed as \`$sha\`"
sha="$(commit_evidence 991204 'fix(#991204): existing landed fix' 'pipeline-system fastlane evidence')"
route_report 991204 "Fix was already on origin/main in $sha"
sha="$(commit_evidence 991205 'chore: existing pipeline-system evidence' 'issue 991205')"
route_report 991205 "Existing pipeline-system commit $sha"
sha="$(commit_evidence 991206 'fix: completion evidence at end of file' 'fix(#991206)')"
route_report_without_final_newline 991206 "Implementation already landed as $sha"

[[ "$FIXTURE_REPO" != "$MODEL_POLICY_TEST_REPO" ]] \
  || { echo 'conclusion fixture resolved to the source checkout' >&2; exit 1; }
sha="$(commit_evidence 991207 'fix: earlier linked evidence for issue 991207' 'Refs #991207')"
REPO_DIR="$FIXTURE_REPO"
git -C "$FIXTURE_REPO" switch -qc off-main-fixture
git -C "$FIXTURE_REPO" config user.name "Pipeline Fixture"
git -C "$FIXTURE_REPO" config user.email "pipeline-fixture@example.invalid"
printf 'off main\n' > "$FIXTURE_REPO/off-main.txt"
git -C "$FIXTURE_REPO" add off-main.txt
git -C "$FIXTURE_REPO" commit -q -m 'fix(#991207): unlanded local change'
unlanded_sha="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"
route_report 991207 "Existing pipeline-system commit $unlanded_sha"

other_sha="$(commit_evidence 991208 'fix: another ticket evidence' 'issue 991208')"
sha="$(commit_evidence 991209 'fix: earlier linked evidence for issue 991209' 'Refs #991209')"
route_report 991209 "Implementation already landed as $other_sha"

sha="$(commit_evidence 991212 'fix: earlier linked evidence for issue 991212' 'Refs #991212')"
issue_991212_sha="$sha"
main_tip_sha="$(commit_evidence 991213 'chore: unrelated later main commit' 'main commit without an issue link')"
route_report 991212 "Already on origin/main at $main_tip_sha"

sha="$(commit_evidence 991214 'fix: prior landed work for issue 991214' 'issue 991214')"
route_report 991214 "Implementation already landed as $sha
Verified, no change after checking the full tree."

sha="$(commit_evidence 991215 'fix: prior landed work for issue 991215' 'Refs #991215')"
route_report 991215 "Fix already landed as $sha"

sha="$(commit_evidence 991216 'fix: prior landed work for issue 991216' 'Refs #991216')"
# This completion wording is outside the old phrase vocabulary.
route_report 991216 "The implementation is complete; published to main in commit $sha."

sha="$(commit_evidence 991217 'fix: prior landed work for issue 991217' 'Refs #991217')"
issue_991217_sha="$sha"
git -C "$FIXTURE_REPO" fetch -q origin main
git -C "$FIXTURE_REPO" switch -qc trailing-off-main-991217 origin/main
printf 'off-main report context\n' > "$FIXTURE_REPO/trailing-off-main.txt"
git -C "$FIXTURE_REPO" add trailing-off-main.txt
git -C "$FIXTURE_REPO" commit -q -m 'fixture: trailing off-main report context'
trailing_off_main_sha="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"
route_report 991217 "The implementation is complete; published to main in commit $sha.
Unrelated context mentions $trailing_off_main_sha."

prior_main_sha="$(git -C "$SEED" rev-parse HEAD)"
sha="$(commit_evidence 991218 'fix: prior landed work for issue 991218' 'Refs #991218')"
issue_991218_sha="$sha"
route_report 991218 "The implementation is complete; published to main in commit $sha.
Earlier main context mentions $prior_main_sha."

prior_main_sha="$(git -C "$SEED" rev-parse HEAD)"
sha="$(commit_evidence 991219 'fix: prior landed work for issue 991219' 'Refs #991219')"
issue_991219_sha="$sha"
git -C "$FIXTURE_REPO" fetch -q origin main
git -C "$FIXTURE_REPO" switch -qc trailing-off-main-991219 origin/main
printf 'off-main report context\n' > "$FIXTURE_REPO/trailing-off-main-991219.txt"
git -C "$FIXTURE_REPO" add trailing-off-main-991219.txt
git -C "$FIXTURE_REPO" commit -q -m 'fixture: trailing off-main report context'
trailing_off_main_sha="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"
route_report 991219 "The implementation is complete; report context includes off-main $trailing_off_main_sha, earlier main $prior_main_sha, and landed main $sha."

sha="$(commit_evidence 991210 'fix: blocked ticket evidence' 'issue 991210')"
printf 'STATUS: BLOCKED\nImplementation already landed as %s\n' "$sha" > "$NIGHT/hand-991210.report"
REPO_DIR="$FIXTURE_REPO"
status=0
pipeline_system_hand_report_conclusion 991210 "$(issue_json 991210)" || status=$?
[[ "$status" == 1 ]] || { echo "non-DONE report returned $status, expected 1" >&2; exit 1; }

printf 'STATUS: DONE\nImplementation already landed as expected; SHA %s is context only.\n' \
  "$sha" > "$NIGHT/hand-991211.report"
REPO_DIR="$FIXTURE_REPO"
status=0
pipeline_system_hand_report_conclusion 991211 "$(issue_json 991211)" || status=$?
[[ "$status" == 0 ]] || { echo "unlinked SHA handoff returned $status, expected 0" >&2; exit 1; }
grep -Fq 'inbox:hand-done-no-diff-close issue=991211:' "$LOG" \
  || { echo 'unlinked SHA was not routed to the supervisor' >&2; exit 1; }

for issue in 991201 991202 991203 991204 991205 991206; do
  grep -Fq "close:$issue:pipeline-system:" "$LOG" || { echo "missing close for $issue" >&2; exit 1; }
done
for issue in 991207 991209; do
  if grep -Fq "close:$issue:" "$LOG"; then
    echo "incorrect close for $issue" >&2
    exit 1
  fi
  grep -Fq "inbox:hand-done-no-diff-close issue=$issue:" "$LOG" \
    || { echo "missing supervisor handoff for $issue" >&2; exit 1; }
done
for issue in 991212 991214 991215 991216 991217 991218 991219; do
  grep -Fq "close:$issue:pipeline-system:" "$LOG" \
    || { echo "missing close for positive case $issue" >&2; exit 1; }
  if grep -Fq "inbox:hand-done-no-diff-close issue=$issue:" "$LOG"; then
    echo "positive case $issue was also routed to supervisor" >&2
    exit 1
  fi
done
grep -Fq "Already on origin/main at $main_tip_sha per " "$LOG" \
  || { echo 'latest-main-tip report SHA was not retained in close evidence' >&2; exit 1; }
grep -Fq "close evidence commit $issue_991212_sha is issue-linked on origin/main" "$LOG" \
  || { echo 'current-main-tip case did not use the linked fix commit' >&2; exit 1; }
grep -Fq "Already on origin/main at $issue_991217_sha per $NIGHT/hand-991217.report; The implementation is complete" "$LOG" \
  || { grep '^close:991217:' "$LOG" >&2 || true; echo "trailing off-main SHA replaced the valid report SHA: expected $issue_991217_sha" >&2; exit 1; }
grep -Fq "close evidence commit $issue_991217_sha is issue-linked on origin/main" "$LOG" \
  || { echo 'off-main context case did not retain the issue-linked fix commit' >&2; exit 1; }
grep -Fq "Already on origin/main at $issue_991218_sha per $NIGHT/hand-991218.report; The implementation is complete" "$LOG" \
  || { grep '^close:991218:' "$LOG" >&2 || true; echo "trailing earlier main SHA replaced the valid report SHA: expected $issue_991218_sha" >&2; exit 1; }
grep -Fq "close evidence commit $issue_991218_sha is issue-linked on origin/main" "$LOG" \
  || { echo 'earlier-main context case did not retain the issue-linked fix commit' >&2; exit 1; }
grep -Fq "Already on origin/main at $issue_991219_sha per $NIGHT/hand-991219.report; The implementation is complete" "$LOG" \
  || { grep '^close:991219:' "$LOG" >&2 || true; echo "same-line off-main and earlier-main candidates hid the valid report SHA: expected $issue_991219_sha" >&2; exit 1; }
grep -Fq "close evidence commit $issue_991219_sha is issue-linked on origin/main" "$LOG" \
  || { echo 'same-line multi-SHA case did not retain the issue-linked fix commit' >&2; exit 1; }
if grep -Fq 'close:991210:' "$LOG"; then
  echo 'non-DONE report was incorrectly closed' >&2
  exit 1
fi
if grep -Fq 'close:991211:' "$LOG"; then
  echo 'unlinked SHA was incorrectly closed' >&2
  exit 1
fi
! grep -q '^dispatch:991206:' "$LOG" \
  || { echo 'unterminated final completion line requeued the hand' >&2; exit 1; }
! grep -q '^dispatch:' "$LOG" || { echo 'completed/handoff reports requeued a hand' >&2; exit 1; }
EOF
chmod +x "$FASTLANE_CONCLUSION_HOME/run.sh"
FASTLANE_CONCLUSION_OUTPUT="$(AGENT_HOME="$FASTLANE_CONCLUSION_HOME/agent" \
  FASTLANE_CONCLUSION_LOG="$FASTLANE_CONCLUSION_LOG" \
  bash "$FASTLANE_CONCLUSION_HOME/run.sh" "$SCRIPT_DIR" \
    "$ROUTE_PIPELINE_SYSTEM_CANDIDATES_FN" "$FASTLANE_CONCLUSION_SEED" \
    "$FASTLANE_CONCLUSION_REPO" "$FASTLANE_CONCLUSION_LOG" 2>&1)" || {
  printf '%s\n' "$FASTLANE_CONCLUSION_OUTPUT" >&2
  exit 1
}
assert_contains 'legacy DONE SHA report formats remain compatible' \
  "$(cat "$FASTLANE_CONCLUSION_LOG")" 'close:991205:pipeline-system:'
assert_contains 'off-main SHA is routed to supervisor instead of closing' \
  "$(cat "$FASTLANE_CONCLUSION_LOG")" 'inbox:hand-done-no-diff-close issue=991207:'
assert_contains 'another issue SHA without this ticket commit is handed off' \
  "$(cat "$FASTLANE_CONCLUSION_LOG")" 'inbox:hand-done-no-diff-close issue=991209:'
assert_eq 'verified DONE reports do not dispatch replacement hands' '' \
  "$(grep '^dispatch:' "$FASTLANE_CONCLUSION_LOG" || true)"
rm -rf "$FASTLANE_CONCLUSION_HOME"

ROADMAP_FASTLANE_HOME="$(mktemp -d)"
ROADMAP_FASTLANE_LOG="$ROADMAP_FASTLANE_HOME/order.log"
ROADMAP_FASTLANE_TREE='{"roots":[{"number":990000,"title":"Roadmap","state":"open","labels":["roadmap"],"children":[{"number":990001,"title":"Theme","state":"open","labels":["roadmap-theme"],"children":[{"number":990002,"title":"Epic","state":"open","labels":["roadmap-epic"],"children":[{"number":991009,"title":"Earlier ready issue","state":"open","labels":[],"blockedBy":[],"children":[]},{"number":991008,"title":"Later triage issue","state":"open","labels":[],"blockedBy":[],"children":[]}]}]}]}]}'
ROADMAP_FASTLANE_OUTPUT="$(AGENT_HOME="$ROADMAP_FASTLANE_HOME" FASTLANE_LOG="$ROADMAP_FASTLANE_LOG" \
  ROADMAP_FASTLANE_TREE="$ROADMAP_FASTLANE_TREE" bash -c '
    set -euo pipefail
    source "$1/lib.sh"
    eval "$2"
    REPO=test/repo
    ROADMAP_ORDER_ENABLED=true
    ROADMAP_TREE_READY=1
    ROADMAP_TREE_JSON="$ROADMAP_FASTLANE_TREE"
    NIGHT="$AGENT_HOME/night"
    pipeline_system_issue_matches() { return 1; }
    issue_is_parent_tracker() { return 1; }
    issue_body_is_direct_main_lane() { return 0; }
    route_pipeline_fastlane_issue() { printf "%s\n" "$1" >> "$FASTLANE_LOG"; }
    gh() {
      if [ "$1 $2" = "issue view" ]; then
        printf "%s\n" "{\"number\":$3,\"title\":\"Leaf\",\"body\":\"paths\",\"comments\":[],\"labels\":[],\"state\":\"OPEN\",\"subIssuesSummary\":{\"total\":0,\"completed\":0}}"
      elif [[ " $* " == *" --label needs-triage "* ]]; then
        printf "%s\n" "[{\"number\":991008,\"title\":\"Later triage issue\",\"body\":\"paths\",\"comments\":[],\"labels\":[{\"name\":\"needs-triage\"}],\"state\":\"OPEN\"}]"
      elif [[ " $* " == *" --label ready-for-agent "* ]]; then
        printf "%s\n" "[{\"number\":991009,\"title\":\"Earlier ready issue\",\"body\":\"paths\",\"comments\":[],\"labels\":[{\"name\":\"ready-for-agent\"}],\"state\":\"OPEN\"}]"
      fi
    }
    route_nonproduct_path_candidates
    cat "$FASTLANE_LOG"
  ' _ "$SCRIPT_DIR" "$ROUTE_PIPELINE_SYSTEM_CANDIDATES_FN" 2>&1)"
assert_eq 'roadmap fastlane merges stage queues before applying depth-first tree order' \
  $'991009\n991008' "$ROADMAP_FASTLANE_OUTPUT"
rm -rf "$ROADMAP_FASTLANE_HOME"

FASTLANE_PARENT_HOME="$(mktemp -d)"
FASTLANE_PARENT_LOG="$FASTLANE_PARENT_HOME/dispatch.log"
FASTLANE_PARENT_OUTPUT="$(FASTLANE_PARENT_LOG="$FASTLANE_PARENT_LOG" bash -c '
  set -euo pipefail
  source "$1/lib.sh"
  eval "$2"
  REPO=test/repo
  pipeline_system_issue_matches() { return 1; }
  issue_body_is_direct_main_lane() { return 0; }
  route_pipeline_fastlane_issue() { printf "DISPATCH:%s\n" "$1" >> "$FASTLANE_PARENT_LOG"; }
  gh() {
    if [ "$*" = "issue view 991008 --json state --jq .state" ]; then echo OPEN; else return 97; fi
  }
  rows="$(jq -cn \
    --arg spec_body "Migration overview.

Spec: migration

packages/example/file.ts" \
    --arg task_body "Migration tasks:
- [ ] Implement child #991008

packages/example/file.ts" \
    --arg spec_word_leaf_body "Update the spec-compliance guard.

packages/example/file.ts" \
    --arg title_spec "Runtime pilot spec, ADR-1" \
    --arg title_adr "运行时试点：后台任务迁移（ADR-2）" \
    --arg heading_body "## Spec

packages/example/file.ts" \
    "[{number:991006,title:\"Migration design\",body:\$spec_body,comments:[],labels:[],state:\"OPEN\",subIssuesSummary:{total:0,completed:0},blockedBy:{nodes:[]}}, {number:991007,title:\"Migration tasks\",body:\$task_body,comments:[],labels:[],state:\"OPEN\",subIssuesSummary:{total:0,completed:0},blockedBy:{nodes:[]}}, {number:991009,title:\"Completed child parent\",body:\"packages/example/file.ts\",comments:[],labels:[],state:\"OPEN\",subIssuesSummary:{total:1,completed:1},blockedBy:{nodes:[]}}, {number:991012,title:\"Fix spec-compliance check\",body:\$spec_word_leaf_body,comments:[],labels:[],state:\"OPEN\",subIssuesSummary:{total:0,completed:0},blockedBy:{nodes:[]}}, {number:991013,title:\$title_spec,body:\"packages/example/file.ts\",comments:[],labels:[],state:\"OPEN\",subIssuesSummary:{total:0,completed:0},blockedBy:{nodes:[]}}, {number:991014,title:\$title_adr,body:\"packages/example/file.ts\",comments:[],labels:[],state:\"OPEN\",subIssuesSummary:{total:0,completed:0},blockedBy:{nodes:[]}}, {number:991015,title:\"Migration design\",body:\$heading_body,comments:[],labels:[],state:\"OPEN\",subIssuesSummary:{total:0,completed:0},blockedBy:{nodes:[]}}]")"
  route_nonproduct_path_issue_rows "$rows"
' _ "$SCRIPT_DIR" "$ROUTE_PIPELINE_SYSTEM_CANDIDATES_FN" 2>&1)"
assert_contains 'non-product fastlane leaves Spec parents for triage' \
  "$FASTLANE_PARENT_OUTPUT" 'path-only #991006 is a parent tracker (spec/ADR pilot)'
assert_contains 'non-product fastlane leaves task-list parents for triage' \
  "$FASTLANE_PARENT_OUTPUT" 'path-only #991007 is a parent tracker (task list references open child #991008)'
assert_contains 'non-product fastlane leaves native parents with completed children queued' \
  "$FASTLANE_PARENT_OUTPUT" 'path-only #991009 is a parent tracker (has GitHub sub-issues)'
assert_contains 'non-product fastlane recognizes the #4472 title-form spec marker' \
  "$FASTLANE_PARENT_OUTPUT" 'path-only #991013 is a parent tracker (spec/ADR pilot)'
assert_contains 'non-product fastlane recognizes the #4279 title-form ADR pilot marker' \
  "$FASTLANE_PARENT_OUTPUT" 'path-only #991014 is a parent tracker (spec/ADR pilot)'
assert_contains 'non-product fastlane recognizes a Spec heading' \
  "$FASTLANE_PARENT_OUTPUT" 'path-only #991015 is a parent tracker (spec/ADR pilot)'
assert_contains 'a leaf mentioning spec-compliance remains eligible for fastlane' \
  "$(cat "$FASTLANE_PARENT_LOG" 2>/dev/null || true)" 'DISPATCH:991012'
assert_eq 'non-product fastlane dispatches none of the additional spec/ADR parents' '' \
  "$(grep -E 'DISPATCH:99101[345]' "$FASTLANE_PARENT_LOG" 2>/dev/null || true)"
assert_eq 'non-product fastlane does not hand-dispatch parent trackers' '' \
  "$(grep -v 'DISPATCH:991012' "$FASTLANE_PARENT_LOG" 2>/dev/null || true)"
rm -rf "$FASTLANE_PARENT_HOME"

STALE_PIPELINE_ROUTE_LOG="$(mktemp)"
(
  state_merge() { printf 'state:%s:%s\n' "$1" "$2" >> "$STALE_PIPELINE_ROUTE_LOG"; }
  guarded_write() { printf 'gh:%s\n' "$*" >> "$STALE_PIPELINE_ROUTE_LOG"; }
  gh() { printf '%s\n' '{"number":991003,"labels":[]}'; }
  if prepare_pipeline_system_issue 991003 '{"number":991003,"labels":[{"name":"pipeline-system"}]}' needs-advisor; then
    printf 'accepted\n' >> "$STALE_PIPELINE_ROUTE_LOG"
  else
    printf 'rejected\n' >> "$STALE_PIPELINE_ROUTE_LOG"
  fi
)
assert_contains "pipeline-system writer rejects stale membership after fresh product labels" \
  "$(cat "$STALE_PIPELINE_ROUTE_LOG")" 'rejected'
assert_eq "stale pipeline-system snapshot cannot write product ticket state or labels" \
  "" "$(grep -E '^(state|gh):991003:' "$STALE_PIPELINE_ROUTE_LOG" || true)"
rm -f "$STALE_PIPELINE_ROUTE_LOG"

REPREP_HOME="$(mktemp -d)"
REPREP_LOG="$(mktemp)"
REPREP_OUTPUT="$(AGENT_HOME="$REPREP_HOME" SCRIPT_DIR="$SCRIPT_DIR" REPREP_LOG="$REPREP_LOG" bash -c '
  set -euo pipefail
  source "$SCRIPT_DIR/lib.sh"
  roadmap_ensure_issue_parent() { return 0; }
  REPO=test/repo
  gh() {
    if [ "$1 $2" = "issue view" ]; then
      printf "%s\n" '\''{"number":991007,"labels":[{"name":"pipeline-system"},{"name":"ready-for-agent"}]}'\''
    elif [ "${1:-}" = api ]; then
      echo '\''[]'\''
    else
      printf "gh:%s\n" "$*" >> "$REPREP_LOG"
    fi
  }
  state_merge 991007 '\''{"pipeline_system":{"enabled":true},"state":"ready-for-agent","advisor_episode_seq":7,"model_policy":{"unit":"implement","step":"advisor"},"web_advisor_provider_job_id":"stale-job","web_advisor_provider_job_started_at":"2026-09-27T00:00:00Z","web_advisor_provider_job_episode_seq":7}'\''
  prepare_pipeline_system_issue 991007 '\''{"labels":[{"name":"pipeline-system"},{"name":"ready-for-agent"}]}'\'' ""
  prepare_pipeline_system_issue 991007 '\''{"labels":[{"name":"pipeline-system"},{"name":"ready-for-agent"}]}'\'' ""
  state_read 991007 | jq -r '\''[.advisor_episode_seq, .model_policy.step, (.web_advisor_provider_job_id // "none")] | @tsv'\''
  grep -c "^gh:issue edit" "$REPREP_LOG"
')"
assert_eq "pipeline-system re-preparation resets stale advisor state and bumps its episode once" \
  $'8\twork\tnone\n1' "$REPREP_OUTPUT"
rm -rf "$REPREP_HOME" "$REPREP_LOG"

# Exercise the real triage selection loops with only GitHub/systemd edges
# stubbed. Selected issues go into one batch; retry-alone markers override
# ordinary members, and cap leftovers remain queued for another tick.
TRIAGE_SELECTION_BODY="$(sed -n '/^  for next_triage in \$NEEDS_TRIAGE_IDS; do$/,/^  done$/p' "$PIPELINE_SRC")"
MEASURE_SELECTION_BODY="$(sed -n '/^  for next_measure in \$READY_MEASURE_IDS; do$/,/^  done$/p' "$PIPELINE_SRC")"
run_triage_selection() (
  local mode="$1" issue_numbers="$2" deferred_issue="$3" retry_deadline="$4" now="$5" backoff_issue="${6:-}" retry_alone_issue="${7:-}"
  TRIAGE_CAP="${AGENT_TRIAGE_CAP:-8}" TRIAGE_RETRY_NOW="$now" REPO=test/repo
  NEEDS_TRIAGE_IDS="$issue_numbers" READY_MEASURE_IDS="$issue_numbers"
  NEEDS_TRIAGE_JSON="$(printf '%s\n' "$issue_numbers" | jq -Rsc 'split("\n") | map(select(test("^[0-9]+$")) | tonumber | {number:.,labels:[]})')"
  READY_MEASURE_JSON="$NEEDS_TRIAGE_JSON"
  triage_slots="$TRIAGE_CAP"
  TRIAGE_BATCH_IDS=()
  TRIAGE_RETRY_ALONE=0
  TRIAGE_DEFERRED_COUNT=0
  state_read() {
    if [ "$1" = "$deferred_issue" ]; then
      printf '{"triage_retry_after_epoch":%s}\n' "$retry_deadline"
    elif [ "$1" = "$retry_alone_issue" ]; then
      printf '{"triage_batch_retry_alone":true}\n'
    else
      printf '{}\n'
    fi
  }
  issue_model_failure_backoff_remaining() {
    [ "$1" = "$backoff_issue" ] && printf '100\n' || printf '0\n'
  }
  state_file() { printf '%s\n' "$1"; }
  triage_classification_status() { printf 'unmeasured\n'; }
  is_on_hold() { return 1; }
  stage_unit_count() { printf '0\n'; }
  stage_unit_active() { return 1; }
  stage_dispatch_allowed() { return 0; }
  dispatch_triage_batch() { printf 'batch:%s\n' "$*"; }
  if [ "$mode" = "needs-triage" ]; then
    eval "$TRIAGE_SELECTION_BODY"
  else
    eval "$MEASURE_SELECTION_BODY"
  fi
  [ "${#TRIAGE_BATCH_IDS[@]}" -eq 0 ] || dispatch_triage_batch "${TRIAGE_BATCH_IDS[@]}"
  printf 'deferred:%s\n' "$TRIAGE_DEFERRED_COUNT"
)
TRIAGE_QUEUE_FIXTURE=$'910201\n910202'
assert_eq "stale-index deferral lets next needs-triage issue use the slot" \
  $'batch:910202\ndeferred:0' "$(AGENT_TRIAGE_CAP=1 run_triage_selection needs-triage "$TRIAGE_QUEUE_FIXTURE" 910201 2000 1000)"
assert_eq "needs-triage retry resumes at its deadline" \
  $'batch:910201\ndeferred:1' "$(AGENT_TRIAGE_CAP=1 run_triage_selection needs-triage "$TRIAGE_QUEUE_FIXTURE" 910201 2000 2000)"
assert_eq "scoped model failure skips only failed triage issue and leaves slot for next issue" \
  $'batch:910202\ndeferred:0' "$(AGENT_TRIAGE_CAP=1 run_triage_selection needs-triage "$TRIAGE_QUEUE_FIXTURE" '' 0 1000 910201)"
assert_eq "stale-index deferral also lets next precut measurement use the slot" \
  $'batch:910202\ndeferred:0' "$(AGENT_TRIAGE_CAP=1 run_triage_selection measure "$TRIAGE_QUEUE_FIXTURE" 910201 2000 1000)"
assert_eq "scoped model failure skips only failed precut measurement and leaves slot for next issue" \
  $'batch:910202\ndeferred:0' "$(AGENT_TRIAGE_CAP=1 run_triage_selection measure "$TRIAGE_QUEUE_FIXTURE" '' 0 1000 910201)"
TRIAGE_MULTI_QUEUE_FIXTURE=$'910201\n910202\n910203\n910204'
assert_eq "AGENT_TRIAGE_CAP=3 dispatches three needs-triage issues in one tick" \
  $'batch:910201 910202 910203\ndeferred:1' \
  "$(AGENT_TRIAGE_CAP=3 run_triage_selection needs-triage "$TRIAGE_MULTI_QUEUE_FIXTURE" 0 0 1000)"
assert_eq "AGENT_TRIAGE_CAP=3 dispatches three precut measurements in one tick" \
  $'batch:910201 910202 910203\ndeferred:1' \
  "$(AGENT_TRIAGE_CAP=3 run_triage_selection measure "$TRIAGE_MULTI_QUEUE_FIXTURE" 0 0 1000)"
assert_eq "a failed record retries alone after backoff" \
  $'batch:910202\ndeferred:0' \
  "$(AGENT_TRIAGE_CAP=3 run_triage_selection needs-triage "$TRIAGE_MULTI_QUEUE_FIXTURE" 0 0 1000 '' 910202)"

jq -n '{issues:[991010]}' > "$AGENT_HOME/triage-batch-active.json"
TRIAGE_BATCH_MEMBER_ACTIVE="$(
  systemctl() {
    if [ "${2:-}" = list-units ]; then
      printf '%s\n' 'zf-triage-batch.service loaded activating start-pre'
      return 0
    fi
    return 1
  }
  stage_unit_active triage 991010 && echo active || echo inactive
)"
TRIAGE_BATCH_NONMEMBER_ACTIVE="$(
  systemctl() {
    if [ "${2:-}" = list-units ]; then
      printf '%s\n' 'zf-triage-batch.service loaded activating start-pre'
      return 0
    fi
    return 1
  }
  stage_unit_active triage 991011 && echo active || echo inactive
)"
assert_eq "active batch member blocks implement and duplicate triage" active "$TRIAGE_BATCH_MEMBER_ACTIVE"
assert_eq "batch marker does not block unrelated issue" inactive "$TRIAGE_BATCH_NONMEMBER_ACTIVE"
TRIAGE_BATCH_ACTIVATING="$(
  systemctl() {
    if [ "${2:-}" = list-units ]; then
      printf '%s\n' 'zf-triage-batch.service loaded activating start-pre'
      return 0
    fi
    return 1
  }
  stage_unit_active triage batch && echo active || echo inactive
)"
assert_eq "activating batch owns scheduler slot" active "$TRIAGE_BATCH_ACTIVATING"
TRIAGE_BATCH_ABSENT="$(
  systemctl() { return 0; }
  stage_unit_active triage batch && echo active || echo inactive
)"
assert_eq "absent batch leaves scheduler slot open" inactive "$TRIAGE_BATCH_ABSENT"
rm -f "$AGENT_HOME/triage-batch-active.json"

TRIAGE_CAP_ASSIGNMENT="$(grep -E '^TRIAGE_CAP=.*$' "$PIPELINE_SRC")"
DEFAULT_TRIAGE_CAP="$(env -u AGENT_TRIAGE_CAP bash -c \
  "$TRIAGE_CAP_ASSIGNMENT; printf '%s\\n' \"\$TRIAGE_CAP\"")"
assert_eq "triage batch cap defaults to eight" '8' "$DEFAULT_TRIAGE_CAP"
CONFIGURED_TRIAGE_CAP="$(env AGENT_TRIAGE_CAP=3 bash -c \
  "$TRIAGE_CAP_ASSIGNMENT; printf '%s\\n' \"\$TRIAGE_CAP\"")"
assert_eq "AGENT_TRIAGE_CAP overrides triage cap" '3' "$CONFIGURED_TRIAGE_CAP"

assert_cond "fastlane stage no longer routes pipeline-system tickets to a hand" \
  "$(grep -qF 'route_pipeline_system_candidates' "$PIPELINE_SRC" && echo 0 || echo 1)"
assert_cond "path-only ticket routing reuses shared delivery classifier" \
  "$(route_body="$(sed -n '/^route_nonproduct_path_issue_rows() {/,/^}/p; /^route_nonproduct_path_candidates() {/,/^}/p' "$PIPELINE_SRC")"; grep -qF 'issue_body_is_direct_main_lane' <<< "$route_body" && grep -qF 'pipeline_system_issue_matches' <<< "$route_body" && echo 1 || echo 0)"
assert_cond "configured non-product tickets are excluded from recut and release dispatch snapshots" \
  "$(grep -A3 -F 'for next_recut in $(gh issue list' "$PIPELINE_SRC" | grep -qF '$lane_labels' && grep -A4 -F 'if ! release_issue_numbers=' "$PIPELINE_SRC" | grep -qF '$lane_labels' && echo 1 || echo 0)"
assert_cond "pipeline-system triage uses lightweight classification before model prompt" \
  "$(classify_line="$(grep -nF 'prepare_pipeline_system_issue "$N" "$ISSUE_JSON"' "$SCRIPT_DIR/run-triage.sh" | cut -d: -f1)"; prompt_line="$(grep -nF 'cat "$SCRIPT_DIR/prompts/triage.md"' "$SCRIPT_DIR/run-triage.sh" | cut -d: -f1)"; [ -n "$classify_line" ] && [ -n "$prompt_line" ] && [ "$classify_line" -lt "$prompt_line" ] && echo 1 || echo 0)"
assert_cond "technical advisor routes return pipeline-system tickets to implementation" \
  "$(grep -qF '.pipeline_system.enabled // false' "$SCRIPT_DIR"/lib.d/*.sh && grep -qF 'pipeline_system_return_to_implement' "$SCRIPT_DIR"/lib.d/*.sh && echo 1 || echo 0)"
assert_cond "advisor entry points skip and reconcile pipeline-system tickets" \
  "$(grep -qF 'pipeline_system_issue_matches' "$SCRIPT_DIR/run-advisor.sh" && echo 1 || echo 0)"
assert_cond "recut wrapper classifies pipeline-system tickets before model call" \
  "$(lane_line="$(grep -nF 'pipeline_system_issue_matches' "$SCRIPT_DIR/run-recut.sh" | tail -n 1 | cut -d: -f1)"; model_line="$(grep -nF 'run_model_json' "$SCRIPT_DIR/run-recut.sh" | head -n 1 | cut -d: -f1)"; [ -n "$lane_line" ] && [ -n "$model_line" ] && [ "$lane_line" -lt "$model_line" ] && echo 1 || echo 0)"
RELEASE_DELEGATE_LINE="$(grep -nF '[ "$PIPELINE_STAGE" = release ] && [ "${ZF_RELEASE_TRAIN_DELEGATE:-0}" = 1 ]' "$PIPELINE_SRC" | head -n 1 | cut -d: -f1)"
MODE_ANNOUNCE_LINE="$(grep -nF 'echo "issue-pipeline: AGENT_PIPELINE=$MODE"' "$PIPELINE_SRC" | head -n 1 | cut -d: -f1)"
assert_cond "release-train delegation runs the release slice under triage mode before any mode dispatch" \
  "$([ -n "$RELEASE_DELEGATE_LINE" ] && [ -n "$MODE_ANNOUNCE_LINE" ] && [ "$RELEASE_DELEGATE_LINE" -lt "$MODE_ANNOUNCE_LINE" ] && sed -n "${RELEASE_DELEGATE_LINE},$((RELEASE_DELEGATE_LINE + 2))p" "$PIPELINE_SRC" | grep -qF 'MODE=release' && echo 1 || echo 0)"
assert_cond "release delegate waits for the pipeline lock instead of a silent -n exit" \
  "$(grep -qF 'flock -w "${ZF_RELEASE_DELEGATE_LOCK_WAIT_SECONDS:-600}" 9' "$PIPELINE_SRC" && grep -qF 'release delegate found the pipeline lock busy' "$PIPELINE_SRC" && echo 1 || echo 0)"
assert_cond "release tick no longer infers awaiting-release from PR bodies" \
  "$(grep -qF 'Refs in:body' "$PIPELINE_SRC" && echo 0 || echo 1)"
DELIVERY_READ_OUT="$(
  REPO=test/repo
  gh() { echo 'Post https://api.github.com/graphql: Bad Gateway' >&2; return 1; }
  reconcile_pipeline_system_delivery 2>&1
  printf 'status=%s\n' "$?"
)"
assert_contains "transient delivery-label read leaves tickets open without failing tick" "$DELIVERY_READ_OUT" \
  'pipeline delivery label query failed; leaving tickets open'
assert_contains "transient delivery-label read is non-fatal to pipeline tick" "$DELIVERY_READ_OUT" 'status=0'
assert_cond "maintainer outcome recovery precedes digest send in post-dispatch maintenance" "$(awk '
  /^[[:space:]]*if reconcile_maintainer_outcomes; then$/ { recover=NR }
  /^[[:space:]]*flush_maintainer_outcome_digest \\|\\| true$/ { flush=NR }
  END { print recover && flush && recover < flush ? 1 : 0 }
' <<< "$POST_DISPATCH_MAINTENANCE_FN")"

LOW_MEMORY_OUT="$(bash -c '
  source "$1/lib.sh"
  agent_memory_available_kib() { echo 2047999; }
  agent_memory_floor_allows implement 2>&1
  echo "status=$?"
' _ "$SCRIPT_DIR")"
assert_contains "memory floor refuses below 2048MiB" "$LOW_MEMORY_OUT" "below 2048MiB floor"
assert_contains "low-memory refusal is nonzero" "$LOW_MEMORY_OUT" "status=1"
FLOOR_MEMORY_OUT="$(bash -c '
  source "$1/lib.sh"
  agent_memory_available_kib() { echo 2097152; }
  agent_memory_floor_allows implement
  echo "status=$?"
' _ "$SCRIPT_DIR")"
assert_contains "memory floor admits exact 2048MiB boundary" "$FLOOR_MEMORY_OUT" "status=0"

run_implement_resource_gate() (
  export IMPLEMENT_TEST_MEMORY_KIB="$1" IMPLEMENT_TEST_LOAD_1M="$2" IMPLEMENT_TEST_NPROC="$3"
  if [ "$#" -ge 4 ]; then export AGENT_DISPATCH_LOAD_LIMIT_MULTIPLIER="$4"; else unset AGENT_DISPATCH_LOAD_LIMIT_MULTIPLIER; fi
  source "$SCRIPT_DIR/lib.sh"
  agent_memory_available_kib() { echo "$IMPLEMENT_TEST_MEMORY_KIB"; }
  nproc() { echo "$IMPLEMENT_TEST_NPROC"; }
  agent_implement_dispatch_resources_allow
  echo "status=$?"
)
LOW_IMPLEMENT_MEMORY_OUT="$(run_implement_resource_gate 3145727 1.0 9 2>&1)"
assert_contains "implement gate refuses below 3072MiB" "$LOW_IMPLEMENT_MEMORY_OUT" "below 3072MiB floor"
assert_contains "low implement memory refusal is nonzero" "$LOW_IMPLEMENT_MEMORY_OUT" "status=1"
IMPLEMENT_BOUNDARY_OUT="$(run_implement_resource_gate 3145728 1.0 9 2>&1)"
assert_contains "implement gate admits exact 3072MiB" "$IMPLEMENT_BOUNDARY_OUT" "status=0"
# 2026-10-08: load 50-62 on 12 cores refused every implement tick with 5.7 GB free.
HIGH_LOAD_OUT="$(run_implement_resource_gate 3145728 62.58 12 4 2>&1)"
assert_contains "implement gate ignores CPU load when memory is above the floor" "$HIGH_LOAD_OUT" "status=0"
INVALID_LOAD_OUT="$(run_implement_resource_gate 3145728 invalid 9 invalid 2>&1)"
assert_contains "implement gate does not depend on load readings" "$INVALID_LOAD_OUT" "status=0"

# A unit's ExecStopPost records systemd's own result before --collect removes
# it. OOM results are capacity retries: refund implement accounting, retain a
# retry count, and name the cap kill in both the attempt record and conclusion.
OOM_STATE_ISSUE=990101
state_merge "$OOM_STATE_ISSUE" '.attempts = 4'
OOM_RECORDER_STATUS=0
SERVICE_RESULT=oom-kill EXIT_CODE=killed EXIT_STATUS=9 \
  "$SCRIPT_DIR/record-unit-result.sh" implement "$OOM_STATE_ISSUE" >/dev/null 2>&1 \
  || OOM_RECORDER_STATUS=$?
assert_eq "unit result hook persists systemd oom-kill before collect" 'oom-kill' \
  "$(state_read "$OOM_STATE_ISSUE" | jq -r '.unit_results.implement.result // empty')"
assert_eq "unit result hook succeeds" '0' "$OOM_RECORDER_STATUS"

TRIAGE_BATCH_ISSUE_A=990104
TRIAGE_BATCH_ISSUE_B=990105
state_merge "$TRIAGE_BATCH_ISSUE_A" '.attempts = 2'
state_merge "$TRIAGE_BATCH_ISSUE_B" '.attempts = 3'
TRIAGE_BATCH_RECORDER_STATUS=0
SERVICE_RESULT=oom-kill EXIT_CODE=killed EXIT_STATUS=9 \
  "$SCRIPT_DIR/record-unit-result.sh" triage-batch \
  "$TRIAGE_BATCH_ISSUE_A" "$TRIAGE_BATCH_ISSUE_B" >/dev/null 2>&1 \
  || TRIAGE_BATCH_RECORDER_STATUS=$?
assert_eq "triage batch result hook succeeds" '0' "$TRIAGE_BATCH_RECORDER_STATUS"
assert_eq "triage batch result is saved for every member" \
  'oom-kill,oom-kill' \
  "$(state_read "$TRIAGE_BATCH_ISSUE_A" | jq -r '.unit_results.triage.result')$(printf ',')$(state_read "$TRIAGE_BATCH_ISSUE_B" | jq -r '.unit_results.triage.result')"
assert_eq "triage batch result records its shared unit name" 'zf-triage-batch.service' \
  "$(state_read "$TRIAGE_BATCH_ISSUE_A" | jq -r '.unit_results.triage.unit')"

CONSUME_UNIT_OOM_FN="$(sed -n '/^consume_unit_memory_oom() {/,/^}/p' "$PIPELINE_SRC")"
if [ -n "$CONSUME_UNIT_OOM_FN" ]; then eval "$CONSUME_UNIT_OOM_FN"; fi
OOM_CONSUMED=missing
if declare -F consume_unit_memory_oom >/dev/null; then
  consume_unit_memory_oom "$OOM_STATE_ISSUE" implement && OOM_CONSUMED=handled
fi
assert_eq "OOM capacity event is consumed" 'handled' "$OOM_CONSUMED"
assert_eq "OOM event refunds implement attempt" '3' \
  "$(state_read "$OOM_STATE_ISSUE" | jq -r '.attempts')"
assert_eq "OOM retry counter survives result consumption" '1' \
  "$(state_read "$OOM_STATE_ISSUE" | jq -r '.unit_memory_ooms.implement')"
assert_contains "attempt record names systemd result and per-unit cap" \
  "$(state_read "$OOM_STATE_ISSUE" | jq -r '.run.decisions[-1].what // empty')" \
  'Result=oom-kill; killed by the per-unit memory cap'

REPEATED_OOM_ISSUE=990106
state_merge "$REPEATED_OOM_ISSUE" '.attempts = 4'
for _ in 1 2 3 4; do
  state_merge "$REPEATED_OOM_ISSUE" '.unit_results.implement = {result:"oom-kill"}'
  consume_unit_memory_oom "$REPEATED_OOM_ISSUE" implement
done
assert_eq "repeated MemoryMax kills cannot exhaust the implement attempt cap" '0' \
  "$(state_read "$REPEATED_OOM_ISSUE" | jq -r '.attempts')"
assert_eq "every capacity kill remains recorded" '4' \
  "$(state_read "$REPEATED_OOM_ISSUE" | jq -r '.unit_memory_ooms.implement')"

TRIAGE_OOM_ISSUE=990103
state_merge "$TRIAGE_OOM_ISSUE" '.attempts = 4 | .unit_results.triage = {result:"oom-kill"}'
consume_unit_memory_oom "$TRIAGE_OOM_ISSUE" triage
assert_eq "triage OOM is recorded without changing ticket attempts" '4' \
  "$(state_read "$TRIAGE_OOM_ISSUE" | jq -r '.attempts')"
assert_eq "triage OOM selects its own retry counter" '1' \
  "$(state_read "$TRIAGE_OOM_ISSUE" | jq -r '.unit_memory_ooms.triage')"
assert_eq "MemoryMax retries use shared env-fault taxonomy without extra attempt refunds" '6' \
  "$(wc -l < "$ENV_FAULT_DIR/env:unit-memory-cap.log")"

CAP_REASON_FN="$(sed -n '/^unit_attempt_cap_reason() {/,/^}/p' "$PIPELINE_SRC")"
if [ -n "$CAP_REASON_FN" ]; then eval "$CAP_REASON_FN"; fi
CAP_REASON_ISSUE=990107
state_merge "$CAP_REASON_ISSUE" '{"attempts":4,"unit_results":{"implement":{"result":"success","exit_status":0}},"model_policy":{"failure":{"stage":"review_verdict","reason":"review rejected the change"}}}'
CAP_REASON_NOTE=missing
if declare -F unit_attempt_cap_reason >/dev/null; then
  CAP_REASON_NOTE="$(unit_attempt_cap_reason "$CAP_REASON_ISSUE")"
fi
assert_contains "attempt-cap conclusion uses recorded systemd result" \
  "$CAP_REASON_NOTE" 'Result=success'
assert_contains "attempt-cap conclusion uses the latest attempt failure reason" \
  "$CAP_REASON_NOTE" 'review_verdict: review rejected the change'
assert_cond "attempt-cap conclusion does not invent a kill when unit completed" \
  "$([[ "$CAP_REASON_NOTE" != *'killed before its own give-up check could fire'* ]] && echo 1 || echo 0)"
HISTORY_REASON_ISSUE=990108
state_merge "$HISTORY_REASON_ISSUE" '{"unit_results":{"implement":{"result":"success","exit_status":0}},"model_policy":{"history":[{"unit":"implement","step":"work_retry","failure":{"stage":"risk-class","reason":"Implementation touched a P2/L4 path","recorded_at":"2026-10-02T02:51:57Z"}}]}}'
HISTORY_REASON_NOTE=missing
if declare -F unit_attempt_cap_reason >/dev/null; then
  HISTORY_REASON_NOTE="$(unit_attempt_cap_reason "$HISTORY_REASON_ISSUE")"
fi
assert_contains "repeat and cap notes read the failure recorded on model-policy history" \
  "$HISTORY_REASON_NOTE" 'risk-class: Implementation touched a P2/L4 path'

DISPATCH_FN="$(sed -n '/^dispatch() {/,/^}/p' "$PIPELINE_SRC")"
run_memory_capped_dispatch() (
  local stage="$1" oom_count="$2" retry_cap="$3"
  # dispatch builds "$ZF_ENGINE_DIR/run-$stage.sh" argv and lib.sh's unit-name
  # prefix; the hermetic runner sources neither, so take their defaults.
  ZF_ENGINE_DIR="$SCRIPT_DIR" UNIT_PREFIX_TRANSIENT=zf \
    AGENT_UNIT_MEMORY_RETRY_MAX="$retry_cap" OOM_COUNT="$oom_count" TEST_STAGE="$stage" \
    REPO_DIR="$(git rev-parse --show-toplevel)" \
    bash -c '
      set -euo pipefail
      eval "$1"
      SCRIPT_DIR="$2"
      DRY_RUN=0
      IMPLEMENT_RUNTIME_MAX_SEC=3600 TRIAGE_RUNTIME_MAX_SEC=3600 RECUT_RUNTIME_MAX_SEC=3600
      state_read() { printf "{\"unit_memory_ooms\":{\"%s\":%s}}\\n" "$TEST_STAGE" "$OOM_COUNT"; }
      consume_unit_memory_oom() { return 1; }
      coord_issue_key() { printf "issue:%s\n" "$1"; }
      PIPELINE_CLAIM_KEY=""
      pipeline_claim_begin() { PIPELINE_CLAIM_KEY="$(coord_issue_key "$1")"; PIPELINE_CLAIM_STAGE="$2"; PIPELINE_CLAIM_UNIT="$3"; PIPELINE_CLAIM_OWNER=fixture; }
      coord_assert_owned() { return 0; }
      pipeline_claim_drop() { :; }
      pipeline_claim_keep() { return 0; }
      guarded_write() { printf "%s\\n" "$*"; }
      record_env_fault() { :; }
      dispatch "$TEST_STAGE" 990102
    ' _ "$DISPATCH_FN" "$SCRIPT_DIR"
)
TRIAGE_MEMORY_RETRY="$(run_memory_capped_dispatch triage 1 7G)"
assert_contains "triage retry uses larger cap and records its result" \
  "$TRIAGE_MEMORY_RETRY" 'MemoryMax=7G'
assert_contains "triage stop hook records stage and issue" \
  "$TRIAGE_MEMORY_RETRY" "ExecStopPost=$SCRIPT_DIR/record-unit-result.sh triage 990102"

RECUT_MEMORY_FIRST="$(run_memory_capped_dispatch recut 0 7G)"
assert_contains "recut first attempt stays capped at 4G" "$RECUT_MEMORY_FIRST" 'MemoryMax=4G'

TRIAGE_BATCH_DISPATCH_FN="$(sed -n '/^dispatch_triage_batch() {/,/^}/p' "$PIPELINE_SRC")"
run_fake_triage_batch_dispatch() (
  local oom_count="$1" retry_cap="$2"
  ZF_ENGINE_DIR="$SCRIPT_DIR" UNIT_PREFIX_TRANSIENT=zf \
    AGENT_UNIT_MEMORY_RETRY_MAX="$retry_cap" TRIAGE_OOM_COUNT="$oom_count" \
    REPO_DIR="$(git rev-parse --show-toplevel)" AGENT_HOME="$AGENT_HOME" \
    bash -c '
      set -euo pipefail
      eval "$1"
      SCRIPT_DIR="$2"
      DRY_RUN=0
      TRIAGE_RUNTIME_MAX_SEC=3600
      hand_agent_issue_is_live_owned() { return 1; }
      issue_spend_budget_status() { printf "clear\t0\t0\n"; }
      consume_unit_memory_oom() { return 1; }
      state_read() { printf "{\"unit_memory_ooms\":{\"triage\":%s}}\\n" "$TRIAGE_OOM_COUNT"; }
      model_policy() { echo fixture; }
      model_config_fault_blocked() { return 1; }
      coord_new_owner() { printf "fixture-owner"; }
      pipeline_batch_claim_acquire() { return 0; }
      pipeline_batch_claim_drop() { :; }
      pipeline_batch_claim_keep() { :; }
      guarded_write() { printf "%s\\n" "$*"; }
      record_env_fault() { :; }
      dispatch_triage_batch 990104
      rm -f "$AGENT_HOME/triage-batch-active.json"
    ' _ "$TRIAGE_BATCH_DISPATCH_FN" "$SCRIPT_DIR"
)
FIRST_TRIAGE_BATCH="$(run_fake_triage_batch_dispatch 0 6G)"
assert_contains "first triage batch keeps default 4G MemoryMax" \
  "$FIRST_TRIAGE_BATCH" 'MemoryMax=4G'
assert_contains "triage batch stop hook receives every issue id" \
  "$FIRST_TRIAGE_BATCH" "ExecStopPost=$SCRIPT_DIR/record-unit-result.sh triage-batch 990104"
RETRY_TRIAGE_BATCH="$(run_fake_triage_batch_dispatch 1 7G)"
assert_contains "OOM triage batch retries at configured larger cap" \
  "$RETRY_TRIAGE_BATCH" 'MemoryMax=7G'

assert_cond "tick keeps no implement cap; scheduler's implement_cap and footprint mutex own lane concurrency" \
  "$(grep -qE '^(IMPLEMENT_CAP|PIPELINE_SYSTEM_IMPLEMENT_CAP)=' "$PIPELINE_SRC" && echo 0 || echo 1)"

assert_cond "recovery implement gate precedes attempt bump" "$(awk '
  /^dispatch_policy_unit\(\) \{/ { inside=1 }
  inside && /agent_implement_dispatch_resources_allow/ { gate=NR }
  inside && /state_bump_attempts "\$n"/ { if (gate && gate < NR) found=1; inside=0 }
  END { print found ? 1 : 0 }
' "$PIPELINE_SRC")"
assert_cond "advisor batch and release dispatches have memory gates" "$(grep -qF 'agent_memory_floor_allows advisor || return 0' "$PIPELINE_SRC" \
  && grep -qF 'if ! agent_memory_floor_allows release; then' "$PIPELINE_SRC" && echo 1 || echo 0)"
assert_cond "advisor polls gate before dispatch and slot decrement" "$(awk '
  /^advisor_dispatch_pending_job_pool\(\) \{/ { inside=1 }
  inside && /agent_memory_floor_allows advisor/ { gate=NR }
  inside && /dispatch advisor "\$next_poll"/ { dispatch=NR }
  inside && /advisor_slots=\$\(\(advisor_slots - 1\)\)/ { if (gate && gate < dispatch && dispatch < NR) found=1; inside=0 }
  END { print found ? 1 : 0 }
' "$PIPELINE_SRC")"
assert_cond "advisor orphan resumes gate before dispatch and slot decrement" "$(awk '
  /^advisor_dispatch_orphan_pool\(\) \{/ { inside=1 }
  inside && /agent_memory_floor_allows advisor/ { gate=NR }
  inside && /dispatch advisor "\$next_orphan"/ { dispatch=NR }
  inside && /advisor_slots=\$\(\(advisor_slots - 1\)\)/ { if (gate && gate < dispatch && dispatch < NR) found=1; inside=0 }
  END { print found ? 1 : 0 }
' "$PIPELINE_SRC")"

SELECTION_BODY="$(sed -n '/^if \[ "\$ADVISOR_QUEUE_COUNT" -ge "\$ADVISOR_BATCH_MIN" \]; then/,/^# Advisor slice ends/p' "$PIPELINE_SRC" | sed '$d')"
DECISION_BODY="$(sed -n '/^record_advisor_decision() {/,/^}/p' "$PIPELINE_SRC")"
if grep -q '^ADVISOR_BATCH_MIN=1$' "$PIPELINE_SRC"; then
  echo 'ok - a one-ticket queue is eligible for the batch dialogue'
else
  echo 'not ok - batch minimum permits a fresh single-ticket question'
  FAILED=1
fi
if ! grep -qF 'advisor_dispatch_ordinary_pool' "$PIPELINE_SRC" \
  && ! grep -qF 'dispatch advisor "$next_advisor"' "$PIPELINE_SRC"; then
  echo 'ok - fresh needs-advisor tickets have no single-ticket dispatch path'
else
  echo 'not ok - fresh needs-advisor tickets can still start a single-ticket run'
  FAILED=1
fi
if grep -qF 'dispatch_advisor_batch' <<< "$SELECTION_BODY" \
  && grep -qF 'advisor_dispatch_pending_job_pool' <<< "$SELECTION_BODY" \
  && grep -qF 'advisor_dispatch_orphan_pool' "$PIPELINE_SRC"; then
  echo 'ok - selector keeps batch, sent-job polling, and stored-verdict recovery paths'
else
  printf 'not ok - advisor selector is missing a required work path (batch=%s pending=%s orphan=%s)\n' \
    "$(grep -qF 'dispatch_advisor_batch' <<< "$SELECTION_BODY" && echo yes || echo no)" \
    "$(grep -qF 'advisor_dispatch_pending_job_pool' <<< "$SELECTION_BODY" && echo yes || echo no)" \
    "$(grep -qF 'advisor_dispatch_orphan_pool' "$PIPELINE_SRC" && echo yes || echo no)"
  FAILED=1
fi
if grep -qF 'if stage_unit_active advisor batch; then' "$PIPELINE_SRC"; then
  echo 'ok - active batch probe uses fail-closed stage_unit_active helper'
else
  echo 'not ok - batch activity probe bypasses stage_unit_active'
  FAILED=1
fi
if grep -qF 'dispatch advisor "$next_orphan" -E ADVISOR_RESUME_ONLY=1' "$PIPELINE_SRC"; then
  echo 'ok - orphan recovery cannot open a new single-ticket dialogue'
else
  echo 'not ok - orphan recovery can open a new single-ticket dialogue'
  FAILED=1
fi

# Failed GitHub reads stay unknown; they must not look like an empty queue.
ADVISOR_QUEUE_READ_BODY="$(sed -n '/^ADVISOR_QUEUE_READ_FAILED=0$/,/^advisor_slots=/p' "$PIPELINE_SRC")"
if grep -qF 'if ! NEEDS_ADVISOR_IDS=' <<< "$ADVISOR_QUEUE_READ_BODY" \
  && grep -qF 'ADVISOR_QUEUE_READ_FAILED=1' <<< "$ADVISOR_QUEUE_READ_BODY" \
  && grep -qF 'queue is unknown' <<< "$ADVISOR_QUEUE_READ_BODY"; then
  echo 'ok - an unreadable needs-advisor snapshot is recorded as unknown'
else
  echo 'not ok - an unreadable needs-advisor snapshot can abort or masquerade as empty'
  FAILED=1
fi
if grep -qF 'A failed snapshot is not an empty queue' <<< "$SELECTION_BODY" \
  && grep -qF 'elif [ "$ADVISOR_BATCH_UNIT_ACTIVE" = "1" ]; then' <<< "$SELECTION_BODY"; then
  echo 'ok - failed advisor reads skip advisor dispatch without blocking other scheduler legs'
else
  printf 'not ok - failed advisor reads can dispatch against an unknown queue (failed-snapshot=%s batch-active=%s)\n' \
    "$(grep -qF 'A failed snapshot is not an empty queue' <<< "$SELECTION_BODY" && echo yes || echo no)" \
    "$(grep -qF 'elif [ "$ADVISOR_BATCH_UNIT_ACTIVE" = "1" ]; then' <<< "$SELECTION_BODY" && echo yes || echo no)"
  FAILED=1
fi

ADVISOR_LEDGER_HOME="$(mktemp -d)"
run_advisor_selection() (
  local pending="$1" stale="$2" queue_count="$3" active="$4" queue_failed="${5:-0}"
  AGENT_HOME="$ADVISOR_LEDGER_HOME"
  STATE_DIR="$AGENT_HOME/state"
  mkdir -p "$STATE_DIR"
  IMPLEMENT_TICK_ID=20260923T000000Z
  ADVISOR_BATCH_MIN=1
  ADVISOR_QUEUE_COUNT="$queue_count"
  ADVISOR_PENDING_JOB_IDS="$pending"
  ADVISOR_STALE_PENDING_JOB_IDS="$stale"
  ADVISOR_BATCH_UNIT_ACTIVE="$active"
  ADVISOR_QUEUE_READ_FAILED="$queue_failed"
  advisor_slots=1
  advisor_batch_job_active() { return 1; }
  web_advisor_provider_dispatch_allowed() { return 0; }
  dispatch_advisor_batch() {
    [ "${ADVISOR_BATCH_LAUNCH_STATUS:-0}" -eq 0 ] || return "$ADVISOR_BATCH_LAUNCH_STATUS"
    echo batch-dispatch
  }
  advisor_dispatch_pending_job_pool() { echo pending-poll; }
  advisor_dispatch_orphan_pool() { echo orphan-resume; }
  eval "$DECISION_BODY"
  eval "$SELECTION_BODY"
)

SINGLE_QUEUE_SELECTION="$(run_advisor_selection '' '' 1 0 2>&1)"
ADVISOR_CALL_FAILURE_STATUS=0
ADVISOR_CALL_FAILURE_OUT="$(ADVISOR_BATCH_LAUNCH_STATUS=1 run_advisor_selection '' '' 1 0 2>&1)" || ADVISOR_CALL_FAILURE_STATUS=$?
assert_eq 'advisor caller explicitly propagates real launch failure' 1 "$ADVISOR_CALL_FAILURE_STATUS"
assert_cond 'advisor failed caller has no completed batch claim' \
  "$([[ "$ADVISOR_CALL_FAILURE_OUT" != *batch-dispatch* ]] && echo 1 || echo 0)"
if [[ "$SINGLE_QUEUE_SELECTION" == *'batch-dispatch'* ]] \
  && [[ "$SINGLE_QUEUE_SELECTION" != *'orphan-resume'* ]]; then
  echo 'ok - one fresh question starts a batch dialogue'
else
  echo 'not ok - one fresh question does not start a batch dialogue'
  FAILED=1
fi

STALE_PENDING_SELECTION="$(run_advisor_selection '' 1391 1 0 2>&1)"
if [[ "$STALE_PENDING_SELECTION" == *'batch-dispatch'* ]] \
  && [[ "$STALE_PENDING_SELECTION" == *'outcome=bypassed gate=pending-job-liveness object=1391'* ]] \
  && [[ "$STALE_PENDING_SELECTION" != *'pending-poll'* ]]; then
  echo 'ok - stale job marker is audited and does not suppress batch dispatch'
else
  echo 'not ok - stale job marker suppresses batch or lacks bypass audit'
  FAILED=1
fi
STALE_PENDING_RECORD="$(jq -c '.advisor_tick_decision' "$ADVISOR_LEDGER_HOME/state/1391.json")"
assert_eq "stale bypass decision records its gate" \
  "pending-job-liveness" "$(jq -r '.gate' <<< "$STALE_PENDING_RECORD")"
assert_eq "stale bypass decision names blocking issue" \
  "1391" "$(jq -r '.object' <<< "$STALE_PENDING_RECORD")"

LIVE_PENDING_SELECTION="$(run_advisor_selection 1539 '' 1 0 2>&1)"
if [[ "$LIVE_PENDING_SELECTION" == *'outcome=skipped gate=batch-pending object=1539'* ]] \
  && [[ "$LIVE_PENDING_SELECTION" == *'pending-poll'* ]] \
  && [[ "$LIVE_PENDING_SELECTION" != *'batch-dispatch'* ]]; then
  echo 'ok - already-sent single job is polled before the batch starts'
else
  echo 'not ok - pending single job is not polled ahead of batch'
  FAILED=1
fi
LIVE_PENDING_RECORD="$(jq -c '.advisor_tick_decision' "$ADVISOR_LEDGER_HOME/state/1539.json")"
assert_eq "live pending decision records batch-pending gate" \
  "batch-pending" "$(jq -r '.gate' <<< "$LIVE_PENDING_RECORD")"
assert_eq "live pending decision names blocking issue" \
  "1539" "$(jq -r '.object' <<< "$LIVE_PENDING_RECORD")"

NO_QUESTION_SELECTION="$(run_advisor_selection '' '' 0 0 2>&1)"
assert_contains "orphan recovery runs when no fresh batch queue exists" \
  "$NO_QUESTION_SELECTION" 'orphan-resume'
UNKNOWN_QUEUE_SELECTION="$(run_advisor_selection '' '' 0 0 1 2>&1)"
if [[ "$UNKNOWN_QUEUE_SELECTION" != *'batch-dispatch'* ]] \
  && [[ "$UNKNOWN_QUEUE_SELECTION" != *'pending-poll'* ]] \
  && [[ "$UNKNOWN_QUEUE_SELECTION" != *'orphan-resume'* ]]; then
  echo 'ok - unknown queue snapshot skips all advisor dispatch for this tick'
else
  echo 'not ok - unknown queue snapshot still dispatches advisor work'
  FAILED=1
fi
ACTIVE_BATCH_SELECTION="$(run_advisor_selection '' '' 1 1 2>&1)"
if [[ "$ACTIVE_BATCH_SELECTION" != *'batch-dispatch'* ]] \
  && [[ "$ACTIVE_BATCH_SELECTION" != *'pending-poll'* ]] \
  && [[ "$ACTIVE_BATCH_SELECTION" != *'orphan-resume'* ]]; then
  echo 'ok - active batch unit owns its scheduler tick'
else
  echo 'not ok - active batch shares its tick with another advisor path'
  FAILED=1
fi
rm -rf "$ADVISOR_LEDGER_HOME"

PAUSE_POLICY_BODY="$(sed -n '/^if \[ -e "\$PAUSE_FILE" \]; then$/,/^fi$/p' "$PIPELINE_SRC")"
if [[ "$PAUSE_POLICY_BODY" == *'if manual_pause_is_valid'* ]] \
  && [[ "$PAUSE_POLICY_BODY" == *'ignoring invalid PAUSE marker'* ]] \
  && [[ "$PAUSE_POLICY_BODY" != *'rm -f "$PAUSE_FILE"'* ]]; then
  echo 'ok - only complete manual PAUSE metadata stops scheduler; invalid markers are ignored and never auto-expire'
else
  echo 'not ok - invalid PAUSE can freeze or auto-resume the scheduler'
  FAILED=1
fi

# Execute the real PAUSE gate and mode selection with valid operator metadata.
PAUSE_MODE_BODY="$(sed -n '/^if \[ -e "\$PAUSE_FILE" \]; then$/,/^PHASE="$(read_agent_phase)"$/p' "$PIPELINE_SRC")"
for pause_case in triage:0 triage:1 release:0 release:1; do
  pause_result="$(
    PIPELINE_STAGE="${pause_case%:*}" ZF_RELEASE_TRAIN_DELEGATE="${pause_case#*:}"
    PAUSE_FILE="$AGENT_HOME/PAUSE"
    jq -n '{reason:"refactor",caller:"operator",issue:"none",provider:"none",model:"none",timestamp:"2026-10-24T22:10:00Z"}' > "$PAUSE_FILE"
    gh() { echo triage; }
    read_agent_phase() { echo 1; }
    eval "$PAUSE_MODE_BODY"
    echo "continued:$MODE"
  )"
  expected_pause_result=''
  [[ "$pause_case" != release:1 ]] || expected_pause_result='continued:release'
  assert_eq "valid PAUSE gate for stage:delegate=$pause_case" "$expected_pause_result" "$pause_result"
done
rm -f "$AGENT_HOME/PAUSE"

# Provider failure state must leave unrelated Codex dispatch and merge
# coordination runnable. Use real scheduler helpers with only IO mocked.
PROVIDER_DISPATCH_OUT="$(
  jq ".roles.advisor.disabled = false" "$SCRIPT_DIR/model-policy.default.json" > "$MODEL_POLICY_FILE"
  printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$WEB_ADVISOR_PROVIDER_EXHAUSTED_MARKER_FILE"
  jq -n --argjson config "$(jq -c '.roles.advisor' "$MODEL_POLICY_FILE")" \
    --arg identity "$MODEL_POLICY_TEST_ADVISOR_IDENTITY" \
    '{role:"advisor",identity:$identity,config:$config}' > "$AGENT_HOME/model-config-advisor.json"
  eval "$(sed -n '/^recover_stale_policy_unit() {/,/^}/p' "$PIPELINE_SRC")"
  eval "$(sed -n '/^dispatch_policy_unit() {/,/^}/p' "$PIPELINE_SRC")"
  eval "$(sed -n '/^dispatch_triage_batch() {/,/^}/p' "$PIPELINE_SRC")"
  # Real claim helpers (filesystem claims under the isolated AGENT_HOME); only the
  # scheduler-runtime census is IO to mock -- this fixture has no runtime ledgers.
  eval "$(sed -n '/^pipeline_claim_clear() {/,/^}/p; /^pipeline_live_worker_check() {/,/^}/p; /^pipeline_claim_begin() {/,/^}/p; /^pipeline_claim_drop() {/,/^}/p; /^pipeline_claim_keep() {/,/^}/p' "$PIPELINE_SRC")"
  source "$SCRIPT_DIR/coord.sh"
  coord_issue_live_worker() { return 1; }
  state_read() { echo '{}'; }
  state_merge() { :; }
  state_bump_attempts() { :; }
  issue_spend_budget_status() { printf 'clear\t0\t0\n'; }
  model_policy_begin_unit() { :; }
  agent_implement_dispatch_resources_allow() { return 0; }
  codex_probe_ok() { return 0; }
  codex_provider_recovery_probe_if_due() { return 0; }
  codex_quota_exhausted() { return 1; }
  dispatch() { printf '%s\n' "$1" > "$AGENT_HOME/dispatched-$1"; }
  systemctl() { return 1; }
  dispatch_policy_unit implement 910555 ready-for-agent 1
  echo "OTHER-IMPLEMENT:$([ -f "$AGENT_HOME/dispatched-implement" ] && echo yes || echo no)"
  jq -n --argjson config "$(jq -c '.roles.work' "$MODEL_POLICY_FILE")" \
    --arg identity "$MODEL_POLICY_TEST_WORK_IDENTITY" \
    '{role:"work",identity:$identity,config:$config}' > "$AGENT_HOME/model-config-work.json"
  dispatch_policy_unit recut 910556 needs-recut || :
  dispatch_triage_batch 910557
  echo "FAILED-RECUT:$([ -f "$AGENT_HOME/dispatched-recut" ] && echo yes || echo no)"
  echo "FAILED-TRIAGE:$([ -f "$AGENT_HOME/dispatched-triage" ] && echo yes || echo no)"
)" || true
assert_contains "unrelated provider hold still dispatches Codex implement" "$PROVIDER_DISPATCH_OUT" 'OTHER-IMPLEMENT:yes'
assert_contains "failed work role blocks recut dispatch" "$PROVIDER_DISPATCH_OUT" 'FAILED-RECUT:no'
assert_contains "failed work role blocks triage batch dispatch" "$PROVIDER_DISPATCH_OUT" 'FAILED-TRIAGE:no'
rm -f "$AGENT_HOME/model-config-advisor.json" "$AGENT_HOME/model-config-work.json" "$WEB_ADVISOR_PROVIDER_EXHAUSTED_MARKER_FILE" "$AGENT_HOME/dispatched-implement"

# Exercise the real policy and launch boundary with admission refused.
run_issue_admission_case() (
  local stage="$1" launch_status="$2" status=0 attempts=0 active=no claim=none
  ZF_ENGINE_DIR="$AGENT_HOME/admission-legs" UNIT_PREFIX_TRANSIENT=zf
  mkdir -p "$ZF_ENGINE_DIR"
  : > "$ZF_ENGINE_DIR/run-$stage.sh"
  chmod +x "$ZF_ENGINE_DIR/run-$stage.sh"
  IMPLEMENT_RUNTIME_MAX_SEC=60 RECUT_RUNTIME_MAX_SEC=60
  PIPELINE_CLAIM_KEY='' PIPELINE_CLAIM_UNIT='' PIPELINE_CLAIM_STAGE='' PIPELINE_CLAIM_OWNER=''
  eval "$(sed -n '/^dispatch() {/,/^}/p; /^dispatch_policy_unit() {/,/^}/p' "$PIPELINE_SRC")"
  state_read() { printf '{"attempts":%s,"unit_memory_ooms":{}}\n' "$attempts"; }
  state_merge() { [[ "$2" != *'del(.model_policy.active)'* ]] || active=no; [[ "$2" != *'"active"'* ]] || active=yes; return 0; }
  state_bump_attempts() { attempts=$((attempts + 1)); }
  refund_implement_attempt() { attempts=$((attempts - 1)); }
  state_merge_attempt_transition() { attempts=$((attempts - 1)); active=no; }
  issue_spend_budget_status() { printf 'clear\t0\t0\n'; }
  recover_stale_policy_unit() { return 1; }
  agent_implement_dispatch_resources_allow() { return 0; }
  model_policy_begin_unit() { :; }
  model_policy() { case "$1" in initial-step) echo work ;; step-role) echo work ;; dispatch-identity) echo codex:fixture ;; esac; }
  issue_model_failure_backoff_remaining() { echo 0; }
  model_config_fault_blocked() { return 1; }
  codex_probe_ok() { return 0; }
  codex_provider_recovery_probe_if_due() { return 0; }
  codex_quota_exhausted() { return 1; }
  codex_model_capacity_held() { return 1; }
  ensure_issue_roadmap_parent_for_dispatch() { return 0; }
  pipeline_claim_begin() { PIPELINE_CLAIM_KEY="issue:$1"; PIPELINE_CLAIM_STAGE="$2"; PIPELINE_CLAIM_UNIT="$3"; PIPELINE_CLAIM_OWNER=fixture; claim=held; }
  coord_issue_key() { printf 'issue:%s' "$1"; }
  coord_assert_owned() { return 0; }
  pipeline_claim_drop() { claim=dropped; }
  consume_unit_memory_oom() { return 1; }
  guarded_write() { return "$launch_status"; }
  record_env_fault() { printf 'fault:%s\n' "$1"; [ "$2" != implement ] || refund_implement_attempt "$3"; }
  dispatch_policy_unit "$stage" 910101 queued "$([ "$stage" = implement ] && echo 1 || echo 0)" 2>/dev/null || status=$?
  printf 'status:%s attempts:%s active:%s claim:%s queue:queued\n' "$status" "$attempts" "$active" "$claim"
)
assert_eq 'recut admission leaves queued work without a fault or active claim' \
  'status:75 attempts:0 active:no claim:dropped queue:queued' "$(run_issue_admission_case recut 75)"
assert_eq 'implement admission refunds the attempt and leaves queued work without a fault' \
  'status:75 attempts:0 active:no claim:dropped queue:queued' "$(run_issue_admission_case implement 75)"
assert_eq 'ordinary per-issue launch failure still records its fault' \
  $'fault:env:systemd-run-dispatch-failed:recut\nstatus:1 attempts:0 active:no claim:dropped queue:queued' "$(run_issue_admission_case recut 1)"
# Execute the scheduler's real recut status branch as well as the dispatch.
# Supply the refusal through the real caller branch.
run_recut_admission_caller() (
  local dispatch_status=0 next_recut=910101 recut_slots=1
  dispatch_policy_unit() { return 75; }
  record_env_fault() { printf 'fault:%s\n' "$1"; }
  record_implement_decision() { :; }
  for candidate in one; do
    eval "$(sed -n '/    if dispatch_policy_unit recut "\$next_recut" needs-recut; then/,/      esac/p' "$PIPELINE_SRC")
    fi"
  done
  printf 'slots:%s\n' "$recut_slots"
)
assert_eq 'recut scheduler leaves a deferred candidate queued without a policy fault' \
  'slots:1' "$(run_recut_admission_caller)"
run_refresh_admission_case() (
  local launch_status="$1" status=0
  REPO_DIR="$SCRIPT_DIR/.." ZF_ENGINE_DIR="$SCRIPT_DIR" UNIT_PREFIX_TRANSIENT=zf
  eval "$(sed -n '/^dispatch_gitnexus_refresh() {/,/^}/p' "$PIPELINE_SRC")"
  gitnexus_index_matches_origin_main() { return 1; }
  systemctl() { return 1; }
  guarded_write() { return "$launch_status"; }
  record_env_fault() { printf 'fault:%s\n' "$1"; }
  dispatch_gitnexus_refresh 2>/dev/null || status=$?
  printf 'status:%s\n' "$status"
)
assert_eq 'refresh admission deferral records no fault' 'status:0' "$(run_refresh_admission_case 75)"
assert_eq 'refresh launch failure still records its fault' \
  $'fault:env:systemd-run-dispatch-failed:gitnexus-refresh\nstatus:1' "$(run_refresh_admission_case 1)"

# Execution admission's typed 75 is pending work, not a failed systemd launch.
run_batch_admission_case() (
  local kind="$1" launch_status="$2" status=0
  AGENT_HOME="$(mktemp -d)"
  trap 'rm -rf -- "$AGENT_HOME"' EXIT
  REPO_DIR="$SCRIPT_DIR/.."
  # dispatch builds "$ZF_ENGINE_DIR/run-$stage.sh" argv; config.sh normally provides it.
  ZF_ENGINE_DIR="$SCRIPT_DIR" UNIT_PREFIX_TRANSIENT=zf
  DRY_RUN=0
  NEEDS_ADVISOR_IDS=910101
  RELEASE_RUNTIME_MAX_SEC=60
  ADVISOR_RUNTIME_MAX_SEC=60
  TRIAGE_RUNTIME_MAX_SEC=60
  IMPLEMENT_RUNTIME_MAX_SEC=60
  eval "$(sed -n '/^dispatch_release_batch() {/,/^}/p; /^dispatch_advisor_batch() {/,/^}/p; /^dispatch_triage_batch() {/,/^}/p' "$PIPELINE_SRC")"
  systemctl() { return 3; }
  hand_agent_issue_is_live_owned() { return 1; }
  issue_spend_budget_status() { printf 'clear\t0\t0\n'; }
  coord_new_owner() { printf "fixture-owner"; }
  pipeline_batch_claim_acquire() { return 0; }
  pipeline_batch_claim_drop() { :; }
  pipeline_batch_claim_keep() { :; }
  agent_memory_floor_allows() { return 0; }
  model_policy() { echo fixture; }
  model_config_fault_blocked() { return 1; }
  consume_unit_memory_oom() { return 1; }
  state_read() { echo '{}'; }
  guarded_write() {
    if [ "$launch_status" -eq 0 ]; then printf 'unit-created\n'; fi
    return "$launch_status"
  }
  record_env_fault() { printf 'fault:%s\n' "$1"; }
  case "$kind" in
    release) dispatch_release_batch 910101 candidate-sha 2>/dev/null || status=$? ;;
    advisor) dispatch_advisor_batch 2>/dev/null || status=$? ;;
    advisor-poll) dispatch_advisor_batch 1 2>/dev/null || status=$? ;;
    triage) dispatch_triage_batch 910101 2>/dev/null || status=$? ;;
  esac
  printf 'status:%s\n' "$status"
  if [ "$kind" = triage ]; then
    if [ -e "$AGENT_HOME/triage-batch-active.json" ]; then echo active:yes; else echo active:no; fi
  fi
)
assert_eq 'triage admission 75 leaves no fabricated active marker, unit or fault' \
  $'status:75\nactive:no' "$(run_batch_admission_case triage 75)"
assert_eq 'triage real launch error remains fatal and cleans the dispatch marker' \
  $'fault:env:systemd-run-dispatch-failed:triage-batch\nstatus:1\nactive:no' "$(run_batch_admission_case triage 1)"
assert_eq 'triage success creates one unit with the active dispatch marker' \
  $'unit-created\nstatus:0\nactive:yes' "$(run_batch_admission_case triage 0)"
run_triage_admission_caller() (
  local launch_status="$1"
  TRIAGE_BATCH_IDS=(910101)
  TRIAGE_RETRY_ALONE=0
  hand_agent_issue_is_live_owned() { return 1; }
  dispatch_triage_batch() { return "$launch_status"; }
  eval "$(sed -n '/^if \[ "${#TRIAGE_BATCH_IDS\[@\]}" -gt 0 \]; then$/,/^# Not gated on triage:/p' "$PIPELINE_SRC" | sed '$d')"
)
assert_eq 'triage caller leaves admission-refused candidates pending without a dispatched claim' \
  'issue-pipeline: triage batch admission deferred; selected issues remain pending' \
  "$(run_triage_admission_caller 75 2>&1)"
TRIAGE_CALL_FAILURE_STATUS=0
TRIAGE_CALL_FAILURE_OUT="$(run_triage_admission_caller 1 2>&1)" || TRIAGE_CALL_FAILURE_STATUS=$?
assert_eq 'triage caller explicitly propagates real failure' 1 "$TRIAGE_CALL_FAILURE_STATUS"
assert_eq 'triage failed caller makes no dispatch claim' '' "$TRIAGE_CALL_FAILURE_OUT"

# Fail-closed pause read failures are summarized at tick exit without masking
# the scheduler's existing exit status.
ON_HOLD_FAILURE_REPORTER="$(sed -n '/^report_on_hold_query_failures() {/,/^}/p' "$PIPELINE_SRC")"
if grep -q '^trap report_on_hold_query_failures EXIT$' "$PIPELINE_SRC" \
  && grep -qF 'fail-closed skipped those candidates' <<< "$ON_HOLD_FAILURE_REPORTER" \
  && grep -qF 'return "$exit_status"' <<< "$ON_HOLD_FAILURE_REPORTER"; then
  echo 'ok - failed fail-closed pause checks are summarized at tick exit'
else
  echo 'not ok - pause-check failures are not summarized safely'
  FAILED=1
fi
if ON_HOLD_REPORT_OUT="$(ON_HOLD_QUERY_FAILURE_COUNT=2 ON_HOLD_QUERY_FAILURE_ISSUES='1437 1501' bash -c '
  eval "$1"
  trap report_on_hold_query_failures EXIT
  exit 7
' _ "$ON_HOLD_FAILURE_REPORTER" 2>&1)"; then
  ON_HOLD_REPORT_STATUS=0
else
  ON_HOLD_REPORT_STATUS=$?
fi
assert_eq 'the on-hold EXIT summary preserves a failing scheduler status' \
  '7' "$ON_HOLD_REPORT_STATUS"
assert_contains 'the on-hold EXIT summary names failed reads and skipped issue ids' \
  "$ON_HOLD_REPORT_OUT" '2 read(s) across issue(s) 1437 1501'

if grep -qF 'record_advisor_decision' "$PIPELINE_SRC" \
  && grep -qF 'ADVISOR_STALE_PENDING_JOB_IDS' "$PIPELINE_SRC"; then
  echo 'ok - advisor mode decisions retain explicit journal and stale-id snapshot'
else
  echo 'not ok - advisor mode decision audit wiring is incomplete'
  FAILED=1
fi

# Release selection pins one main SHA, validates each ticket against it, then
# dispatches one release unit for the whole eligible cohort.
RELEASE_SELECTION_FN="$(sed -n '/^select_release_batch() {/,/^}/p' "$PIPELINE_SRC")"
RELEASE_CADENCE_FN="$(sed -n '/^release_batch_cadence_mark() {/,/^}/p; /^release_batch_cadence_open() {/,/^}/p' "$PIPELINE_SRC")"
PRODUCTION_DEPLOYMENT_SHA_FN="$(sed -n '/^latest_production_deployment_sha() {/,/^}/p' "$PIPELINE_SRC")"
mkdir -p "$ISSUE_PIPELINE_TEST_AGENT_HOME/deployment-gh"
cat > "$ISSUE_PIPELINE_TEST_AGENT_HOME/deployment-gh/gh" <<'GH'
#!/usr/bin/env bash
case "$2" in
  repos/*/deployments\?environment=production\&per_page=20)
    jq -cn --arg sha "$FAKE_DEPLOYMENT_SHA" '[{id:1,sha:$sha,payload:{sha:$sha,images:{"example-admin":"sha256:test"},image_shas:{"example-admin":$sha}}}]' ;;
  repos/*/deployments/1/statuses) echo '[{"state":"success","created_at":"2026-10-24T00:00:00Z"}]' ;;
  *) echo "unexpected fake deployment API call: $*" >&2; exit 2 ;;
esac
GH
chmod +x "$ISSUE_PIPELINE_TEST_AGENT_HOME/deployment-gh/gh"
run_release_selection() (
  local issue_json="$1" state_issue="${2:-}" on_hold="${3:-}" label_rc="${4:-1}" released="${5:-}" deploy_blocked="${6:-1}" state_pr="${7:-910201}" fleet_issue="${8:-}" missing_pr_issue="${9:-}" slot_count="${10:-10}" invalid_pr_issue="${11:-}" invalid_ancestor_issue="${12:-}" stage_rc="${13:-0}" memory_rc="${14:-0}" active_issue="${15:-}" run_outcome="${16:-merged}" deploy_status="${17:-pending}" pipeline_system_issue="${18:-}" timing_wait_sha="${19:-}"
  if [[ "${RELEASE_CADENCE_TEST_NOW:-}" =~ ^[0-9]+$ ]]; then
    date() {
      if [[ "$#" -eq 1 && "$1" = +%s ]]; then
        printf '%s\n' "$RELEASE_CADENCE_TEST_NOW"
      else
        command date "$@"
      fi
    }
  fi
  PIPELINE_SYSTEM_LABELS_JSON='["pipeline-system"]'
  RELEASE_CAP="$slot_count"
  IMPLEMENT_TICK_ID=test-tick
  REPO=test/repo
  REPO_DIR="$AGENT_HOME/test-repo"
  PRODUCTION_DEPLOYMENT_SHA=""; PRODUCTION_DEPLOYMENT_SHA_LOADED=0
  export PATH="$ISSUE_PIPELINE_TEST_AGENT_HOME/deployment-gh:$PATH"
  selector_side_effects=""
  record_selector_side_effect() {
    selector_side_effects="${selector_side_effects:+$selector_side_effects,}$1"
  }
  record_release_decision() {
    printf 'release-decision issue=#%s outcome=%s gate=%s object=%s reason=%s\n' "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}"
  }
  guarded_write() { record_selector_side_effect blocked-notification; }
  guarded_issue_comment() { record_selector_side_effect blocked-notification; }
  notify_email() { record_selector_side_effect blocked-notification; }
  route_to_advisor() { record_selector_side_effect advisor-route; }
  state_merge() { record_selector_side_effect state-merge; }
  state_write() { record_selector_side_effect state-write; }
  guarded_state_write() { record_selector_side_effect state-write; }
  state_requeue() { record_selector_side_effect state-write; }
  gh() {
    case "$1 ${2:-}" in
      'issue list') printf '%s\n' "$issue_json" ;;
      *) echo "unexpected gh invocation: $*" >&2; return 1 ;;
    esac
  }
  git() {
    if [[ " $* " == *" merge-base --is-ancestor "* ]]; then
      [ "$n" != "$invalid_ancestor_issue" ]
    else
      printf 'candidate-sha\n'
    fi
  }
  cap_slots_remaining() { echo "$RELEASE_CAP"; }
  stage_unit_count() { echo 0; }
  is_on_hold() { [ "$1" = "$on_hold" ]; }
  has_label() { return "$label_rc"; }
  state_read() {
    if [ "$1" = "$missing_pr_issue" ]; then
      echo '{"state":"awaiting-release","deploy_state":"pending","run":{"outcome":"merged","evidence":{}}}'
      elif [ "$1" = "$state_issue" ] || [ "$state_issue" = all ]; then
      if [[ -n "$fleet_issue" && " $fleet_issue " == *" $1 "* ]]; then
        printf '{"state":"awaiting-release","deploy_state":"%s","run":{"outcome":"%s","evidence":{"pr_number":"%s"}},"fleet_roll_pending":{"status":"pending","image_sha":"roll-%s"},"released":%s}\n' "$deploy_status" "$run_outcome" "$state_pr" "$1" "$([ "$1" = "$released" ] && echo true || echo false)"
      elif [ "$1" = "$pipeline_system_issue" ]; then
        printf '{"state":"awaiting-release","deploy_state":"%s","run":{"outcome":"%s","evidence":{"pr_number":"%s"}},"pipeline_system":{"enabled":true}}\n' "$deploy_status" "$run_outcome" "$state_pr"
      else
        printf '{"state":"awaiting-release","deploy_state":"%s","run":{"outcome":"%s","evidence":{"pr_number":"%s"}},"release_timing_wait_sha":"%s","released":%s}\n' "$deploy_status" "$run_outcome" "$state_pr" "$timing_wait_sha" "$([ "$1" = "$released" ] && echo true || echo false)"
      fi
    else
      echo '{}'
    fi
  }
  eval "$PRODUCTION_DEPLOYMENT_SHA_FN"
  merged_pr_for_issue() {
    [ "$1" != "$invalid_pr_issue" ] || return 1
    printf '%s\tmerge-sha\n' "$state_pr"
  }
  deploy_is_blocked() { return "$deploy_blocked"; }
  stage_unit_active() { [ "$1" = release ] && { [ "$2" = batch ] || [ "$2" = "$active_issue" ]; } && [ -n "$active_issue" ]; }
  stage_dispatch_allowed() { return "$stage_rc"; }
  agent_memory_floor_allows() { return "$memory_rc"; }
  dispatch_release_batch() {
    [ "${RELEASE_BATCH_LAUNCH_STATUS:-0}" -eq 0 ] || return "$RELEASE_BATCH_LAUNCH_STATUS"
    printf 'dispatch:release-batch:%s:%s\n' "$1" "$2"
  }
  RELEASE_BATCH_CADENCE_FILE="$AGENT_HOME/release-batch-last-dispatch"
  eval "$RELEASE_CADENCE_FN"
  eval "$RELEASE_SELECTION_FN"
  select_release_batch || return $?
  if [ -n "$fleet_issue" ]; then
    printf 'selector-side-effects:%s\n' "${selector_side_effects:-none}"
    printf 'pending-marker:%s\n' "$(state_read "${fleet_issue%% *}" | jq -r '.fleet_roll_pending.status // empty')"
  fi
)

assert_eq 'awaiting-release state dispatches its recorded PR without a body reference' \
  $'dispatch:release-batch:910101:candidate-sha\nrelease-decision issue=#910101 outcome=dispatched gate=release-batch object=zf-release-batch reason=sha=candidate-sha' \
  "$(run_release_selection '[{"number":910101}]' 910101)"
timing_wait_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
assert_eq 'release timing debt reads the deployed SHA from GitHub Deployments' \
  'release-decision issue=#910102 outcome=skipped gate=timing-debt object=#1449 reason=already-deployed-waiting-next-deploy' \
  "$(FAKE_DEPLOYMENT_SHA="$timing_wait_sha" run_release_selection '[{"number":910102}]' 910102 '' 1 '' 1 910202 '' '' 10 '' '' 0 0 '' merged pending '' "$timing_wait_sha")"
assert_eq 'release batch deferral logs pending candidates without dispatched or batched claims' \
  $'release-decision issue=#910101 outcome=skipped gate=execution-admission object=zf-release-batch reason=temporarily-unavailable\nrelease-decision issue=#910102 outcome=skipped gate=execution-admission object=zf-release-batch reason=temporarily-unavailable' \
  "$(RELEASE_BATCH_LAUNCH_STATUS=75 run_release_selection '[{"number":910101},{"number":910102}]' all)"
RELEASE_SELECTION_FAILURE_STATUS=0
RELEASE_SELECTION_FAILURE_OUT="$(RELEASE_BATCH_LAUNCH_STATUS=1 run_release_selection '[{"number":910101}]' 910101)" || RELEASE_SELECTION_FAILURE_STATUS=$?
assert_eq 'release selector preserves a genuine launch failure' 1 "$RELEASE_SELECTION_FAILURE_STATUS"
assert_eq 'failed release selection makes no dispatched claim' '' "$RELEASE_SELECTION_FAILURE_OUT"
assert_eq 'configured non-product issue is excluded from the release selector' '' \
  "$(run_release_selection '[{"number":910124,"labels":[{"name":"pipeline-system"}]}]' 910124)"
assert_eq 'pipeline-system state keeps its direct close path even without its label snapshot' \
  'release-decision issue=#910125 outcome=skipped gate=pipeline-system object=state reason=direct-close-path' \
  "$(run_release_selection '[{"number":910125}]' 910125 '' 1 '' 1 910201 '' '' 10 '' '' 0 0 '' merged pending 910125)"
assert_eq 'a body mention without awaiting-release state is not a release candidate' \
  'release-decision issue=#910102 outcome=skipped gate=release-state object=state reason=not-awaiting-release' \
  "$(run_release_selection '[{"number":910102}]')"
assert_eq 'non-merged run outcome logs its release skip' \
  'release-decision issue=#910121 outcome=skipped gate=run-outcome object=state reason=not-merged' \
  "$(run_release_selection '[{"number":910121}]' 910121 '' 1 '' 1 910201 '' '' 10 '' '' 0 0 '' closed)"
assert_eq 'invalid deploy state logs its release skip' \
  'release-decision issue=#910122 outcome=skipped gate=deploy-state object=state reason=not-pending-or-deployed' \
  "$(run_release_selection '[{"number":910122}]' 910122 '' 1 '' 1 910201 '' '' 10 '' '' 0 0 '' merged failed)"
assert_eq 'on-hold does not block release dispatch for merged code' \
  $'dispatch:release-batch:910103:candidate-sha\nrelease-decision issue=#910103 outcome=dispatched gate=release-batch object=zf-release-batch reason=sha=candidate-sha' \
  "$(run_release_selection '[{"number":910103}]' 910103 910103)"
assert_eq 'an unreadable ready-for-human label remains fail-closed' \
  'release-decision issue=#910104 outcome=skipped gate=ready-for-human-label object=label reason=label-unavailable' \
  "$(run_release_selection '[{"number":910104}]' 910104 '' 2)"
assert_eq 'ready-for-human label presence logs its release skip' \
  'release-decision issue=#910123 outcome=skipped gate=ready-for-human object=label reason=present' \
  "$(run_release_selection '[{"number":910123}]' 910123 '' 0)"
assert_eq 'released state remains a release-selection skip' \
  'release-decision issue=#910105 outcome=skipped gate=released object=state reason=already-released' \
  "$(run_release_selection '[{"number":910105}]' 910105 '' 1 910105)"
assert_eq 'deploy_is_blocked remains a release-selection skip' \
  'release-decision issue=#910106 outcome=skipped gate=deploy-blocked object=candidate-sha reason=exact-failed-sha' \
  "$(run_release_selection '[{"number":910106}]' 910106 '' 1 '' 0)"
RECHECK_DEPLOY_BLOCK_LINE="$(grep -nF -- '--recheck-deploy-block' "$PIPELINE_SRC" | cut -d: -f1)"
RELEASE_CANDIDATE_LIST_LINE="$(grep -nF 'gh issue list --repo "$REPO" --state open' "$PIPELINE_SRC" | tail -1 | cut -d: -f1)"
assert_cond 'infrastructure block recheck runs before release candidate selection' \
  "$([[ "${RECHECK_DEPLOY_BLOCK_LINE:-0}" -gt 0 && "${RECHECK_DEPLOY_BLOCK_LINE:-0}" -lt "${RELEASE_CANDIDATE_LIST_LINE:-0}" ]] && echo 1 || echo 0)"
PENDING_FLEET_SELECTION="$(run_release_selection '[{"number":910107}]' 910107 '' 1 '' 1 910107 910107)"
assert_eq 'fleet-roll-pending ticket remains eligible for its persisted rollout retry' \
  $'dispatch:release-batch:910107:candidate-sha\nrelease-decision issue=#910107 outcome=dispatched gate=fleet-roll object=zf-release-batch reason=retry-persisted-rollout\nselector-side-effects:none\npending-marker:pending' \
  "$PENDING_FLEET_SELECTION"
# Two pending rolls: the newer image carries the older change and the older pin is
# shadowed, so the newest roll anchors the batch (2026-10-22, #1145 behind #4061).
TWO_PENDING_FLEET_SELECTION="$(run_release_selection '[{"number":910107},{"number":910109}]' all '' 1 '' 1 910201 '910107 910109')"
assert_eq 'two pending fleet rolls anchor the newest image' \
  'dispatch:release-batch:910109:candidate-sha' "$(grep '^dispatch:' <<< "$TWO_PENDING_FLEET_SELECTION")"
assert_eq 'the newest pending roll records the persisted rollout retry' \
  'release-decision issue=#910109 outcome=dispatched gate=fleet-roll object=zf-release-batch reason=retry-persisted-rollout' \
  "$(grep '^release-decision issue=#910109 ' <<< "$TWO_PENDING_FLEET_SELECTION")"
assert_eq 'pending release makes no advisor, blocked-notification, or state-write attempt' \
  'selector-side-effects:none' "$(sed -n 's/^selector-side-effects:/selector-side-effects:/p' <<< "$PENDING_FLEET_SELECTION")"
assert_eq 'pending marker remains persisted for the next retry' \
  'pending-marker:pending' "$(sed -n 's/^pending-marker:/pending-marker:/p' <<< "$PENDING_FLEET_SELECTION")"
assert_eq 'awaiting-release without recorded PR evidence is skipped' \
  'release-decision issue=#910108 outcome=skipped gate=recorded-pr object=state reason=missing-or-invalid-pr-number' \
  "$(run_release_selection '[{"number":910108}]' '' '' 1 '' 1 910201 '' 910108)"
assert_eq 'a recorded PR merged into a feature branch is skipped' \
  'release-decision issue=#910111 outcome=skipped gate=recorded-pr object=#910201 reason=not-merged-to-main' \
  "$(run_release_selection '[{"number":910111}]' 910111 '' 1 '' 1 910201 '' '' 10 910111)"
assert_eq 'a merge commit absent from main is skipped' \
  'release-decision issue=#910112 outcome=skipped gate=main-ancestry object=#910201 reason=merge-not-ancestor-of-origin-main' \
  "$(run_release_selection '[{"number":910112}]' 910112 '' 1 '' 1 910201 '' '' 10 '' 910112)"
assert_eq 'one release capacity slot batches all eligible tickets at one SHA' \
  $'dispatch:release-batch:910109:candidate-sha\nrelease-decision issue=#910109 outcome=dispatched gate=release-batch object=zf-release-batch reason=sha=candidate-sha\nrelease-decision issue=#910110 outcome=batched gate=release-batch object=zf-release-batch reason=shared-sha=candidate-sha anchor=#910109' \
  "$(run_release_selection '[{"number":910110},{"number":910109}]' all '' 1 '' 1 910201 '' '' 1)"
assert_eq 'duplicate candidate IDs produce one decision per ticket per tick' \
  $'dispatch:release-batch:910113:candidate-sha\nrelease-decision issue=#910113 outcome=dispatched gate=release-batch object=zf-release-batch reason=sha=candidate-sha' \
  "$(run_release_selection '[{"number":910113},{"number":910113}]' 910113)"
assert_eq 'three awaiting tickets dispatch exactly one batch and get individual verdicts' \
  $'dispatch:release-batch:910131:candidate-sha\nrelease-decision issue=#910131 outcome=dispatched gate=release-batch object=zf-release-batch reason=sha=candidate-sha\nrelease-decision issue=#910132 outcome=batched gate=release-batch object=zf-release-batch reason=shared-sha=candidate-sha anchor=#910131\nrelease-decision issue=#910133 outcome=batched gate=release-batch object=zf-release-batch reason=shared-sha=candidate-sha anchor=#910131' \
  "$(run_release_selection '[{"number":910131},{"number":910132},{"number":910133}]' all '' 1 '' 1 910201 '' '' 1)"
assert_eq 'ticket merged after captured batch SHA waits for next batch' \
  $'release-decision issue=#910142 outcome=skipped gate=main-ancestry object=#910201 reason=merge-not-ancestor-of-origin-main\ndispatch:release-batch:910141:candidate-sha\nrelease-decision issue=#910141 outcome=dispatched gate=release-batch object=zf-release-batch reason=sha=candidate-sha' \
  "$(run_release_selection '[{"number":910141},{"number":910142}]' all '' 1 '' 1 910201 '' '' 1 '' 910142)"
assert_eq 'stage gate logs each eligible ticket it blocks' \
  $'release-decision issue=#910114 outcome=skipped gate=stage-dispatch object=release reason=quarantine-or-policy-block\nrelease-decision issue=#910115 outcome=skipped gate=stage-dispatch object=release reason=release-dispatch-blocked' \
  "$(run_release_selection '[{"number":910114},{"number":910115}]' all '' 1 '' 1 910201 '' '' 10 '' '' 1)"

CAPACITY_SCHEDULER_HOME="$(mktemp -d)"
CAPACITY_SCHEDULER_OUT="$(AGENT_HOME="$CAPACITY_SCHEDULER_HOME" bash -c '
  set -euo pipefail
  source "$1/lib.sh"
  mkdir -p "$AGENT_HOME/bin"
  printf "%s\n" "#!/usr/bin/env bash" "printf \"Filesystem 1K-blocks Used Available Use%% Mounted\\n/dev/fake %s 1 %s 1%% /\\n\" \"\${FAKE_CIHOST_TOTAL_KB:-1000000000}\" \"\${FAKE_CIHOST_AVAIL_KB:-125829120}\"" > "$AGENT_HOME/bin/ssh"
  chmod +x "$AGENT_HOME/bin/ssh"
  export PATH="$AGENT_HOME/bin:$PATH"
  export FAKE_CIHOST_AVAIL_KB=83886080
  quarantine_open release env:build-capacity "at least 60GiB free disk is required" 1 1700000000
  stage_dispatch_allowed release "[]" 1700000001 && echo dispatched || echo waiting
  export FAKE_CIHOST_AVAIL_KB=125829120
  reconcile_quarantines 1700000002
  stage_dispatch_allowed release "[]" 1700000003 && echo dispatched || echo waiting
' _ "$SCRIPT_DIR" 2>/dev/null)"
rm -rf "$CAPACITY_SCHEDULER_HOME"
assert_eq "an open build-capacity episode prevents another release/build dispatch and resumes after the capacity probe passes" \
  $'waiting\ndispatched' "$CAPACITY_SCHEDULER_OUT"

assert_eq 'memory gate logs each eligible ticket it blocks' \
  $'release-decision issue=#910116 outcome=skipped gate=memory-floor object=release reason=minimum-memory-unavailable\nrelease-decision issue=#910117 outcome=skipped gate=memory-floor object=release reason=release-dispatch-blocked' \
  "$(run_release_selection '[{"number":910116},{"number":910117}]' all '' 1 '' 1 910201 '' '' 10 '' '' 0 1)"
assert_eq 'active release unit is logged as a per-ticket skip' \
  'release-decision issue=#910118 outcome=skipped gate=active-unit object=zf-release-batch reason=already-running' \
  "$(run_release_selection '[{"number":910118}]' 910118 '' 1 '' 1 910201 '' '' 10 '' '' 0 0 910118)"
assert_eq 'zero release capacity logs each unique pending ticket' \
  $'release-decision issue=#910119 outcome=skipped gate=capacity object=RELEASE_CAP reason=slots-exhausted\nrelease-decision issue=#910120 outcome=skipped gate=capacity object=RELEASE_CAP reason=slots-exhausted' \
  "$(run_release_selection '[{"number":910119},{"number":910120}]' all '' 1 '' 1 910201 '' '' 0)"
assert_eq 'zero release capacity does not turn a stale awaiting-release label into pending work' \
  'release-decision issue=#910102 outcome=skipped gate=release-state object=state reason=not-awaiting-release' \
  "$(run_release_selection '[{"number":910102}]' '' '' 1 '' 1 910201 '' '' 0)"

# ---- factory f3 (#4358): ticket releases batch on a 2h cadence -------------
RELEASE_CADENCE_FILE="$ISSUE_PIPELINE_TEST_AGENT_HOME/release-batch-last-dispatch"
RELEASE_CADENCE_TEST_NOW=1800000000
printf '%s\n' "$(( RELEASE_CADENCE_TEST_NOW - 7199 ))" > "$RELEASE_CADENCE_FILE"
assert_eq 'tickets merged inside one window trigger no second release' \
  $'release-decision issue=#910151 outcome=skipped gate=release-cadence object=zf-release-batch reason=window-not-elapsed\nrelease-decision issue=#910152 outcome=skipped gate=release-cadence object=zf-release-batch reason=window-not-elapsed' \
  "$(run_release_selection '[{"number":910151},{"number":910152}]' all)"
printf '%s\n' "$(( RELEASE_CADENCE_TEST_NOW - 7200 ))" > "$RELEASE_CADENCE_FILE"
assert_eq 'an elapsed window dispatches the whole batch once' \
  $'dispatch:release-batch:910151:candidate-sha\nrelease-decision issue=#910151 outcome=dispatched gate=release-batch object=zf-release-batch reason=sha=candidate-sha\nrelease-decision issue=#910152 outcome=batched gate=release-batch object=zf-release-batch reason=shared-sha=candidate-sha anchor=#910151' \
  "$(run_release_selection '[{"number":910151},{"number":910152}]' all)"
unset RELEASE_CADENCE_TEST_NOW
printf '%s\n' "$(date +%s)" > "$RELEASE_CADENCE_FILE"
assert_eq 'a persisted fleet roll resumes without waiting for a window' \
  $'dispatch:release-batch:910107:candidate-sha\nrelease-decision issue=#910107 outcome=dispatched gate=fleet-roll object=zf-release-batch reason=retry-persisted-rollout\nselector-side-effects:none\npending-marker:pending' \
  "$(run_release_selection '[{"number":910107}]' 910107 '' 1 '' 1 910107 910107)"
rm -f "$RELEASE_CADENCE_FILE"

RELEASE_LOOP_BODY="$(sed -n '/^while IFS= read -r n; do$/,/^done <<< "\$release_issue_numbers"$/p' "$PIPELINE_SRC")"
if printf '%s\n' "$RELEASE_LOOP_BODY" | awk '
  { lines[NR] = $0 }
  /continue$/ {
    if ($0 ~ /=~.*continue$/ || $0 ~ /release_issue_seen.*continue$/) next
    found = 0
    for (i = NR - 1; i > 0 && i >= NR - 8; i--) {
      if (lines[i] ~ /record_release_decision/) found = 1
    }
    if (!found) { print "unrecorded release continue at loop line " NR; failed = 1 }
  }
  /^[[:space:]]*break$/ { print "unrecorded release break at loop line " NR; failed = 1 }
  END { exit failed }
'; then
  echo 'ok - each unique release candidate skip records one reason before continuing'
else
  echo 'not ok - a release candidate can still be skipped without a decision line'
  FAILED=1
fi

assert_cond "triage-only ticks emit their timing and label-read profile" "$(awk '
  /^if \[ "\$PIPELINE_STAGE" = implement \]; then$/ { inside=1; next }
  inside && /^fi$/ { inside=0 }
  inside && /profile_finish/ { found=1 }
  END { print found ? 1 : 0 }
' "$PIPELINE_SRC")"
assert_cond "implement-only ticks emit their timing and label-read profile" "$(awk '
  /^if \[ "\$MODE" != "release" \]; then$/ { inside=1; next }
  inside && /^fi$/ { inside=0 }
  inside && /profile_finish/ { found=1 }
  END { print found ? 1 : 0 }
' "$PIPELINE_SRC")"

TRIAGE_MAINTENANCE_ORDER="$(awk '
  /^if \[ "\$PIPELINE_STAGE" = implement \]; then$/ { mode=NR }
  mode && /^[[:space:]]*run_post_dispatch_maintenance$/ { call=NR }
  mode && /^[[:space:]]*profile_finish$/ { finish=NR }
  END { print (mode && call && finish && mode < call && call < finish) ? 1 : 0 }
' "$PIPELINE_SRC")"
assert_cond "the implement stage runs maintenance after its intake dispatch" "$TRIAGE_MAINTENANCE_ORDER"
assert_contains "release and maintenance own separate bounded slices" "$(cat "$SCRIPT_DIR/issue-pipeline-slices.sh")" "recut release maintenance"

# --- static: each issue unit dispatch uses persisted policy state -----------
if grep -q 'codex_implement_model_for_level "\$(state_read "\$n"' "$PIPELINE_SRC"; then
  echo "not ok - issue-pipeline.sh bypasses the policy dispatcher"
  FAILED=1
else
  echo "ok - issue-pipeline.sh no longer calls codex_implement_model_for_level() directly"
fi

BUDGET_DISPATCH_OUT="$(
  eval "$(sed -n '/^dispatch_policy_unit() {/,/^}/p' "$PIPELINE_SRC")"
  eval "$(sed -n '/^record_implement_decision() {/,/^}/p' "$PIPELINE_SRC")"
  IMPLEMENT_TICK_ID=budget-test
  declare -A IMPLEMENT_GATE_COUNTS=() IMPLEMENT_GATE_OBJECT_COUNTS=()
  IMPLEMENT_TOP_OBJECT_COUNT=0
  state_read() { [ -f "$(state_file "$1")" ] && cat "$(state_file "$1")" || echo '{"attempts":0}'; }
  model_policy_begin_unit() { :; }
  model_policy() {
    case "${1:-}:${2:-}" in
      initial-step:) echo work ;;
      step-role:work) echo work ;;
      identity:work) echo "$MODEL_POLICY_TEST_WORK_IDENTITY" ;;
      dispatch-identity:work) echo "$MODEL_POLICY_TEST_WORK_IDENTITY" ;;
      *) return 1 ;;
    esac
  }
  issue_model_failure_backoff_remaining() { echo 0; }
  agent_implement_dispatch_resources_allow() { return 0; }
  recover_stale_policy_unit() { return 1; }
  pipeline_claim_begin() { PIPELINE_CLAIM_KEY="issue:$1"; PIPELINE_CLAIM_STAGE="$2"; PIPELINE_CLAIM_UNIT="$3"; PIPELINE_CLAIM_OWNER=budget-fixture; }
  coord_assert_owned() { return 0; }
  pipeline_claim_drop() { :; }
  model_config_fault_blocked() { return 1; }
  codex_probe_ok() { return 0; }
  codex_provider_recovery_probe_if_due() { return 0; }
  codex_quota_exhausted() { return 1; }
  dispatch() {
    [ "$#" -eq 2 ] || { echo "unexpected-dispatch-args:$*" >&2; return 42; }
    BUDGET_DISPATCH_COUNT=$((BUDGET_DISPATCH_COUNT + 1))
  }
  issue_spend_budget_status() {
    case "$1" in
      991301|991303) printf 'over\t10\t2200000\n' ;;
      *) printf 'clear\t0\t0\n' ;;
    esac
  }
  recut_categorically_oversized() { return 1; }
  BUDGET_HOME="$AGENT_HOME/budget-route"
  AGENT_HOME="$BUDGET_HOME"
  STATE_DIR="$BUDGET_HOME/state"
  mkdir -p "$STATE_DIR"
  state_merge 991301 '.risk_class = "P2" | .level = "L2" | .state = "ready-for-agent"'
  state_merge 991303 'now as $now | .risk_class = "P2" | .level = "L2" | .state = "ready-for-agent" | .issue_spend_budget = {routed_at:($now - 3600 | todate),window_end:($now + 82800 | todate),calls:10,tokens:2200000,repeat_count:0}'
  ROUTE_WRITES="$BUDGET_HOME/routes.log"
  BUDGET_COMMENT_PRESENT=0
  PRIOR_SPEND_COMMENT_COUNT=0
  guarded_write() {
    printf '%s\n' "$*" >> "$ROUTE_WRITES"
    if [ "${2:-}" = issue ] && [ "${3:-}" = comment ] && [ -f "${8:-}" ]; then
      if [ "${4:-}" = 991301 ] && grep -Fq -- "$ISSUE_SPEND_BUDGET_MARKER" "${8:-}"; then
        BUDGET_COMMENT_PRESENT=1
      elif [ "${4:-}" = 991303 ] && grep -Fq -- "$ISSUE_SPEND_BUDGET_MARKER" "${8:-}"; then
        PRIOR_SPEND_COMMENT_COUNT=$((PRIOR_SPEND_COMMENT_COUNT + 1))
      fi
    fi
    if [[ " $* " == *' --add-label on-hold '* ]]; then
      issue_label_cache_invalidate
    fi
  }
  gh() {
    if [ "${1:-}" = issue ] && [ "${2:-}" = view ]; then
      local number="${3:-}" label='{"name":"ready-for-agent"}' comments='[]'
      case "$number" in
        991301|991303)
          if jq -e '.state == "on-hold"' "$(state_file "$number")" >/dev/null 2>&1; then
            label='{"name":"on-hold"}'
          fi
          ;;
      esac
      if [ "$number" = 991301 ] && [ "$BUDGET_COMMENT_PRESENT" = 1 ]; then
        comments="$(jq -cn --arg marker "$ISSUE_SPEND_BUDGET_MARKER" '[{body:$marker}]')"
      fi
      printf '{"state":"OPEN","labels":[%s],"comments":%s}\n' "$label" "$comments"
    elif [ "${1:-}" = issue ] && [ "${2:-}" = list ]; then
      for number in 991301 991303; do
        if jq -e '.state == "on-hold"' "$(state_file "$number")" >/dev/null 2>&1; then
          printf '%s\n' "$number"
        fi
      done
    else
      return 64
    fi
  }
  issue_label_cache_invalidate
  BUDGET_DISPATCH_COUNT=0
  first_status=0; dispatch_policy_unit implement 991301 ready-for-agent 1 || first_status=$?
  second_status=0; dispatch_policy_unit implement 991301 ready-for-agent 1 || second_status=$?
  label_writes="$(grep -c 'gh issue edit' "$ROUTE_WRITES" || true)"
  comment_writes="$(grep -c 'gh issue comment' "$ROUTE_WRITES" || true)"
  normal_status=0; dispatch_policy_unit implement 991302 ready-for-agent 1 || normal_status=$?
  recut_status=0; dispatch_policy_unit recut 991301 needs-recut || recut_status=$?
  prior_status=0; dispatch_policy_unit implement 991303 ready-for-agent 1 || prior_status=$?
  prior_state="$(state_read 991303)"
  prior_comments="$(grep -c 'gh issue comment 991303' "$ROUTE_WRITES" || true)"
  printf 'OVER=%s,%s ROUTES=%s,%s NORMAL=%s RECUT=%s DISPATCHES=%s PRIOR=%s PRIOR_HOLD=%s PRIOR_WINDOW_MATCH=%s PRIOR_COMMENTS=%s PRIOR_SPEND_COMMENTS=%s PRIOR_GATE=%s PRIOR_OBJECT_MATCH=%s\n' \
    "$first_status" "$second_status" "$label_writes" "$comment_writes" "$normal_status" "$recut_status" "$BUDGET_DISPATCH_COUNT" \
    "$prior_status" "$(jq -r '.hold.kind // empty' <<< "$prior_state")" \
    "$(jq -r '.issue_spend_budget.window_end == .hold.expires_at' <<< "$prior_state")" "$prior_comments" \
    "$PRIOR_SPEND_COMMENT_COUNT" "$(jq -r '.implement_tick_decision.gate // empty' <<< "$prior_state")" \
    "$(jq -r '.implement_tick_decision.object == .issue_spend_budget.window_end' <<< "$prior_state")"
)"
# The budget route sends an oversized ticket to recut; the recut itself must
# still dispatch (issues 1983 and 1703 sat in needs-recut until the window rolled).
assert_contains "over-budget ticket does not dispatch and routes once; normal ticket and the over-budget recut still dispatch" \
  "$BUDGET_DISPATCH_OUT" 'OVER=80,80 ROUTES=1,2 NORMAL=0 RECUT=0 DISPATCHES=2'
assert_contains "prior in-window budget route archives durable hold metadata without repeating budget comment" \
  "$BUDGET_DISPATCH_OUT" 'PRIOR=80 PRIOR_HOLD=spend-budget PRIOR_WINDOW_MATCH=true PRIOR_COMMENTS=1 PRIOR_SPEND_COMMENTS=0'
assert_contains "budget skip records spend-budget gate and its window end" \
  "$BUDGET_DISPATCH_OUT" 'PRIOR_GATE=spend-budget PRIOR_OBJECT_MATCH=true'

# The gate itself routes a two-strike pair and refuses the dispatch: run the
# real lib.sh gate over a fixture issue with the route functions faked, the
# same shape the other lib gate fixtures use.
TWO_STRIKE_FN_HOME="$(mktemp -d)"
mkdir -p "$TWO_STRIKE_FN_HOME/state"
jq -cn '{attempts: 3, model_policy: {failures: [
  {unit: "implement", step: "work", stage: "implement-gates", reason: "scope conflict outside the declared blast radius", normalized_reason: "scope conflict outside the declared blast radius", status: 1, recorded_at: "2026-10-08T00:00:00Z"},
  {unit: "implement", step: "work", stage: "implement-gates", reason: "scope conflict outside the declared blast radius", normalized_reason: "scope conflict outside the declared blast radius", status: 1, recorded_at: "2026-10-08T01:00:00Z"}
]}}' > "$TWO_STRIKE_FN_HOME/state/910777.json"
TWO_STRIKE_FN_OUT="$(AGENT_HOME="$TWO_STRIKE_FN_HOME" bash -c '
  source "$1/lib.sh"
  gh() {
    if [[ "${1:-} ${2:-}" == "pr list" ]]; then
      echo "[]"
      return 0
    fi
    return 1
  }
  route_to_recut() { echo "ROUTED-RECUT $1"; return 0; }
  route_to_advisor() { echo "ROUTED-ADVISOR $1"; return 0; }
  guarded_issue_comment() { echo "COMMENTED"; return 0; }
  if enforce_implement_two_strike 910777; then
    echo "DISPATCH=NO third full attempt prevented"
  else
    echo "DISPATCH=YES gate fell through"
  fi
' _ "$SCRIPT_DIR" 2>/dev/null)"
rm -rf -- "$TWO_STRIKE_FN_HOME"
assert_contains "two identical failures at one step prevent the third dispatch" \
  "$TWO_STRIKE_FN_OUT" "DISPATCH=NO"
assert_contains "the prevented ticket is routed to recut, not parked silently" \
  "$TWO_STRIKE_FN_OUT" "ROUTED-RECUT 910777"
assert_contains "the routing posts the issue comment naming both failures" \
  "$TWO_STRIKE_FN_OUT" "COMMENTED"
# 2026-10-08 (hand-node-env-proxy): every systemd-run dispatch site must
# import uppercase NO_PROXY (Node's proxy resolution reads it) and the
# NODE_USE_ENV_PROXY opt-in defaulted to 1 at the top of issue-pipeline.sh.
# Without the opt-in an implement unit's node fetch ignored the imported
# proxy vars and died on raw.githubusercontent.com (issue 2695, run 3).
ENV_PROXY_FAKE_BIN="$(mktemp -d)"
cat > "$ENV_PROXY_FAKE_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
# "no" (exit 3) makes each dispatch reach its systemd-run instead of returning early.
exit 3
EOF
chmod +x "$ENV_PROXY_FAKE_BIN/systemctl"
ENV_PROXY_CAPTURE="$AGENT_HOME/env-proxy-systemd-run.log"
: > "$ENV_PROXY_CAPTURE"
eval "$(sed -n '/^dispatch() {/,/^}/p; /^dispatch_advisor_batch() {/,/^}/p' "$PIPELINE_SRC")"
run_env_proxy_site() (
  PATH="$ENV_PROXY_FAKE_BIN:$PATH"
  RELEASE_RUNTIME_MAX_SEC=3600
  ADVISOR_RUNTIME_MAX_SEC=3600
  agent_memory_floor_allows() { return 0; }
  record_env_fault() { :; }
  guarded_write() { printf '%s\n' "$*" >> "$ENV_PROXY_CAPTURE"; }
  "$@"
)
assert_eq "all four issue-pipeline systemd-run sites carry NO_PROXY and the Node env-proxy opt-in" 4 \
  "$(grep -c -- '-E PATH -E https_proxy -E HTTPS_PROXY -E http_proxy -E HTTP_PROXY -E no_proxy -E NO_PROXY -E NODE_USE_ENV_PROXY' "$PIPELINE_SRC")"
assert_contains "issue-pipeline defaults the Node env-proxy opt-in before any dispatch" "$(cat "$PIPELINE_SRC")" \
  'export NODE_USE_ENV_PROXY="${NODE_USE_ENV_PROXY:-1}"'
# 2026-10-09: with triage paused, nothing refreshed the GitNexus index that
# hand agents query; the pipeline launches one refresh unit when it is stale.
eval "$(sed -n '/^dispatch_gitnexus_refresh() {/,/^}/p' "$PIPELINE_SRC")"
GITNEXUS_REFRESH_CAPTURE="$AGENT_HOME/gitnexus-refresh-systemd-run.log"
run_gitnexus_refresh_site() (
  PATH="$ENV_PROXY_FAKE_BIN:$PATH"
  local index_status="$1"
  gitnexus_index_matches_origin_main() { return "$index_status"; }
  record_env_fault() { :; }
  guarded_write() { printf '%s\n' "$*" >> "$GITNEXUS_REFRESH_CAPTURE"; }
  dispatch_gitnexus_refresh
)
: > "$GITNEXUS_REFRESH_CAPTURE"
run_gitnexus_refresh_site 1
assert_contains "a stale GitNexus index gets one refresh unit" "$(cat "$GITNEXUS_REFRESH_CAPTURE")" \
  "--unit zf-gitnexus-refresh"
assert_contains "the refresh unit goes through the shared locked helper" "$(cat "$GITNEXUS_REFRESH_CAPTURE")" \
  "gitnexus_refresh_index_once"
: > "$GITNEXUS_REFRESH_CAPTURE"
run_gitnexus_refresh_site 0
assert_eq "a fresh GitNexus index launches no refresh unit" "" "$(cat "$GITNEXUS_REFRESH_CAPTURE")"
rm -rf "$ENV_PROXY_FAKE_BIN"


# Reconciliation and lane routing share the same merged state. An open
# pipeline-system issue with a merged PR must stay release-gated across ticks:
# keep the one merge comment, and never put it back in the implement query.
MERGED_REOPEN_HOME="$(mktemp -d)"
run_merged_reopen_regression() (
  set -euo pipefail
  AGENT_HOME="$MERGED_REOPEN_HOME"
  source "$SCRIPT_DIR/lib.sh"
  roadmap_ensure_issue_parent() { return 0; }
  eval "$ROUTE_PIPELINE_SYSTEM_CANDIDATES_FN"
  REPO=test/repo
  REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
  PIPELINE_SYSTEM_LABELS_JSON='["pipeline-system"]'
  FAKE_ISSUE=991050
  FAKE_PR=991051
  FAKE_LABELS_FILE="$MERGED_REOPEN_HOME/labels"
  FAKE_LABELS="pipeline-system ready-for-agent"
  printf '%s\n' "$FAKE_LABELS" > "$FAKE_LABELS_FILE"
  FAKE_COMMENTS_JSON="[[]]"
  FAKE_COMMENT_WRITES=0
  FAKE_DISPATCHES=0
  FAKE_TRANSITIONS=0
  FAKE_OUTCOME_RECONCILIATIONS=0
  MERGE_SHA="$(git -C "$REPO_DIR" rev-parse HEAD)"
  fake_issue_json() {
    FAKE_LABELS="$(cat "$FAKE_LABELS_FILE")"
    jq -cn --argjson n "$FAKE_ISSUE" --arg labels "$FAKE_LABELS" \
      '{number:$n,labels:($labels | split(" ") | map(select(length > 0) | {name:.}))}'
  }
  is_on_hold() { return 1; }
  stage_unit_active() { return 1; }
  recut_parent_has_open_child() { return 1; }
  ensure_state_labels() { :; }
  merged_pr_main_row() { printf "%s\t%s\n" "$FAKE_PR" "$MERGE_SHA"; }
  issue_closure_evidence_valid() { return 1; }
  web_advisor_provider_clear_job_state() { return 0; }
  gh() {
    local args=" $* "
    if [[ "$args" == *" api "* && "$args" == *"/comments?"* ]]; then
      printf "%s\n" "$FAKE_COMMENTS_JSON"
    elif [[ "$args" == *" issue view "* ]]; then
      fake_issue_json
    elif [[ "$args" == *" issue list "* && "$args" == *"--label ready-for-agent"* ]]; then
      FAKE_LABELS="$(cat "$FAKE_LABELS_FILE")"
      if [[ " $FAKE_LABELS " == *" ready-for-agent "* ]]; then
        jq -cn --argjson n "$FAKE_ISSUE" '[{number:$n}]'
      else
        echo '[]'
      fi
    else
      return 2
    fi
  }
  guarded_write() {
    local -a args=("$@")
    local i body_file=""
    if [[ "${args[0]:-} ${args[1]:-} ${args[2]:-}" == "gh issue edit" ]]; then
      FAKE_LABELS="$(cat "$FAKE_LABELS_FILE")"
      for ((i = 0; i < ${#args[@]}; i++)); do
        case "${args[$i]}" in
          --add-label)
            if [[ " $FAKE_LABELS " != *" ${args[$((i + 1))]} "* ]]; then
              FAKE_LABELS="${FAKE_LABELS:+$FAKE_LABELS }${args[$((i + 1))]}"
            fi
            ;;
          --remove-label)
            FAKE_LABELS="$(jq -nr --arg labels "$FAKE_LABELS" --arg remove "${args[$((i + 1))]}" \
              '$labels | split(" ") | map(select(. != $remove)) | join(" ")')"
            ;;
        esac
      done
      printf '%s\n' "$FAKE_LABELS" > "$FAKE_LABELS_FILE"
    elif [[ "${args[0]:-} ${args[1]:-} ${args[2]:-}" == "gh issue comment" ]]; then
      for ((i = 0; i < ${#args[@]}; i++)); do
        [[ "${args[$i]}" == --body-file ]] && body_file="${args[$((i + 1))]}"
      done
      FAKE_COMMENTS_JSON="$(jq -cn --argjson previous "$FAKE_COMMENTS_JSON" --rawfile body "$body_file" \
        '$previous + [[{body:$body}]]')"
      FAKE_COMMENT_WRITES=$((FAKE_COMMENT_WRITES + 1))
    fi
  }
  dispatch_implement_work() { FAKE_DISPATCHES=$((FAKE_DISPATCHES + 1)); }
  state_merge "$FAKE_ISSUE" "$(jq -cn --arg sha "$MERGE_SHA" --argjson pr "$FAKE_PR" \
    '{pipeline_system:{enabled:true},state:"ready-for-agent",run:{evidence:{pr_number:$pr,pr_head_sha:$sha,mandatory_checks:{status:"passed",head_sha:$sha}}}}')"
  previous_route_snapshot="$(jq -cn --arg state ready-for-agent --arg labels "$FAKE_LABELS" \
    '{state:$state,labels:($labels | split(" ") | sort)}')"
  for tick in 1 2; do
    FAKE_LABELS="$(cat "$FAKE_LABELS_FILE")"
    conclude_merged_run "$FAKE_ISSUE" "$FAKE_PR" "PR #$FAKE_PR auto-merged (squash). Waiting on Postsubmit validate before release." >/dev/null 2>&1
    FAKE_OUTCOME_RECONCILIATIONS=$((FAKE_OUTCOME_RECONCILIATIONS + 1))
    FAKE_LABELS="$(cat "$FAKE_LABELS_FILE")"
    ready_candidates="$(gh issue list --repo "$REPO" --state open --label ready-for-agent --json number)"
    while IFS= read -r candidate; do
      [ -n "$candidate" ] && dispatch_implement_work "$candidate"
    done < <(jq -r '.[].number' <<< "$ready_candidates")
    tick_state="$(state_read "$FAKE_ISSUE" | jq -r .state)"
    route_snapshot="$(jq -cn --arg state "$tick_state" --arg labels "$FAKE_LABELS" \
      '{state:$state,labels:($labels | split(" ") | sort)}')"
    if [ "$route_snapshot" != "$previous_route_snapshot" ]; then
      FAKE_TRANSITIONS=$((FAKE_TRANSITIONS + 1))
    fi
    previous_route_snapshot="$route_snapshot"
    printf "tick=%s state=%s labels=%s transitions=%s outcomes=%s comments=%s comment-writes=%s dispatches=%s\n" \
      "$tick" "$(state_read "$FAKE_ISSUE" | jq -r .state)" "$FAKE_LABELS" \
      "$FAKE_TRANSITIONS" "$FAKE_OUTCOME_RECONCILIATIONS" \
      "$(jq '[flatten[]?] | length' <<< "$FAKE_COMMENTS_JSON")" \
      "$FAKE_COMMENT_WRITES" "$FAKE_DISPATCHES"
  done
  FAKE_COMMENTS_JSON="$(jq -cn --arg body "$BOT_DISCLAIMER
这张票的实现已合并，正在等待生产部署及同一次真实用户路径的 URL、可见 DOM 和网络交换证据。PR #$FAKE_PR auto-merged (squash). Waiting on Postsubmit validate before release." '[[{body:$body}]]')"
  prior_comment_writes="$FAKE_COMMENT_WRITES"
  conclude_merged_run "$FAKE_ISSUE" "$FAKE_PR" "PR #$FAKE_PR auto-merged (squash). Waiting on Postsubmit validate before release." >/dev/null 2>&1
  printf "legacy-comment-writes=%s comments=%s\n" "$((FAKE_COMMENT_WRITES - prior_comment_writes))" \
    "$(jq '[flatten[]?] | length' <<< "$FAKE_COMMENTS_JSON")"
  FAKE_COMMENTS_JSON="$(jq -cn --arg body "$BOT_DISCLAIMER
这张票的实现已合并，正在等待生产部署及同一次真实用户路径的 URL、可见 DOM 和网络交换证据。PR #$((FAKE_PR - 1)) auto-merged (squash)." '[[{body:$body}]]')"
  prior_comment_writes="$FAKE_COMMENT_WRITES"
  conclude_merged_run "$FAKE_ISSUE" "$FAKE_PR" "PR #$FAKE_PR auto-merged (squash). Waiting on Postsubmit validate before release." >/dev/null 2>&1
  printf "different-pr-comment-writes=%s comments=%s\n" "$((FAKE_COMMENT_WRITES - prior_comment_writes))" \
    "$(jq '[flatten[]?] | length' <<< "$FAKE_COMMENTS_JSON")"
)
MERGED_REOPEN_OUT="$(run_merged_reopen_regression 2>&1)"
assert_contains "merged reopened issue stays release-gated on tick one with one comment and no implement dispatch" \
  "$MERGED_REOPEN_OUT" 'tick=1 state=awaiting-release labels=pipeline-system awaiting-release transitions=1 outcomes=1 comments=1 comment-writes=1 dispatches=0'
assert_contains "merged issue has no state-label transition after tick one" \
  "$MERGED_REOPEN_OUT" 'tick=2 state=awaiting-release labels=pipeline-system awaiting-release transitions=1 outcomes=2 comments=1 comment-writes=1 dispatches=0'
assert_contains "reconciliation recognizes the existing legacy comment and does not add another" \
  "$MERGED_REOPEN_OUT" 'legacy-comment-writes=0 comments=1'
assert_contains "a different merged PR gets its own waiting-release comment" \
  "$MERGED_REOPEN_OUT" 'different-pr-comment-writes=1 comments=2'
rm -rf "$MERGED_REOPEN_HOME"
if [ "$FAILED" -eq 0 ]; then
  echo "ALL PASSED"
else
  echo "FAILURES"
  exit 1
fi
