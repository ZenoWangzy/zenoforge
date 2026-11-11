# A queued PR run can stay check-pending forever when GitHub has not created its jobs.
# Re-trigger one such head once; a second affected head goes to the existing supervisor lane.
ci_stuck_unqueued_pending() { # unit-id pr head branch → 0 when this head was handled
  local id="$1" pr="$2" head="$3" branch="$4" runs count run_ids run_id jobs newest_created_at age_seconds threshold now_stamp prior_head
  local tree_sha new_head patched_head endpoint
  local -a stuck_run_ids=()
  [[ -n "$branch" && "$branch" != main ]] || return 1
  [[ "${TICK_UNFINISHED_ALL_OK:-false}" == true ]] || return 1
  command git check-ref-format "refs/heads/$branch" >/dev/null 2>&1 || return 1

  runs="$(unfinished_runs | jqf -c --arg head "$head" --arg branch "$branch" \
    '[.[] | select((.event == "pull_request" or .event == "pull_request_target")
      and .headSha == $head and .headBranch == $branch)]')" || return 1
  count="$(jqf -r 'length' <<<"$runs")"
  [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 )) || return 1
  jqf -e 'all(.[]; .status == "queued")' <<<"$runs" >/dev/null || return 1
  run_ids="$(jqf -r '[.[].databaseId | tostring] | sort | join(",")' <<<"$runs")"
  while IFS= read -r run_id; do
    [[ "$run_id" =~ ^[0-9]+$ ]] || return 1
    stuck_run_ids+=("$run_id")
  done < <(jqf -r '.[].databaseId' <<<"$runs")
  ci_jobs_prefetch "${stuck_run_ids[@]}" || :
  while IFS= read -r run_id; do
    [[ -n "${CI_RUN_JOBS_CACHE[$run_id]+cached}" ]] || return 1
    jobs="$(ci_jobs_data "$run_id")" || return 1
    jqf -e 'type == "array" and length == 0' <<<"$jobs" >/dev/null || return 1
  done < <(printf '%s\n' "${stuck_run_ids[@]}")

  newest_created_at="$(jqf -r '[.[].createdAt // empty] | max // empty' <<<"$runs")"
  [[ -n "$newest_created_at" ]] || return 1
  threshold="${CI_STUCK_UNQUEUED_SECONDS:-1800}"
  [[ "$threshold" =~ ^[0-9]+$ ]] || threshold=1800
  threshold=$((10#$threshold))
  now_stamp="${STAMP:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  age_seconds="$(python3 - "$now_stamp" "$newest_created_at" <<'PY'
from datetime import datetime, timezone
import sys

def epoch(value):
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return (parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)).timestamp()

try:
    print(int(epoch(sys.argv[1]) - epoch(sys.argv[2])))
except Exception:
    print("")
PY
)" || return 1
  [[ "$age_seconds" =~ ^-?[0-9]+$ ]] && (( age_seconds > threshold )) || return 1

  prior_head="$(unit_field "$id" '.ci_unqueued_retrigger_head // empty')"
  [[ "$prior_head" == "$head" ]] && return 0
  say "STUCK-UNQUEUED unit=$id PR#$pr head=$head run_ids=$run_ids age=${age_seconds}s"
  if [[ -n "$prior_head" ]]; then
    to_supervisor "$id" "second STUCK-UNQUEUED head $head after one retrigger on $prior_head (PR#$pr; runs $run_ids)"
    return $?
  fi

  tree_sha="$(gh api --method GET "repos/{owner}/{repo}/git/commits/$head" --jq .tree.sha 2>/dev/null)" || {
    say "STUCK-UNQUEUED unit=$id PR#$pr head=$head tree lookup failed"
    return 1
  }
  [[ "$tree_sha" =~ $SHA_RE ]] || { say "STUCK-UNQUEUED unit=$id PR#$pr head=$head tree SHA unavailable"; return 1; }
  new_head="$(guarded_write gh api --method POST "repos/{owner}/{repo}/git/commits" \
    -f "message=CI recovery: retrigger stuck queued run" -f "tree=$tree_sha" -f "parents[]=$head" --jq .sha 2>/dev/null)" || {
    say "STUCK-UNQUEUED unit=$id PR#$pr head=$head empty commit creation failed"
    return 1
  }
  [[ "$new_head" =~ $SHA_RE ]] || { say "STUCK-UNQUEUED unit=$id PR#$pr head=$head empty commit SHA unavailable"; return 1; }
  endpoint="repos/{owner}/{repo}/git/refs/heads/$branch"
  patched_head="$(guarded_write gh api --method PATCH "$endpoint" -f "sha=$new_head" -F force=false --jq .object.sha 2>/dev/null)" || {
    say "STUCK-UNQUEUED unit=$id PR#$pr head=$head branch update failed"
    return 1
  }
  [[ "$patched_head" == "$new_head" ]] || { say "STUCK-UNQUEUED unit=$id PR#$pr head=$head branch update was not confirmed"; return 1; }
  set_unit "$id" "$(hist ci-stuck-unqueued "retriggered PR#$pr head $head once with empty commit $new_head (runs $run_ids)") | .ci_unqueued_retrigger_head=$(js "$head")" \
    || { say "STUCK-UNQUEUED unit=$id PR#$pr head=$head retriggered but ledger update failed"; return 1; }
  say "STUCK-UNQUEUED retriggered unit=$id PR#$pr head=$head new_head=$new_head run_ids=$run_ids"
  return 0
}
