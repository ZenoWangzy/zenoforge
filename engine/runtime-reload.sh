#!/usr/bin/env bash
# Source this; checkpoints belong outside item bodies, never in a verdict/revert.
agent_reload_signature() {
  local files capacity="${AGENT_HOME:-${ZF_HOME:-$HOME/.zenoforge}}/capacity.env"
  files="$(sha256sum -- "$AGENT_RELOAD_SCRIPT" "$AGENT_RELOAD_LIB" "$AGENT_RELOAD_HELPER")" || return 1
  if [[ -r "$capacity" ]]; then files+=$'\n'"$(sha256sum -- "$capacity")" || return 1; fi
  {
    git -C "$AGENT_RELOAD_ROOT" rev-parse HEAD 2>/dev/null || printf 'unversioned\n'
    printf '%s\n' "$files"
  } | sha256sum | cut -d ' ' -f1
}

agent_reload_init() {
  AGENT_RELOAD_SCRIPT="$(realpath -- "$1")"
  shift
  AGENT_RELOAD_ARGS=("$@")
  AGENT_RELOAD_CWD="$PWD"
  AGENT_RELOAD_PID="$BASHPID"
  AGENT_RELOAD_HELPER="$(realpath -- "${BASH_SOURCE[0]}")"
  AGENT_RELOAD_LIB="${AGENT_RELOAD_HELPER%/*}/lib.sh"
  AGENT_RELOAD_ROOT="$(git -C "${AGENT_RELOAD_HELPER%/*}" rev-parse --show-toplevel 2>/dev/null || printf '%s' "${AGENT_RELOAD_HELPER%/*}/..")"
  AGENT_RELOAD_SIGNATURE="$(agent_reload_signature)" || return 1
  AGENT_RELOAD_STATE_DIR="${AGENT_HOME:-${ZF_HOME:-$HOME/.zenoforge}}/state/runtime-code"
  mkdir -p -- "$AGENT_RELOAD_STATE_DIR" || return 1
  local stat_fields ticks head tmp
  stat_fields="$(cat "/proc/$AGENT_RELOAD_PID/stat")"
  stat_fields="${stat_fields##*) }"
  read -r -a stat_fields <<< "$stat_fields"
  ticks="${stat_fields[19]}"
  head="$(git -C "$AGENT_RELOAD_ROOT" rev-parse HEAD 2>/dev/null || printf unversioned)"
  tmp="$(mktemp "$AGENT_RELOAD_STATE_DIR/.record.XXXXXX")" || return 1
  printf '%s\t%s\t%s\t%s\t%s\n' "$ticks" "$head" "$AGENT_RELOAD_SIGNATURE" "$(date +%s)" "$AGENT_RELOAD_SCRIPT" > "$tmp"
  mv -f -- "$tmp" "$AGENT_RELOAD_STATE_DIR/$BASHPID.tsv"
}

agent_reload_restore() {
  # Only consume our own exec handoff, never a child process's inherited state.
  if [[ "${ZF_RELOAD_PID:-}" == "$BASHPID" && -n "${ZF_RELOAD_STATE:-}" ]]; then
    source "$ZF_RELOAD_STATE" || return 1
    rm -f -- "$ZF_RELOAD_STATE"
  fi
  unset ZF_RELOAD_STATE ZF_RELOAD_PID
}

agent_reload_checkpoint() {
  [[ -n "${AGENT_RELOAD_SCRIPT:-}" && "$BASHPID" == "$AGENT_RELOAD_PID" ]] || return 0
  local current state name
  current="$(agent_reload_signature)" || return 1
  [[ "$current" != "$AGENT_RELOAD_SIGNATURE" ]] || return 0
  state="$(mktemp "$AGENT_RELOAD_STATE_DIR/.handoff.$BASHPID.XXXXXX")" || return 1
  for name; do
    # Bash quotes values, arrays and associative keys; no caller text is evaluated.
    declare -p "$name" 2>/dev/null | sed 's/^declare /declare -g /' >> "$state" || true
  done
  printf 'runtime-code: re-exec pid=%s script=%s at safe point\n' "$BASHPID" "$AGENT_RELOAD_SCRIPT" >&2
  export ZF_RELOAD_PID="$BASHPID" ZF_RELOAD_STATE="$state"
  cd -- "$AGENT_RELOAD_CWD" || return 1
  exec bash "$AGENT_RELOAD_SCRIPT" "${AGENT_RELOAD_ARGS[@]}"
}
