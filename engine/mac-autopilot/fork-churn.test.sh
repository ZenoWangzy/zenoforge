#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/../.." && pwd -P)"
work="$test_env_root/fork-churn"
baseline_engine="$work/origin-main"
driver="$work/tick-driver.sh"
base_ref="${FORK_CHURN_BASE_REF:-origin/main}"
strace_bin="${FORK_CHURN_STRACE_BIN:-$(command -v strace || true)}"
timeout_bin="$(command -v timeout || true)"
fail() { echo "fork-churn.test.sh: $*" >&2; exit 1; }
[[ -x "$strace_bin" ]] || fail 'strace is required for the fork-count regression'
[[ -x "$timeout_bin" ]] || fail 'GNU timeout is required for the fork-count regression'
git cat-file -e "$base_ref:engine/mac-autopilot/scheduler.d/harvest-workers.sh" \
  || fail "cannot read the origin/main baseline at $base_ref"
mkdir -p "$work"
mkdir -p "$baseline_engine"
cp -a "$script_dir/." "$baseline_engine/"
git show "$base_ref:engine/mac-autopilot/scheduler.d/harvest-workers.sh" > "$baseline_engine/scheduler.d/harvest-workers.sh"
git show "$base_ref:engine/mac-autopilot/scheduler.d/size-recuts.sh" > "$baseline_engine/scheduler.d/size-recuts.sh"
git show "$base_ref:engine/mac-autopilot/bell.sh" > "$baseline_engine/bell.sh"

cat > "$driver" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$ZF_FORK_CHURN_ENGINE_DIR/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY
read -r stat_line < "/proc/$BASHPID/stat"
read -r -a stat_fields <<<"${stat_line##*) }"
jq --argjson pid "$BASHPID" --argjson group "${stat_fields[2]}" --arg start "${stat_fields[19]}" \
  '.workers |= map(.pid=$pid | .process_group=$group | .pid_start=$start)' "$WORKERS" > "$WORKERS.tmp"
mv "$WORKERS.tmp" "$WORKERS"
acquire_scheduler_lock() { SCHED_LOCK_HELD=true; }
release_scheduler_lock() { SCHED_LOCK_HELD=false; }
state_schema_ok() { return 0; }
tick_gh_calls_begin() { :; }
tick_roadmap_cache_begin() { :; }
tick_roadmap_cache_end() { :; }
rotate_logs() { :; }
update_budget() { return 0; }
budget_meter_scan() { :; }
budget_alert_if_needed() { :; }
git() { return 1; }
harvest_station_fresh() { return 1; }
phase_mark() { :; }
phase() { case "$1" in harvest_workers|reconcile_size_recuts) "$@" ;; *) return 0 ;; esac; }
phase_yield_lock() { :; }
scheduler_lock_yield_between_units() { :; }
tick_prs_prime() { :; }
tick_prs_changed() { :; }
scheduler_issue_state() { printf '{"state":"on-hold"}\n'; }
flush_focus_alert() { :; }
publish_pr_run_snapshot() { :; }
launch_views() { :; }
cleanup_tick() { :; }
tick_gh_calls_summary() { printf 'gh_calls=0 gql=0 rest=0\n'; }
tick_rest_usage_summary() { printf 'rest_used=0\n'; }
dispatch_skip_summary() { :; }
live_workers() { printf '63'; }
main
SH
chmod +x "$driver"

prepare_tick() {
  local run="$work/tick-$1"
  mkdir -p "$run/repo" "$run/runtime/alerts" "$run/supervisor" "$run/agent/state" "$run/home" "$run/tmp" "$run/sessions"
  cp "$script_dir/config.template.json" "$run/runtime/config.json"
  printf '{"units":[' > "$run/runtime/units.json"
  printf '{"workers":[' > "$run/runtime/workers.json"
  local i issue sep='' started
  started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for ((i = 0; i < 63; i++)); do
    issue=$((7000 + i))
    printf '%s{"id":"issue-%s","issue":%s,"stage":"blocked-external","size_recut_pending":true,"note":"issue #%s recut is on hold","history":[]}' \
      "$sep" "$issue" "$issue" "$issue" >> "$run/runtime/units.json"
    printf '%s{"pid":1,"unit":"issue-%s","type":"implement","provider":"codex","model":"test-model","mode":"fresh","started":"%s","token_usage_start":{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0},"harvested":false,"log":"worker-%s.log","report":"worker-%s.md"}' \
      "$sep" "$issue" "$started" "$issue" "$issue" >> "$run/runtime/workers.json"
    : > "$run/supervisor/worker-$issue.log"
    sep=,
  done
  printf ']}\n' >> "$run/runtime/units.json"
  printf ']}\n' >> "$run/runtime/workers.json"
  : > "$run/agent/PAUSE"
}

fork_count() {
  awk '
    ($NF == "clone" || $NF == "clone3" || $NF == "fork" || $NF == "vfork") { n += $4 }
    END { print n + 0 }
  ' "$1"
}
profile_tick() {
  local label="$1" engine="$2" run="$3" summary
  summary="$work/$label.tick.strace"
  export HOME="$run/home" AGENT_HOME="$run/agent" TMPDIR="$run/tmp"
  export MAC_AUTOPILOT_ROOT="$run/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$run/supervisor" MAC_AUTOPILOT_RUNTIME_DIR="$run/runtime"
  export ZF_ENGINE_DIR="$engine_dir" ZF_REPO_DIR="$run/repo" ZF_GH_REPO=example-maintainer/example-repo
  export ZF_FORK_CHURN_ENGINE_DIR="$engine" CODEX_SESSIONS_DIR="$run/sessions" WORKER_SCRATCH_ROOT="$run/worker-scratch"
  export AUTOPILOT_PAUSE_FILE="$run/agent/PAUSE" SIZE_RECUT_RECONCILE_SECONDS=300
  "$timeout_bin" 1500 "$strace_bin" -f -c -e trace=clone,clone3,fork,vfork -o "$summary" bash "$driver" > "$run/tick.out" 2>&1
  fork_count "$summary"
}

prepare_tick origin
prepare_tick changed
origin_tick="$(profile_tick origin "$baseline_engine" "$work/tick-origin")"
changed_tick="$(profile_tick changed "$script_dir" "$work/tick-changed")"
(( changed_tick * 2 <= origin_tick )) || fail "scheduler tick forks origin/main=$origin_tick changed=$changed_tick (must be at most half)"
printf 'fork-churn tick: origin/main=%s changed=%s\n' "$origin_tick" "$changed_tick"

mock_bin="$work/bin"
mkdir -p "$mock_bin"
cat > "$mock_bin/systemctl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$mock_bin/ps" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$mock_bin/pkill" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$mock_bin/timeout" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == --foreground ]] && exit 0
exec "$@"
SH
cat > "$mock_bin/git" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == -C ]] && shift 2
case "${1:-}" in
  ls-remote) printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\trefs/heads/main\n' ;;
  merge-base) exit 0 ;;
  remote) printf 'https://github.com/example-maintainer/example-repo.git\n' ;;
  *) exit 2 ;;
esac
SH
cat > "$mock_bin/gh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$mock_bin/"*

prepare_bell() {
  local run="$work/bell-$1" now i
  mkdir -p "$run/repo/engine/mac-autopilot" "$run/repo/engine/night" "$run/runtime/alerts" "$run/supervisor" "$run/agent/state" "$run/home" "$run/tmp"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s\n' '{"bell":{"enabled":true,"dedup_minutes":30},"incident":{"file_min_severity":"off"}}' > "$run/runtime/config.json"
  printf '%s\n' '{"units":[]}' > "$run/runtime/units.json"
  printf '%s\n' '{"workers":[]}' > "$run/runtime/workers.json"
  jq -n '{monitor_initialized:true,scheduler_lines:0,alert_mtimes:{},merge_events:{},signatures:{},pending:[]}' > "$run/runtime/bell-state.json"
  for ((i = 0; i < 800; i++)); do printf '[%s] routine pass completed item=%s\n' "$now" "$i"; done > "$run/runtime/scheduler.log"
}
profile_bell() {
  local label="$1" engine="$2" run="$3" summary
  summary="$work/$label.bell.strace"
  export HOME="$run/home" AGENT_HOME="$run/agent" TMPDIR="$run/tmp" PATH="$mock_bin:$PATH"
  export MAC_AUTOPILOT_ROOT="$run/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$run/supervisor" MAC_AUTOPILOT_RUNTIME_DIR="$run/runtime"
  export ZF_ENGINE_DIR="$engine_dir" ZF_REPO_DIR="$run/repo" ZF_GH_REPO=example-maintainer/example-repo
  export BELL_SUPERVISOR_DIR="$run/supervisor" BELL_AUTOPI_DIR="$run/runtime" BELL_LIVE_EVIDENCE_DISABLE=1 BELL_STALE_CI_DISABLE=1
  unset AUTOPILOT_LOOP_UNIT
  "$timeout_bin" 1500 "$strace_bin" -f -c -e trace=clone,clone3,fork,vfork -o "$summary" bash "$engine/bell.sh" > "$run/bell.out" 2>&1
  fork_count "$summary"
}

prepare_bell origin
prepare_bell changed
origin_bell="$(profile_bell origin "$baseline_engine" "$work/bell-origin")"
changed_bell="$(profile_bell changed "$script_dir" "$work/bell-changed")"
(( changed_bell * 2 <= origin_bell )) || fail "bell forks origin/main=$origin_bell changed=$changed_bell (must be at most half)"
printf 'fork-churn bell: origin/main=%s changed=%s\n' "$origin_bell" "$changed_bell"
