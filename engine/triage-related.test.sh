#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
export ZF_REPO_DIR="$SCRIPT_DIR/.."
source "$SCRIPT_DIR/lib.sh"
REPO="$ZF_REPO"

FAKE_BIN="$test_env_root/fake-bin"
mkdir -p "$FAKE_BIN"
export FAKE_GH_RELATIONS="$test_env_root/related-relations.json"
export FAKE_GH_CALLS="$test_env_root/related-gh-calls.log"
printf '[]\n' > "$FAKE_GH_RELATIONS"
: > "$FAKE_GH_CALLS"
cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = api ]; then
  shift
  method=GET endpoint="" related_id=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --method) method="$2"; shift 2 ;;
      -F) related_id="${2#issue_id=}"; shift 2 ;;
      repos/*) endpoint="$1"; shift ;;
      *) shift ;;
    esac
  done
  endpoint="${endpoint%%\?*}"
  if [[ "$endpoint" =~ /issues/([0-9]+)/relates_to$ ]]; then
    issue="${BASH_REMATCH[1]}"
    if [ "$method" = POST ]; then
      printf 'write %s %s\n' "$issue" "$related_id" >> "$FAKE_GH_CALLS"
      related_number="$((related_id / 10))"
      jq --argjson issue "$issue" --argjson id "$related_id" --argjson number "$related_number" \
        '. + [{issue:$issue,id:$id,number:$number}]' "$FAKE_GH_RELATIONS" > "$FAKE_GH_RELATIONS.tmp"
      mv "$FAKE_GH_RELATIONS.tmp" "$FAKE_GH_RELATIONS"
    else
      printf 'read-related %s\n' "$issue" >> "$FAKE_GH_CALLS"
      jq --argjson issue "$issue" '[.[] | select(.issue == $issue) | {id,number}]' "$FAKE_GH_RELATIONS"
    fi
  elif [[ "$endpoint" =~ /issues/([0-9]+)$ ]]; then
    issue="${BASH_REMATCH[1]}"
    jq -n --argjson issue "$issue" '{id:($issue * 10),number:$issue}'
  else
    echo "unexpected gh api call: $endpoint" >&2
    exit 2
  fi
  exit 0
fi
echo "unexpected gh call: $*" >&2
exit 2
EOF
chmod +x "$FAKE_BIN/gh"
export PATH="$FAKE_BIN:$PATH"

assert_eq() {
  local description="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    echo "not ok - $description (expected [$expected], got [$actual])" >&2
    exit 1
  fi
  echo "ok - $description"
}

if ! grep -Fq 'record_triage_related_issues "$N" "$RESULT"' "$SCRIPT_DIR/run-triage.sh"; then
  echo 'not ok - run-triage records the related issue group' >&2
  exit 1
fi
echo 'ok - run-triage records the related issue group'

ISSUE=1001
record_triage_related_issues "$ISSUE" '{"related":[],"suspected_shared_cause":"one shared regression"}'
assert_eq 'empty related list writes no tracker relations' 0 "$(jq 'length' "$FAKE_GH_RELATIONS")"
assert_eq 'empty related list makes no GitHub calls' 0 "$(wc -l < "$FAKE_GH_CALLS")"
assert_eq 'empty related list is stored in state' '[]' "$(jq -c '.related' "$(state_file "$ISSUE")")"

RESULT='{"related":[{"issue":2001,"reason":"same module"},{"issue":2002,"reason":"same failing check"}],"suspected_shared_cause":"shared retry handling"}'
record_triage_related_issues "$ISSUE" "$RESULT"
assert_eq 'two related issues write two tracker relations' 2 "$(jq 'length' "$FAKE_GH_RELATIONS")"
assert_eq 'state exposes both related issues and reasons' \
  '[{"issue":2001,"reason":"same module"},{"issue":2002,"reason":"same failing check"}]' \
  "$(jq -c '.related' "$(state_file "$ISSUE")")"
assert_eq 'state exposes the suspected shared cause' 'shared retry handling' \
  "$(jq -r '.suspected_shared_cause' "$(state_file "$ISSUE")")"

record_triage_related_issues "$ISSUE" "$RESULT"
assert_eq 'rerun does not duplicate either tracker relation' 2 "$(jq 'length' "$FAKE_GH_RELATIONS")"
assert_eq 'rerun reads existing native relations before writing' 4 "$(grep -c '^read-related ' "$FAKE_GH_CALLS")"
echo 'ALL PASS'
