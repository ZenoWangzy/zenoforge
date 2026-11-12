#!/usr/bin/env bash
# Pins the newest zenoforge main commit as soon as main moves (rulings zenoforge-instant-effect-2026-11-05, zenoforge-batch-land-2026-11-08:
# "Pin follows the batch at once"). Commits merged together are pinned once, at main's head: walking them one by one cost ~500 s each.
# A failed pin waits for the next main commit, then moves on; dirty-checkout and changed-VectA-head refusals retry once per fix. Stop by hand: touch "$ZF_AUTO_PIN_HOME/auto-pin.stop"
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
# Only a PR holding build.json, overrides.tsv and, optionally, the pack copies merged by this pin, with no failed check.
# A clean three-way merge that leaves a pack copy byte-identical adds no pack file, so the PR is base-only.
merge_override_pin() { # log -> 0 merged, 1 leave for head
  local log=$1 url pr allowed files bad state i
  url=$(sed -n 's/.*result=pr-open route=PR landed=no pr=\([^ ]*\).*/\1/p' "$log" | tail -1)
  pr=${url##*/}; [[ $pr =~ ^[1-9][0-9]*$ ]] || { echo 'override-pin: no PR number in the pin log'; return 1; }
  allowed=$(printf '%s\n' .zenoforge/build.json .zenoforge/build/overrides.tsv; sed -n 's#^pin-vecta: merged override \([^ ]*\) base=.*#.zenoforge/build/pack/scripts/agent/\1#p' "$log")
  [[ $(wc -l <<<"$allowed") -ge 3 ]] || { echo "override-pin: #$pr merged no override"; return 1; }
  files=$(gh pr view "$pr" -R ZenoWangzy/vecta --json files -q '.files[].path') || return 1
  if [[ -n $(comm -23 <(sort <<<"$files") <(sort <<<"$allowed")) \
     || -n $(comm -13 <(sort <<<"$files") <(sort <<<".zenoforge/build.json"$'\n'".zenoforge/build/overrides.tsv")) ]]; then
    echo "override-pin: #$pr files are not the pin, its overrides and their pack copies"; return 1
  fi
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
  local last next merged log rc vecta_failed_head vecta_head
  git -C "$C" fetch -q origin main || { sleep "$idle"; return 0; }
  last=$(cat "$state")
  next=$(git -C "$C" rev-list -1 --first-parent "$last..origin/main")
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
    vecta_failed_head=$(git -C "$AGENT_HOME/checkout" rev-parse HEAD 2>/dev/null || :)
    echo "$(date -u +%H:%M:%S) PIN-FAILED ${next:0:12} log=$log"; grep -E 'pin-vecta:|refus|add this row' "$log" | tail -4 | cut -c1-200
    # Fix forward: a failed pin must not stop the daemon, the next main commit carries the repair.
    while [[ ! -e $stop ]]; do
      sleep "$retry"; git -C "$C" fetch -q origin main || continue
      [[ "$(git -C "$C" rev-parse origin/main)" == "$next" ]] || break
      # A dirty checkout clears with no new main commit, so try the same commit again.
      grep -q 'source checkout has changes' "$log" && [[ -z "$(git -C "$AGENT_HOME/checkout" status --porcelain 2>/dev/null)" ]] && return 0
      # A row declared for this commit after the refusal: try it again, since a new main commit would make the row stale. Once only.
      if grep -q 'add this row' "$log" && [[ ! -e $log.row-retried ]] \
        && grep -Eq "$next|sha256:" "$AGENT_HOME/checkout/.zenoforge/build/intended-changes.tsv" 2>/dev/null; then
        : > "$log.row-retried"; return 0
      fi
      # A moved VectA checkout may fix a refusal; retry this commit once for each new checkout head.
      vecta_head=$(git -C "$AGENT_HOME/checkout" rev-parse HEAD 2>/dev/null || :)
      if [[ -n $vecta_failed_head && -n $vecta_head && $vecta_head != "$vecta_failed_head" \
        && ! -e $log.vecta-head-$vecta_head-retried ]]; then
        : > "$log.vecta-head-$vecta_head-retried"
        echo "$(date -u +%H:%M:%S) RETRY-VECTA-HEAD from=$vecta_failed_head to=$vecta_head commit=$next"
        return 0
      fi
    done
    echo "$next" > "$state"
  fi
}

auto_pin_main() {
  mkdir -p "$logdir" "$ZF_AUTO_PIN_HOME/locks"
  exec 8>"$ZF_AUTO_PIN_HOME/locks/auto-pin"; flock -n 8 || { echo 'zf-auto-pin: already running'; exit 1; }
  while [[ ! -e $stop ]]; do
    auto_pin_pass || exit 1
    # A running daemon keeps the script it started with: #656 sat unused for 13 hours. On exit systemd reinstalls the copy from the clone.
    if [[ -f $C/tools/auto-pin.sh ]] && ! cmp -s "$C/tools/auto-pin.sh" "${BASH_SOURCE[0]}"; then
      echo 'zf-auto-pin: the clone has a newer script, exiting for systemd to reinstall it'; exit 0
    fi
  done
  echo 'zf-auto-pin: stopped by stop file'
}
[[ ${BASH_SOURCE[0]} != "$0" ]] || auto_pin_main
