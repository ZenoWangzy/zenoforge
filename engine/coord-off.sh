#!/usr/bin/env bash

COORD_DIR="$AGENT_HOME/coord/claims"
COORD_LEASE_SECONDS="${ZF_COORD_LEASE_SECONDS:-900}"
coord_remote_enabled() { return 1; }
coord_init() { return 0; }
coord_refresh() { return 0; }
coord_issue_key() { [[ "${1:-}" =~ ^[1-9][0-9]*$ ]] || return 2; printf 'issue-%s\n' "$1"; }
coord_unit_key() { [[ "${1:-}" =~ ^[A-Za-z0-9._-]+$ ]] || return 2; printf 'unit-%s\n' "$1"; }
coord_new_owner() { printf 'owner-off-%s-%s\n' "$BASHPID" "$RANDOM"; }
coord_read() { return 1; }
coord_acquire() { return 0; }
coord_acquire_many() { return 0; }
coord_release() { return 0; }
coord_release_many() { return 0; }
coord_renew() { return 0; }
coord_assert_owned() { return 0; }
coord_remote_active() { return 1; }
coord_reap_expired() { return 0; }
coord_reconcile_systemd_workers() { return 0; }
coord_with_scheduler_lock() { "$@"; }
coord_enter() { return 0; }
coord_exit() { return 0; }
coord_issue_live_worker() { return 1; }
coord_process_start_ticks_into() {
  local pid="${1:-}"
  COORD_START_TICKS=""
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  declare -F pid_start_id_into >/dev/null || return 1
  pid_start_id_into "$pid" 2>/dev/null || return 1
  [[ "${PID_START_ID:-}" =~ ^[0-9]+$ ]] || return 1
  COORD_START_TICKS="$PID_START_ID"
}
coord_process_start_ticks() {
  coord_process_start_ticks_into "${1:-}" && printf '%s\n' "$COORD_START_TICKS"
}
