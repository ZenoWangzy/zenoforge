#!/usr/bin/env bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
case "${1:-}:${2:-}" in
  api:--method)
    [[ "${FAKE_GH_LIST_FAIL:-0}" != 1 ]] || exit 42
    jq -c 'if length == 0 then [[]] else [.[0:1], .[1:]] end' "$FAKE_ISSUES"
    ;;
  issue:create)
    title=""; body_file=""; previous=""; labels=()
    for arg in "$@"; do
      case "$previous" in
        --title) title="$arg" ;;
        --body-file) body_file="$arg" ;;
        --label) labels+=("$arg") ;;
      esac
      previous="$arg"
    done
    [[ -n "$title" && -r "$body_file" ]]
    number="$(cat "$FAKE_NEXT_NUMBER")"
    printf '%s\n' "$((number + 1))" > "$FAKE_NEXT_NUMBER"
    labels_json="$(printf '%s\n' "${labels[@]}" | jq -R . | jq -s 'map({name:.})')"
    jq --argjson number "$number" --arg title "$title" --argjson labels "$labels_json" --rawfile body "$body_file" \
      '. + [{number:$number,title:$title,body:$body,state:"OPEN",labels:$labels}]' \
      "$FAKE_ISSUES" > "$FAKE_ISSUES.tmp"
    mv "$FAKE_ISSUES.tmp" "$FAKE_ISSUES"
    printf 'https://github.com/test/repo/issues/%s\n' "$number"
    ;;
  issue:comment)
    number="${3:-}"; body_file=""; previous=""
    for arg in "$@"; do
      [[ "$previous" != --body-file ]] || body_file="$arg"
      previous="$arg"
    done
    [[ "$number" =~ ^[1-9][0-9]*$ && -r "$body_file" ]]
    jq -cn --argjson number "$number" --rawfile body "$body_file" '{number:$number,body:$body}' \
      >> "$FAKE_COMMENTS"
    ;;
  issue:view)
    jq -ce --argjson number "${3:?}" '[.[] | select(.number == $number)][0]' "$FAKE_ISSUES"
    ;;
  issue:edit)
    echo '{}'
    ;;
  api:repos/*/issues/*/sub_issues)
    echo '{}'
    ;;
  api:repos/*/issues/*)
    echo 501000
    ;;
  *) echo "unexpected fake gh call: $*" >&2; exit 90 ;;
esac
FAKE_GH
chmod +x "$tmp/bin/gh"

export ZF_GH_REAL_CLI="$tmp/bin/gh"
export PATH="$SCRIPT_DIR/gh-shim:$tmp/bin:$PATH"
export FAKE_GH_LOG="$tmp/gh.log"
export FAKE_ISSUES="$tmp/issues.json"
export FAKE_COMMENTS="$tmp/comments.jsonl"
export FAKE_NEXT_NUMBER="$tmp/next-number"
printf '[{"number":4999,"title":"Unrelated open issue","body":"no class marker","state":"OPEN","labels":[{"name":"pipeline-system"}]}]\n' > "$FAKE_ISSUES"
: > "$FAKE_GH_LOG"
: > "$FAKE_COMMENTS"
printf '5001\n' > "$FAKE_NEXT_NUMBER"
printf 'first observation\n' > "$tmp/first.md"
printf 'same class, new run evidence\n' > "$tmp/repeat.md"
printf 'distinct class\n' > "$tmp/distinct.md"
printf 'first product red\n' > "$tmp/product.md"
printf 'repeat product red\n' > "$tmp/product-repeat.md"

run_upsert() {
  ZF_ISSUE_LOCK_DIR="$tmp/locks" ZF_GH_REPO=test/repo \
    bash "$SCRIPT_DIR/pipeline-issue-upsert.sh" "$@"
}
run_zf_upsert() {
  ZF_ISSUE_LOCK_DIR="$tmp/locks-example" ZF_GH_REPO=example-maintainer/example-repo \
    REPO=example-maintainer/example-repo ZF_ROADMAP_TREE_CACHE_FILE="$tmp/roadmap-tree.json" \
    MODEL_POLICY_FILE="$tmp/model-policy.json" \
    bash "$SCRIPT_DIR/pipeline-issue-upsert.sh" "$@"
}

if gh issue create --label 'needs-triage, pipeline-system' --title 'bypass attempt' --body-file "$tmp/first.md" 2>"$tmp/refusal"; then
  echo 'not ok - hand gh shim must reject direct pipeline-system issue creation' >&2
  exit 1
fi
grep -Fq 'pipeline-issue-upsert.sh' "$tmp/refusal"
[[ ! -s "$FAKE_GH_LOG" ]]
gh issue comment 4999 --body-file "$tmp/first.md"
grep -Fq 'issue comment 4999 --body-file' "$FAKE_GH_LOG"
: > "$FAKE_GH_LOG"
: > "$FAKE_COMMENTS"

run_upsert --class merge-health-probe --title 'Merge health probe fails' --body-file "$tmp/first.md"
jq -e 'length == 1 and any(.[0].labels[]; .name == "pipeline-system") and any(.[0].labels[]; .name == "ready-for-agent")' \
  <(jq '[.[] | select(.number == 5001)]' "$FAKE_ISSUES") >/dev/null
jq -e '[.[] | select(.number == 5001)][0].body | contains("<!-- zf-incident-class:merge-health-probe -->") and contains("<!-- zenoforge-agent-comment -->")' \
  "$FAKE_ISSUES" >/dev/null

run_upsert --class merge-health-probe --title 'Merge health probe fails again' --body-file "$tmp/repeat.md"
[[ "$(jq 'length' "$FAKE_ISSUES")" == 2 ]]
[[ "$(wc -l < "$FAKE_COMMENTS" | tr -d ' ')" == 1 ]]
jq -se '.[0] as $comment | $comment.number == 5001 and ($comment.body | contains("same class, new run evidence"))' \
  "$FAKE_COMMENTS" >/dev/null
[[ "$(grep -c '^issue create ' "$FAKE_GH_LOG")" == 1 ]]
grep -Fq 'api --method GET --paginate --slurp repos/test/repo/issues' "$FAKE_GH_LOG"
echo 'ok - second occurrence of an open class comments on the existing issue'

run_upsert --class dispatch-queue-timeout --title 'Dispatch queue timeout' --body-file "$tmp/distinct.md"
[[ "$(jq 'length' "$FAKE_ISSUES")" == 3 ]]
echo 'ok - distinct class creates its own issue'

cat > "$tmp/roadmap-tree.json" <<'JSON'
{"roots":[{"number":900,"title":"the product roadmap","state":"open","labels":["roadmap"],"children":[{"number":910,"title":"开发流水线与运行稳定","state":"open","milestone":"开发流水线与运行稳定","labels":["roadmap-theme"],"children":[{"number":912,"title":"Automation issue tracking","state":"open","labels":["roadmap-epic"],"children":[]}]},{"number":911,"title":"产品研发","state":"open","milestone":"产品研发","labels":["roadmap-theme"],"children":[{"number":913,"title":"待归类","state":"open","labels":["roadmap-epic"],"children":[]}]}]}]}
JSON
printf '{"switches":{"roadmap-order":false}}\n' > "$tmp/model-policy.json"
printf 'roadmap parent must be attached\n' > "$tmp/roadmap.md"
ZF_ISSUE_LOCK_DIR="$tmp/locks-example" ZF_GH_REPO=example-maintainer/example-repo \
  REPO=example-maintainer/example-repo ZF_ROADMAP_TREE_CACHE_FILE="$tmp/roadmap-tree.json" \
  MODEL_POLICY_FILE="$tmp/model-policy.json" FAKE_NEXT_NUMBER="$tmp/next-number" \
    bash "$SCRIPT_DIR/pipeline-issue-upsert.sh" --class roadmap-parent-regression \
      --title 'Pipeline helper issue parent regression' --body-file "$tmp/roadmap.md"
grep -Fq 'api repos/example-maintainer/example-repo/issues/912/sub_issues --method POST' "$FAKE_GH_LOG"
echo 'ok - the product pipeline-system issue is attached to the roadmap epic before upsert succeeds'

product_class=ci-example-pack-0123456789abcdef0123456789abcdef01234567
run_zf_upsert --lane product --class "$product_class" --title '主线 CI Example 测试失败' --body-file "$tmp/product.md"
product_issue="$(jq -r --arg marker "<!-- zf-incident-class:$product_class -->" '.[] | select((.body // "") | contains($marker)) | .number' "$FAKE_ISSUES")"
jq -e --argjson number "$product_issue" '.[] | select(.number==$number)
  | ([.labels[].name] | sort) == ["bug","needs-triage","priority:top"]' "$FAKE_ISSUES" >/dev/null
grep -Fq 'api repos/example-maintainer/example-repo/issues/913/sub_issues --method POST' "$FAKE_GH_LOG"
echo 'ok - product lane upsert attaches new issue to roadmap epic before success'
[[ "$(jq 'length' "$FAKE_ISSUES")" == 5 ]]
run_zf_upsert --lane product --class "$product_class" --title '主线 CI Example 测试再次失败' --body-file "$tmp/product-repeat.md"
[[ "$(jq 'length' "$FAKE_ISSUES")" == 5 ]]
[[ "$(wc -l < "$FAKE_COMMENTS" | tr -d ' ')" == 2 ]]
jq -se --argjson number "$product_issue" 'any(.[]; .number==$number and (.body | contains("repeat product red")))' \
  "$FAKE_COMMENTS" >/dev/null
jq -se --argjson number "$product_issue" 'any(.[]; .number==$number and (.body | contains("Repeated occurrence for product class")))' \
  "$FAKE_COMMENTS" >/dev/null
last_list_call="$(grep '^api ' "$FAKE_GH_LOG" | tail -n 1)"
[[ "$last_list_call" != *"labels=pipeline-system"* ]]
echo 'ok - product lane upserts bug, priority:top, needs-triage without pipeline-system label'

if FAKE_GH_LIST_FAIL=1 run_upsert --class unreadable-list --title 'Do not lose issue' --body-file "$tmp/distinct.md" >/dev/null 2>&1; then
  echo 'not ok - unreadable issue list must refuse creation' >&2
  exit 1
fi
[[ "$(jq 'length' "$FAKE_ISSUES")" == 5 ]]
[[ "$(grep -c '^issue create ' "$FAKE_GH_LOG")" == 4 ]]
echo 'ok - unreadable issue list fails closed without creating a duplicate'
