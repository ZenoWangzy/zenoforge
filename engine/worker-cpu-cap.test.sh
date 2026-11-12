#!/usr/bin/env bash
# Every pipeline worker start path hands systemd-run a CPUQuota and a CPUWeight (AGENT_WORKER_CPU_QUOTA / _WEIGHT,
# defaults 200% and 10) plus MemoryHigh=2G and TasksMax=500 (AGENT_WORKER_MEM_HIGH / _TASKS_MAX), and the scheduler scope logs the worker's wall and cpu seconds when it ends.
# dispatch-codex.sh's owner unit is asserted in dispatch-codex.test.sh, which already drives that script.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
engine="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
root="$test_env_root/worker-cpu-cap"
fake_bin="$root/bin"; calls="$root/systemd-run.calls"
mkdir -p "$fake_bin"
fail() { printf 'worker-cpu-cap.test.sh: %s\n' "$*" >&2; exit 1; }

# Records every argument, then runs the command after `--` the way a scope does (nothing when there is none).
cat > "$fake_bin/systemd-run" <<'SH'
#!/usr/bin/env bash
{ printf 'BEGIN\n'; printf '%s\n' "$@"; printf 'END\n'; } >> "$SYSTEMD_RUN_CALLS"
while (($#)); do [[ "$1" == -- ]] && { shift; (($#)) && [[ -n "${SYSTEMD_RUN_EXEC:-}" ]] && exec "$@"; exit 0; }; shift; done
exit 0
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_bin/pgrep"
# Records each systemctl call and whether the run's rc file already exists (bin/luna and bin/zc stop their scope after writing it).
sctl="$root/systemctl.calls"
cat > "$fake_bin/systemctl" <<'SH'
#!/usr/bin/env bash
rc=absent; [[ -f "$WORKER_SCRATCH_ROOT/luna/k1/rc" || -f "$WORKER_SCRATCH_ROOT/zc/k1/rc" ]] && rc=present
printf '%s rc=%s\n' "$*" "$rc" >> "$SYSTEMCTL_CALLS"
exit 0
SH
chmod +x "$fake_bin/systemd-run" "$fake_bin/pgrep" "$fake_bin/systemctl"
export SYSTEMD_RUN_CALLS="$calls" SYSTEMCTL_CALLS="$sctl" PATH="$fake_bin:$PATH"

# Each recorded call must carry both properties; $2 and $3 are the expected quota and weight.
assert_cpu_props() { # label quota weight
  local n
  n="$(grep -c '^BEGIN$' "$calls")"
  (( n > 0 )) || fail "$1: systemd-run was never called"
  [[ "$(grep -Fxc "CPUQuota=$2" "$calls")" == "$n" ]] || fail "$1: $n call(s) but not each has CPUQuota=$2"
  [[ "$(grep -Fxc "CPUWeight=$3" "$calls")" == "$n" ]] || fail "$1: $n call(s) but not each has CPUWeight=$3"
  printf 'PASS %s: CPUQuota=%s CPUWeight=%s\n' "$1" "$2" "$3"
}
# MemoryHigh throttles a worker past the line instead of killing it, so the scheduler scope sets no MemoryMax.
assert_mem_props() { # label memoryhigh tasksmax [nomax]
  grep -Fxq "MemoryHigh=$2" "$calls" && grep -Fxq "TasksMax=$3" "$calls" || fail "$1: expected MemoryHigh=$2 TasksMax=$3, got: $(tr '\n' ' ' < "$calls")"
  if [[ "${4:-}" == nomax ]] && grep -q '^MemoryMax=' "$calls"; then fail "$1: MemoryMax must stay unset"; fi
  printf 'PASS %s: MemoryHigh=%s TasksMax=%s%s\n' "$1" "$2" "$3" "${4:+ (no MemoryMax)}"
}
assert_inline_props() { # label quota weight: the property pair as one -p each, as bin/luna and friends pass them
  grep -Fxq "CPUQuota=$2" "$calls" && grep -Fxq "CPUWeight=$3" "$calls" || fail "$1: expected CPUQuota=$2 CPUWeight=$3, got: $(tr '\n' ' ' < "$calls")"
  printf 'PASS %s: CPUQuota=%s CPUWeight=%s\n' "$1" "$2" "$3"
}
assert_scope_stop() { # label: the run's own scope (--unit of its systemd-run) is stopped after its rc file is written
  local unit; unit="$(sed -n 's/^--unit=//p' "$calls" | head -1)"
  [[ -n "$unit" ]] || fail "$1: systemd-run got no --unit"
  [[ "$(cat "$sctl")" == "--user stop $unit.scope rc=present" ]] || fail "$1: systemctl got '$(cat "$sctl")', want '--user stop $unit.scope rc=present'"
  printf 'PASS %s: stops %s.scope after rc is written\n' "$1" "$unit"
}

# --- scheduler worker scope (every worker_scope_launch caller) ---
say() { printf '%s\n' "$*" >> "$root/scheduler.log"; }
source "$engine/mac-autopilot/scheduler.d/worker-scope.sh"
launch_scope() { # label
  WORKER_SCOPE_PREPARED=false WORKER_SCOPE_WARNED=false WORKER_SCOPE_MODE='' WORKER_SCOPE_SYSTEMD_RUN=''
  : > "$calls"; : > "$root/scheduler.log"
  CFG='{"engine":{"worker_tasks_max":500}}'
  mkdir -p "$root/cg"; printf '%s\n' "${PIDS_EVENTS:-}" > "$root/cg/pids.events"; printf 'usage_usec 2543210\nuser_usec 1\n' > "$root/cg/cpu.stat"
  export WORKER_SCOPE_EVENTS_FILE="$root/cg/pids.events" LOG="$root/scheduler.log" SYSTEMD_RUN_EXEC=1
  WORKER_COST_TAG='type=implement unit=issue-9'
  worker_scope_launch "$root/$1.pid" "$root" "$root/$1.out" setsid -- bash -c 'sleep 1.2'
  [[ "$WORKER_SCOPE_MODE" == scope ]] || fail "$1: scope mode not used ($WORKER_SCOPE_MODE)"
}
TZ=Asia/Shanghai launch_scope default # the scope's local TZ must not leak into the Z stamps
assert_cpu_props 'worker-scope default' 200% 10
assert_mem_props 'worker-scope default' 2G 500 nomax
for _ in {1..150}; do grep -q 'worker cost' "$root/scheduler.log" && break; sleep 0.1; done
grep -Eq '^\[[0-9TZ:-]+\] worker cost type=implement unit=issue-9 wall=[0-9]+ cpu=2\.5$' "$root/scheduler.log" \
  || fail "worker cost line missing or malformed: $(cat "$root/scheduler.log")"
stamp="$(sed -n 's/^\[\([0-9T:-]*Z\)\] worker cost .*/\1/p' "$root/scheduler.log" | head -1)"
skew=$(( $(date -u +%s) - $(date -u -d "$stamp" +%s) )); skew=${skew#-}
(( skew < 60 )) || fail "worker cost stamp $stamp is ${skew}s off UTC now: the scope's TZ leaked into a Z stamp"
printf 'PASS worker-scope logs wall and cpu: %s\n' "$(grep 'worker cost' "$root/scheduler.log")"
# The TasksMax refusal stamps its own row from the watcher's other printf site; "max 3" is a refused fork count.
PIDS_EVENTS='max 3' TZ=Asia/Shanghai launch_scope tasksmax
for _ in {1..150}; do grep -q 'worker-tasksmax-hit' "$root/scheduler.log" && grep -q 'worker cost' "$root/scheduler.log" && break; sleep 0.1; done
stamp="$(sed -n 's/^\[\([0-9T:-]*Z\)\] worker-tasksmax-hit .*/\1/p' "$root/scheduler.log" | head -1)"
[[ -n $stamp ]] || fail "worker-tasksmax-hit row missing or malformed: $(cat "$root/scheduler.log")"
skew=$(( $(date -u +%s) - $(date -u -d "$stamp" +%s) )); skew=${skew#-}
(( skew < 60 )) || fail "worker-tasksmax-hit stamp $stamp is ${skew}s off UTC now: the scope's TZ leaked into a Z stamp"
printf 'PASS worker-scope tasksmax-hit stamp is UTC: %s\n' "$stamp"
AGENT_WORKER_CPU_QUOTA=150% AGENT_WORKER_CPU_WEIGHT=5 AGENT_WORKER_MEM_HIGH=1G launch_scope override
assert_cpu_props 'worker-scope override' 150% 5
assert_mem_props 'worker-scope override' 1G 500 nomax
# The task limit stays the existing engine.worker_tasks_max knob (config.template.json: 500); worker-tasksmax.test.sh pins that.
unset WORKER_SCOPE_EVENTS_FILE LOG SYSTEMD_RUN_EXEC WORKER_COST_TAG

# --- bin/luna and bin/zc: LUNA_CPU_QUOTA still wins, hotfix keeps 1000 ---
export WORKER_SCRATCH_ROOT="$root/scratch"; mkdir -p "$WORKER_SCRATCH_ROOT"
export AGENT_HOME="$root/agent-home"; mkdir -p "$AGENT_HOME"   # no hold marker here, so the live one cannot leak in
: > "$root/prompt.md"
for backend in luna zc; do
  : > "$calls"; : > "$sctl"; rm -f "$WORKER_SCRATCH_ROOT"/luna/k1/rc "$WORKER_SCRATCH_ROOT"/zc/k1/rc
  "$engine/bin/$backend" k1 "$root" "$root/prompt.md" >/dev/null 2>&1 || :
  assert_inline_props "bin/$backend default" 200% 10
  assert_mem_props "bin/$backend default" 2G 500
  assert_scope_stop "bin/$backend default"
  : > "$calls"; LUNA_CPU_QUOTA=300% AGENT_WORKER_CPU_WEIGHT=7 "$engine/bin/$backend" k1 "$root" "$root/prompt.md" >/dev/null 2>&1 || :
  assert_inline_props "bin/$backend LUNA_CPU_QUOTA" 300% 7
  : > "$calls"; LUNA_PRIORITY=hotfix "$engine/bin/$backend" k1 "$root" "$root/prompt.md" >/dev/null 2>&1 || :
  assert_inline_props "bin/$backend hotfix" 200% 1000
  : > "$calls"; AGENT_WORKER_MEM_HIGH=3G AGENT_WORKER_TASKS_MAX=900 "$engine/bin/$backend" k1 "$root" "$root/prompt.md" >/dev/null 2>&1 || :
  assert_mem_props "bin/$backend knobs" 3G 900
done

# --- bin/zc honours the ZCode hold marker (bin/worker reads the same file) ---
hold_home="$root/hold-home"; mkdir -p "$hold_home"
echo $(( $(date +%s) + 3600 )) > "$hold_home/zcode-exhausted-until"
rc=0; : > "$calls"; AGENT_HOME="$hold_home" "$engine/bin/zc" k1 "$root" "$root/prompt.md" >/dev/null 2>"$root/zc-hold.err" || rc=$?
[[ "$rc" == 75 ]] || fail "bin/zc held: rc $rc, want 75"
grep -Eq '^zc: ZCode held until [0-9T:-]+Z \(zcode-exhausted-until\); set ZC_IGNORE_HOLD=1 to override$' "$root/zc-hold.err" \
  || fail "bin/zc held: stderr line missing: $(cat "$root/zc-hold.err")"
! grep -q '^BEGIN$' "$calls" || fail "bin/zc held: systemd-run was called"
printf 'PASS bin/zc held marker: rc 75, no systemd-run\n'
: > "$calls"; ZC_IGNORE_HOLD=1 AGENT_HOME="$hold_home" "$engine/bin/zc" k1 "$root" "$root/prompt.md" >/dev/null 2>&1 || :
assert_inline_props 'bin/zc ZC_IGNORE_HOLD=1' 200% 10
echo $(( $(date +%s) - 60 )) > "$hold_home/zcode-exhausted-until"
: > "$calls"; AGENT_HOME="$hold_home" "$engine/bin/zc" k1 "$root" "$root/prompt.md" >/dev/null 2>&1 || :
assert_inline_props 'bin/zc expired marker' 200% 10
unset AGENT_HOME

# --- factory/launch.sh ---
fhome="$root/home"; mkdir -p "$fhome/.zenoforge/checkout-wt/f1" "$fhome/.zenoforge/scratch/factory" "$fhome/.zenoforge/scratch/luna/briefs"
: > "$fhome/.zenoforge/scratch/factory/common.md"; : > "$fhome/.zenoforge/scratch/luna/briefs/_rules.md"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_bin/git"; cp "$fake_bin/git" "$fake_bin/gh"; chmod +x "$fake_bin/git" "$fake_bin/gh"
printf 'x\n' > "$root/note.md"
: > "$calls"; HOME="$fhome" WORKER_SCRATCH_ROOT="$fhome/.zenoforge/scratch" "$engine/factory/launch.sh" f1 0 "$root/note.md" >/dev/null 2>&1 || :
assert_inline_props 'factory/launch.sh default' 200% 10
assert_mem_props 'factory/launch.sh default' 2G 500 nomax
: > "$calls"; HOME="$fhome" LUNA_CPU_QUOTA=250% WORKER_SCRATCH_ROOT="$fhome/.zenoforge/scratch" "$engine/factory/launch.sh" f1 0 "$root/note.md" >/dev/null 2>&1 || :
assert_inline_props 'factory/launch.sh LUNA_CPU_QUOTA' 250% 10
