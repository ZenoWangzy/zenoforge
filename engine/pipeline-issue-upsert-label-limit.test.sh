#!/usr/bin/env bash
set -euo pipefail

source "$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin"
# gh label list is GraphQL: above --limit 100 the stub answers with the
# per-query resource-limit refusal, below it the label page succeeds.
cat > "$tmp/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
case "${1:-}:${2:-}" in
  label:list)
    limit=""
    previous=""
    for arg in "$@"; do
      [[ "$previous" == --limit ]] && limit="$arg"
      previous="$arg"
    done
    if [[ -z "$limit" || ! "$limit" =~ ^[0-9]+$ || "$limit" -gt 100 ]]; then
      echo 'gh: Resource limits for this query exceeded.' >&2
      echo 'Resource limits for this query exceeded.' >&2
      echo 'Resource limits for this query exceeded.' >&2
      exit 1
    fi
    cat "$FAKE_LABELS"
    ;;
  label:create)
    label="${3:?}"
    grep -qx -- "$label" "$FAKE_LABELS" || printf '%s\n' "$label" >> "$FAKE_LABELS"
    ;;
  api:--method)
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
export FAKE_NEXT_NUMBER="$tmp/next-number"
export FAKE_LABELS="$tmp/labels"
printf '[{"number":4999,"title":"Unrelated open issue","body":"no class marker","state":"OPEN","labels":[{"name":"pipeline-system"}]}]\n' > "$FAKE_ISSUES"
: > "$FAKE_LABELS"
printf '%s\n' pipeline-system ready-for-agent > "$FAKE_LABELS"
: > "$FAKE_GH_LOG"
printf '5001\n' > "$FAKE_NEXT_NUMBER"
printf 'label page above the limit\n' > "$tmp/first.md"

ZF_ISSUE_LOCK_DIR="$tmp/locks" ZF_GH_REPO=test/repo \
  bash "$SCRIPT_DIR/pipeline-issue-upsert.sh" \
  --class label-limit-refusal --title 'Label read above the query limit' \
  --body-file "$tmp/first.md" > "$tmp/upsert.out" 2> "$tmp/upsert.err"

jq -e --arg marker '<!-- vecta-incident-class:label-limit-refusal -->' \
  '[.[] | select((.body // "") | contains($marker))][0]
   | ([.labels[].name] | sort) == ["auto-filed","pipeline-system","ready-for-agent"]' "$FAKE_ISSUES" >/dev/null
grep -q '^created https://github.com/test/repo/issues/5001 for class label-limit-refusal$' "$tmp/upsert.out"

# The label read paged down: one refusal at --limit 200, one retry at --limit 100.
# Two reads for the downshift, one for the auto-filed marker at issue creation.
[[ "$(grep -c '^label list ' "$FAKE_GH_LOG")" == 3 ]]
first_label_call="$(grep '^label list ' "$FAKE_GH_LOG" | sed -n '1p')"
second_label_call="$(grep '^label list ' "$FAKE_GH_LOG" | sed -n '2p')"
[[ "$first_label_call" == *'--limit 200'* ]]
[[ "$first_label_call" != *'--limit 100'* ]]
[[ "$second_label_call" == *'--limit 100'* ]]

# One line for the downshift; none of the per-path refusal spam reaches the log.
[[ "$(grep -c 'Resource limits for this query exceeded' "$tmp/upsert.err")" == 0 ]]
[[ "$(grep -c 'gh query resource limit' "$tmp/upsert.err")" == 1 ]]

# A later upsert for the same open class comments instead of creating, and the
# bounded label read still succeeds.
printf 'same class after downshift\n' > "$tmp/repeat.md"
ZF_ISSUE_LOCK_DIR="$tmp/locks" ZF_GH_REPO=test/repo \
  bash "$SCRIPT_DIR/pipeline-issue-upsert.sh" \
  --class label-limit-refusal --title 'Label read above the query limit, again' \
  --body-file "$tmp/repeat.md" > "$tmp/repeat.out" 2> "$tmp/repeat.err"
grep -q '^commented issue #5001 for class label-limit-refusal' "$tmp/repeat.out"
[[ "$(jq 'length' "$FAKE_ISSUES")" == 2 ]]
[[ "$(grep -c 'Resource limits for this query exceeded' "$tmp/repeat.err")" == 0 ]]
echo 'ok - label list above the query limit halves once, logs one line, and the upsert still lands'
