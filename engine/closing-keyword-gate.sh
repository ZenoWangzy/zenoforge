#!/usr/bin/env bash
# Refuse GitHub closing keywords that would close an issue before its recorded
# real-user-path acceptance. `--sweep-closed` is deliberately report-only.
set -euo pipefail

REPO="${REPO:-${GITHUB_REPOSITORY:-${ZF_REPO:?ZF_REPO is not set}}}"
EXCLUDED_SWEEP_ISSUES=(1443 1449)

usage() {
  cat <<'EOF'
Usage:
  closing-keyword-gate.sh --body-file <path> [--commits-file <path>]
  closing-keyword-gate.sh --sweep-closed
EOF
}

BODY_FILE=""
COMMITS_FILE=""
TEXT_FILES=()
MODE=""
case "${1:-}" in
  --body-file)
    [ "$#" -ge 2 ] || { usage >&2; exit 2; }
    BODY_FILE="$2"
    MODE="gate"
    shift 2
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --commits-file)
          [ "$#" -eq 2 ] && [ -z "$COMMITS_FILE" ] || { usage >&2; exit 2; }
          COMMITS_FILE="$2"
          shift 2
          ;;
        *)
          usage >&2
          exit 2
          ;;
      esac
    done
    ;;
  --sweep-closed)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    MODE="sweep"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

if [ "$MODE" = "gate" ] && [ ! -r "$BODY_FILE" ]; then
  echo "closing keyword gate: cannot read PR body file: $BODY_FILE" >&2
  exit 2
fi
if [ "$MODE" = "gate" ] && [ -n "$COMMITS_FILE" ] && [ ! -r "$COMMITS_FILE" ]; then
  echo "closing keyword gate: cannot read PR commit messages file: $COMMITS_FILE" >&2
  exit 2
fi
if [ "$MODE" = "gate" ]; then
  TEXT_FILES=("$BODY_FILE")
  [ -n "$COMMITS_FILE" ] && TEXT_FILES+=("$COMMITS_FILE")
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

issue_json_path() {
  printf '%s/issue-%s.json' "$TMP_DIR" "$1"
}

fetch_issue() {
  local issue="$1" issue_repo="${2:-$REPO}" issue_json
  issue_json="$(issue_json_path "$issue")"
  if ! gh issue view "$issue" --repo "$issue_repo" --json title,labels,comments > "$issue_json"; then
    return 1
  fi
  jq -e '(.labels | type == "array") and (.comments | type == "array")' "$issue_json" >/dev/null
}

issue_has_label() {
  local issue_json="$1" label="$2"
  jq -e --arg want_label "$label" '.labels | any(.[]?; .name == $want_label)' "$issue_json" >/dev/null
}

# A passing record has an explicit real-user-path acceptance result and the
# three required observations in one comment. Scanning comments newest-first
# makes a later FAIL/blocked record override an earlier PASS record.
has_recorded_passing_acceptance_evidence() {
  local issue_json="$1" comment
  local acceptance_header='(real[-[:space:]]user[-[:space:]]path[[:space:]]+acceptance|真实用户路径验收)[[:space:]]*[:：-]'
  local passing_header='(real[-[:space:]]user[-[:space:]]path[[:space:]]+acceptance)[[:space:]]*[:：-][[:space:]]*\*{0,2}(pass|passed)|真实用户路径验收[[:space:]]*[:：-][[:space:]]*\*{0,2}通过'

  while IFS= read -r -d '' comment; do
    if ! grep -Eiq "$acceptance_header" <<< "$comment"; then
      continue
    fi
    if ! grep -Eiq "$passing_header" <<< "$comment"; then
      return 1
    fi
    if ! grep -Eiq 'https?://' <<< "$comment"; then
      return 1
    fi
    if ! grep -Eiq 'DOM|visible|可见' <<< "$comment"; then
      return 1
    fi
    if ! grep -Eiq 'network|网络' <<< "$comment"; then
      return 1
    fi
    if ! grep -Eiq '(GET|POST|PUT|PATCH|DELETE)[[:space:]]+[^[:space:]]+.{0,160}(->|→)[[:space:]]*[1-5][0-9][0-9]' <<< "$comment"; then
      return 1
    fi
    if ! grep -Eiq 'same[-[:space:]]run|same[[:space:]]+run|同一次(运行|run)|本次运行' <<< "$comment"; then
      return 1
    fi
    return 0
  done < <(jq -jr '.comments | reverse[]? | ((.body // "") + "\u0000")' "$issue_json")

  return 1
}

body_declares_incomplete_work() {
  local incomplete_work_pattern
  incomplete_work_pattern='(^|[^[:alnum:]])(half|incomplete)([^[:alnum:]]|$)'
  incomplete_work_pattern+='|(^|[^[:alnum:]])partial[[:space:]]+(implementation|fix|work|support|solution|coverage)([^[:alnum:]]|$)'
  incomplete_work_pattern+='|(^|[^[:alnum:]])partly[[:space:]]+(implemented|fixed|completed|addressed)([^[:alnum:]]|$)'
  incomplete_work_pattern+='|(work|implementation|fix|feature|support|solution|coverage)[[:space:]]+(is|remains)[[:space:]]+partial([^[:alnum:]]|$)'
  incomplete_work_pattern+='|does[[:space:]]+not[[:space:]]+(implement|address|complete|fix)[[:space:]]+(the[[:space:]]+)?(requested|issue|feature|requirement|scope)'
  incomplete_work_pattern+='|does[[:space:]]+not[[:space:]]+change[[:space:]]+(the[[:space:]]+)?(requested|target|expected|intended)[[:space:]]+(behavior|feature|scope)'
  incomplete_work_pattern+='|follow(ing)?[[:space:]]+merged|一半'
  incomplete_work_pattern+='|仅(完成|实现|修复|处理)(了)?(一部分|部分(工作|内容|需求|功能)?)'
  incomplete_work_pattern+='|只(完成|实现|修复|处理)(了)?(一部分|部分(工作|内容|需求|功能)?)'
  incomplete_work_pattern+='|(没有|尚未|未能|未)(完成|实现|修复|处理)(本次|该|此)?(需求|要求|问题|功能|工作|目标)'
  incomplete_work_pattern+='|后续.*(合并|部署|验收)'
  grep -Eiq "$incomplete_work_pattern" "$BODY_FILE"
}

closing_issue_numbers() {
  # Same GitHub reference grammar as lib.sh's scrub_closing_keywords(), but
  # retain repository plus issue number so a qualified reference cannot evade
  # the live evidence read.
  local text_file
  for text_file in "${TEXT_FILES[@]}"; do
    REPO="$REPO" perl -CSD -ne '
      while (/\b(close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b (:?\s*)
        (?:
          https?:\/\/github\.com\/([\w.-]+\/[\w.-]+)\/(?:issues|pull)\/(\d+)
          | ([\w.-]+\/[\w.-]+) \# (\d+)
          | \# (\d+)
        )/gxi) {
        my ($repo, $num) = $3 ? ($3, $4) : $5 ? ($5, $6) : ($ENV{REPO}, $7);
        print "$repo\t$num\n";
      }
    ' "$text_file"
  done | sort -u || true
}

run_gate() {
  local issue issue_repo issue_json failures=0 incomplete=0
  local issues
  issues="$(closing_issue_numbers)"
  if [ -z "$issues" ]; then
    echo "closing keyword evidence gate passed: no closing keywords found"
    return 0
  fi

  if body_declares_incomplete_work; then
    incomplete=1
  fi

  while IFS=$'\t' read -r issue_repo issue; do
    [ -n "$issue" ] || continue
    issue_json="$(issue_json_path "$issue")"
    if ! fetch_issue "$issue" "$issue_repo"; then
      echo "#$issue closing keyword refused: cannot read labels and acceptance evidence; use \`Refs #$issue\` until verification is available." >&2
      failures=1
      continue
    fi

    if issue_has_label "$issue_json" on-hold; then
      echo "#$issue closing keyword refused: issue is labelled on-hold; its external blocker remains. Use \`Refs #$issue\` instead." >&2
      failures=1
    fi

    if issue_has_label "$issue_json" evidence-gate && ! has_recorded_passing_acceptance_evidence "$issue_json"; then
      echo "#$issue closing keyword refused: issue is labelled evidence-gate but lacks recorded passing real-user-path acceptance evidence (PASS record with URL, DOM/visible state, same-run network method/status). Use \`Refs #$issue\` until that evidence is recorded." >&2
      failures=1
    fi

    if [ "$incomplete" -eq 1 ]; then
      echo "#$issue closing keyword refused: PR body declares incomplete work (half/partial/incomplete/does not change/follow merged). Use \`Refs #$issue\` instead." >&2
      failures=1
    fi
  done <<< "$issues"

  if [ "$failures" -ne 0 ]; then
    return 1
  fi
  echo "closing keyword evidence gate passed"
}

list_closed_numbers_with_label() {
  local label="$1" response
  if ! response="$(gh issue list --repo "$REPO" --state closed --label "$label" --limit 1000 --json number 2>&1)"; then
    echo "closed evidence sweep: cannot list CLOSED issues labelled $label: $response" >&2
    return 1
  fi
  if ! jq -r '.[]?.number' <<< "$response"; then
    echo "closed evidence sweep: invalid issue list for label $label" >&2
    return 1
  fi
}

is_excluded_from_sweep() {
  local issue="$1" excluded
  for excluded in "${EXCLUDED_SWEEP_ISSUES[@]}"; do
    [ "$issue" = "$excluded" ] && return 0
  done
  return 1
}

run_sweep() {
  local on_hold_numbers evidence_gate_numbers issues issue issue_json title labels found=0
  if ! on_hold_numbers="$(list_closed_numbers_with_label on-hold)"; then
    return 1
  fi
  if ! evidence_gate_numbers="$(list_closed_numbers_with_label evidence-gate)"; then
    return 1
  fi
  issues="$(printf '%s\n%s\n' "$on_hold_numbers" "$evidence_gate_numbers" | awk 'NF' | sort -n -u)"

  while IFS= read -r issue; do
    [ -n "$issue" ] || continue
    if is_excluded_from_sweep "$issue"; then
      continue
    fi
    issue_json="$(issue_json_path "$issue")"
    if ! fetch_issue "$issue"; then
      echo "closed evidence sweep: cannot inspect #$issue; refusing to report it verified" >&2
      return 1
    fi
    if ! issue_has_label "$issue_json" on-hold && ! issue_has_label "$issue_json" evidence-gate; then
      continue
    fi
    if has_recorded_passing_acceptance_evidence "$issue_json"; then
      continue
    fi
    title="$(jq -r '.title // "(untitled)"' "$issue_json")"
    labels="$(jq -r '[.labels[]?.name] | join(", ")' "$issue_json")"
    echo "CLOSED UNVERIFIED #$issue $title [labels: $labels] — no recorded passing real-user-path acceptance evidence"
    found=1
  done <<< "$issues"

  if [ "$found" -eq 0 ]; then
    echo "No CLOSED on-hold/evidence-gate issues without recorded passing real-user-path acceptance evidence."
  fi
}

case "$MODE" in
  gate) run_gate ;;
  sweep) run_sweep ;;
esac
