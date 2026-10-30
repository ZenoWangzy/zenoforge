#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/test-env.sh"
pipeline="$(dirname "$0")/issue-pipeline.sh"
source "$(dirname "$0")/lib.sh"
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
  if [[ "$1 $2" == 'issue view' ]]; then
    jq -sc --argjson number "$3" 'add | unique_by(.number) | .[] | select(.number == $number)' "$AGENT_HOME/first.json" "$AGENT_HOME/second.json"
  elif [[ " $* " == *' --label lane-one '* || " $* " == *' --label needs-triage '* ]]; then
    cat "$AGENT_HOME/first.json"
  else
    cat "$AGENT_HOME/second.json"
  fi
}
roadmap_order_candidate_json() { jq -c 'sort_by(.number) | reverse' <<< "$2"; }
route_nonproduct_path_issue_rows() { printf '%s\n' "$1" >> "$AGENT_HOME/routed.json"; }
for size in 0 200000; do
  jq -cn --argjson size "$size" '[1,3] | map({number:.,body:("x" * $size),comments:[{body:"retained"}],labels:[]})' > "$AGENT_HOME/first.json"
  jq -cn --argjson size "$size" '[2,3] | map({number:.,body:("x" * $size),comments:[{body:"retained"}],labels:[]})' > "$AGENT_HOME/second.json"
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
