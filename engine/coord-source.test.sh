#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

engine="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
for mode in off on; do
  if ZF_COORD_MODE="$mode" bash -c '
    set -euo pipefail
    engine="$1"
    mode="$2"
    source "$engine/test-env.sh"
    ZF_COORD="$mode"
    source "$engine/lib.sh"
    if [[ "$ZF_COORD" == off ]]; then
      if declare -F _coord_paths >/dev/null || declare -F _coord_read_locked >/dev/null || declare -F _coord_remote_read >/dev/null; then
        printf "coord-source.test.sh: coordination module loaded while off\n" >&2
        exit 1
      fi
      declare -F coord_acquire >/dev/null || exit 1
      coord_lane_acquire merge owner-off 0 || exit 1
      coord_lane_release merge owner-off || exit 1
      coord_lane_run merge 0 true || exit 1
      [[ "$COORD_LANE_BUSY" == 0 ]] || exit 1
      start_ticks="$(coord_process_start_ticks "${BASHPID:-$PPID}")" || { echo "coord-source.test.sh: off-mode process identity helper unavailable" >&2; exit 1; }
      [[ "$start_ticks" =~ ^[0-9]+$ ]] || exit 1
      coord_acquire issue-1 owner test 1 unit stage || exit 1
      [[ ! -e "$AGENT_HOME/coord" ]] || { echo "coord-source.test.sh: off-mode stub created claim state" >&2; exit 1; }
      if coord_read issue-1; then
        echo "coord-source.test.sh: off-mode stub returned a claim" >&2
        exit 1
      else
        status=$?
        [[ "$status" == 1 ]] || exit "$status"
      fi
      config_engine="$test_env_root/config-engine"
      mkdir -p "$config_engine"
      cp "$engine/coord-off.sh" "$config_engine/coord-off.sh"
      printf "%s\n" COORD_OFF_SELECTED=config >> "$config_engine/coord-off.sh"
      export ZF_ENGINE_DIR="$config_engine"
      source "$engine/config.sh"
      [[ "${COORD_OFF_SELECTED:-}" == config ]] || { printf "config did not load selected off helpers: %s\\n" "$ZF_ENGINE_DIR" >&2; exit 1; }
      fixture="$test_env_root/scheduler"
      selected_engine="$fixture/selected-engine"
      mkdir -p "$fixture/sup/autopi" "$fixture/repo" "$selected_engine"
      cp "$engine/mac-autopilot/config.template.json" "$fixture/sup/autopi/config.json"
      cp "$engine/coord-off.sh" "$selected_engine/coord-off.sh"
      : > "$selected_engine/lib.sh"
      printf "%s\n" COORD_OFF_SELECTED=1 >> "$selected_engine/coord-off.sh"
      printf '{"units":[]}' > "$fixture/sup/autopi/units.json"
      export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/sup"
      unset ZF_ENGINE_DIR
      export ZF_EXECUTION_MODULE_DIR="$selected_engine"
      unset -f coord_remote_enabled coord_init coord_refresh coord_issue_key coord_unit_key coord_new_owner coord_read coord_acquire coord_lane_acquire coord_lane_release coord_lane_run coord_acquire_many coord_release coord_release_many coord_renew coord_assert_owned coord_remote_active coord_reap_expired coord_reconcile_systemd_workers coord_with_scheduler_lock coord_enter coord_exit coord_issue_live_worker coord_process_start_ticks_into coord_process_start_ticks
      AUTOPI_TEST_LIBRARY_ONLY=true
      source "$engine/mac-autopilot/scheduler.sh"
      [[ "${COORD_OFF_SELECTED:-}" == 1 ]] || { printf "scheduler did not load selected off helpers: %s\\n" "$SCHEDULER_AGENT_LIB" >&2; exit 1; }
      declare -F coord_unit_key >/dev/null || { printf "scheduler off helpers missing from %s\\n" "$SCHEDULER_AGENT_LIB" >&2; exit 1; }
      coord_lane_run merge 0 true || exit 1
      [[ "$COORD_LANE_BUSY" == 0 ]] || exit 1
      declare -F _coord_paths >/dev/null && exit 1
      coord_unit_key scheduler-unit >/dev/null || exit 1
    else
      declare -F _coord_read_locked >/dev/null || exit 1
      declare -F _coord_remote_read >/dev/null || exit 1
    fi
  ' _ "$engine" "$mode"; then
    :
  else
    printf 'coord-source.test.sh: source path failed for mode %s\n' "$mode" >&2
    exit 1
  fi
done

printf 'coord-source.test.sh: PASS\n'
