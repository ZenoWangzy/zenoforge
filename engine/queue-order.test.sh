#!/usr/bin/env bash
# queue-order.test.sh — guards the queue's pickup order.
#
# Issue selection orders production incidents first, then maintainer-test issues,
# then ordinary priority:top, the batch STATE critical path (#4363), named
# implementation authors, other issues, and legacy tickets last; each band is
# oldest first. Pipeline-system lane priority remains outermost.
#
# Two reasons this test exists rather than a test driving the loops:
# run-tick.test.sh deliberately never lets the launcher reach
# issue-pipeline.sh (executing it dispatches systemd units and sends
# email — see that file's header), so the selection loops themselves have
# no functional harness. What IS cheaply testable is the ordering
# expression, and whether every selection site still uses it. So: one
# functional check on the expression, one static scan for regressions
# back to a bare `sort_by(.createdAt)`, plus a meta-test proving the
# scanner has teeth — the same shape as jq-arg-safety.test.sh.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FAILED=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok - $desc"
  else
    echo "not ok - $desc (expected [$expected], got [$actual])"
    FAILED=1
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "ok - $desc"
  else
    echo "not ok - $desc (expected to find [$needle])"
    FAILED=1
  fi
}

# Functional contract for the implementation queue. The static scan below
# separately keeps `priority:top` in every other selection query. The
# delay-cost bands (#4363, from the batch STATE via `critical-path`/`legacy`
# labels) put critical-path work ahead of features and legacy last, behind
# every other band regardless of age.
ORDER_JQ='sort_by([(if any(.labels[]?; .name == "bug") and any(.labels[]?; .name == "priority:top") then 0 else 1 end), (if any(.labels[]?; .name == "maintainer-test") then 0 else 1 end), (if any(.labels[]?; .name == "priority:top") then 0 else 1 end), (if any(.labels[]?; .name == "critical-path") then 0 else 1 end), (if (.author.login // "") == "hige1227" or (.author.login // "") == "1661253700-droid" then 0 else 1 end), (if any(.labels[]?; .name == "legacy") then 1 else 0 end), .createdAt]) | .[].number'

# --- functional: the ordering expression itself ------------------------------
#
# Fixture deliberately mixes the bands and lists them out of order, so
# a filter that merely preserved input order, or sorted on createdAt alone,
# cannot pass. 1500 is the newest issue in the queue and still sorts ahead of
# the named authors (critical path beats features); 1100 is the oldest and
# still sorts last (legacy loses to features even when older).
fixture='[
  {"number":1130,"createdAt":"2026-09-01T00:00:00Z","labels":[{"name":"ready-for-agent"}]},
  {"number":1442,"createdAt":"2026-09-13T00:00:00Z","labels":[{"name":"enhancement"},{"name":"priority:top"}]},
  {"number":1441,"createdAt":"2026-09-14T00:00:00Z","labels":[{"name":"enhancement"},{"name":"priority:top"},{"name":"maintainer-test"}]},
  {"number":1440,"createdAt":"2026-09-15T00:00:00Z","labels":[{"name":"bug"},{"name":"priority:top"}]},
  {"number":1330,"createdAt":"2026-09-16T00:00:00Z","labels":[{"name":"ready-for-agent"},{"name":"priority:top"}]},
  {"number":1200,"createdAt":"2026-09-05T00:00:00Z","labels":[{"name":"ready-for-agent"}]},
  {"number":1317,"createdAt":"2026-09-15T00:00:00Z","labels":[{"name":"priority:top"},{"name":"ready-for-agent"}]},
  {"number":1588,"createdAt":"2026-09-20T00:00:00Z","author":{"login":"1661253700-droid"},"labels":[{"name":"ready-for-agent"}]},
  {"number":1624,"createdAt":"2026-09-18T00:00:00Z","author":{"login":"hige1227"},"labels":[{"name":"ready-for-agent"}]},
  {"number":1500,"createdAt":"2026-09-25T00:00:00Z","labels":[{"name":"critical-path"},{"name":"ready-for-agent"}]},
  {"number":1100,"createdAt":"2026-08-01T00:00:00Z","labels":[{"name":"legacy"},{"name":"ready-for-agent"}]}
]'

# jq is the pipeline's own runtime dependency — lib.sh pipes through it in
# dozens of places — but it is not installed on every shell this repo gets
# checked out into, and a sibling test that assumes it simply dies there
# ("jq: command not found", sweep-merges.test.sh:195, 2026-09-16). Skip the
# two functional cases in that case instead of hard-failing, and keep the
# static scan below unconditional, so this file still earns its run on a
# machine without jq. Where jq exists — the pipeline host, by definition,
# since the pipeline cannot run without it — both cases execute.
if command -v jq >/dev/null 2>&1; then
  actual="$(printf '%s' "$fixture" | jq -r "$ORDER_JQ" | paste -sd, -)"
  assert_eq "production incidents first, maintainer-test before priority:top features, critical path before features, legacy last" "1440,1441,1442,1317,1330,1500,1624,1588,1130,1200,1100" "$actual"

  # An empty label list, or only unrelated labels, must still sort into the
  # non-priority band rather than erroring out.
  edge='[
    {"number":2,"createdAt":"2026-09-02T00:00:00Z","labels":[]},
    {"number":1,"createdAt":"2026-09-01T00:00:00Z","labels":[{"name":"bug"}]}
  ]'
  actual="$(printf '%s' "$edge" | jq -r "$ORDER_JQ" | paste -sd, -)"
  assert_eq "unlabelled and unrelated-label issues stay oldest-first" "1,2" "$actual"
else
  echo "skip - jq not installed; functional ordering cases not run"
fi

# --- static: every selection site uses it ------------------------------------
#
# Matches the `--json number,createdAt...` selection sites and requires each
# to request `labels` and band on `priority:top`. A site that regressed to
# `--json number,createdAt -q 'sort_by(.createdAt) ...'` fails here.
scan_file() {
  local path="$1" matches line line_number window
  # `|| true`: grep exits 1 on a file with no selection site at all, which
  # under this file's own `set -euo pipefail` would abort the scan (and,
  # inside the command substitution below, the whole test) before a single
  # assertion ran — silently, since the abort happens mid-assignment.
  matches="$(grep -n -- '--json number,createdAt' "$path" 2>/dev/null || true)"
  [ -n "$matches" ] || return 0
  printf '%s\n' "$matches" | while IFS= read -r line; do
    line_number="${line%%:*}"
    # shortcut: 40-line source window; parse query boundaries if selectors grow further.
    window="$(sed -n "${line_number},$((line_number + 40))p" "$path")"
    case "$line" in
      *'labels'*)
        case "$window" in
          *'priority:top'*) ;;
          *) echo "BAD $path $line" ;;
        esac
        ;;
      *) echo "BAD $path $line" ;;
    esac
  done
}

bad="$(for f in "$SCRIPT_DIR"/*.sh; do
  case "$f" in
    *.test.sh) continue ;;  # tests assert query strings; they are not selection sites
  esac
  scan_file "$f"
done)"
assert_eq "no selection site sorts on createdAt alone" "" "$bad"

triage_query="$(sed -n '/NEEDS_TRIAGE_JSON=/,/<<< "\$NEEDS_TRIAGE_JSON")/p' "$SCRIPT_DIR/issue-pipeline.sh")"
triage_selection="$(sed -n '/^elif ! NEEDS_TRIAGE_IDS=/,/<<< "\$NEEDS_TRIAGE_JSON")/p' "$SCRIPT_DIR/issue-pipeline.sh")"
assert_contains "triage intake fetches author and issue-origin fields" "$triage_query" '--json number,createdAt,labels,author,title,body'
assert_contains "triage intake puts maintainer-test ahead of feature priority" "$triage_selection" 'maintainer-test'
assert_contains "triage intake keeps production incidents ahead" "$triage_selection" 'bug'
assert_contains "triage intake bands the batch critical path (#4363)" "$triage_selection" 'critical-path'
assert_contains "triage intake sorts legacy tickets behind features (#4363)" "$triage_selection" 'legacy'
ready_measure_selection="$(sed -n '/^elif ! READY_MEASURE_IDS=/,/<<< "\$READY_MEASURE_JSON")/p' "$SCRIPT_DIR/issue-pipeline.sh")"
assert_contains "unmeasured triage queue ranks maintainer-test first" "$ready_measure_selection" 'maintainer-test'
assert_contains "unmeasured triage queue keeps production incidents first" "$ready_measure_selection" 'bug'
assert_contains "unmeasured triage queue bands the batch critical path (#4363)" "$ready_measure_selection" 'critical-path'
assert_contains "unmeasured triage queue sorts legacy tickets behind features (#4363)" "$ready_measure_selection" 'legacy'
maintainer_classifier="$(sed -n '/^MAINTAINER_TEST_CANDIDATE_FILTER=/,/^}/p' "$SCRIPT_DIR/lib.sh")"
assert_contains "maintainer classifier checks pipeline bot comments" "$maintainer_classifier" '.comments[]?'

# --- meta-test: the scanner catches a regression -----------------------------
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
cat >"$TMP_DIR/regressed.sh" <<'REGRESSED'
  for n in $(gh issue list --repo "$REPO" --label ready-for-agent --state open \
      --json number,createdAt -q 'sort_by(.createdAt) | .[].number'); do
REGRESSED
meta="$(scan_file "$TMP_DIR/regressed.sh" | wc -l | tr -d ' ')"
assert_eq "meta-test: a bare sort_by(.createdAt) selection site is caught" "1" "$meta"

if [ "$FAILED" -eq 0 ]; then
  echo "ALL PASSED"
else
  echo "FAILURES"
  exit 1
fi
