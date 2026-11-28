#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
test_tmp="$TMPDIR/roadmap-issue-create"
mkdir -p "$test_tmp/bin" "$test_tmp/agent"
trap 'rm -rf -- "$test_tmp" "$test_env_root"' EXIT

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" != "$expected" ]]; then
    printf 'not ok - %s\nexpected: %s\nactual:   %s\n' "$name" "$expected" "$actual" >&2
    exit 1
  fi
}

cat > "$test_tmp/tree.json" <<'JSON'
{"roots":[{"number":900,"title":"the product Roadmap","state":"OPEN","labels":["roadmap"],"children":[{"number":901,"title":"Platform","state":"OPEN","labels":["roadmap-theme"],"children":[{"number":902,"title":"Domain pack","state":"OPEN","labels":["roadmap-epic"],"children":[]},{"number":904,"title":"待归类","state":"OPEN","labels":["roadmap-epic"],"children":[]}]},{"number":910,"title":"开发流水线与运行稳定","state":"OPEN","milestone":"开发流水线与运行稳定","labels":["roadmap-theme"],"children":[{"number":912,"title":"Automated dispatch rule validation","state":"OPEN","labels":["roadmap-epic"],"children":[]}]}]}]}
JSON

cat > "$test_tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >> "$FAKE_GH_LOG"
printf '\n' >> "$FAKE_GH_LOG"
if [[ "${EXPECT_WRAPPER:-0}" == 1 && "${WRAPPER_SENTINEL:-}" != loaded ]]; then
  echo 'credential env did not reach gh' >&2
  exit 42
fi
case "${1:-}:${2:-}:${3:-}" in
  label:list:*) cat "$FAKE_LABELS" ;;
  label:create:*)
    label="${3:?}"
    grep -qx -- "$label" "$FAKE_LABELS" || printf '%s\n' "$label" >> "$FAKE_LABELS"
    ;;
  issue:create:*)
    echo "https://github.com/example-maintainer/example-repo/issues/${FAKE_NEXT_ISSUE:?}"
    ;;
  issue:view:*)
    jq -cn --argjson number "$3" --arg title "$FAKE_ISSUE_TITLE" --arg body "$FAKE_ISSUE_BODY" \
      --arg labels "${FAKE_ISSUE_LABELS:-}" \
      '{number:$number,title:$title,body:$body,state:"OPEN",labels:[$labels|split(",")[]|select(length>0)|{name:.}]}'
    ;;
  issue:edit:*) echo '{}' ;;
  api:repos/*/issues/*/sub_issues:*)
    if [[ -n "${FAKE_FULL_EPIC:-}" && "${2:-}" == "repos/$REPO/issues/$FAKE_FULL_EPIC/sub_issues" ]]; then
      printf 'simulated 422 for full epic #%s\n' "$FAKE_FULL_EPIC" >> "$FAKE_GH_LOG"
      exit 22
    fi
    [[ "${FAKE_LINK_FAIL:-0}" != 1 ]] || exit 19
    echo '{}'
    ;;
  api:repos/*/issues/*:*)
    echo 99001
    ;;
  api:graphql:*)
    exit 1
    ;;
  *)
    echo "unexpected fake gh call: $*" >&2
    exit 43
    ;;
esac
GH
chmod +x "$test_tmp/bin/gh"
export PATH="$test_tmp/bin:$PATH"
export AGENT_HOME="$test_tmp/agent" ZF_REPO_DIR="$REPO_ROOT"
export ZF_REPO=example-maintainer/example-repo REPO=example-maintainer/example-repo
export MODEL_POLICY_FILE="$test_tmp/model-policy.json"
printf '%s\n' '{"switches":{"roadmap-order":false}}' > "$MODEL_POLICY_FILE"
export ZF_ROADMAP_TREE_CACHE_FILE="$test_tmp/tree.json"
export FAKE_GH_LOG="$test_tmp/gh.log" FAKE_NEXT_ISSUE=99000
export FAKE_LABELS="$test_tmp/labels"
export FAKE_ISSUE_TITLE='Unrelated follow-up'
export FAKE_ISSUE_BODY='Observed evidence with no category keyword.'
: > "$FAKE_GH_LOG"
printf '%s\n' needs-triage pipeline-system > "$FAKE_LABELS"

source "$SCRIPT_DIR/lib.sh"

: > "$FAKE_GH_LOG"
if guarded_write gh issue create --repo "$REPO" --title 'Empty body must be refused' --body "" \
  > "$test_tmp/empty-body.stdout" 2> "$test_tmp/empty-body.stderr"; then
  empty_body_rc=0
else
  empty_body_rc=$?
fi
assert_eq 'empty --body is refused with rc 64' 64 "$empty_body_rc"
assert_eq 'empty --body does not call gh issue create' false \
  "$(grep -Eq '^issue create ' "$FAKE_GH_LOG" && echo true || echo false)"

printf ' \t\n\r\n' > "$test_tmp/whitespace-body.md"
: > "$FAKE_GH_LOG"
if guarded_write gh issue create --repo "$REPO" --title 'Whitespace body must be refused' \
  --body-file "$test_tmp/whitespace-body.md" > "$test_tmp/whitespace-body.stdout" \
  2> "$test_tmp/whitespace-body.stderr"; then
  whitespace_body_rc=0
else
  whitespace_body_rc=$?
fi
assert_eq 'whitespace-only --body-file is refused with rc 64' 64 "$whitespace_body_rc"
assert_eq 'whitespace-only --body-file does not call gh issue create' false \
  "$(grep -Eq '^issue create ' "$FAKE_GH_LOG" && echo true || echo false)"

FAKE_ISSUE_TITLE='Unrelated follow-up'
: > "$FAKE_GH_LOG"
created_url="$(guarded_write gh issue create --repo "$REPO" --title "$FAKE_ISSUE_TITLE" \
  --body "$FAKE_ISSUE_BODY" --label needs-triage)"
assert_eq 'guarded issue creation returns URL after linking' \
  'https://github.com/example-maintainer/example-repo/issues/99000' "$created_url"
assert_eq 'unmatched issue stays in triage without a roadmap parent' '' \
  "$(sed -nE 's#^api repos/example-maintainer/example-repo/issues/([0-9]+)/sub_issues .*#\1#p' "$FAKE_GH_LOG")"
assert_eq 'stage label stays on original create request' true \
  "$(grep -Eq '^issue create .*--label needs-triage' "$FAKE_GH_LOG" && echo true || echo false)"
assert_eq 'automatic issue creation adds the auto-filed label' true \
  "$(grep -Eq '^issue create .*--label auto-filed' "$FAKE_GH_LOG" && echo true || echo false)"
assert_eq 'the auto-filed label is created before issue creation' true \
  "$(grep -qx auto-filed "$FAKE_LABELS" && echo true || echo false)"
assert_eq 'placement does not edit stage labels' false \
  "$(grep -Fq -- '--add-label' "$FAKE_GH_LOG" && echo true || echo false)"

FAKE_NEXT_ISSUE=99001 FAKE_ISSUE_TITLE='Domain pack pipeline dispatch' \
  FAKE_ISSUE_BODY='Pipeline automation follow-up.' \
  FAKE_ISSUE_LABELS='pipeline-system,needs-triage'
export FAKE_NEXT_ISSUE FAKE_ISSUE_TITLE FAKE_ISSUE_BODY FAKE_ISSUE_LABELS
pipeline_url="$(guarded_write gh issue create --repo "$REPO" --title "$FAKE_ISSUE_TITLE" \
  --body "$FAKE_ISSUE_BODY" --label pipeline-system,needs-triage)"
assert_eq 'pipeline issue create returns URL after linking' \
  'https://github.com/example-maintainer/example-repo/issues/99001' "$pipeline_url"
assert_eq 'pipeline-system label selects pipeline roadmap theme' true \
  "$(grep -Fq 'repos/example-maintainer/example-repo/issues/912/sub_issues' "$FAKE_GH_LOG" && echo true || echo false)"

cat > "$test_tmp/topic-tree.json" <<'JSON'
{"roots":[{"number":900,"title":"the product Roadmap","state":"OPEN","labels":["roadmap"],"children":[{"number":901,"title":"Enterprise capability","state":"OPEN","labels":["roadmap-theme"],"children":[{"number":8291,"title":"Enterprise capability map 大企业平台能力","state":"OPEN","labels":["roadmap-epic"],"children":[]},{"number":1938,"title":"模型名称与实际能力一致","state":"OPEN","labels":["roadmap-epic"],"children":[]},{"number":3311,"title":"账号会话恢复流程","state":"OPEN","labels":["roadmap-epic"],"children":[]}]},{"number":910,"title":"Authorization features","state":"OPEN","labels":["roadmap-theme"],"children":[{"number":6709,"title":"确认卡加以后都批准","state":"OPEN","labels":["roadmap-epic"],"children":[]},{"number":3293,"title":"渠道对话记录和账号状态可回查","state":"OPEN","labels":["roadmap-epic"],"children":[]}]},{"number":920,"title":"Other requests","state":"OPEN","labels":["roadmap-theme"],"children":[{"number":9990,"title":"待归类","state":"OPEN","labels":["roadmap-epic"],"children":[]}]}]}]}
JSON

assert_topic_route() {
  local name="$1" number="$2" title="$3" body="$4" expected_parent="$5" issue_url actual_parent
  ZF_ROADMAP_TREE_CACHE_FILE="$test_tmp/topic-tree.json"
  FAKE_NEXT_ISSUE="$number" FAKE_ISSUE_TITLE="$title" FAKE_ISSUE_BODY="$body"
  FAKE_ISSUE_LABELS=needs-triage FAKE_LINK_FAIL=0
  export ZF_ROADMAP_TREE_CACHE_FILE FAKE_NEXT_ISSUE FAKE_ISSUE_TITLE FAKE_ISSUE_BODY FAKE_ISSUE_LABELS FAKE_LINK_FAIL
  : > "$FAKE_GH_LOG"
  issue_url="$(guarded_write gh issue create --repo "$REPO" --title "$title" --body "$body")"
  assert_eq "$name is created" "https://github.com/example-maintainer/example-repo/issues/$number" "$issue_url"
  assert_eq "$name keeps the triage label" true "$(grep -Eq '^issue create .*--label needs-triage' "$FAKE_GH_LOG" && echo true || echo false)"
  actual_parent="$(sed -nE 's#^api repos/example-maintainer/example-repo/issues/([0-9]+)/sub_issues .*#\1#p' "$FAKE_GH_LOG")"
  assert_eq "$name parent route" "$expected_parent" "$actual_parent"
}

assert_topic_route 'enterprise platform ticket ignores unrelated model text' 99101 '大企业平台能力的先后' '模型名称与实际能力一致' 8291
assert_topic_route 'approval ticket ignores unrelated channel text' 99102 '确认卡加「以后都批准」' '渠道对话记录和账号状态可回查' 6709
assert_topic_route 'map child follows its topic despite account text in the body' 99103 'Map child: 大企业平台能力的先后' '账号会话恢复流程' 8291
assert_topic_route 'model text in the body does not parent a generic ticket' 99104 'Fresh cleanup request' '模型名称与实际能力一致' ''
assert_topic_route 'channel text in the body does not parent a generic ticket' 99105 'New follow-up request' '渠道对话记录和账号状态可回查' ''

cat > "$test_tmp/capacity-tree.json" <<'JSON'
{"roots":[{"number":900,"title":"the product Roadmap","state":"OPEN","labels":["roadmap"],"children":[{"number":3279,"title":"开发流水线与运行稳定","state":"OPEN","milestone":"开发流水线与运行稳定","labels":["roadmap-theme"],"children":[{"number":3304,"title":"生产异常被发现并有人修复","state":"OPEN","labels":["roadmap-epic"],"children_total":100,"children":[]},{"number":3309,"title":"生产日志异常自动诊断","state":"OPEN","labels":["roadmap-epic"],"children_total":15,"children":[]}]}]}]}
JSON
ZF_ROADMAP_TREE_CACHE_FILE="$test_tmp/capacity-tree.json"
FAKE_NEXT_ISSUE=99006 FAKE_ISSUE_TITLE='生产日志异常 new metric' \
  FAKE_ISSUE_BODY='Production log anomaly evidence.' FAKE_ISSUE_LABELS=needs-triage FAKE_FULL_EPIC=3304
export ZF_ROADMAP_TREE_CACHE_FILE FAKE_NEXT_ISSUE FAKE_ISSUE_TITLE FAKE_ISSUE_BODY FAKE_ISSUE_LABELS FAKE_FULL_EPIC
: > "$FAKE_GH_LOG"
capacity_url="$(guarded_write gh issue create --repo "$REPO" --title "$FAKE_ISSUE_TITLE" --body "$FAKE_ISSUE_BODY")"
assert_eq 'full matching epic uses a non-full sibling before issue creation' \
  'https://github.com/example-maintainer/example-repo/issues/99006' "$capacity_url"
assert_eq 'full matching epic was skipped before the sub-issues API 422' false \
  "$(grep -Fq 'simulated 422 for full epic #3304' "$FAKE_GH_LOG" && echo true || echo false)"
assert_eq 'full epic case places the issue in its existing theme sibling' true \
  "$(grep -Fq 'repos/example-maintainer/example-repo/issues/3309/sub_issues' "$FAKE_GH_LOG" && echo true || echo false)"
assert_eq 'creation without an existing stage label starts in triage' true \
  "$(grep -Eq '^issue create .*--label needs-triage' "$FAKE_GH_LOG" && echo true || echo false)"

ZF_ROADMAP_TREE_CACHE_FILE="$test_tmp/tree.json"
FAKE_NEXT_ISSUE=99007 FAKE_ISSUE_TITLE='Domain pack invoice export after 422' \
  FAKE_ISSUE_BODY='Placement will be rejected by the fake sub-issues API.' \
  FAKE_ISSUE_LABELS=needs-triage FAKE_FULL_EPIC=902
export ZF_ROADMAP_TREE_CACHE_FILE FAKE_NEXT_ISSUE FAKE_ISSUE_TITLE FAKE_ISSUE_BODY FAKE_ISSUE_LABELS FAKE_FULL_EPIC
: > "$FAKE_GH_LOG"
if guarded_write gh issue create --repo "$REPO" --title "$FAKE_ISSUE_TITLE" --body "$FAKE_ISSUE_BODY" \
  2> "$test_tmp/placement-422.log"; then
  echo 'expected the simulated sub-issues 422 to report placement failure' >&2
  exit 1
fi
assert_eq 'fake sub-issues API returned a 422 after creating the issue' true \
  "$(grep -Fq 'simulated 422 for full epic #902' "$FAKE_GH_LOG" && echo true || echo false)"
assert_eq 'placement failure leaves a created issue with needs-triage' true \
  "$(grep -Eq '^issue create .*--label needs-triage' "$FAKE_GH_LOG" && echo true || echo false)"

FAKE_FULL_EPIC=''
export FAKE_FULL_EPIC
FAKE_ISSUE_LABELS=''
export FAKE_ISSUE_LABELS

FAKE_NEXT_ISSUE=99005 FAKE_ISSUE_TITLE='Demo wrapper-created follow-up' \
  FAKE_ISSUE_BODY='Body routed before demo-account lookup.'
export FAKE_NEXT_ISSUE FAKE_ISSUE_TITLE FAKE_ISSUE_BODY
: > "$FAKE_GH_LOG"

FAKE_ISSUE_TITLE='Domain pack' FAKE_ISSUE_BODY='Evidence' FAKE_ISSUE_LABELS=needs-triage
export FAKE_ISSUE_TITLE FAKE_ISSUE_BODY FAKE_ISSUE_LABELS
FAKE_NEXT_ISSUE=99003 FAKE_LINK_FAIL=1
export FAKE_NEXT_ISSUE FAKE_LINK_FAIL
: > "$FAKE_GH_LOG"
if guarded_write gh issue create --repo "$REPO" --title 'Domain pack' --body 'Evidence' 2> "$test_tmp/link-failure.log"; then
  echo 'not ok - parent-link failure must fail issue creation' >&2
  exit 1
fi
assert_eq 'link failure names the already-created issue' true \
  "$(grep -Fq 'issue #99003 was created' "$test_tmp/link-failure.log" && echo true || echo false)"
printf '%s\n' '{"switches":{"roadmap-order":true}}' > "$MODEL_POLICY_FILE"
FAKE_LINK_FAIL=0
roadmap_ensure_issue_parent 99003 needs-triage \
  '{"number":99003,"title":"Domain pack","body":"Evidence","state":"OPEN","labels":[{"name":"needs-triage"}]}'
assert_eq 'failed attach recovers through existing issue-parent helper' true \
  "$(grep -Fq 'api repos/example-maintainer/example-repo/issues/902/sub_issues --method POST' "$FAKE_GH_LOG" && echo true || echo false)"
assert_eq 'attach recovery does not create duplicate issue' 1 \
  "$(grep -c '^issue create ' "$FAKE_GH_LOG")"

unset ZF_ROADMAP_TREE_CACHE_FILE
FAKE_LINK_FAIL=0 FAKE_NEXT_ISSUE=99004
export FAKE_LINK_FAIL FAKE_NEXT_ISSUE
: > "$FAKE_GH_LOG"
if guarded_write gh issue create --repo "$REPO" --title 'No tree' --body 'Evidence' 2> "$test_tmp/no-tree.log"; then
  echo 'not ok - missing roadmap tree must refuse issue creation' >&2
  exit 1
fi
assert_eq 'missing tree is reported before issue creation' false \
  "$(grep -Fq 'issue:create' "$FAKE_GH_LOG" && echo true || echo false)"
assert_eq 'missing tree refusal is explicit' true \
  "$(grep -Fq 'refusing to create' "$test_tmp/no-tree.log" && echo true || echo false)"

# roadmap.body_check_command (night.json): a ready-for-agent feature ticket's body must pass the target's check.
body_check_log="$test_tmp/body-check.log" body_cfg="$test_tmp/body-check-config" body_none="$test_tmp/body-check-none"
mkdir -p "$body_cfg" "$body_none"
cat > "$test_tmp/body-check.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$body_check_log"
grep -q 'delivery form' "\$1" && exit 0
echo 'R1: missing delivery form'
exit 1
SH
chmod +x "$test_tmp/body-check.sh"
printf '{"roadmap":{"body_check_command":"%s"}}\n' "$test_tmp/body-check.sh" > "$body_cfg/night.json"
printf 'Feature body without the required section.\n' > "$test_tmp/feature-bad.md"
printf 'Feature body.\n\ndelivery form: Agent tool and /chat/ UI block.\n' > "$test_tmp/feature-good.md"
ZF_ROADMAP_TREE_CACHE_FILE="$test_tmp/tree.json"
export ZF_ROADMAP_TREE_CACHE_FILE FAKE_LINK_FAIL=0

: > "$body_check_log"; : > "$FAKE_GH_LOG"
if ZF_CONFIG_ROOT="$body_cfg" guarded_write gh issue create --repo "$REPO" --title 'Agent feature' \
  --body-file "$test_tmp/feature-bad.md" --label ready-for-agent,enhancement \
  > "$test_tmp/body-check-refused.stdout" 2> "$test_tmp/body-check-refused.stderr"; then
  body_refused_rc=0
else
  body_refused_rc=$?
fi
assert_eq 'ready-for-agent feature whose check exits 1 is refused with rc 64' 64 "$body_refused_rc"
assert_eq 'refused feature ticket does not call gh issue create' false \
  "$(grep -Eq '^issue create ' "$FAKE_GH_LOG" && echo true || echo false)"
assert_eq 'refusal prints the check output' true \
  "$(grep -Fq 'R1: missing delivery form' "$test_tmp/body-check-refused.stderr" && echo true || echo false)"
assert_eq 'check ran on the body file' true \
  "$(grep -Fq "$test_tmp/feature-bad.md" "$body_check_log" && echo true || echo false)"

: > "$body_check_log"; : > "$FAKE_GH_LOG"
FAKE_NEXT_ISSUE=99020 export FAKE_NEXT_ISSUE
body_ok_url="$(ZF_CONFIG_ROOT="$body_cfg" guarded_write gh issue create --repo "$REPO" --title 'Domain pack Agent feature' \
  --body-file "$test_tmp/feature-good.md" --label ready-for-agent,enhancement)"
assert_eq 'ready-for-agent feature whose check exits 0 is created' \
  'https://github.com/example-maintainer/example-repo/issues/99020' "$body_ok_url"

: > "$body_check_log"; : > "$FAKE_GH_LOG"
FAKE_NEXT_ISSUE=99021 export FAKE_NEXT_ISSUE
bug_url="$(ZF_CONFIG_ROOT="$body_cfg" guarded_write gh issue create --repo "$REPO" --title 'Domain pack Agent bug' \
  --body-file "$test_tmp/feature-bad.md" --label ready-for-agent,bug)"
assert_eq 'bug-labelled ticket skips the body check and is created' \
  'https://github.com/example-maintainer/example-repo/issues/99021' "$bug_url"
assert_eq 'bug-labelled ticket does not run the check' 0 "$(wc -l < "$body_check_log")"

: > "$body_check_log"; : > "$FAKE_GH_LOG"
FAKE_NEXT_ISSUE=99022 export FAKE_NEXT_ISSUE
none_url="$(ZF_CONFIG_ROOT="$body_none" guarded_write gh issue create --repo "$REPO" --title 'Domain pack Agent feature' \
  --body-file "$test_tmp/feature-bad.md" --label ready-for-agent,enhancement)"
assert_eq 'without roadmap.body_check_command nothing runs and the ticket is created' \
  'https://github.com/example-maintainer/example-repo/issues/99022' "$none_url"
assert_eq 'without roadmap.body_check_command the check does not run' 0 "$(wc -l < "$body_check_log")"
# 597: engine incident tickets (ci-checks.sh:303 shape: repeated --label, inline --body) skip the target body check.
: > "$body_check_log"; : > "$FAKE_GH_LOG"
FAKE_NEXT_ISSUE=99023 export FAKE_NEXT_ISSUE
incident_url="$(ZF_CONFIG_ROOT="$body_cfg" guarded_write gh issue create --repo "$REPO" --title 'Automated dispatch rule validation incident' \
  --label pipeline-system --label ready-for-agent --body 'Incident body without feature sections.')"
assert_eq 'ci-checks incident shape (pipeline-system, inline body) is created under a refusing check' \
  'https://github.com/example-maintainer/example-repo/issues/99023' "$incident_url"
assert_eq 'pipeline-system ticket does not run the check' 0 "$(wc -l < "$body_check_log")"
unset ZF_ROADMAP_TREE_CACHE_FILE

echo 'roadmap-issue-create.test.sh: PASS'
