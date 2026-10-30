#!/usr/bin/env bash
# Reviewed PRs: CI + concurrent exact-tree mergecheck -> ordered landing. No release.
{
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/queue-lib.sh"
n=${1:-}; shift || true
[[ $n =~ ^b[0-9]+$ && $# -gt 0 ]] || { echo 'usage: drive-train.sh <bNN> <pr>...' >&2; exit 2; }
mkdir -p "$T/$n" "$S/lw"
mc_pid=''
cleanup() {
  local rc=$?
  [[ -z $mc_pid ]] || { kill -- "-$mc_pid" 2>/dev/null || true; wait "$mc_pid" 2>/dev/null || true; }
  case $(state "$n") in
    landed|red) ;;
    *) set_state "$n" failed; cancel_runs "$n"
       if [[ -f $T/$n/prs ]]; then
         mapfile -t retry_prs < "$T/$n/prs"; requeue "$n" "${retry_prs[@]}"
       fi;;
  esac
  return "$rc"
}
trap cleanup EXIT
trap 'exit 143' TERM INT
if [[ ${TRAIN_QUEUE_PREPARED:-0} != 1 ]]; then
  compose "$n" 0 "$@" || exit 1
fi
while true; do
  rm -f "$T/$n/mergecheck.rc" "$T/$n/mergecheck.failure" "$T/$n/cancelled"
  set_state "$n" ci
  publish_train "$n" || { set_state "$n" failed; cancel_runs "$n"; exit 1; }
  expected_runs=$(train_expected_runs "$n") || { qlog "invalid suites decision $n"; exit 1; }
  sha=$(cat "$T/$n/sha"); base=$(cat "$T/$n/base")
  env ZF_SCRATCH="$S" ZF_CHECKOUT="$C" TRAIN_DIR="$T" TRAIN_WORKTREE_ROOT="$WROOT" setsid bash -c 'bash "$1/prs/mergecheck.sh" "$2" "$3" --tree "$4"; rc=$?; printf "%s\n" "$rc" > "$5/$2/mergecheck.rc.tmp"; mv "$5/$2/mergecheck.rc.tmp" "$5/$2/mergecheck.rc"' _ "$S" "$n" "$base" "$sha" "$T" &
  mc_pid=$!
  while true; do
    if [[ -f $T/$n/mergecheck.rc && $(cat "$T/$n/mergecheck.rc") != 0 ]]; then
      test=mergecheck; path=''
      [[ ! -f $T/$n/mergecheck.failure ]] || IFS=$'\t' read -r test path < "$T/$n/mergecheck.failure"
      if [[ $test == INFRA:* ]]; then
        qlog "infra $n $test"
        set_state "$n" failed; exit 1
      fi
      red_train "$n" "$test" "$path"; exit 1
    fi
    # mergecheck itself may be killed; do not silently wait for hours.
    if ! kill -0 "$mc_pid" 2>/dev/null && [[ ! -f $T/$n/mergecheck.rc ]]; then
      red_train "$n" mergecheck-exited; exit 1
    fi
    refresh_runs
    if cache_fresh; then
      rows=$(train_runs "$n") || rows='[]'
      if jq -e 'any(.[]; .status == "completed" and .conclusion != "success")' <<<"$rows" >/dev/null; then
        red_train "$n" CI; exit 1
      fi
      if jq --argjson expected "$expected_runs" -e 'length == $expected and all(.[]; .status == "completed" and .conclusion == "success")' <<<"$rows" >/dev/null &&
        [[ -f $T/$n/mergecheck.rc && $(cat "$T/$n/mergecheck.rc") == 0 ]]; then
        break
      fi
    fi
    sleep "$POLL"
  done
  wait "$mc_pid"; mc_pid=''
  printf '[%s] TRAIN GREEN %s sha=%s\n' "$(date -u +%FT%TZ)" "$n" "${sha:0:9}" >> "${TRAIN_EVENTS_FILE:-$S/prs/merge-events.log}"
  atomic "$T/$n/bisect-result" green
  set_state "$n" green
  while lower_pending "$n"; do sleep "$POLL"; done
  # Siblings were tested on the old main. A later train must earn fresh CI on
  # the advanced baseline; train.sh's exact-base landing contract stays intact.
  git -C "$C" fetch -q origin main || exit 1
  current=$(git -C "$C" rev-parse origin/main) || exit 1
  if [[ $current != "$base" ]]; then
    set_state "$n" rebuild
    qlog "rebuild $n base=$current"
    until [[ $(state "$n") == preparing ]]; do sleep "$POLL"; done
    mapfile -t prs < "$T/$n/prs"
    compose "$n" 1 "${prs[@]}" || exit 1
    continue
  fi
  bash "$S/prs/land-train.sh" "$n" || exit 1
  set_state "$n" landed
  qlog "land $n $(cat "$T/$n/landed-sha")"
  exit 0
done
}
