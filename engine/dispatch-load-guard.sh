#!/usr/bin/env bash
# dispatch_load_exceeded <1m-load> <nproc> [limit-multiple=$AGENT_DISPATCH_LOAD_LIMIT_MULTIPLIER|2] [reject-at-limit=0]:
# 0 above (or at, when requested), 1 below (or at/below by default), 2 invalid.
dispatch_load_exceeded() {
  local load_1m="${1:-}" processors="${2:-}" \
    limit_multiple="${3:-${AGENT_DISPATCH_LOAD_LIMIT_MULTIPLIER:-2}}" reject_at_limit="${4:-0}"
  [[ "$load_1m" =~ ^[0-9]+([.][0-9]+)?$ \
    && "$processors" =~ ^[1-9][0-9]*$ \
    && "$limit_multiple" =~ ^[1-9][0-9]*$ \
    && "$reject_at_limit" =~ ^[01]$ ]] || return 2
  LC_ALL=C awk -v load_value="$load_1m" -v processors="$processors" \
    -v limit_multiple="$limit_multiple" -v reject_at_limit="$reject_at_limit" \
    'BEGIN {
      limit = limit_multiple * processors
      exit !(reject_at_limit == 1 ? load_value >= limit : load_value > limit)
    }'
}

# One scheduling policy for enqueue, resume and both admission gates.
# An explicit HAND_PRIORITY_STATE wins; otherwise the target config copy of state/hand-priority.json,
# then the pack, then this engine's own default.
hand_priority_state() {
  local candidate
  [[ -n "${HAND_PRIORITY_STATE:-}" ]] && { printf '%s\n' "$HAND_PRIORITY_STATE"; return 0; }
  if declare -F zf_config_file >/dev/null 2>&1 && candidate="$(zf_config_file state/hand-priority.json)"; then
    printf '%s\n' "$candidate"; return 0
  fi
  printf '%s\n' "$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")/state/hand-priority.json"
}

hand_dispatch_tier() {
  local role="${1:-work}" name="${2:-}" priority="${3:-}" tier="${ENQUEUE_TIER:-}" session="${SUPERVISOR_SESSION:-}"
  local night="${ZF_NIGHT_DIR:-${AGENT_HOME:-${ZF_HOME:-$HOME/.zenoforge}}/night}"
  if [ -z "$tier" ] && [ -n "$name" ]; then
    tier="$(jq -r '.tier // empty' "$night/hand-registry/$name.json" 2>/dev/null || true)"
  fi
  if [ -z "$session" ] && [ -n "${TMUX:-}" ]; then
    session="$(tmux display-message -p -t "${TMUX_PANE:-}" '#S' 2>/dev/null || true)"
  fi
  jq -er --arg tier "$tier" --arg session "$session" --arg role "$role" --arg priority "$priority" '
    if $tier != "" and (.order | index($tier)) == null then error("invalid hand tier") else . end |
    (.roles[$role] // (if $tier != "" then $tier else .sessions[$session] //
      (if $priority == "pipeline" then "optimization" else .default end) end)) as $selected |
    if (.order | index($selected)) != null then $selected else error("invalid hand tier") end
  ' "$(hand_priority_state)"
}

hand_dispatch_worker_priority() {
  case "${1:-}" in
    hotfix) printf 'hotfix\n' ;;
    optimization) printf 'opt\n' ;;
    *) printf 'normal\n' ;;
  esac
}

hand_dispatch_memory_floor() {
  case "$1" in
    hotfix) printf '%s\n' "${AGENT_DISPATCH_HOTFIX_MIN_MEM_MB:-$(jq -er '.memory_floor_mb.hotfix' "$(hand_priority_state)")}" ;;
    finishing) jq -er '.memory_floor_mb.finishing' "$(hand_priority_state)" ;;
    optimization|general) printf '%s\n' "${AGENT_DISPATCH_MIN_MEM_MB:-$(jq -er --arg tier "$1" '.memory_floor_mb[$tier]' "$(hand_priority_state)")}" ;;
    *) return 2 ;;
  esac
}
