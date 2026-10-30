#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../test-env.sh"
source "$MODEL_POLICY_TEST_REPO/engine/night/outcomes-audit.sh"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/home/night"
connections=(recent boundary refs implements titles)
searches=(recent boundary refs implements titles)
now="$(date +%s)"
gh_q() {
  local arg connection=initial cursor='' page
  for arg in "$@"; do
    case "$arg" in q=*) connection="${arg#q=}" ;; after=*) cursor="${arg#after=c}" ;; esac
  done
  printf '%s %s\n' "$connection" "$cursor" >> "$work/calls"
  if [ "$connection" = initial ]; then
    jq -cn '{data:(reduce ["recent","boundary","refs","implements","titles"][] as $c ({};
      .[$c]={nodes:[],pageInfo:{hasNextPage:true,endCursor:"c1"}}))}'
    return
  fi
  page=$((cursor+1))
  jq -cn --argjson page "$page" --arg c "$connection" --arg at "$(date -u +%FT%TZ)" '
    {data:{search:{nodes:[range(0;100) | {
      number:($page*100+.),title:"docs: pagination fixture",headRefName:"hand/pagination",
      body:("x"*2048),mergedAt:$at,baseRefName:"main"}],
      pageInfo:{hasNextPage:($page<9),endCursor:("c"+($page|tostring))}}}}'
}
total_calls=0
started=$SECONDS
for ((tick=0; tick<20; tick++)); do
  : > "$work/calls"
  if result="$(SECONDS=0 outcomes_merged_pr_search "$work/home" test/repo "$now" "${searches[@]}" 2> "$work/log")"; then
    done_scan=1
  else
    done_scan=0
    [[ ! -s "$work/result" ]] || { echo 'partial snapshot escaped' >&2; exit 1; }
    grep -q 'scan pending; cursor persisted' "$work/log"
    test -f "$work/home/night/outcomes-merged-search/manifest.json"
  fi
  calls="$(wc -l < "$work/calls")"
  ((calls <= 3)) || { echo "unbounded calls: $calls" >&2; exit 1; }
  total_calls=$((total_calls+calls))
  [[ "$done_scan" != 1 ]] || break
done
[[ "$done_scan" == 1 && "$total_calls" == 41 ]]
jq -e 'all(.data[]; (.nodes|length)==800 and .pageInfo.hasNextPage==false)' <<< "$result" >/dev/null
test ! -f "$work/home/night/outcomes-merged-search/manifest.json"
elapsed=$((SECONDS-started))
echo "ok - 45 pages, 41 calls across bounded ticks, no partial snapshot, ${elapsed}s"

# A repeated cursor fails closed; its saved page is never promoted or skipped.
gh_q() {
  if [[ "$*" != *' after='* ]]; then
    jq -cn '{data:(reduce ["recent","boundary","refs","implements","titles"][] as $c ({};
      .[$c]={nodes:[],pageInfo:{hasNextPage:($c=="recent"),endCursor:"stuck"}}))}'
  else
    printf '{"data":{"search":{"nodes":[],"pageInfo":{"hasNextPage":true,"endCursor":"stuck"}}}}\n'
  fi
}
if SECONDS=0 outcomes_merged_pr_search "$work/home" test/repo "$now" "${searches[@]}" > "$work/result" 2> "$work/log"; then
  echo 'repeated cursor accepted' >&2; exit 1
fi
[[ ! -s "$work/result" ]]
[[ "$(jq -r '.connections.recent.pages' "$work/home/night/outcomes-merged-search/manifest.json")" == 1 ]]
echo 'ok - repeated cursor stays unknown without advancing saved scan'

# jq normalizes impossible calendar dates; only exact ISO round-trips may use
# its fast path. Other formats keep the existing date parser and fail closed.
mkdir -p "$work/home/state"
printf '{"run":{"merged_at":"2026-02-30T00:00:00Z"}}\n' > "$work/home/state/1.json"
rows='[{"number":1,"state":"OPEN","title":"","labels":[]}]'
mapfile -d '' -t fields < <(outcomes_awaiting_rows "$work/home" "$rows")
[[ "${#fields[@]}" == 8 && -z "${fields[7]}" ]]
if outcomes_epoch "${fields[6]}" >/dev/null; then echo 'invalid date accepted' >&2; exit 1; fi
printf '{"run":{"merged_at":"2026-10-12T15:33:53Z"}}\n' > "$work/home/state/1.json"
mapfile -d '' -t fields < <(outcomes_awaiting_rows "$work/home" "$rows")
[[ "${fields[7]}" == "$(outcomes_epoch "${fields[6]}")" ]]
printf '[]\n' > "$work/home/state/1.json"
if outcomes_awaiting_rows "$work/home" "$rows" > "$work/rows" 2>/dev/null; then
  echo 'invalid persisted state accepted' >&2; exit 1
fi
echo 'ok - bulk state parse preserves invalid-date and invalid-state failure'

(
  outcomes_deadline=70
  OUTCOMES_GH_TIMEOUT_SECONDS=3
  SECONDS=0
  outcomes_stage_mark merged-issue-comments 2>/dev/null
  [[ "$OUTCOMES_GH_TIMEOUT_SECONDS" == 3 ]]
  SECONDS=62
  outcomes_stage_mark awaiting-release-timelines 2>/dev/null
  [[ "$OUTCOMES_GH_TIMEOUT_SECONDS" == 1 ]]
  SECONDS=64
  if outcomes_stage_mark priority-close-comments 2>/dev/null; then
    echo 'expired whole-audit budget accepted' >&2; exit 1
  fi
)
echo 'ok - shared read deadline retains stricter timeout and rejects late reads'
