#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/../config.sh"

usage() {
  echo "usage: $0 --report jsonl-file" >&2
}

report=""
while (($#)); do
  case "$1" in
    --report) report="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 64 ;;
  esac
done
[[ -n "$report" && -r "$report" ]] || { usage; exit 64; }

threshold="${PROMPT_OBSERVER_LOW_SCORE_THRESHOLD:-0.5}"
required="${PROMPT_OBSERVER_LOW_SCORE_REPORTS:-3}"
[[ "$threshold" =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ && "$required" =~ ^[1-9][0-9]*$ ]] || {
  echo 'prompt-observer-low-score: invalid threshold or consecutive-report count' >&2
  exit 64
}

jq -e -s '
  length > 0
  and all(.[];
    type == "object"
    and (.stage | type == "string" and test("^[a-z0-9][a-z0-9-]{0,39}$"))
    and (.prompt | type == "string"
      and ((. == "engine/mac-autopilot/scheduler.d/dispatch-queue.sh")
        or (test("^engine/prompts/[A-Za-z0-9][A-Za-z0-9._/-]*\\.md$")
          and (split("/") | all(.[]; . != "" and . != "." and . != "..")))))
    and ((has("prompt_stage") | not) or (.prompt_stage | type == "string" and test("^[a-z0-9][a-z0-9-]{0,39}$")))
    and ((.prompt != "engine/mac-autopilot/scheduler.d/dispatch-queue.sh") or .prompt_stage == "implement")
    and ((has("prompt_version") | not) or (.prompt_version | type == "string" and test("^[0-9a-f]{64}$")))
    and (.sample_size | type == "number" and . >= 0 and floor == .)
    and (.unit_ids | type == "array"
      and all(.[]; type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}$")))
    and (
      ((.status // "scored") == "insufficient-data" and ((has("score") | not) or .score == null))
      or ((.status // "scored") == "scored"
        and (.score | type == "number" and . >= 0 and . <= 1)
        and (.unit_ids | length > 0))
    )
  )
  and ([.[] | [.stage, .prompt, (.prompt_version // "")]] as $keys | ($keys | unique | length) == ($keys | length))
' "$report" >/dev/null || {
  echo 'prompt-observer-low-score: invalid report; no issue created' >&2
  exit 65
}
reports="$(jq -c -s '.' "$report")"

agent_home="${AGENT_HOME:-${ZF_HOME:-$HOME/.zenoforge}}"
state_file="${PROMPT_OBSERVER_LOW_SCORE_STATE:-$agent_home/night/prompt-observer-low-score-state.json}"
mkdir -p -- "$(dirname -- "$state_file")"
exec 9>"$state_file.lock"
flock -x 9
if [[ -e "$state_file" ]]; then
  jq -e '
    type == "object" and .version == 1
    and (.entries | type == "array" and all(.[];
      (.stage | type == "string" and test("^[a-z0-9][a-z0-9-]{0,39}$"))
      and (.prompt | type == "string" and (. == "engine/mac-autopilot/scheduler.d/dispatch-queue.sh" or startswith("engine/prompts/")))
      and ((has("prompt_version") | not) or (.prompt_version | type == "string" and test("^[0-9a-f]{64}$")))
      and (.streak | type == "number" and floor == . and . > 0)
    ))
  ' "$state_file" >/dev/null || {
    echo 'prompt-observer-low-score: invalid state file; no issue created' >&2
    exit 65
  }
  state="$(jq -c '.' "$state_file")"
else
  state='{"version":1,"entries":[]}'
fi

triggered=()
while IFS= read -r row; do
  result="$(jq -c --argjson row "$row" --argjson threshold "$threshold" '
    . as $state
    | ($row.prompt_version // "") as $version
    | ([$state.entries[] | select(.stage == $row.stage and .prompt == $row.prompt and (.prompt_version // "") == $version) | .streak][0] // 0) as $old
    | (if ($row.status // "scored") == "insufficient-data" or $row.score >= $threshold then 0 else $old + 1 end) as $streak
    | {
        state: {
          version: 1,
          entries: ([$state.entries[] | select(.stage != $row.stage or .prompt != $row.prompt or (.prompt_version // "") != $version)]
            + (if $streak > 0 then [{stage:$row.stage,prompt:$row.prompt,streak:$streak} + (if $version == "" then {} else {prompt_version:$version} end)] else [] end))
        },
        streak: $streak
      }
  ' <<< "$state")"
  state="$(jq -c '.state' <<< "$result")"
  streak="$(jq -r '.streak' <<< "$result")"
  if (( streak >= required )) && jq -e --argjson threshold "$threshold" \
    '(.status // "scored") == "scored" and .score < $threshold' <<< "$row" >/dev/null; then
    triggered+=("$row")
  fi
done < <(jq -c '.[]' <<< "$reports")

state_tmp="$(mktemp "${state_file}.XXXXXX")"
trap 'rm -f -- "${state_tmp:-}" "${body:-}"' EXIT
jq '.' <<< "$state" > "$state_tmp"
mv -f -- "$state_tmp" "$state_file"
exec 9>&-

if ((${#triggered[@]})); then
  repo_slug="${ZF_GH_REPO:-${ZF_REPO:-}}"
  if [[ -z "$repo_slug" ]]; then
    repo_slug="$(git -C "$ZF_REPO_DIR" remote get-url origin 2>/dev/null \
      | sed -E 's#^(git@[^:]+:|[a-z]+://([^/@]+@)?[^/]+/)##; s#\.git$##' || true)"
  fi
  [[ "$repo_slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
    echo 'prompt-observer-low-score: could not resolve repository slug' >&2
    exit 64
  }

  upsert="${PROMPT_OBSERVER_LOW_SCORE_UPSERT:-$script_dir/../pipeline-issue-upsert.sh}"
  for row in "${triggered[@]}"; do
    prompt="$(jq -r '.prompt' <<< "$row")"
    stage="$(jq -r '.stage' <<< "$row")"
    prompt_stage="$(jq -r '.prompt_stage // empty' <<< "$row")"
    prompt_version="$(jq -r '.prompt_version // empty' <<< "$row")"
    score="$(jq -r '.score' <<< "$row")"
    if [[ -n "$prompt_version" ]]; then
      unit_hash="$(printf '%s\n%s\n%s' "$stage" "$prompt" "$prompt_version" | sha256sum | cut -c1-24)"
    else
      unit_hash="$(printf '%s\n%s' "$stage" "$prompt" | sha256sum | cut -c1-24)"
    fi
    class="prompt-low-score-$unit_hash"
    body="$(mktemp)"
    {
      printf 'Prompt path: `%s`\nStage: `%s`\nScore: %s (below threshold %s for at least %s consecutive reports)\n\nEvidence units:\n' \
        "$prompt" "$stage" "$score" "$threshold" "$required"
      [[ -z "$prompt_stage" ]] || printf 'Prompt stage: `%s`\n' "$prompt_stage"
      [[ -z "$prompt_version" ]] || printf 'Prompt version: `%s`\n' "$prompt_version"
      [[ -z "$prompt_version" ]] || printf '\n'
      jq -r '.unit_ids[] | "- `\(.)`"' <<< "$row"
      printf '\nSuggested change: Revise the prompt or prompt builder to address the repeated low machine-signal score for this stage, then verify the edit through the existing `engine/eval` gate.\n'
    } > "$body"
    ZF_REPO="$repo_slug" bash "$upsert" --class "$class" --title "Improve low-scoring prompt: $prompt" \
      --body-file "$body" --lane product --repo "$repo_slug"
    rm -f -- "$body"
    body=""
  done
fi

printf 'prompt-observer-low-score reports=%s issues-upserted=%s\n' "$(jq 'length' <<< "$reports")" "${#triggered[@]}"
