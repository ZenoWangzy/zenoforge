#!/usr/bin/env bash
# Invoke on the existing WSL controller (SSH or the WSL workspace bridge).
# This adapter owns request identity only; existing executors own all gates.
set -euo pipefail
usage() {
  echo 'Usage: delivery-request.sh ID land BRANCH SHA OWNER | ID merge ISSUE PR SHA | ID release ISSUE SHA | ID status' >&2
  exit 64
}
(($# >= 2)) || usage
id="$1" action="$2"; shift 2
[[ "$id" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$ ]] || usage
case "$action" in
  land) (($# == 3)) || usage; git check-ref-format "refs/heads/$1" >/dev/null || usage
    [[ "$1" != main && "$2" =~ ^[0-9a-f]{40}$ && "$3" =~ ^[a-zA-Z0-9_.-]+$ ]] || usage ;;
  merge) (($# == 3)) || usage
    [[ "$1" =~ ^[1-9][0-9]*$ && "$2" =~ ^[1-9][0-9]*$ && "$3" =~ ^[0-9a-f]{40}$ ]] || usage ;;
  release) (($# == 2)) || usage
    [[ "$1" =~ ^[1-9][0-9]*$ && "$2" =~ ^[0-9a-f]{40}$ ]] || usage ;;
  status) (($# == 0)) || usage ;;
  *) usage ;;
esac
if [[ "${ZF_AGENT_TEST_MODE:-0}" != 1 ]]; then
  [[ -r /proc/sys/kernel/osrelease ]] && grep -qi microsoft /proc/sys/kernel/osrelease || {
    echo 'delivery-request: invoke this entry on the WSL controller; clients submit through SSH or the WSL bridge' >&2
    exit 78
  }
fi
AGENT_HOME="${AGENT_HOME:-${HOME:?}/.zenoforge}"
runtime="$AGENT_HOME/checkout"
[[ -r "$runtime/engine/lib.sh" ]] || { echo 'delivery-request: controller runtime is unavailable' >&2; exit 78; }
source "$runtime/engine/lib.sh"
agent_pipeline_write_guard delivery-request "$AGENT_HOME/delivery-requests" || exit 1
root="$AGENT_HOME/delivery-requests"
record="$root/$id.json"
if [[ "$action" == status ]]; then
  [[ -f "$record" ]] || { echo 'delivery-request: unknown request' >&2; exit 66; }
  cat "$record"
  exit 0
fi
mkdir -p -- "$root"
exec {request_fd}>"$root/$id.lock"
flock -n "$request_fd" || exit 75
args="$(jq -cn --args '$ARGS.positional' -- "$@")"
if [[ -e "$record" ]]; then
  jq -e --arg action "$action" --argjson args "$args" '.action == $action and .args == $args' "$record" >/dev/null || {
    echo 'delivery-request: ID already belongs to different arguments; refusing identity reuse' >&2; exit 65;
  }
  if jq -e '.status == "accepted"' "$record" >/dev/null; then cat "$record"; exit 0; fi
fi
save() {
  local tmp
  tmp="$(mktemp "$root/.$id.XXXXXX")"
  jq -n --arg id "$id" --arg action "$action" --argjson args "$args" \
    --arg status "$1" --arg result "${2:-}" \
    '{id:$id,action:$action,args:$args,status:$status,result:$result,updated_at:(now|todate)}' > "$tmp"
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$record"
}
save pending
case "$action" in
  land)
    branch="$1" sha="$2" owner="$3"
    worktree="$root/worktrees/$id"
    # Recover the enqueue/ack crash window from the existing queue itself.
    ticket=""
    for queued in "$AGENT_HOME"/land-queue/requests/*.json; do
      [[ -f "$queued" ]] || continue
      if jq -e --arg path "$worktree" '.worktree == $path' "$queued" >/dev/null; then
        ticket="$(jq -r .ticket "$queued")"; break
      fi
    done
    if [[ -n "$ticket" ]]; then
      result="LANDING-QUEUED $ticket $sha"
    else
      if [[ ! -e "$worktree" ]]; then
        ref="refs/zf-delivery/$id"
        # Fetch a named topic, never a client-supplied path or remote URL.
        timeout --kill-after=5s 60s git -C "$runtime" fetch --no-tags origin "refs/heads/$branch:$ref"
        [[ "$(git -C "$runtime" rev-parse "$ref")" == "$sha" ]] || {
          echo 'delivery-request: published branch advanced; submit its new SHA under a new ID' >&2; exit 65;
        }
        mkdir -p -- "$root/worktrees"
        git -C "$runtime" worktree add -b "codex/delivery-$id" "$worktree" "$sha"
      fi
      [[ "$(git -C "$worktree" rev-parse HEAD)" == "$sha" ]] || {
        echo 'delivery-request: retained worktree differs from the request' >&2; exit 65;
      }
      report="$root/$id.report.md"
      [[ -e "$report" ]] || (umask 077; printf 'STATUS: READY\n' > "$report")
      result="$(cd -- "$worktree" && ZF_REPO_DIR="$worktree" ZF_AGENT_NAME="$owner" ZF_AGENT_REPORT="$report" \
        bash "$runtime/engine/land-direct-main.sh" --enqueue)"
    fi
    ;;
  merge)
    # Unattended mode retains exact-head review, CI, migration and hold gates.
    # A pending prerequisite returns to the existing scheduler; no model polling.
    mkdir -p -- "$LOG_DIR"
    MERGE_LOCK_WAIT_SECONDS=0
    row="$(pr_merge_delivery_row "$2")" || exit 1
    IFS=$'\t' read -r pr_state pr_head merged_sha <<< "$row"
    [[ "$pr_head" == "$3" ]] || { echo 'delivery-request: PR head changed' >&2; exit 65; }
    if [[ "$pr_state" == MERGED ]]; then
      [[ "$merged_sha" =~ ^[0-9a-f]{40}$ ]] || exit 1
      conclude_merged_run "$1" "$2" || exit 1
      result="MERGED PR=$2 HEAD=$3"
    elif merge_agent_pr "$1" "$2" "$3" 1 0 "$LOG_DIR/delivery-$id.log"; then
      conclude_merged_run "$1" "$2" || exit 1
      result="MERGED PR=$2 HEAD=$3"
    else
      save pending "${MERGE_GATE_FAILURE_KIND:-merge}:${MERGE_GATE_FAILURE_REASON:-deferred}"
      cat "$record"
      exit 75
    fi
    ;;
  release)
    N="$1" MERGE_SHA="" RELEASE_BATCH_SHA="$2"
    issue_state="$(state_read "$N")"
    jq -e '.state == "awaiting-release" and (.released // false) == false' <<< "$issue_state" >/dev/null || {
      echo 'delivery-request: issue is not awaiting release' >&2; exit 65;
    }
    row="$(merged_pr_for_issue "$N")" || exit 1
    MERGE_SHA="${row#*$'\t'}"
    git_fetch_bounded "$REPO_DIR" main || exit 1
    DEPLOY_HOST=cihost DEPLOY_DIR=/srv/app
    # Deployment records are the shared production baseline. A missing record is unavailable, not a prompt to read host-local state.
    deployment_records="$(bash "$runtime/engine/production-deployment-read.sh" "$REPO")" || exit 75
    OLD_DEPLOYED_SHA="$(jq -r '.[0].sha // empty' <<< "$deployment_records")" || exit 75
    [[ -n "$OLD_DEPLOYED_SHA" ]] || {
      echo 'delivery-request: production baseline is unavailable; no successful Deployment record exists' >&2
      exit 78
    }
    [[ "$OLD_DEPLOYED_SHA" =~ ^[0-9a-f]{40}$ ]] || {
      echo 'delivery-request: production baseline is invalid; refusing candidate binding' >&2; exit 65;
    }
    source "$runtime/engine/release-candidate.sh"
    release_candidate_bind || exit $?
    # An existing release owns its candidate. A new request cannot advance it.
    [[ "$RELEASE_BATCH_SHA" == "$2" || "$(state_read "$N" | jq -r '.release_candidate.head_sha')" == "$2" ]] || {
      echo "delivery-request: existing release owns $RELEASE_BATCH_SHA; requested head was $2" >&2; exit 75;
    }
    result="RELEASE-PENDING ISSUE=$N HEAD=$RELEASE_BATCH_SHA; existing pipeline tick owns dispatch and production gates"
    ;;
esac
save accepted "$result"
cat "$record"
