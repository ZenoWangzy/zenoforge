#!/usr/bin/env bash
set -uo pipefail

script=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")

control() (
  local engine=$1 target=$2 engine_sha=$3 head_sha=$4 pin=$1/tools/pin-vecta.sh
  local agent_home=${AGENT_HOME:-${ZF_HOME:-}} live_engine_sync
  local engine_repo=${ZF_LOCAL_CLONE:-$engine} worktree out_root steps scratch build_status check_status
  local -a version_dirs
  [[ -n $agent_home ]] || return 2
  engine_repo=$(git -C "$engine_repo" rev-parse --show-toplevel 2>/dev/null) || return 2
  live_engine_sync=${ZF_ENGINE_SYNC:-$agent_home/engine-live/engine-sync.sh}
  [[ $live_engine_sync == */* ]] || live_engine_sync=$(command -v -- "$live_engine_sync") || return 2
  [[ -f $live_engine_sync ]] || return 2
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/pin-fail-control.XXXXXXXX") || return 2
  worktree=$scratch/worktree out_root=$scratch/out steps=$scratch/steps.sh
  cleanup() {
    git -C "$target" worktree remove --force "$worktree" >/dev/null 2>&1 || :
    chmod -R u+w -- "$scratch" 2>/dev/null || :
    rm -rf -- "$scratch"
  }
  trap cleanup EXIT
  trap 'exit 124' TERM INT
  # A changed block must be checked before the control can execute it.
  awk '/^run_bounded_step\(\) \{/ { copy=1; starts++ } copy { print } copy && /^run_bounded_step check / { ends++; copy=0 } END { if (starts != 1 || ends != 1 || copy) exit 1 }' "$pin" > "$steps" || return 2
  [[ $(git -C "$engine" hash-object --stdin < "$steps") == d03626670cccd62a022be60b1401c05252c57452 ]] || return 2
  bash -n "$steps" || return 2
  mkdir -p "$out_root" || return 2
  git -C "$target" worktree add -q --detach "$worktree" "$head_sha" || return 2
  source "$steps"
  ((build_status == 0 && check_status == 0 && ${#version_dirs[@]} <= 1)) || return 1
)

if [[ ${1:-} == --control ]]; then
  (($# == 5)) || exit 2
  control "$2" "$3" "$4" "$5"
  exit $?
fi
(($# == 5)) || exit 2
engine=$1 target=$2 head=$3 log=$4 pin_rc=$5
home=${ZF_AUTO_PIN_HOME:-$HOME/.zenoforge}
agent_home=${AGENT_HOME:-${ZF_HOME:-}}
alerts=${ZF_ALERTS_FILE:-${agent_home:+$agent_home/logs/head-watch.alerts}}
[[ -n $alerts ]] || exit 2
[[ ! -e $home/pin-fail-triage.stop ]] || exit 0
case $pin_rc in 0|2|75|124|137) exit 0 ;; esac
excluded() { grep -Eqi 'add this row|rate limit|source checkout has changes|could not (read|inspect) zenoforge main CI runs|result=land-failed' "$1"; }
excluded "$log" && exit 0
( set -o noclobber; : > "$log.pin-fail-triaged" ) 2>/dev/null || exit 0
repo=$(git -C "$engine" remote get-url origin | sed -E 's#^(https?://[^/]+/|[^@]+@[^:]+:)##; s#\.git$##')
pinned=unknown
alert() {
  mkdir -p "$(dirname -- "$alerts")" || return 1
  printf '%s %s %s main head=%s pinned=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$repo" "$head" "$pinned" "$2" >> "$alerts"
}
no_culprit() { alert PIN-FAIL-NO-CULPRIT "$1"; exit 0; }
# auto-pin pins the same head again when product main moves; without the marker that attempt is triaged again.
moved() { rm -f -- "$log.pin-fail-triaged"; no_culprit "$1"; }
[[ $head =~ ^[0-9a-f]{40}$ ]] || no_culprit 'invalid failed head'
old_product=$(git -C "$target" rev-parse --verify refs/remotes/origin/main^{commit} 2>/dev/null) || no_culprit 'product main unavailable'
timeout --kill-after=5 60 git -C "$target" fetch -q --no-tags origin +refs/heads/main:refs/remotes/origin/main || no_culprit 'product fetch failed'
product_head=$(git -C "$target" rev-parse --verify refs/remotes/origin/main^{commit}) || no_culprit 'product main unavailable'
pinned=$(git -C "$target" show "$product_head:.zenoforge/build.json" | jq -er '.engine | select(type == "string" and test("^[0-9a-f]{40}$"))') || no_culprit 'product engine pin unavailable'
control_rc=0
timeout --kill-after=5 500 bash "$script" --control "$engine" "$target" "$pinned" "$product_head" || control_rc=$?
if ((control_rc == 1)); then
  alert PIN-FAIL-PRODUCT "log=$log"
  exit 0
fi
((control_rc == 0)) || no_culprit "control unavailable rc=$control_rc"
[[ $old_product == "$product_head" ]] || moved 'product main moved after the failed pin'
source_head=$(git -C "$target" rev-parse HEAD 2>/dev/null || :)
[[ $source_head == "$product_head" ]] || { [[ $(git -C "$target" symbolic-ref -q --short HEAD 2>/dev/null || :) == main ]] \
  && git -C "$target" merge-base --is-ancestor "$source_head" "$product_head"; } || no_culprit 'pin source does not use product main'
git -C "$engine" merge-base --is-ancestor "$pinned" "$head" || no_culprit 'pinned commit is not an ancestor of failed head'
scratch=$(mktemp -d "${TMPDIR:-/tmp}/pin-fail-triage.XXXXXXXX") || no_culprit 'could not create temporary directory'
trap 'rm -rf -- "$scratch"' EXIT
if ! timeout --kill-after=5 60 git -C "$engine" rev-list --first-parent --reverse "$pinned..$head" > "$scratch/candidates"; then
  no_culprit 'could not list engine candidates'
fi
mapfile -t candidates < "$scratch/candidates"
shorts=$(printf '%.7s ' "${candidates[@]}")
((${#candidates[@]} > 0)) || no_culprit "no candidates: $shorts"
first_parent=$(git -C "$engine" rev-parse "${candidates[0]}^1" 2>/dev/null || :)
[[ $first_parent == "$pinned" ]] || no_culprit "pinned commit is not on first-parent history; candidates: $shorts"
((${#candidates[@]} <= 5)) || no_culprit "more than five candidates: $shorts"
culprit=''
if ((${#candidates[@]} == 1)); then
  if awk '/pin-vecta: refusing publication / { for (i=1; i<=NF; i++) if ($i ~ /^(build_status|check_status|vecta_gate_status)=[0-9]+$/) { split($i,a,"="); if (a[2] != 0) found=1 } } END { exit !found }' "$log" \
    || grep -q '^pin-vecta: refusing pin: override .*:' "$log"; then
    culprit=${candidates[0]}
  fi
else
  for candidate in "${candidates[@]}"; do
    candidate_rc=0
    (cd "$engine" && timeout --kill-after=5 500 bash tools/pin-vecta.sh "$candidate" "$target") > "$scratch/candidate.log" 2>&1 || candidate_rc=$?
    if ((candidate_rc != 0)); then
      case $candidate_rc in 2|75|124|137) no_culprit "candidate ${candidate:0:7} unavailable rc=$candidate_rc; candidates: $shorts" ;; esac
      excluded "$scratch/candidate.log" && no_culprit "candidate ${candidate:0:7} had an excluded refusal; candidates: $shorts"
      culprit=$candidate
      break
    fi
  done
fi
[[ -n $culprit ]] || no_culprit "no failing candidate; candidates: $shorts"
timeout --kill-after=5 60 git -C "$target" fetch -q --no-tags origin +refs/heads/main:refs/remotes/origin/main || no_culprit "product fetch failed; culprit=$culprit"
[[ $(git -C "$target" rev-parse refs/remotes/origin/main) == "$product_head" ]] || moved "product main moved; culprit=$culprit"
revert_rc=0
(cd "$engine" && ZF_MAIN_RED_REVERT_HOME=${ZF_MAIN_RED_REVERT_HOME:-$home} timeout --kill-after=5 120 bash tools/main-red-revert.sh \
  --culprit "$culprit" --reason "pin build failed at $culprit" --last-pinned "$pinned" --failed-head "$head") > "$scratch/revert.log" 2>&1 || revert_rc=$?
cat "$scratch/revert.log"
if ((revert_rc != 0)) && ! grep -q 'PIN-FAIL-' "$scratch/revert.log"; then
  alert PIN-FAIL-REVERT-CONFLICT "culprit=$culprit revert unavailable rc=$revert_rc"
fi
