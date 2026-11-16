#!/usr/bin/env bash
# Files one deduplicated engine issue per repeated stall class (founder ruling zenoforge-self-heal-2026-11-02:
# a stall the head fixes by hand must become an engine self-heal rule). Input is the supervisor alert
# counters (kind/time only, never log content); filing goes through pipeline-issue-upsert.sh, which
# dedupes by class marker. It files issues only: no PR, no code change.
# Rate limit (gh hit resource limits 2026-11-04): a per-class cooldown and a global minimum gap between
# filing attempts, failed attempts included, so a gh outage cannot make every beat retry.
# shortcut: state file is not locked, the caller (bell.sh) is single-instance; add flock if another caller appears.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
home="${AGENT_HOME:?AGENT_HOME is not set}"
repo="${ZF_ENGINE_REPO:-ZenoWangzy/zenoforge}"
upsert="${ZF_STALL_UPSERT:-$SCRIPT_DIR/pipeline-issue-upsert.sh}"
kinds="${ZF_STALL_KINDS:-repeat-dispatch label-churn ticket-progress advisor-batch-stalled advisor-batch-quarantine blocker-root-failed ownerless-hold supervisor-hold-without-owner footprint-convoy pipeline-quarantine landing-failed node-stuck-30min}"
min_count="${ZF_STALL_MIN_COUNT:-5}"
window="${ZF_STALL_WINDOW_S:-86400}"
cooldown="${ZF_STALL_CLASS_COOLDOWN_S:-21600}"
min_gap="${ZF_STALL_MIN_GAP_S:-600}"
state="${ZF_STALL_STATE_FILE:-$home/state/engine-stall-issue.json}"
now="${ZF_STALL_NOW:-$(date +%s)}"
for n in "$min_count" "$window" "$cooldown" "$min_gap" "$now"; do [[ "$n" =~ ^[0-9]+$ ]] || { echo "engine-stall-issue: bad number $n" >&2; exit 64; }; done

mkdir -p -- "$(dirname -- "$state")"
[[ -s "$state" ]] && jq -e 'type == "object"' "$state" >/dev/null 2>&1 || printf '{"last_attempt":0,"classes":{}}\n' > "$state"
(( now - $(jq -r '.last_attempt // 0' "$state") >= min_gap )) || exit 0

iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
files=()
for day in "$(date -u -d "@$((now - window))" +%F)" "$(date -u -d "@$now" +%F)"; do
  f="$home/logs/supervisor-alerts-$day.jsonl"
  [[ -r "$f" && " ${files[*]-} " != *" $f "* ]] && files+=("$f")
done
(( ${#files[@]} )) || exit 0

# kind, count, first, last for every allowlisted kind at or over the threshold, busiest first.
rows="$(cat -- "${files[@]}" | jq -rnR --arg cutoff "$(iso $((now - window)))" --arg kinds "$kinds" --argjson min "$min_count" '
  ($kinds | split(" ")) as $k
  | [inputs | fromjson? | select(type == "object" and (.at // "") >= $cutoff and (.kind as $x | $k | index($x)))]
  | group_by(.kind) | map(select(length >= $min)) | sort_by(-length)[]
  | [.[0].kind, length, (map(.at) | min), (map(.at) | max)] | @tsv')"

while IFS=$'\t' read -r kind count first last; do
  [[ -n "$kind" ]] || continue
  class="engine-stall-$(printf '%s' "$kind" | LC_ALL=C tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-|-$//g')"
  class="${class:0:64}"
  filed="$(jq -r --arg c "$class" '.classes[$c] // 0' "$state")"
  (( now - filed >= cooldown )) || continue
  body="$(mktemp "${TMPDIR:-/tmp}/engine-stall.XXXXXX")"
  printf '# Repeated engine stall\n\n- Signature: `%s`\n- Class: `%s`\n- Occurrences in the last %ss: %s\n- First seen: %s\n- Last seen: %s\n\nCounted from the supervisor alert log; no log content is attached. Find the root cause and make it an engine self-heal rule.\n' \
    "$kind" "$class" "$window" "$count" "$first" "$last" > "$body"
  tmp="$(mktemp "$state.XXXXXX")"
  if ZF_GH_REPO="$repo" ZF_REPO="$repo" bash "$upsert" --class "$class" --title "Engine stall: $kind repeated" \
    --body-file "$body" --lane pipeline-system --label incident --repo "$repo"; then
    jq --arg c "$class" --argjson n "$now" '.last_attempt = $n | .classes[$c] = $n' "$state" > "$tmp"
  else
    echo "engine-stall-issue: upsert failed class=$class; backing off" >&2
    jq --argjson n "$now" '.last_attempt = $n' "$state" > "$tmp"
  fi
  mv -f -- "$tmp" "$state"
  rm -f -- "$body"
  break # one gh write per run; the next class waits for the minimum gap
done <<< "$rows"
