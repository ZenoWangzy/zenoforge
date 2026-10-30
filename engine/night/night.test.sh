#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
# Preserve the owner context locally after bootstrap; seed/group/aux children cannot inherit it.
declare +x night_test_progress_context="${NIGHT_TEST_PROGRESS_CONTEXT:-}"
unset NIGHT_TEST_PROGRESS_CONTEXT
# Resolve the runtime used by the progress helper.
night_test_node="$(node -p 'process.execPath')"
set -E
NIGHT_TEST_ERR_REPORTED=0
trap 'NIGHT_TEST_ERR_REPORTED=1; printf "not ok - NIGHT_TEST_GROUP=%s line %s: %s\n" "${NIGHT_TEST_GROUP:-all}" "$LINENO" "$BASH_COMMAND" >&2' ERR
NIGHT_TEST_GROUP="${NIGHT_TEST_GROUP:-all}"
test_group_runner_pid=""
recovery_pid=""
test_group_runner_pgid_file=""
recovery_pgid_file=""

test_process_session_groups() {
  ps -eo pgid=,sid=,stat= | awk -v sid="$1" \
    '$2 == sid && $3 !~ /^Z/ {groups[$1]=1} END {for (group in groups) print group}' | sort -n
}

stop_test_process_group() {
  local session_id="$1" leader="$2" attempt group
  local -a groups=()
  if ! [[ "$session_id" =~ ^[1-9][0-9]*$ ]]; then
    kill -TERM "$leader" 2>/dev/null || true
    wait "$leader" 2>/dev/null || true
    return
  fi
  for ((attempt=0; attempt<50; attempt++)); do
    mapfile -t groups < <(test_process_session_groups "$session_id")
    ((${#groups[@]})) || break
    for group in "${groups[@]}"; do kill -TERM -- "-$group" 2>/dev/null || true; done
    sleep 0.1
  done
  mapfile -t groups < <(test_process_session_groups "$session_id")
  for group in "${groups[@]}"; do kill -KILL -- "-$group" 2>/dev/null || true; done
  for ((attempt=0; attempt<50; attempt++)); do
    mapfile -t groups < <(test_process_session_groups "$session_id")
    ((${#groups[@]})) || break
    sleep 0.1
  done
  mapfile -t groups < <(test_process_session_groups "$session_id")
  if ((${#groups[@]})); then
    printf 'not ok - test process session %s still active after SIGKILL (groups: %s)\n' \
      "$session_id" "${groups[*]}" >&2
    return 1
  fi
  wait "$leader" 2>/dev/null || true
}

stop_test_process() {
  local pid="$1" session_file="$2" session_id="" attempt
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return
  for ((attempt=0; attempt<50; attempt++)); do
    if [ -s "$session_file" ] && read -r session_id < "$session_file"; then break; fi
    sleep 0.01
  done
  [[ "$session_id" =~ ^[1-9][0-9]*$ ]] || session_id="$pid"
  stop_test_process_group "$session_id" "$pid"
}

cleanup_test_env() {
  local status=$?
  trap - EXIT
  if [ -n "$test_group_runner_pid" ]; then
    stop_test_process "$test_group_runner_pid" "$test_group_runner_pgid_file"
  fi
  if [ -n "$recovery_pid" ]; then
    stop_test_process "$recovery_pid" "$recovery_pgid_file"
  fi
  rm -rf -- "$test_env_root"
  if [ "$status" -ne 0 ] && [ "$NIGHT_TEST_ERR_REPORTED" != 1 ]; then
    printf 'not ok - NIGHT_TEST_GROUP=%s exited %s\n' "$NIGHT_TEST_GROUP" "$status" >&2
  fi
}
trap cleanup_test_env EXIT

NIGHT_TEST_JOBS="${NIGHT_TEST_JOBS:-8}"
[[ "$NIGHT_TEST_JOBS" =~ ^[1-9][0-9]*$ ]] || { echo 'NIGHT_TEST_JOBS must be a positive integer' >&2; exit 2; }
night_test_groups=(hand-owned-issues merge-handoff)
night_test_groups+=(hand-dispatch)
case "$NIGHT_TEST_GROUP" in
  all|night-seed) ;;
  *) [[ " ${night_test_groups[*]} " == *" $NIGHT_TEST_GROUP "* ]] || { echo "Unknown NIGHT_TEST_GROUP: $NIGHT_TEST_GROUP" >&2; exit 2; } ;;
esac

if [[ "$NIGHT_TEST_GROUP" == all ]]; then
  night_test_script="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
  seed_fixture="$test_env_root/night-seed"
  seed_pgid_file="$test_env_root/night-seed.pgid"
  test_group_runner_pgid_file="$seed_pgid_file"
  setsid --wait bash -c 'printf "%s\n" "$$" > "$1"; shift; exec "$@"' _ \
    "$seed_pgid_file" env HOME="$test_host_home" NIGHT_TEST_GROUP=night-seed \
      NIGHT_TEST_SEED_FIXTURE="$seed_fixture" bash "$night_test_script" &
  test_group_runner_pid=$!
  if wait "$test_group_runner_pid"; then seed_status=0; else seed_status=$?; fi
  test_group_runner_pid=""
  if (( seed_status != 0 )); then exit "$seed_status"; fi

  night_progress_manifest=""
  night_progress_helper="$(dirname -- "$night_test_script")/night-test-progress.mjs"
  night_group_command=(bash "$night_test_script")
  recovery_command=(bash "$(dirname -- "$night_test_script")/main-ci-recovery.test.sh")
  if [[ -n "$night_test_progress_context" ]]; then
    night_progress_manifest="$("$night_test_node" "$night_progress_helper" prepare \
      "$night_test_progress_context" "$night_test_script" "${night_test_groups[@]}")"
    night_group_command=("$night_test_node" "$night_progress_helper" run "$night_progress_manifest" "$night_test_script" "{}")
    recovery_command=("$night_test_node" "$night_progress_helper" run "$night_progress_manifest" "$night_test_script" main-ci-recovery)
  fi
  # main-ci-recovery.test.sh is not exported (needs the product scripts/branch-delivery-policy.mjs); the progress suite supplies its own fixture copy
  [[ -f "$(dirname -- "$night_test_script")/main-ci-recovery.test.sh" ]] || recovery_command=(true)
  recovery_log="$test_env_root/main-ci-recovery.log"
  recovery_pgid_file="$test_env_root/main-ci-recovery.pgid"
  setsid --wait bash -c 'printf "%s\n" "$$" > "$1"; shift; exec "$@"' _ \
    "$recovery_pgid_file" env HOME="$test_host_home" "${recovery_command[@]}" >"$recovery_log" 2>&1 &
  recovery_pid=$!
  groups_file="$test_env_root/night-test-groups"
  printf '%s\n' "${night_test_groups[@]}" > "$groups_file"
  test_group_runner_pgid_file="$test_env_root/night-test-groups.pgid"
  setsid --wait bash -c 'printf "%s\n" "$$" > "$1"; shift; exec "$@"' _ \
    "$test_group_runner_pgid_file" xargs -P "$NIGHT_TEST_JOBS" -I{} env HOME="$test_host_home" NIGHT_TEST_GROUP="{}" NIGHT_TEST_SEED_FIXTURE="$seed_fixture" "${night_group_command[@]}" \
    < "$groups_file" &
  test_group_runner_pid=$!
  if wait "$test_group_runner_pid"; then group_status=0; else group_status=$?; fi
  test_group_runner_pid=""
  if wait "$recovery_pid"; then recovery_status=0; else recovery_status=$?; fi
  recovery_pid=""
  if (( group_status != 0 || recovery_status != 0 )); then
    if (( group_status != 0 )); then printf 'not ok - night test groups failed (xargs exit %s)\n' "$group_status" >&2; fi
    if (( recovery_status != 0 )); then
      printf 'not ok - main-ci-recovery exited %s; log follows\n' "$recovery_status" >&2
      cat "$recovery_log" >&2
    fi
    NIGHT_TEST_ERR_REPORTED=1
    exit 1
  fi
  if [[ -n "$night_progress_manifest" ]]; then
    "$night_test_node" "$night_progress_helper" complete "$night_progress_manifest" "$night_test_script"
  fi
  echo 'night.test.sh: PASS'
  exit 0
fi

night_test_group() { [[ "$NIGHT_TEST_GROUP" == "$1" ]]; }

if night_test_group night-seed; then
  mkdir -p -- "${NIGHT_TEST_SEED_FIXTURE:?}"
  exit 0
fi

case "$NIGHT_TEST_GROUP" in
  hand-owned-issues)
    bash "$(dirname -- "${BASH_SOURCE[0]}")/hand-owned-issues.test.sh"
    ;;
  hand-dispatch)
    script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
    bash "$script_dir/../dispatch-codex.test.sh"
    bash "$script_dir/../dispatch-load-guard.test.sh"
    ;;
  merge-handoff)
    bash "$(dirname -- "${BASH_SOURCE[0]}")/hand-handoff-chain.test.sh"
    ;;
esac
