#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
export ZF_REPO=test/repo ZF_REPO_DIR="$MODEL_POLICY_TEST_REPO" AGENT_DRY_RUN=0
source "$SCRIPT_DIR/lib.sh"
export ANSWER_FIXTURE="$test_env_root/answer"
mkdir -p "$ANSWER_FIXTURE"
jq '.switches["roadmap-order"] = true | .roles.advisor.disabled = false' "$SCRIPT_DIR/model-policy.default.json" > "$AGENT_HOME/model-policy.json"
cat > "$test_env_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$ANSWER_FIXTURE/calls"
case "$1:$2" in
  api:repos/test/repo/issues/comments/99) cat "$ANSWER_FIXTURE/comment.json" ;;
  api:graphql)
    [ "${ANSWER_TREE_FAILURE:-0}" != 1 ] || exit 1
    if [ "${ANSWER_NEW_REQUEST:-0}" = 1 ]; then
      jq '.implement_decision.requested_at="2026-10-12T11:07:00Z"' "$AGENT_HOME/state/2867.json" > "$ANSWER_FIXTURE/new-request.json"
      mv "$ANSWER_FIXTURE/new-request.json" "$AGENT_HOME/state/2867.json"
    fi
    cat "$ANSWER_FIXTURE/tree.json"
    ;;
  api:repos/test/repo/issues/2867/sub_issues?per_page=100) printf '[]\n' ;;
  label:list) printf '%s\n' ready-for-agent on-hold ;;
  label:create) ;;
  issue:edit)
    [ "${ANSWER_EDIT_FAILURE:-0}" != 1 ] || exit 1
    jq '.labels = [{name:"ready-for-agent"}]' "$ANSWER_FIXTURE/issue.json" > "$ANSWER_FIXTURE/issue.tmp"
    mv "$ANSWER_FIXTURE/issue.tmp" "$ANSWER_FIXTURE/issue.json"
    ;;
  *) echo "unexpected gh call: $*" >&2; exit 64 ;;
esac
EOF
chmod +x "$test_env_bin/gh"
jq -cn '
  def issue($n;$labels;$children):
    {number:$n,title:"decision hold",state:"OPEN",labels:{nodes:[$labels[]|{name:.}]},
     subIssues:{totalCount:($children|length),pageInfo:{hasNextPage:false},nodes:[$children[]|{number:.}]}};
  [{data:{repository:{issues:{nodes:[issue(1;["roadmap"];[2]),issue(2;["roadmap-theme"];[3]),
    issue(3;["roadmap-epic"];[2867]),issue(2867;["on-hold"];[])]}}}}]
' > "$ANSWER_FIXTURE/tree.json"
reset_case() {
  unset ANSWER_TREE_FAILURE ANSWER_EDIT_FAILURE ANSWER_NEW_REQUEST ZF_ROADMAP_TREE_CACHE_FILE
  : > "$ANSWER_FIXTURE/calls"
  jq -cn '{state:"on-hold",attempts:3,brief_md:"original brief",run:{outcome:"needs-decision"},
    implement_decision:{route:"supervisor-inbox",question:"scope?",requested_at:"2026-10-12T11:05:06Z"},
    hold:{holder:"supervisor-inbox",kind:"conclusion",created_at:"2026-10-12T11:05:10Z",
      stage_before:"ready-for-agent",expires_at:"2026-10-13T11:05:07Z",release_condition:"review decision",durable_record:true}}
  ' > "$STATE_DIR/2867.json"
  printf '{"labels":[{"name":"on-hold"}]}\n' > "$ANSWER_FIXTURE/issue.json"
  jq -cn --arg body "$BOT_DISCLAIMER
**Supervisor engineering decision (#2867):** use existing transaction; no new queue." \
    '{id:99,issue_url:"https://api.github.com/repos/test/repo/issues/2867",
      html_url:"https://github.com/test/repo/issues/2867#issuecomment-99",author_association:"OWNER",
      created_at:"2026-10-12T11:06:39Z",body:$body}' > "$ANSWER_FIXTURE/comment.json"
}
answer() { bash "$SCRIPT_DIR/hold.sh" --answer 2867 --comment 99; }
assert_held() {
  jq -e '.state=="on-hold" and .attempts==3 and .implement_decision.answer==null and .hold.holder=="supervisor-inbox"' "$STATE_DIR/2867.json" >/dev/null
  jq -e '.labels==[{name:"on-hold"}]' "$ANSWER_FIXTURE/issue.json" >/dev/null
}
reset_case
answer
jq -e '.state=="ready-for-agent" and .attempts==0 and .hold==null
  and (.brief_md | startswith("original brief")) and .implement_decision.answer.id==99
  and (.implement_decision.answer.body | contains("no new queue"))' "$STATE_DIR/2867.json" >/dev/null
jq -e '.labels==[{name:"ready-for-agent"}]' "$ANSWER_FIXTURE/issue.json" >/dev/null
grep -q '^api graphql ' "$ANSWER_FIXTURE/calls"
if find "$AGENT_HOME/night" -maxdepth 1 -type d \( -name '.hold-answer-*' -o -name '.roadmap-parent.*' \) | grep -q .; then
  echo 'unexpected match' >&2
  exit 1
fi
decision="$(state_read 2867 | jq -r '.brief_md')"
[[ "$decision" == *'no new queue'* && "$decision" == *'#issuecomment-99'* ]]
[[ "$decision" == *'<!-- ZF_SUPERVISOR_WORKFLOW_DECISION:BEGIN -->'* ]]
echo 'PASS answered bot decision releases with fresh roadmap and reaches next prompt'

for invalid in stale wrong-issue wrong-author empty wrong-hold; do
  reset_case
  case "$invalid" in
    stale) filter='.created_at="2026-10-12T11:00:00Z"' ;;
    wrong-issue) filter='.issue_url="https://api.github.com/repos/test/repo/issues/3237"' ;;
    wrong-author) filter='.author_association="NONE"' ;;
    empty) filter='.body=""' ;;
    wrong-hold)
      jq '.hold.holder="zf-23"' "$STATE_DIR/2867.json" > "$STATE_DIR/2867.tmp"
      mv "$STATE_DIR/2867.tmp" "$STATE_DIR/2867.json"
      filter='.' ;;
  esac
  jq "$filter" "$ANSWER_FIXTURE/comment.json" > "$ANSWER_FIXTURE/comment.tmp"
  mv "$ANSWER_FIXTURE/comment.tmp" "$ANSWER_FIXTURE/comment.json"
  before="$(cat "$STATE_DIR/2867.json")"
  if answer; then echo "invalid answer accepted: $invalid" >&2; exit 1; fi
  [ "$before" = "$(cat "$STATE_DIR/2867.json")" ]
  if grep -q '^issue edit ' "$ANSWER_FIXTURE/calls"; then
    echo 'unexpected match' >&2
    exit 1
  fi
  echo "PASS reject $invalid without changing hold"
done
for failure in TREE EDIT; do
  reset_case
  export "ANSWER_${failure}_FAILURE=1"
  if answer; then echo "$failure failure accepted" >&2; exit 1; fi
  assert_held
  echo "PASS $failure failure keeps unanswered hold and attempt budget"
done
reset_case
export ANSWER_NEW_REQUEST=1
if answer; then echo 'old answer released a new request' >&2; exit 1; fi
assert_held
jq -e '.implement_decision.requested_at=="2026-10-12T11:07:00Z"' "$STATE_DIR/2867.json" >/dev/null
echo 'PASS concurrent new request cannot consume old answer'
reset_case
jq '.brief_md += "\n<!-- ZF_SUPERVISOR_WORKFLOW_DECISION:BEGIN -->old decision<!-- ZF_SUPERVISOR_WORKFLOW_DECISION:END -->"' \
  "$STATE_DIR/2867.json" > "$STATE_DIR/2867.tmp"
mv "$STATE_DIR/2867.tmp" "$STATE_DIR/2867.json"
answer
decision="$(state_read 2867 | jq -r '.brief_md')"
[[ "$decision" == *'no new queue'* && "$decision" != *'old decision'* ]]
echo 'PASS new answer replaces old workflow decision block'
