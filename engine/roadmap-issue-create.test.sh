#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
test_tmp="$TMPDIR/roadmap-issue-create"
mkdir -p "$test_tmp/bin" "$test_tmp/agent"
trap 'rm -rf -- "$test_tmp"' EXIT

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
export FAKE_ISSUE_TITLE='Unrelated follow-up'
export FAKE_ISSUE_BODY='Observed evidence with no category keyword.'
: > "$FAKE_GH_LOG"

source "$SCRIPT_DIR/lib.sh"
created_url="$(guarded_write gh issue create --repo "$REPO" --title "$FAKE_ISSUE_TITLE" \
  --body "$FAKE_ISSUE_BODY" --label needs-triage)"
assert_eq 'guarded issue creation returns URL after linking' \
  'https://github.com/example-maintainer/example-repo/issues/99000' "$created_url"
assert_eq 'unmatched issue uses existing 待归类 epic' true \
  "$(grep -Fq 'repos/example-maintainer/example-repo/issues/904/sub_issues' "$FAKE_GH_LOG" && echo true || echo false)"
assert_eq 'stage label stays on original create request' true \
  "$(grep -Eq '^issue create .*--label needs-triage' "$FAKE_GH_LOG" && echo true || echo false)"
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

cat > "$test_tmp/capacity-tree.json" <<'JSON'
{"roots":[{"number":900,"title":"the product Roadmap","state":"OPEN","labels":["roadmap"],"children":[{"number":3279,"title":"开发流水线与运行稳定","state":"OPEN","milestone":"开发流水线与运行稳定","labels":["roadmap-theme"],"children":[{"number":3304,"title":"生产异常被发现并有人修复","state":"OPEN","labels":["roadmap-epic"],"children_total":100,"children":[]},{"number":3309,"title":"自动派发与规则校验持续可靠","state":"OPEN","labels":["roadmap-epic"],"children_total":15,"children":[]}]}]}]}
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
FAKE_NEXT_ISSUE=99007 FAKE_ISSUE_TITLE='Unrelated invoice export after 422' \
  FAKE_ISSUE_BODY='Placement will be rejected by the fake sub-issues API.' \
  FAKE_ISSUE_LABELS=needs-triage FAKE_FULL_EPIC=904
export ZF_ROADMAP_TREE_CACHE_FILE FAKE_NEXT_ISSUE FAKE_ISSUE_TITLE FAKE_ISSUE_BODY FAKE_ISSUE_LABELS FAKE_FULL_EPIC
: > "$FAKE_GH_LOG"
if guarded_write gh issue create --repo "$REPO" --title "$FAKE_ISSUE_TITLE" --body "$FAKE_ISSUE_BODY" \
  2> "$test_tmp/placement-422.log"; then
  echo 'expected the simulated sub-issues 422 to report placement failure' >&2
  exit 1
fi
assert_eq 'fake sub-issues API returned a 422 after creating the issue' true \
  "$(grep -Fq 'simulated 422 for full epic #904' "$FAKE_GH_LOG" && echo true || echo false)"
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

FAKE_NEXT_ISSUE=99003 FAKE_LINK_FAIL=1
export FAKE_NEXT_ISSUE FAKE_LINK_FAIL
: > "$FAKE_GH_LOG"
if guarded_write gh issue create --repo "$REPO" --title 'Link failure' --body 'Evidence' 2> "$test_tmp/link-failure.log"; then
  echo 'not ok - parent-link failure must fail issue creation' >&2
  exit 1
fi
assert_eq 'link failure names the already-created issue' true \
  "$(grep -Fq 'issue #99003 was created' "$test_tmp/link-failure.log" && echo true || echo false)"
printf '%s\n' '{"switches":{"roadmap-order":true}}' > "$MODEL_POLICY_FILE"
FAKE_LINK_FAIL=0
roadmap_ensure_issue_parent 99003 needs-triage \
  '{"number":99003,"title":"Link failure","body":"Evidence","state":"OPEN","labels":[{"name":"needs-triage"}]}'
assert_eq 'failed attach recovers through existing issue-parent helper' true \
  "$(grep -Fq 'api repos/example-maintainer/example-repo/issues/904/sub_issues --method POST' "$FAKE_GH_LOG" && echo true || echo false)"
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

echo 'roadmap-issue-create.test.sh: PASS'
