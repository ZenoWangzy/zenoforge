#!/usr/bin/env bash
# Pins each new zenoforge main commit, oldest first, one pin per merge (ruling zenoforge-instant-effect-2026-11-05).
# A failed pin waits for the next main commit, then moves on. Stop by hand: touch "$ZF_AUTO_PIN_HOME/auto-pin.stop"
# Run a copy, not the clone's file: the loop checks out new commits in its clone (see tools/zf-auto-pin.service).
# State and stop file live in ZF_AUTO_PIN_HOME; engine/mac-autopilot/pin-lag.sh (bell) reads auto-pin.last to alert on a stall.
set -u
ZF_AUTO_PIN_HOME=${ZF_AUTO_PIN_HOME:-$HOME/.zenoforge}
AGENT_HOME=${AGENT_HOME:-$HOME/.vecta-agent}
C=${ZF_AUTO_PIN_CLONE:-$ZF_AUTO_PIN_HOME/clones/pz-zf-review-verdict-clobber}
idle=${ZF_AUTO_PIN_IDLE_SECS:-30} retry=${ZF_AUTO_PIN_RETRY_SECS:-60}
state=$ZF_AUTO_PIN_HOME/auto-pin.last; stop=$ZF_AUTO_PIN_HOME/auto-pin.stop
logdir=$ZF_AUTO_PIN_HOME/auto-pin-logs
# Head 2026-11-05: an override pin must take the PR lane; merge that PR here so it does not wait for head.
# Only a PR holding exactly build.json, overrides.tsv and the pack copies merged by this pin, with no failed check.
merge_override_pin() { # log -> 0 merged, 1 leave for head
  local log=$1 url pr allowed files bad state i
  url=$(sed -n 's/.*result=pr-open route=PR landed=no pr=\([^ ]*\).*/\1/p' "$log" | tail -1)
  pr=${url##*/}; [[ $pr =~ ^[1-9][0-9]*$ ]] || { echo 'override-pin: no PR number in the pin log'; return 1; }
  allowed=$(printf '%s\n' .zenoforge/build.json .zenoforge/build/overrides.tsv; sed -n 's#^pin-vecta: merged override \([^ ]*\) base=.*#.zenoforge/build/pack/scripts/agent/\1#p' "$log")
  [[ $(wc -l <<<"$allowed") -ge 3 ]] || { echo "override-pin: #$pr merged no override"; return 1; }
  files=$(gh pr view "$pr" -R ZenoWangzy/vecta --json files -q '.files[].path') || return 1
  if [[ $(sort <<<"$files") != "$(sort <<<"$allowed")" ]]; then echo "override-pin: #$pr files are not exactly the pin and its overrides"; return 1; fi
  bad=$(gh pr view "$pr" -R ZenoWangzy/vecta --json statusCheckRollup -q '[.statusCheckRollup[] | select((.conclusion // .state // "") | test("^(FAILURE|ERROR|CANCELLED|TIMED_OUT|ACTION_REQUIRED|STARTUP_FAILURE)$"))] | length') || return 1
  [[ $bad == 0 ]] || { echo "override-pin: #$pr has $bad failed check(s)"; return 1; }
  gh pr merge "$pr" -R ZenoWangzy/vecta --squash >>"$log" 2>&1 || { echo "override-pin: gh pr merge #$pr failed"; return 1; }
  for ((i = 0; i < 20; i++)); do
    state=$(gh pr view "$pr" -R ZenoWangzy/vecta --json state -q .state 2>/dev/null)
    [[ $state == MERGED ]] && return 0
    sleep 6
  done
  echo "override-pin: #$pr not MERGED after the wait"; return 1
}

# One pass: fetch, pin the oldest unpinned main commit. Returns 1 only when the checkout fails (the unit restarts the daemon).
auto_pin_pass() {
  local last next merged log rc
  git -C "$C" fetch -q origin main || { sleep "$idle"; return 0; }
  last=$(cat "$state")
  next=$(git -C "$C" rev-list --reverse --first-parent "$last..origin/main" | head -1)
  if [[ -z $next ]]; then sleep "$idle"; return 0; fi
  git -C "$C" checkout -q --detach "$next" || return 1
  merged=$(git -C "$C" log -1 --format=%cI "$next"); log="$logdir/${next:0:12}.log"
  # shortcut: timeout bounds one pin at 500s, same as the manual flow; a slower land needs a manual rerun.
  rc=0; (cd "$C" && timeout 500 bash tools/pin-vecta.sh "$next" "$AGENT_HOME/checkout" --land) >"$log" 2>&1 || rc=$?
  if ((rc == 75)) && merge_override_pin "$log"; then
    # The PR route does not fast-forward the live checkout; the agent tick does, then converges.
    systemctl --user start --no-block vecta-agent.service 2>/dev/null || :
    echo "$next" > "$state"; echo "$(date -u +%H:%M:%S) PINNED ${next:0:12} via-pr committed=$merged $(git -C "$C" log -1 --format=%s "$next" | cut -c1-70)"
  elif ((rc == 0)); then
    AGENT_HOME=$AGENT_HOME timeout 280 "$AGENT_HOME/checkout/.zenoforge/build/engine-sync.sh" --converge "$AGENT_HOME/checkout" "$AGENT_HOME" >>"$log" 2>&1 || echo "$(date -u +%H:%M:%S) CONVERGE-FAILED ${next:0:12}"  # live now, not at the next timer run
    echo "$next" > "$state"; echo "$(date -u +%H:%M:%S) PINNED ${next:0:12} committed=$merged $(git -C "$C" log -1 --format=%s "$next" | cut -c1-70)"
  else
    echo "$(date -u +%H:%M:%S) PIN-FAILED ${next:0:12} log=$log"; grep -E 'pin-vecta:|refus|add this row' "$log" | tail -4 | cut -c1-200
    # Fix forward: a failed pin must not stop the daemon, the next main commit carries the repair.
    while [[ ! -e $stop ]]; do
      sleep "$retry"; git -C "$C" fetch -q origin main || continue
      [[ "$(git -C "$C" rev-parse origin/main)" == "$next" ]] || break
    done
    echo "$next" > "$state"
  fi
}

auto_pin_main() {
  mkdir -p "$logdir" "$ZF_AUTO_PIN_HOME/locks"
  exec 8>"$ZF_AUTO_PIN_HOME/locks/auto-pin"; flock -n 8 || { echo 'zf-auto-pin: already running'; exit 1; }
  while [[ ! -e $stop ]]; do auto_pin_pass || exit 1; done
  echo 'zf-auto-pin: stopped by stop file'
}
[[ ${BASH_SOURCE[0]} != "$0" ]] || auto_pin_main
