#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/test-env.sh"
pipeline="$(dirname "$0")/issue-pipeline.sh"
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/lib.d/issue-rest.sh"
NIGHT="$AGENT_HOME/night"
eval "$(sed -n '/^fastlane_scan_order() {/,/^}/p; /^route_nonproduct_path_candidates() {/,/^}/p; /^fastlane_snapshot_candidates() {/,/^}/p; /^fastlane_read_path_contexts() {/,/^}/p' "$pipeline")"
REPO=test/repo
PIPELINE_SYSTEM_LABELS_JSON='["lane-one","lane-two"]'
ROADMAP_ORDER_ENABLED=true
ROADMAP_TREE_READY=1
ROADMAP_TREE_JSON='{}'

# Both per-query and accumulated snapshots cross MAX_ARG_STRLEN. Builtin
# printf and function calls keep the fixture off external process argv.
gh() {
  if [[ "$1 $2" == 'api graphql' ]]; then
    local context='{}' n
    while IFS= read -r n; do
      [[ "$n" =~ ^[1-9][0-9]*$ ]] || continue
      context="$(jq -cn --argjson context "$context" --argjson n "$n" '$context + {("i" + ($n | tostring)):{number:$n,blockedBy:{nodes:[]},subIssues:{totalCount:0,nodes:[]},subIssuesSummary:{total:0,completed:0}}}')"
    done < <(grep -oE 'issue\(number: [0-9]+\)' <<<"$*" | grep -oE '[0-9]+')
    jq -cn --argjson context "$context" '{data:{repository:$context}}'
  elif [[ "$1" == api && "$2" == repos/*/issues\?* ]]; then
    local label="${2##*&labels=}"
    [[ "$label" != "$2" ]] || label=""
    jq -sc --arg label "$label" '[.[].[] | select($label == "" or any(.labels[]?; .name == $label))
      | {number,title,body,state:(.state | ascii_downcase),created_at:"2026-11-26T00:00:00Z",updated_at:"2026-11-26T00:00:00Z",labels,user:{login:"fixture"}}]' \
      "$AGENT_HOME/first.json" "$AGENT_HOME/second.json"
  fi
}
roadmap_order_candidate_json() { jq -c 'sort_by(.number) | reverse' <<< "$2"; }
issue_body_is_direct_main_lane() { return 0; }
issue_rest_view() {
  jq -sc --argjson number "$1" 'add | unique_by(.number)[] | select(.number == $number)
    | {number,title,body,state:(.state | ascii_upcase),labels,comments:[{body:"retained"}]}' \
    "$AGENT_HOME/first.json" "$AGENT_HOME/second.json"
}
route_nonproduct_path_issue_rows() { printf '%s\n' "$1" >> "$AGENT_HOME/routed.json"; }
for size in 0 200000; do
  jq -cn --argjson size "$size" '[1,3] | map({number:.,title:"fixture",body:("x" * $size),state:"open",labels:[{name:"needs-triage"}],created_at:"2026-11-26T00:00:00Z",updated_at:"2026-11-26T00:00:00Z"})' > "$AGENT_HOME/first.json"
  jq -cn --argjson size "$size" '[2,3] | map({number:.,title:"fixture",body:("x" * $size),state:"open",labels:[{name:"ready-for-agent"}],created_at:"2026-11-26T00:00:00Z",updated_at:"2026-11-26T00:00:00Z"})' > "$AGENT_HOME/second.json"
  rm -f "$AGENT_HOME/routed.json"
  route_nonproduct_path_candidates
  jq -se --argjson size "$size" 'add | [.[].number] == [3,2,1] and all(.[]; (.body | length) == $size and .comments[0].body == "retained")' "$AGENT_HOME/routed.json" >/dev/null
  echo "ok - both census paths merge/deduplicate $size-byte issue bodies and retain roadmap order"
done
printf '[]\n' > "$AGENT_HOME/first.json"
printf '[]\n' > "$AGENT_HOME/second.json"
rm -f "$AGENT_HOME/routed.json"
route_nonproduct_path_candidates
[[ ! -e "$AGENT_HOME/routed.json" ]]
for broken in first second; do
 for invalid in 'invalid-json' '' $'[]\n[]'; do
  printf '%s\n' "$invalid" > "$AGENT_HOME/$broken.json"
  rm -f "$AGENT_HOME/routed.json"
  route_nonproduct_path_candidates
  [[ ! -e "$AGENT_HOME/routed.json" ]]
 done
  printf '[]\n' > "$AGENT_HOME/$broken.json"
done
echo 'ok - empty snapshots remain empty; unreadable snapshots cannot dispatch'
