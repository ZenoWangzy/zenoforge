QUOTA_MARKER_SCOPE_FILE="${QUOTA_MARKER_SCOPE_FILE:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/quota-marker-scope.json}"

_quota_scope_cell() {
  local key="$1" station="$2" file cell
  file="$(routing_file_path)"
  if [[ -n "$file" ]]; then
    cell="$(jq -r --arg k "$key" --arg s "$station" '.quota_marker_scope[$k][$s] // empty' "$file" 2>/dev/null || true)"
    case "$cell" in block|allow) printf '%s' "$cell"; return 0 ;; esac
  fi
  jq -r --arg k "$key" --arg s "$station" '.[$k][$s] // empty' "$QUOTA_MARKER_SCOPE_FILE" 2>/dev/null || true
}

_quota_scope_decision() {
  local cause="$1" station="$2" cell
  cell="$(_quota_scope_cell "$cause" "$station")"
  if [[ -z "$cell" && "$cause" == *.* ]]; then cell="$(_quota_scope_cell "${cause%%.*}" "$station")"; fi
  [[ -n "$cell" ]] || cell=block
  if [[ "$cell" == allow ]]; then return 1; fi
  printf '%s:%s\n' "$cause" "$station"
}

_quota_marker_held() {
  local marker until
  marker="$(_quota_marker_file "$1")" || return 1
  [[ -f "$marker" ]] || return 1
  until="$(cat "$marker" 2>/dev/null || true)"
  case "$until" in ''|*[!0-9]*) return 1 ;; esac
  [[ "$(date +%s)" -lt "$until" ]]
}

quota_marker_cause() {
  local marker="$1"
  case "$marker" in glm) marker=zcode ;; esac
  case "$marker" in
    claude)
      if snapshot_week_at "${CLAUDE_WEEK_STOP_PCT:-95}" "${CLAUDE_QUOTA_SNAPSHOT_FILE:-${AGENT_HOME:-$HOME/.zenoforge}/claude-quota.json}"; then
        printf 'claude.week_stop\n'
        return 0
      fi
      _quota_marker_held claude || return 1
      printf 'claude.exhausted\n'
      ;;
    codex|zcode)
      provider_quota_exhausted "$marker" || return 1
      printf '%s\n' "$marker"
      ;;
    *)
      echo "quota_marker_cause: unknown marker $1" >&2
      return 2
      ;;
  esac
}

quota_marker_blocks() {
  local marker="$1" station="$2" cause
  case "$marker" in claude|codex|zcode|glm) ;; *) echo "quota_marker_blocks: unknown marker $marker" >&2; return 2 ;; esac
  case "$station" in implement|review|triage|intake|recut|owner_session) ;; *) echo "quota_marker_blocks: unknown station $station" >&2; return 2 ;; esac
  cause="$(quota_marker_cause "$marker")" || return 1
  _quota_scope_decision "$cause" "$station"
}
