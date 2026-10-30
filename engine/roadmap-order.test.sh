#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/roadmap.sh"
test_tmp="$(mktemp -d)"
trap 'rm -rf -- "$test_tmp"' EXIT

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" != "$expected" ]]; then
    printf 'not ok - %s\nexpected: %s\nactual:   %s\n' "$name" "$expected" "$actual" >&2
    exit 1
  fi
}

TREE='{"roots":[{"number":900,"title":"the product Roadmap","state":"OPEN","createdAt":"2026-10-01T00:00:00Z","labels":["roadmap"],"children":[{"number":901,"title":"UX and customer workflows","state":"OPEN","createdAt":"2026-10-01T00:00:00Z","milestone":"UX 2026","labels":["roadmap-theme"],"children":[{"number":902,"title":"Domain pack","state":"OPEN","createdAt":"2026-10-01T00:00:00Z","labels":["roadmap-epic"],"children":[{"number":106,"title":"Domain pack intake","state":"OPEN","createdAt":"2026-10-11T11:50:00Z","labels":["ready-for-agent"],"blockedBy":[],"children":[]},{"number":105,"title":"Change intake UI","state":"OPEN","createdAt":"2026-10-11T11:40:00Z","labels":["ready-for-agent","focus"],"blockedBy":[],"children":[]},{"number":107,"title":"Blocked issue","state":"OPEN","createdAt":"2026-10-11T11:30:00Z","labels":["ready-for-agent"],"blockedBy":[{"number":108,"state":"OPEN"}],"children":[]},{"number":109,"title":"Issue with children","state":"OPEN","createdAt":"2026-10-11T11:20:00Z","labels":[],"blockedBy":[],"children":[{"number":110,"title":"Too deep","state":"OPEN","createdAt":"2026-10-11T11:10:00Z","labels":["ready-for-agent"],"blockedBy":[],"children":[]}]},{"number":114,"title":"Closed issue","state":"CLOSED","createdAt":"2026-10-11T10:00:00Z","labels":["ready-for-agent"],"blockedBy":[],"children":[]}]},{"number":904,"title":"待归类","state":"OPEN","createdAt":"2026-10-01T00:00:00Z","labels":["roadmap-epic"],"children":[{"number":112,"title":"Unclassified ticket","state":"OPEN","createdAt":"2026-10-10T10:00:00Z","labels":["needs-triage","priority:top"],"blockedBy":[],"children":[]},{"number":113,"title":"Held ticket","state":"OPEN","createdAt":"2026-10-11T11:00:00Z","labels":["needs-triage","on-hold"],"blockedBy":[],"children":[]}]}]}]}]}'
CANDIDATES='[{"number":900,"state":"OPEN","labels":[{"name":"roadmap"}]},{"number":901,"state":"OPEN","labels":[{"name":"roadmap-theme"}]},{"number":902,"state":"OPEN","labels":[{"name":"roadmap-epic"}]},{"number":106,"state":"OPEN","labels":[{"name":"ready-for-agent"}]},{"number":105,"state":"OPEN","labels":[{"name":"ready-for-agent"},{"name":"focus"}]},{"number":107,"state":"OPEN","labels":[{"name":"ready-for-agent"}]},{"number":109,"state":"OPEN","labels":[{"name":"ready-for-agent"}]},{"number":110,"state":"OPEN","labels":[{"name":"ready-for-agent"}]},{"number":112,"state":"OPEN","labels":[{"name":"needs-triage"},{"name":"priority:top"}]},{"number":113,"state":"OPEN","labels":[{"name":"needs-triage"},{"name":"on-hold"}]},{"number":114,"state":"CLOSED","labels":[{"name":"ready-for-agent"}]}]'

ordered="$(roadmap_order_candidates "$TREE" "$CANDIDATES" | paste -sd, -)"
assert_eq 'tree tickets lead; deeper leaf follows; focus does not override tree' '112,106,105,110' "$ordered"
BUG_TOP_TREE="$(jq '.roots[0].children[0].children[1].children += [{"number":115,"title":"Wrong number production bug","state":"OPEN","labels":["bug","priority:top"],"children":[]}]' <<< "$TREE")"
BUG_TOP_CANDIDATES="$(jq '. + [{"number":115,"state":"OPEN","labels":[{"name":"bug"},{"name":"priority:top"}]}]' <<< "$CANDIDATES")"
ordered="$(roadmap_order_candidates "$BUG_TOP_TREE" "$BUG_TOP_CANDIDATES" | paste -sd, -)"
assert_eq 'bug+priority:top keeps legacy override ahead of tree order' '115,112,106,105,110' "$ordered"

ROOT_TREE="$(jq '.roots[0].children[0].children[0].children += [
  {number:116,title:"Root blocker 4",state:"OPEN",createdAt:"2026-10-11T09:00:00Z",labels:["ready-for-agent"],blockedBy:[],dependents_count:4,children:[]},
  {number:117,title:"Root blocker 9",state:"OPEN",createdAt:"2026-10-11T08:00:00Z",labels:["ready-for-agent"],blockedBy:[],dependents_count:9,children:[]},
  {number:118,title:"Blocked root",state:"OPEN",createdAt:"2026-10-11T07:00:00Z",labels:["ready-for-agent"],blockedBy:[{number:108,state:"OPEN"}],dependents_count:20,children:[]}
]' <<< "$TREE")"
ROOT_CANDIDATES="$(jq '. + [
  {number:116,state:"OPEN",labels:[{name:"ready-for-agent"}]},
  {number:117,state:"OPEN",labels:[{name:"ready-for-agent"}]},
  {number:118,state:"OPEN",labels:[{name:"ready-for-agent"}]}
]' <<< "$CANDIDATES")"
ordered="$(roadmap_order_candidates "$ROOT_TREE" "$ROOT_CANDIDATES" | paste -sd, -)"
assert_eq 'priority override leads, then unblocking roots by open dependents count' \
  '112,117,116,106,105,110' "$ordered"

FALLBACK_TREE="$(jq '.roots[0].children[0].children += [
  {number:119,title:"Depth-2 leaf",state:"OPEN",labels:[],children:[]},
  {number:125,title:"Held depth-2 leaf",state:"OPEN",labels:["on-hold"],children:[]},
  {number:126,title:"Blocked depth-2 leaf",state:"OPEN",labels:[],blockedBy:[{state:"OPEN"}],children:[]}
]' <<< "$TREE")"
FALLBACK_CANDIDATES="$(jq -cn '[
  {number:120,labels:[]},
  {number:119,labels:[]},
  {number:105,labels:[]},
  {number:121,labels:["priority:top","bug"],blockedBy:[{state:"CLOSED"}]},
  {number:122,labels:[{name:"on-hold"}]},
  {number:123,labels:[],blockedBy:{nodes:[{state:"OPEN"}]}},
  {number:124,labels:[],blockedBy:[{state:"open"}]},
  {number:125,labels:[]},
  {number:126,labels:[]},
  {number:127,labels:["roadmap-epic"]},
  {number:128,labels:[],subIssuesSummary:{total:1}},
  {number:129,labels:[],subIssues:[{number:130}]},
  {number:131,labels:[],subIssues:{nodes:[{number:132}]}},
  {number:133,labels:[],children:[{number:134}]},
  {number:135,labels:[],children_total:1},
  {number:136,labels:[],state:"CLOSED"},
  {number:137,labels:[],subIssues:{totalCount:1,nodes:[]}}
]')"
assert_eq 'tree first; orphan and depth-2 leaf follow in incoming order; hold, blockers and parents excluded' \
  '105,120,119,121' "$(roadmap_order_candidates "$FALLBACK_TREE" "$FALLBACK_CANDIDATES" 2> "$test_tmp/fallback.log" | paste -sd, -)"
assert_eq 'fallback candidates are visible without contaminating numeric caller input' \
  'roadmap: appended fallback candidates 120,119,121' "$(cat "$test_tmp/fallback.log")"
assert_eq 'JSON fastlane adapter preserves eligible candidate objects in shared order' \
  '105,120,119,121' "$(roadmap_order_candidate_json "$FALLBACK_TREE" "$FALLBACK_CANDIDATES" | jq -r 'map(.number) | join(",")')"
assert_eq 'JSON adapter keeps fallback labels for lane classification' 'priority:top,bug' \
  "$(roadmap_order_candidate_json "$FALLBACK_TREE" "$FALLBACK_CANDIDATES" | jq -r '.[] | select(.number == 121) | .labels | join(",")')"
assert_eq 'candidate blocker excludes mapped ticket even when tree snapshot is clear' '' \
  "$(roadmap_order_candidates "$TREE" '[{"number":105,"blockedBy":{"nodes":[{"state":"OPEN"}]}}]')"
assert_eq 'candidate hold excludes mapped ticket even when tree snapshot is clear' '' \
  "$(roadmap_order_candidates "$TREE" '[{"number":105,"labels":["on-hold"]}]')"
assert_eq 'empty candidate set is a successful empty JSON queue' '[]' \
  "$(roadmap_order_candidate_json "$TREE" '[]')"
assert_eq 'all excluded candidates form a successful empty JSON queue' '[]' \
  "$(roadmap_order_candidate_json "$TREE" '[{"number":122,"labels":["on-hold"]}]')"
assert_eq 'completed-only sub-issues do not block candidate admission' '138' \
  "$(roadmap_order_candidates "$TREE" '[{"number":138,"labels":[],"subIssuesSummary":{"total":1,"completed":1}}]')"
assert_eq 'open sub-issues still block candidate admission' '' \
  "$(roadmap_order_candidates "$TREE" '[{"number":138,"labels":[],"subIssuesSummary":{"total":1,"completed":0}}]')"

RAW_PAGE="$(jq -cn '
  def issue($n;$title;$labels;$children):
    {number:$n,title:$title,state:"OPEN",labels:{nodes:[$labels[]|{name:.}]},blocking:{nodes:(if $n==106 then [{state:"OPEN"},{state:"CLOSED"}] else [] end),pageInfo:{hasNextPage:false}},blockedBy:{nodes:[]},
     subIssues:{totalCount:($children|length),pageInfo:{hasNextPage:false},nodes:[$children[]|{number:.}]}};
  [{data:{repository:{issues:{nodes:[issue(106;"Ticket";["ready-for-agent"];[]), issue(900;"Roadmap";["roadmap"];[901])],
     pageInfo:{hasNextPage:true}}}}},
   {data:{repository:{issues:{nodes:[issue(901;"Theme";["roadmap-theme"];[902]), issue(902;"Epic";["roadmap-epic"];[106,107])],
     pageInfo:{hasNextPage:false}}}}}]
')"
NORMALIZED_TREE="$(roadmap_tree_normalize_pages "$RAW_PAGE")"
assert_eq 'GraphQL normalization includes level-3 ticket nodes' 3 \
  "$(roadmap_flatten "$NORMALIZED_TREE" | jq -r '.[] | select(.number == 106) | .depth')"
assert_eq 'flat pages rebuild sub-issue order across pages, closed children as stubs' '106:open 107:closed' \
  "$(jq -r '.roots[0].children[0].children[0].children | map("\(.number):\(.state)") | join(" ")' <<< "$NORMALIZED_TREE")"
assert_eq 'open dependents are counted for root-blocker ordering' 1 \
  "$(roadmap_flatten "$NORMALIZED_TREE" | jq -r '.[] | select(.number == 106) | .dependents_count')"
TRUNCATED_PAGE="$(jq '.[1].data.repository.issues.nodes[1].subIssues.pageInfo.hasNextPage = true' <<< "$RAW_PAGE")"
assert_eq 'nested sub-issue pagination truncation fails closed' false \
  "$(roadmap_tree_is_valid "$(roadmap_tree_normalize_pages "$TRUNCATED_PAGE")" && echo true || echo false)"
TRUNCATED_DEPENDENTS="$(jq '.[0].data.repository.issues.nodes[0].blocking.pageInfo.hasNextPage = true' <<< "$RAW_PAGE")"
assert_eq 'nested blocking pagination truncation fails closed' false \
  "$(roadmap_tree_is_valid "$(roadmap_tree_normalize_pages "$TRUNCATED_DEPENDENTS")" && echo true || echo false)"

inherited="$(roadmap_choose_epic "$TREE" '{"title":"New child"}' 106)"
assert_eq 'split/follow-up inherits source roadmap epic' 902 "$(jq -r '.epic' <<< "$inherited")"
assert_eq 'inheritance mirrors theme milestone' 'UX 2026' "$(jq -r '.milestone' <<< "$inherited")"

classified="$(roadmap_choose_epic "$TREE" '{"title":"Domain pack intake labels"}' '')"
assert_eq 'title classifier selects best epic' 902 "$(jq -r '.epic' <<< "$classified")"
fallback="$(roadmap_choose_epic "$TREE" '{"title":"Unrelated invoice export"}' '')"
assert_eq 'unmatched issue falls under 待归类' 904 "$(jq -r '.epic' <<< "$fallback")"

CATEGORY_TREE="$(jq '.roots[0].children += [{number:910,title:"开发流水线与运行稳定",state:"OPEN",milestone:"开发流水线与运行稳定",labels:["roadmap-theme"],children:[{number:912,title:"自动派发与规则校验持续可靠",state:"OPEN",labels:["roadmap-epic"],children:[]}]}]' <<< "$TREE")"
CATEGORY_TREE="$(jq '.roots[0].children[1].children[0].children += [{number:913,title:"Product source issue",state:"OPEN",labels:["needs-triage"],children:[]}]' <<< "$CATEGORY_TREE")"
pipeline_classified="$(roadmap_choose_epic "$CATEGORY_TREE" '{"title":"Domain pack pipeline dispatch","body":"Issue from pipeline automation.","labels":[{"name":"pipeline-system"}]}' '913')"
assert_eq 'pipeline-system label scopes inherited source to pipeline theme' 912 \
  "$(jq -r '.epic' <<< "$pipeline_classified")"
pipeline_health_classified="$(roadmap_choose_epic "$CATEGORY_TREE" '{"title":"pipeline health: release.hotpatch_blockers unhealthy","body":"Node health metric stayed unhealthy.","labels":[{"name":"pipeline-system"}]}' '')"
assert_eq 'pipeline health issues map to the pipeline-system epic without a 待归类 epic' 912 \
  "$(jq -r '.epic' <<< "$pipeline_health_classified")"

printf '%s\n' "$TREE" > "$test_tmp/tree.json"
printf '%s\n' '{"switches":{"roadmap-order":false}}' > "$test_tmp/policy.json"
MODEL_POLICY_FILE="$test_tmp/policy.json"
assert_eq 'switch defaults off' false "$(roadmap_switch_value)"
jq '.switches["roadmap-order"] = true | .roles.advisor.disabled = false' "$test_tmp/policy.json" > "$test_tmp/policy.next"
mv "$test_tmp/policy.next" "$test_tmp/policy.json"
assert_eq 'switch reads persistent model policy' true "$(roadmap_switch_value)"
REPO=fixture/repo
ROADMAP_COMMANDS="$test_tmp/commands.log"
ROADMAP_GH_CALLS="$test_tmp/gh-calls.log"
gh() {
  printf '%s\n' "$*" >> "$ROADMAP_GH_CALLS"
  [[ "$1" == api && "$2" =~ /issues/([0-9]+)$ ]] || return 2
  printf '%s\n' "$((10000 + BASH_REMATCH[1]))"
}
guarded_write() { printf '%s\n' "$*" >> "$ROADMAP_COMMANDS"; }
roadmap_place_issue "$test_tmp/tree.json" 120 '{"title":"Follow-up"}' 106
assert_eq 'inherited ticket attaches to source epic before milestone write' \
  $'gh api repos/fixture/repo/issues/902/sub_issues --method POST -F sub_issue_id=10120 -F replace_parent=true\ngh issue edit 120 --repo fixture/repo --milestone UX 2026' \
  "$(cat "$ROADMAP_COMMANDS")"
assert_eq 'sub-issue API receives the issue database id' 'api repos/fixture/repo/issues/120 --jq .id | select(type == "number" and . > 0)' \
  "$(cat "$ROADMAP_GH_CALLS")"
ROADMAP_RETRY_COMMANDS="$test_tmp/retry-commands.log"
MILESTONE_FAIL_ONCE=1
guarded_write() {
  printf '%s\n' "$*" >> "$ROADMAP_RETRY_COMMANDS"
  if [[ "$1 $2" == 'gh issue' && "${3:-}" == edit && "$MILESTONE_FAIL_ONCE" == 1 ]]; then
    MILESTONE_FAIL_ONCE=0
    return 1
  fi
}
if roadmap_place_issue "$test_tmp/tree.json" 122 '{"title":"Retry follow-up"}' 106; then
  echo 'not ok - failed milestone write must keep intake incomplete' >&2
  exit 1
fi
roadmap_place_issue "$test_tmp/tree.json" 122 '{"title":"Retry follow-up"}' 106
assert_eq 'intake retry does not POST a duplicate parent link' 1 "$(grep -c '^gh api ' "$ROADMAP_RETRY_COMMANDS")"
assert_eq 'intake retry retries milestone after parent link succeeds' 2 \
  "$(grep -c '^gh issue edit ' "$ROADMAP_RETRY_COMMANDS")"
assert_eq 'intake retry records fully placed ticket' true \
  "$(grep -Fqx 122 "$test_tmp/tree.json.placed" && echo true || echo false)"
ZF_ROADMAP_TREE_CACHE_FILE="$test_tmp/tree.json"
export ZF_ROADMAP_TREE_CACHE_FILE
: > "$ROADMAP_COMMANDS"
guarded_write() { printf '%s\n' "$*" >> "$ROADMAP_COMMANDS"; }
roadmap_ensure_issue_parent 106 ready-for-agent '{"title":"Domain pack intake"}'
assert_eq 'existing roadmap ticket can enter active stage' \
  'gh issue edit 106 --repo fixture/repo --milestone UX 2026' \
  "$(cat "$ROADMAP_COMMANDS")"
roadmap_ensure_issue_parent 120 needs-triage '{"title":"Follow-up"}' 106
assert_eq 'already placed intake does not reparent on first stage label' 1 "$(wc -l < "$ROADMAP_COMMANDS" | tr -d ' ')"
printf '%s\n' "$FALLBACK_TREE" > "$test_tmp/tree.json"
: > "$ROADMAP_COMMANDS"
roadmap_ensure_issue_parent 119 ready-for-agent '{"title":"Depth-2 leaf"}'
assert_eq 'depth-2 leaf can enter active stage without reparenting' \
  'gh issue edit 119 --repo fixture/repo --milestone UX 2026' "$(cat "$ROADMAP_COMMANDS")"
: > "$ROADMAP_COMMANDS"
roadmap_ensure_issue_parent 123 on-hold '{"title":"Follow-up"}' 106
assert_eq 'held ticket is placed before entering on-hold' \
  $'gh api repos/fixture/repo/issues/902/sub_issues --method POST -F sub_issue_id=10123 -F replace_parent=true\ngh issue edit 123 --repo fixture/repo --milestone UX 2026' \
  "$(cat "$ROADMAP_COMMANDS")"
closed_child_tree="$(jq '.roots[0].children[0].children[0].children += [{number:138,title:"Completed child parent",state:"OPEN",labels:["needs-triage"],children_total:1,children:[{number:139,title:"Closed child",state:"CLOSED",labels:[],children:[]}]}]' <<< "$TREE")"
printf '%s\n' "$closed_child_tree" > "$test_tmp/tree.json"
ZF_ROADMAP_TREE_CACHE_FILE="$test_tmp/tree.json"
: > "$ROADMAP_COMMANDS"
roadmap_ensure_issue_parent 138 needs-triage '{"title":"Completed child parent"}'
assert_eq 'a ticket with only closed children remains stage-eligible' \
  'gh issue edit 138 --repo fixture/repo --milestone UX 2026' "$(cat "$ROADMAP_COMMANDS")"
printf '%s\n' "$TREE" > "$test_tmp/tree.json"

mkdir -p "$test_tmp/agent"
AGENT_HOME="$test_tmp/agent" ZF_REPO=fixture/repo
export AGENT_HOME ZF_REPO
source "$SCRIPT_DIR/lib.sh"
gh() { printf '10121\n'; }
jq '.switches["roadmap-order"] = true | .roles.advisor.disabled = false' "$MODEL_POLICY_FILE" > "$test_tmp/policy.next"
mv "$test_tmp/policy.next" "$MODEL_POLICY_FILE"
ZF_ROADMAP_TREE_CACHE_FILE="$test_tmp/tree.json"
export ZF_ROADMAP_TREE_CACHE_FILE
ensure_state_labels() { :; }
is_on_hold() { return 1; }
guarded_write() { printf '%s\n' "$*" >> "$ROADMAP_COMMANDS"; }
: > "$ROADMAP_COMMANDS"
container_intake_status=0
roadmap_ensure_issue_parent 902 needs-triage '{"number":902,"title":"Domain pack"}' || container_intake_status=$?
assert_eq 'roadmap container reports the tracker-only intake outcome' 3 "$container_intake_status"
intake_issue_json='{"number":121,"title":"Follow-up","body":"","state":"OPEN","labels":[]}'
issue_transition 121 needs-triage roadmap-intake . 0 "$intake_issue_json" 106
assert_eq 'intake parent and milestone precede first stage label' \
  $'gh api repos/fixture/repo/issues/902/sub_issues --method POST -F sub_issue_id=10121 -F replace_parent=true\ngh issue edit 121 --repo fixture/repo --milestone UX 2026' \
  "$(head -n 2 "$ROADMAP_COMMANDS")"
assert_eq 'first stage label follows parent and milestone writes' true \
  "$(sed -n '3p' "$ROADMAP_COMMANDS" | grep -Fq -- '--add-label needs-triage' && echo true || echo false)"
assert_eq 'a roadmap root cannot receive an active stage label' false \
  "$(roadmap_ensure_issue_parent 900 ready-for-agent '{}' && echo true || echo false)"

NOW="$(date -u -d '2026-10-11T12:00:00Z' +%s)"
OPEN='[{"number":106,"state":"OPEN","createdAt":"2026-10-11T11:50:00Z","labels":[{"name":"ready-for-agent"}]},{"number":112,"state":"OPEN","createdAt":"2026-10-10T10:00:00Z","labels":[{"name":"needs-triage"}]},{"number":119,"state":"OPEN","createdAt":"2026-10-11T10:00:00Z","labels":[{"name":"needs-triage"}]}]'
broken="$(roadmap_health_assess "$TREE" "$OPEN" "$NOW" true)"
assert_eq 'orphan and stale 待归类 issue make roadmap HEALTH BROKEN' BROKEN "$(jq -r '.verdict' <<< "$broken")"
assert_eq 'stable item keys identify only failing issues' 'orphan:#119,unclassified:#112' "$(jq -r '.item_keys | join(",")' <<< "$broken")"

healthy_open='[{"number":106,"state":"OPEN","createdAt":"2026-10-11T11:50:00Z","labels":[{"name":"ready-for-agent"}]},{"number":112,"state":"OPEN","createdAt":"2026-10-11T11:30:00Z","labels":[{"name":"needs-triage"}]}]'
healthy="$(roadmap_health_assess "$TREE" "$healthy_open" "$NOW" true)"
assert_eq 'roadmap HEALTH is OK when every open ticket has a fresh root chain' OK "$(jq -r '.verdict' <<< "$healthy")"
container_tree="$(jq '.roots[0].children[0].children[0].labels += ["needs-triage"]' <<< "$TREE")"
container_health="$(roadmap_health_assess "$container_tree" "$healthy_open" "$NOW" true)"
assert_eq 'stage label on container makes roadmap HEALTH BROKEN' 'container-stage:#902' "$(jq -r '.item_keys | join(",")' <<< "$container_health")"
failed_read="$(roadmap_health_assess '{}' '[]' "$NOW" false)"
assert_eq 'failed tree read makes roadmap HEALTH BROKEN' BROKEN "$(jq -r '.verdict' <<< "$failed_read")"
empty_tree="$(roadmap_health_assess '{"roots":[]}' '[]' "$NOW" true)"
assert_eq 'no root issue reports NONE' NONE "$(jq -r '.verdict' <<< "$empty_tree")"
closed_child_health_tree="$(jq '.roots[0].children[0].children[0].children += [{number:138,title:"Completed child parent",state:"OPEN",labels:["needs-triage"],children_total:1,children:[{number:139,title:"Closed child",state:"CLOSED",labels:[],children:[]}]}]' <<< "$TREE")"
closed_child_open='[{"number":138,"state":"OPEN","createdAt":"2026-10-11T11:50:00Z","labels":[{"name":"needs-triage"}],"subIssuesSummary":{"total":1,"completed":1}}]'
closed_child_health="$(roadmap_health_assess "$closed_child_health_tree" "$closed_child_open" "$NOW" true)"
assert_eq 'closed-only children do not make active stage a container' OK "$(jq -r '.verdict' <<< "$closed_child_health")"
open_child_health_tree="$(jq '.roots[0].children[0].children[0].children[-1].children[0].state="OPEN"' <<< "$closed_child_health_tree")"
open_child_open='[{"number":138,"state":"OPEN","createdAt":"2026-10-11T11:50:00Z","labels":[{"name":"needs-triage"}],"subIssuesSummary":{"total":1,"completed":0}}]'
open_child_health="$(roadmap_health_assess "$open_child_health_tree" "$open_child_open" "$NOW" true)"
assert_eq 'open children still flag stage labels on containers' 'container-stage:#138' \
  "$(jq -r '.item_keys | join(",")' <<< "$open_child_health")"

printf 'HEALTH fixture: roadmap %s %s\n' "$(jq -r '.verdict' <<< "$broken")" "$(jq -r '.detail' <<< "$broken")"
echo 'roadmap-order.test.sh: PASS'

# Implement dependencies clear when existing blocker policy says code is on main.
MERGED_TREE="$(jq '.roots[0].children[0].children[0].children += [{number:108,state:"OPEN",labels:["awaiting-release"],children:[]}]' <<< "$TREE")"
assert_eq 'implement admits merged dependency still waiting for production' '107' \
  "$(roadmap_order_candidates "$MERGED_TREE" '[{"number":107,"labels":["ready-for-agent"]}]' '["awaiting-release","released"]')"
assert_eq 'triage retains default open-blocker policy' '' \
  "$(roadmap_order_candidates "$MERGED_TREE" '[{"number":107,"labels":["ready-for-agent"]}]')"
assert_eq 'inline blocker labels use same merged policy' '105' \
  "$(roadmap_order_candidates "$TREE" '[{"number":105,"blockedBy":{"nodes":[{"number":999,"state":"OPEN","labels":[{"name":"awaiting-release"}]}]}}]' '["awaiting-release","released"]')"
