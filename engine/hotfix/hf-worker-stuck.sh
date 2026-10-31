#!/usr/bin/env bash
# hf-worker-stuck.sh: list live bin/worker runs that are past HF_WORKER_BUDGET_MIN (default 45) with nothing to show: no commit ahead
# of origin/main and no uncommitted change in the worker's cwd. Exit 1 if any. The worker's own stall check (10 min without output)
# measures activity; a looping worker passes it for hours (10-31: fix-fruit-r 2h and 19k events, #4620 8 rounds, no code).
# shortcut: reads cwd from the wrapper's argv (bash worker <key> <cwd>) and trusts it is the target worktree; brief paths that differ are skipped.
set -uo pipefail
S=${WORKER_SCRATCH_ROOT:-${HOME:-/tmp}/.zenoforge/scratch}; budget=${HF_WORKER_BUDGET_MIN:-45}; now=${HF_NOW:-$(date +%s)}
out=''
for d in "$S"/luna/*/; do
  k=$(basename "$d"); [[ -f $d/rc ]] && continue
  pid=$(cat "$d/wrapper.pid" 2>/dev/null) || continue
  [[ -r /proc/$pid/cmdline ]] || continue
  cwd=$(tr '\0' '\n' < "/proc/$pid/cmdline" | sed -n 4p)
  [[ -d $cwd/.git || -f $cwd/.git ]] || continue
  age=$(( (now - $(stat -c %Y "$d/backend")) / 60 ))
  ((age >= budget)) || continue
  ahead=$(git -C "$cwd" rev-list --count origin/main..HEAD 2>/dev/null || echo 0)
  dirty=$(git -C "$cwd" status --porcelain 2>/dev/null | wc -l)
  ((ahead == 0 && dirty == 0)) && out+="$k running ${age} min, 0 commits, 0 changes in $cwd"$'\n'
done
[[ -z $out ]] && exit 0
printf 'hf-worker-stuck: workers past %s min with nothing to show:\n%s' "$budget" "$out"
exit 1
