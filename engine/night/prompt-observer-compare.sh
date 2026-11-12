#!/usr/bin/env bash
# Compare one prompt's observer scores strictly before and after its landing commit.
# usage: prompt-observer-compare.sh --prompt NAME --landing SHA --samples FILE
# FILE is JSONL, one {"unit":"id","ts":<epoch seconds>,"score":<0..1> or null} per line.
# A null score is unknown: it counts as neither a pass nor a failure.
# Every verdict is recorded; a regression also opens one deduplicated pipeline issue for the revert.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/../config.sh"

usage() {
  echo "usage: $0 --prompt name --landing sha --samples file" >&2
}

prompt=""
landing=""
samples=""
while (($#)); do
  case "$1" in
    --prompt) prompt="${2:-}"; shift 2 ;;
    --landing) landing="${2:-}"; shift 2 ;;
    --samples) samples="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 64 ;;
  esac
done

[[ "$prompt" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]] || { usage; exit 64; }
[[ -n "$landing" && -r "$samples" ]] || { usage; exit 64; }

min_samples="${PROMPT_OBSERVER_MIN_SAMPLES:-5}"
drop="${PROMPT_OBSERVER_DROP:-0.1}"
[[ "$min_samples" =~ ^[1-9][0-9]*$ && "$drop" =~ ^[0-9]+(\.[0-9]+)?$ ]] || {
  echo "prompt-observer-compare: invalid PROMPT_OBSERVER_MIN_SAMPLES or PROMPT_OBSERVER_DROP" >&2
  exit 64
}

repo_dir="${ZF_REPO_DIR:?ZF_REPO_DIR is not set}"
landing_sha="$(git -C "$repo_dir" rev-parse --verify --quiet "$landing^{commit}")" || {
  echo "prompt-observer-compare: unknown landing commit $landing" >&2
  exit 64
}
landing_ts="$(git -C "$repo_dir" show -s --format=%ct "$landing_sha")"

jq -e -s 'all(.[];
  (.unit | type) == "string"
  and (.ts | type) == "number"
  and (.score == null or ((.score | type) == "number" and .score >= 0 and .score <= 1)))' \
  "$samples" >/dev/null || {
  echo "prompt-observer-compare: invalid samples file" >&2
  exit 65
}

stats="$(jq -c -s --argjson at "$landing_ts" '
  [.[] | select(.score != null)] as $known
  | ([$known[] | select(.ts < $at) | .score]) as $before
  | ([$known[] | select(.ts > $at) | .score]) as $after
  | {
      before_n: ($before | length),
      before_mean: (if ($before | length) > 0 then ($before | add / length) else null end),
      after_n: ($after | length),
      after_mean: (if ($after | length) > 0 then ($after | add / length) else null end)
    }
' "$samples")"

verdict="$(jq -r --argjson min "$min_samples" --argjson drop "$drop" '
  if .before_n < $min or .after_n < $min then "insufficient-data"
  elif .after_mean < .before_mean - $drop then "regression"
  elif .after_mean > .before_mean + $drop then "improvement"
  else "no-change" end
' <<< "$stats")"

agent_home="${AGENT_HOME:-${ZF_HOME:-$HOME/.zenoforge}}"
report="${PROMPT_OBSERVER_REPORT:-$agent_home/night/prompt-observer-compare.jsonl}"
mkdir -p -- "$(dirname -- "$report")"
jq -c -n --arg prompt "$prompt" --arg landing "$landing_sha" --arg verdict "$verdict" \
  --argjson stats "$stats" '{prompt: $prompt, landing: $landing, verdict: $verdict} + $stats' >> "$report"
printf 'prompt=%s landing=%s verdict=%s\n' "$prompt" "${landing_sha:0:12}" "$verdict"

if [[ "$verdict" == regression ]]; then
  body="$(mktemp)"
  trap 'rm -f -- "${body:-}"' EXIT
  {
    printf 'Prompt `%s` scored lower after its change landed in `%s`.\n\n' "$prompt" "${landing_sha:0:12}"
    jq -r '"before: n=\(.before_n) mean=\(.before_mean)\nafter: n=\(.after_n) mean=\(.after_mean)"' <<< "$stats"
    printf '\nProposed action: revert commit `%s`.\n\nSamples:\n' "$landing_sha"
    jq -r -s --argjson at "$landing_ts" '.[] | select(.score != null and .ts != $at)
      | "- \(if .ts < $at then "before" else "after" end) \(.unit) score=\(.score)"' "$samples"
  } > "$body"
  # lib.sh derives ZF_REPO from origin; this script sources only config.sh, so derive it the same way.
  # The upsert helper reads ZF_REPO before it parses --repo, so the slug is also passed in the environment.
  repo_slug="${ZF_REPO:-$(git -C "$repo_dir" remote get-url origin 2>/dev/null | sed -E 's#^(git@[^:]+:|[a-z+]+://([^/@]+@)?[^/]+/)##; s#\.git$##' || true)}"
  [[ -n "$repo_slug" ]] || { echo "prompt-observer-compare: ZF_REPO is not set and origin has no owner/name; no revert issue" >&2; exit 64; }
  ZF_REPO="$repo_slug" bash "${PROMPT_OBSERVER_UPSERT:-$script_dir/../pipeline-issue-upsert.sh}" \
    --class "revert-$prompt-${landing_sha:0:12}" \
    --title "Revert prompt $prompt change at ${landing_sha:0:12}" \
    --body-file "$body" --lane pipeline-system --repo "$repo_slug"
fi
