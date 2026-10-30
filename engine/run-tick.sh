#!/usr/bin/env bash
# Launcher for one issue-pipeline.sh tick. systemd/zenoforge-agent.service runs
# THIS script (not issue-pipeline.sh directly); systemd/zenoforge-agent.timer
# fires it every 5 minutes.
#
# 2026-09-13: issue-pipeline.sh used to run straight out of
# $HOME/src/target-repo — the maintainer's own interactive checkout. On
# 2026-09-13 that checkout sat one commit behind main while being reported
# as fixed: the running pipeline executed stale code and missed an
# instruction already published to main, and nothing told "main has the
# fix" apart from "the service is running the fix". This launcher's whole
# job is to close that gap: fast-forward a checkout DEDICATED to the
# pipeline ($HOME/.zenoforge/checkout, never touched interactively)
# from origin/main before every tick, and refuse to run that tick at all —
# rather than silently execute whatever was already on disk — if the
# fast-forward can't happen cleanly (wrong branch, divergence, fetch failure).
# A dirty checkout is quarantined and restored to HEAD before the fetch.
#
# Self-update hazard: this file lives INSIDE the checkout it fast-forwards.
# `git merge --ff-only` can rewrite this very file's bytes on disk while
# bash is still reading it — bash does not slurp a running script fully
# into memory up front, it reads it incrementally, so a rewrite mid-run can
# corrupt or skip whatever part of the file executes next. The fix is
# structural: the ENTIRE body below (fetch, merge, exec) lives inside one
# function, and that function is called on the LAST line of the file. Bash
# has to fully parse a function's body (find the matching closing brace)
# before it can execute any part of it or even finish defining it — so by
# the time `run_tick "$@"` below triggers the git commands that could
# rewrite this file, the whole function is already parsed and held in
# memory, with nothing left to re-read from disk. Do not "simplify" this
# back into top-level statements; that reopens exactly this hazard.
#
# 2026-09-14: the silent-death hole. zenoforge-agent.service is a Type=oneshot
# fired by a timer — a refused tick just exits 1 into the journal and
# systemd tries again in 5 minutes, forever, with no alert. That makes a
# PERSISTENT refusal (dirty checkout, diverged branch, a dead proxy)
# indistinguishable from "nothing to do": the whole pipeline can be down
# and the only symptom is silence. Two fixes, both required to live inside
# run_tick() itself for the self-update reason above:
#
# 1. A consecutive-failure counter under AGENT_HOME (outside the repo,
#    outside git, survives a reboot -- see AGENT_HOME resolution below,
#    same default $HOME/.zenoforge every other wrapper script uses via
#    lib.sh). Every refusal bumps it; a real success resets it. Crossing
#    the threshold writes one supervisor-inbox event per outage; a later
#    success writes an internal recovery event.
#    Threshold reasoning is in refuse()'s own comment.
# 2. Every exit now explains itself, on purpose, not by accident. The
#    known refusals already did (restore/branch/fetch/diverged); what didn't
#    exist was a backstop for anything ELSE that fails -- e.g. the
#    script_dir/repo_dir `cd` resolution just below, whose own failure
#    mode was a genuinely silent `x=$(cd ... && pwd)` exit under `set -e`
#    (a command substitution's exit status IS checked when it's the sole
#    right-hand side of a bare assignment -- verified empirically, this is
#    not the "command substitution failures are ignored" case people
#    usually mean). `set -E` (errtrace) plus a `trap ... ERR` inside
#    run_tick() catches any such failure, anywhere in this function
#    (including inside refuse() itself, which disarms the trap on entry so
#    it can't recurse into itself) and routes it through refuse() the same
#    as a known refusal, so nothing here can exit without saying why.
#
# Investigated, with evidence, whether this closes the ACTUAL 21:22 tick
# (exited 1 after 30s having printed only the opening "dedicated checkout
# is ..." line -- no refusal message at all): it does not need to, because
# the script did not fail silently that time either. Cross-referencing the
# unit-filtered journal (`journalctl --user -u zenoforge-agent.service`, the
# exact command this unit's own header tells an operator to run) against
# the full, unfiltered journal for the same second shows BOTH the expected
# git failure text and this script's own "refusing to run this tick — git
# fetch origin main failed ... (network down?)" line DO exist, timestamped
# 21:22:51, correctly attributed to this script's own PID -- they are just
# missing from the `-u`-filtered view. Microsecond timestamps
# (`-o short-precise`) show why: both lines were logged ~10ms AFTER
# systemd's own "Main process exited" record for the same tick, i.e. in
# the tail window right as this process's cgroup was being torn down --
# and the tls-proxy-bridge (the SAME proxy this fetch was failing through)
# was independently logging a 504 roughly every 1-3 seconds through that
# entire window, saturating journald. A process's last lines racing its
# own cgroup teardown, under heavy concurrent journal load, is a known
# journald quirk: the line still gets written and still gets its PID
# tagged correctly, but can lose its _SYSTEMD_UNIT association and so
# silently drop out of a `-u`-filtered query. The 19:51 fetch failure, same
# code path, logged under lighter journald load, shows no such gap. So:
# the 21:22 tick behaved exactly as designed; what actually failed was the
# documented way to VERIFY that (`journalctl -u ...`) under load. That is
# the other reason this fix does not lean on the journal at all -- the
# failure counter above is a direct file write from inside this same
# process, and its supervisor-inbox event is durable outside the checkout.
set -Eeuo pipefail

run_tick() {
  local script_dir="" repo_dir="" branch
  local fail_count_file alerted_file fail_threshold
  local timer_list timer_repo timer_gh_timeout_sec timer timer_off_variable timer_alert_marker
  local scheduler_status=0
  local dirty_status quarantine_root quarantine_entry untracked_paths snapshot_stamp
  local fast_forward_old_head fast_forward_new_head
  local timer_alerted_file timer_mode
  local timer_repair_action
  # AGENT_HOME declared+assigned in the SAME statement, not bare
  # `local AGENT_HOME` followed by a separate `AGENT_HOME="${AGENT_HOME:-...}"`
  # later: bash creates a bare `local NAME` as an already-shadowing empty
  # local the moment it's declared, so a later `NAME="${NAME:-default}"`
  # reads that fresh empty local, never the caller's/environment's value —
  # verified empirically, this cost a real test run a stray write into the
  # live AGENT_HOME before it was caught. `local NAME=$NAME` on one line
  # evaluates the right-hand side against the OUTER value first, which is
  # what this launcher needs.
  local AGENT_HOME="${AGENT_HOME:-$HOME/.zenoforge}"
  # One bounded retry handles a transient stall in the shared TLS proxy
  # without letting a single fetch hold the five-minute timer indefinitely.
  # fetch is read-only/idempotent; each attempt keeps the existing 60s cap.
  local git_fetch_timeout_sec="${GIT_FETCH_TIMEOUT_SEC:-60}"
  local git_fetch_status=0 git_fetch_attempt=0
  local load_1m processors
  local timer_gh_timeout_sec="${GH_CALL_TIMEOUT_SEC:-60}"

  append_supervisor_event() (
    local helper_dir="$script_dir"
    if [ -z "$helper_dir" ]; then
      helper_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[1]}")" && pwd -P)" || return 1
    fi
    export AGENT_HOME
    if [ -n "$repo_dir" ]; then export ZF_REPO_DIR="$repo_dir"; fi
    source "$helper_dir/lib.sh"
    supervisor_inbox_append "$@"
  )

  # refuse <tag> <detail> — the ONE exit path every refusal in this
  # function (known or, via the ERR trap below, unknown) routes through.
  # Explaining itself on stderr is the very first thing it does, before
  # anything that could itself fail (counter file, inbox write) — so that part
  # of the point (nothing exits without saying why) holds even if
  # AGENT_HOME turns out to be unwritable.
  refuse() {
    local tag="$1" detail="$2" observed count
    trap - ERR # don't recurse into ourselves on our own failures below
    echo "run-tick: refusing to run this tick — $detail" >&2
    observed="${detail//$'\n'/ }"
    observed="${observed//$'\r'/ }"

    if [ -n "$fail_count_file" ]; then
      count=$(( $(cat "$fail_count_file" 2>/dev/null || echo 0) + 1 ))
      echo "$count" >"$fail_count_file" 2>/dev/null || true

      if [ "$count" -ge "$fail_threshold" ] && [ ! -f "$alerted_file" ]; then
        append_supervisor_event tick-outage \
          "cause=$tag failures=$count observed=$observed" 2>/dev/null || true
        touch "$alerted_file" 2>/dev/null || true
      fi
    fi

    exit 1
  }

  # See the header's "2026-09-14: the silent-death hole" — set -E makes
  # this fire for a failure anywhere in this function, not just a bare
  # top-level command, so the script_dir/repo_dir resolution immediately
  # below (a real, if unlikely, silent-exit vector: `x=$(cd ... && pwd)`
  # exits under `set -e` with no message at all if that `cd` fails) is
  # covered from its very first line.
  trap 'refuse "unexpected" "internal error at line $LINENO running: $BASH_COMMAND"' ERR

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # engine/run-tick.sh -> repo root is two levels up.
  repo_dir="$(cd "$script_dir/.." && pwd)"
  # Load before this checkout self-updates; the shared function is then held in this shell.
  source "$script_dir/model-policy-fast-forward.sh"
  timer_list="$repo_dir/engine/systemd/pipeline-timers.list"
  # The target repository, as lib.sh derives it: ZF_REPO, else the checkout's origin remote.
  timer_repo="${ZF_REPO:-$(git -C "$repo_dir" remote get-url origin 2>/dev/null | sed -E 's#^(git@[^:]+:|[a-z+]+://([^/@]+@)?[^/]+/)##; s#\.git$##' || true)}"

  # AGENT_HOME (see above) is the same one every other wrapper script
  # resolves via lib.sh — outside the repo, outside git, survives a reboot.
  # Not sourcing lib.sh itself here: lib.sh also does `cd "$REPO_DIR"`
  # (default $HOME/src/target-repo, the maintainer's own interactive
  # checkout) and mkdir's a state/logs layout this launcher doesn't need —
  # pulling that in would fight this file's whole job of only ever
  # touching the DEDICATED checkout.
  # Source lib.sh only in child shells, so its cwd change and shared state
  # setup stay out of this launcher.
  mkdir -p "$AGENT_HOME"
  fail_count_file="$AGENT_HOME/tick-failure-count"
  alerted_file="$AGENT_HOME/tick-failure-alerted"
  # Ticks run every 5 minutes. Both real failures observed 2026-09-14
  # (19:51, 21:22) were single isolated ticks that recovered on their own
  # by the very next attempt — so 1 failure is noise, not signal, and
  # alerting on it would be exactly the false alarm the brief warns
  # against. 3 in a row (>=10 minutes of nothing but refusals) clears that
  # observed noise floor with room to spare, while still recording a real
  # outage for supervisor handling well inside 15 minutes rather than hours.
  fail_threshold=3

  source "$script_dir/dispatch-load-guard.sh"

  echo "run-tick: dedicated checkout is $repo_dir" >&2

  dirty_status="$(git -C "$repo_dir" status --porcelain --untracked-files=all)"
  if [ -n "$dirty_status" ]; then
    # No legitimate local edit belongs in this dedicated checkout. Keep
    # tracked and untracked payloads outside Git before restoring it.
    quarantine_root="$AGENT_HOME/quarantine"
    snapshot_stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    quarantine_entry="$quarantine_root/checkout-dirty-$snapshot_stamp"
    untracked_paths="$quarantine_entry/untracked.paths"
    if ! mkdir -p "$quarantine_root" || ! mkdir -m 700 "$quarantine_entry"; then
      refuse "checkout-restore-failed" "could not create dirty-checkout quarantine at $quarantine_entry"
    fi
    if ! git -C "$repo_dir" diff --binary HEAD >"$quarantine_entry/tracked.patch" \
      || ! git -C "$repo_dir" ls-files --others --exclude-standard -z >"$untracked_paths"; then
      refuse "checkout-restore-failed" "could not save tracked diff and untracked path list to $quarantine_entry"
    fi
    if [ -s "$untracked_paths" ] && ! (
      cd "$repo_dir" && tar --null --verbatim-files-from -cf "$quarantine_entry/untracked.tar" -T "$untracked_paths"
    ); then
      refuse "checkout-restore-failed" "could not archive untracked files to $quarantine_entry"
    fi
    chmod 600 "$quarantine_entry"/* 2>/dev/null || true
    if ! git -C "$repo_dir" reset --hard HEAD >/dev/null 2>&1 \
      || ! git -C "$repo_dir" clean -fd -- >/dev/null 2>&1; then
      refuse "checkout-restore-failed" "could not restore dirty checkout to HEAD after quarantining it at $quarantine_entry"
    fi
    dirty_status="$(git -C "$repo_dir" status --porcelain --untracked-files=all)"
    if [ -n "$dirty_status" ]; then
      refuse "checkout-restore-failed" "checkout still has changes after restore; quarantine saved at $quarantine_entry"
    fi
    echo "run-tick: dirty checkout quarantined at $quarantine_entry; restored to HEAD and continuing" >&2
  fi

  branch="$(git -C "$repo_dir" symbolic-ref --quiet --short HEAD || true)"
  if [ "$branch" != "main" ]; then
    refuse "wrong-branch" "$repo_dir is on '${branch:-detached HEAD}', not main"
  fi

  while :; do
    git_fetch_attempt=$((git_fetch_attempt + 1))
    if (
      export AGENT_HOME
      export ZF_REPO_DIR="$repo_dir" GIT_FETCH_TIMEOUT_SEC="$git_fetch_timeout_sec"
      source "$script_dir/lib.sh"
      ZF_GIT_FETCH_TRANSIENT_RETRIES=1 git_fetch_bounded "$repo_dir" main
    ); then
      break
    else
      git_fetch_status=$?
    fi
    if [ "$git_fetch_status" -eq 124 ] && [ "$git_fetch_attempt" -eq 1 ]; then
      echo "run-tick: git fetch timed out after ${git_fetch_timeout_sec}s; retrying once" >&2
      sleep 2
      continue
    fi
    if [ "$git_fetch_status" -eq 124 ]; then
      load_1m="$(awk 'NR == 1 { print $1 }' /proc/loadavg 2>/dev/null || true)"
      processors="$(nproc 2>/dev/null || true)"
      if dispatch_load_exceeded "$load_1m" "$processors" "${AGENT_DISPATCH_LOAD_LIMIT_MULTIPLIER:-2}"; then
        refuse "fetch-starved" "git fetch timed out after ${git_fetch_timeout_sec}s while host 1m load $load_1m exceeded ${AGENT_DISPATCH_LOAD_LIMIT_MULTIPLIER:-2}x processors ($processors)"
      fi
      refuse "fetch-timeout" "git fetch origin main timed out after ${git_fetch_timeout_sec}s on attempt $git_fetch_attempt; host 1m load was $load_1m on $processors processors"
    fi
    refuse "fetch-failed" "git fetch origin main failed on attempt $git_fetch_attempt (status $git_fetch_status) in $repo_dir"
  done

  fast_forward_old_head="$(git -C "$repo_dir" rev-parse HEAD)"
  if ! git -C "$repo_dir" merge --quiet --ff-only origin/main; then
    refuse "diverged" "$repo_dir has diverged from origin/main, fast-forward not possible"
  fi
  fast_forward_new_head="$(git -C "$repo_dir" rev-parse HEAD)"
  if ! sync_model_policy_default_after_fast_forward \
    "$repo_dir" "$AGENT_HOME" "$fast_forward_old_head" "$fast_forward_new_head"; then
    refuse "policy-sync-failed" "could not synchronize live model policy after fast-forward"
  fi

  # Name the version by its commit subject, never by an object id: this
  # project's hash ban forbids reading, recording or reporting Git object
  # IDs, and a subject line is what a human reading the journal at 3am can
  # actually act on.
  echo "run-tick: $repo_dir fast-forwarded to origin/main, now at: $(git -C "$repo_dir" log -1 --format=%s); handing off to issue-pipeline.sh" >&2

  # 2026-09-15 (#1299 review): the checkout above is fast-forwarded every
  # tick, but nothing was ever copying engine/systemd/*.service/
  # *.timer OUT of it into ~/.config/systemd/user/ -- the directory
  # systemd --user actually reads -- or telling systemd to re-read it.
  # Confirmed live: the installed zenoforge-agent.service was a plain `cp`, not
  # a symlink, and `systemctl --user show zenoforge-agent.service -p
  # RuntimeMaxUSec` still read the OLD value after this PR's own unit-file
  # change had already landed on main and been fast-forwarded into this
  # very checkout -- a hard cap sitting in version control, looking
  # applied, changing nothing live. Same shape as the incident this PR
  # fixes: a guarantee that exists in exactly one place nobody reads.
  #
  # A loop over the directory, not one filename special-cased, so
  # zenoforge-label-churn.service/.timer (or anything shipped here later) gets
  # the same guarantee. Comparison is `diff`, never a hash (project hash
  # ban). Never touches a live unit this repo doesn't ship (this box also
  # runs zenoforge-pgtest.service, installed by hand, unrelated to the issue
  # pipeline) -- this only ever pushes repo -> live, one direction, only
  # for files actually present in engine/systemd/.
  #
  # Placed right after the fast-forward above, before the hand-off below,
  # so a unit-file change on main takes effect the SAME tick it lands --
  # the same freshness guarantee this launcher already gives the rest of
  # the checkout.
  #
  # daemon-reload semantics below are VERIFIED LIVE on this box (systemd
  # 257, --user manager) against a throwaway test unit (never the real
  # zenoforge-agent.service/.timer -- those were never stopped, disabled or
  # restarted to produce this evidence), never assumed:
  #   1. `systemctl --user daemon-reload` while a unit is ACTIVE does not
  #      disturb it -- confirmed same MainPID, same ActiveState, across a
  #      reload landing mid-run.
  #   2. RuntimeMaxSec has NO EFFECT on a Type=oneshot unit on this
  #      systemd -- it logs exactly that ("RuntimeMaxSec= has no effect in
  #      combination with Type=oneshot. Ignoring.") and a running instance
  #      is never touched by it, confirmed against a throwaway Type=oneshot
  #      unit matching zenoforge-agent.service's own Type. This is why that
  #      unit's hard cap (this same PR) is TimeoutStartSec, not
  #      RuntimeMaxSec -- see systemd/zenoforge-agent.service's own comment.
  #      TimeoutStartSec DOES enforce for Type=oneshot (a oneshot has no
  #      separate "started, now idling" phase RuntimeMaxSec's "active too
  #      long" concept assumes; the whole ExecStart run IS the start job)
  #      -- confirmed: a throwaway unit with TimeoutStartSec=2s was
  #      SIGTERM-killed (Result=timeout) within 3s of a fresh start.
  #   3. Unlike RuntimeMaxSec, a reload DOES retroactively re-evaluate
  #      TimeoutStartSec against an ALREADY-RUNNING start job's elapsed
  #      time -- confirmed: a unit with no timeout, already 10s into its
  #      run, was killed within about a second of a reload that installed
  #      TimeoutStartSec=2s (already exceeded by the time the reload
  #      landed). Harmless for this launcher's own tick: this step runs
  #      seconds into a tick, nowhere near a 20-minute budget either way,
  #      so a tick reloading its own unit's TimeoutStartSec can never
  #      retroactively cut itself off mid-run.
  #
  # A failed install/reload here is logged loudly but does not refuse the
  # tick (unlike the four checks above): the actual dispatch work below
  # does not depend on the unit files being current, only on those checks
  # having passed. One more tick under a stale RuntimeMaxSec/
  # TimeoutStartSec is a degraded outer safety net, retried automatically
  # next tick -- not the same class of unsafe as running the pipeline
  # against a dirty or diverged checkout.
  local unit_src_dir="$repo_dir/engine/systemd"
  local unit_dest_dir="${SYSTEMD_USER_UNIT_DIR:-$HOME/.config/systemd/user}"
  local unit_src unit_name unit_dest units_changed=0
  if [ -d "$unit_src_dir" ]; then
    for unit_src in "$unit_src_dir"/*.service "$unit_src_dir"/*.timer; do
      [ -f "$unit_src" ] || continue
      unit_name="$(basename "$unit_src")"
      unit_dest="$unit_dest_dir/$unit_name"
      if [ ! -f "$unit_dest" ] || ! diff -q "$unit_src" "$unit_dest" >/dev/null 2>&1; then
        if mkdir -p "$unit_dest_dir" 2>/dev/null && cp "$unit_src" "$unit_dest" 2>/dev/null; then
          echo "run-tick: installed updated unit: $unit_name -> $unit_dest_dir" >&2
          units_changed=1
        else
          echo "run-tick: failed to install unit $unit_name into $unit_dest_dir -- live unit stays stale until this succeeds" >&2
        fi
      fi
    done
  fi
  if [ "$units_changed" = "1" ]; then
    if systemctl --user daemon-reload; then
      echo "run-tick: systemctl --user daemon-reload applied the unit change(s) above" >&2
    else
      echo "run-tick: systemctl --user daemon-reload failed after installing unit change(s) -- systemd may still be running the OLD definition" >&2
    fi
  fi

  if [[ -f "$repo_dir/engine/check-host-daemons.py" ]] && ! python3 -B \
    "$repo_dir/engine/check-host-daemons.py" "$repo_dir" --sync "$fast_forward_old_head" "$fast_forward_new_head"; then
    refuse "host-daemon-sync-failed" "could not synchronize running host daemons after fast-forward"
  fi

  # 2026-09-21 (#1531, generalized by #1547): a stopped dependency timer
  # cannot observe its own silence. The still-running tick reads the
  # unit-adjacent list after its dedicated checkout has fast-forwarded. An
  # entry's exact `off` variable is an intentional stop; a stopped timer is
  # repaired with start, while a disabled timer needs enable --now or it will
  # never recover on this continuously running machine. Markers live outside
  # git, one per timer outage, and clear only after active/off.
  if [ ! -r "$timer_list" ]; then
    refuse "unexpected" "pipeline timer list is missing or unreadable: $timer_list"
  fi
  while read -r timer timer_off_variable timer_alert_marker; do
    case "$timer" in
      ""|\#*) continue ;;
    esac

    timer_alerted_file="$AGENT_HOME/$timer_alert_marker"
    if [ "$timer_off_variable" != "-" ]; then
      timer_mode="$(timeout "${timer_gh_timeout_sec}s" gh variable get "$timer_off_variable" \
        --repo "$timer_repo" 2>/dev/null || echo observe)"
      timer_mode="$(echo "$timer_mode" | tr -d '[:space:]')"
      if [ "$timer_mode" = "off" ]; then
        rm -f "$timer_alerted_file"
        continue
      fi
    fi

    timer_repair_action=""
    if ! systemctl --user is-enabled --quiet "$timer"; then
      timer_repair_action="enable --now"
      if systemctl --user enable --now "$timer"; then
        echo "run-tick: enabled and started $timer because it was disabled" >&2
      else
        echo "run-tick: failed to enable and start $timer because it was disabled" >&2
      fi
    elif systemctl --user is-active --quiet "$timer"; then
      rm -f "$timer_alerted_file"
      continue
    else
      timer_repair_action="start"
      if systemctl --user start "$timer"; then
        echo "run-tick: started $timer because it was inactive" >&2
      else
        echo "run-tick: failed to start $timer because it was inactive" >&2
      fi
    fi

    # A successful systemctl command is not proof that the timer recovered.
    # Alert only when the repair attempt still leaves it inactive.
    if systemctl --user is-active --quiet "$timer"; then
      echo "run-tick: recovered $timer; no alert needed" >&2
      rm -f "$timer_alerted_file"
      continue
    fi
    echo "run-tick: $timer remains inactive after systemctl --user $timer_repair_action" >&2
    if [ ! -f "$timer_alerted_file" ]; then
      append_supervisor_event timer-outage \
        "timer=$timer observed=inactive repair_command=\"systemctl --user $timer_repair_action $timer\" status_command=\"systemctl --user status $timer\"" \
        2>/dev/null || true
      touch "$timer_alerted_file" 2>/dev/null || true
    fi
  done <"$timer_list"

  export ZF_REPO_DIR="$repo_dir"
  # 2026-09-15: no longer `exec`. exec replaces this process's own image, so
  # any non-zero exit from issue-pipeline.sh (it has no ERR trap of its own
  # -- only `set -euo pipefail`) landed nowhere: refuse()'s counter/alert
  # code below had already stopped existing in memory by the time it could
  # have fired. A genuine crash in the scheduler -- exactly the class of
  # failure the 2026-09-14 fail-threshold/alert machinery exists to catch --
  # was therefore invisible to it, forever, while the known restore/
  # branch/fetch/diverged refusals (which all fire BEFORE this line, still
  # inside this function) were the only failures that machinery could ever
  # see. Losing exec's process-replacement costs nothing here: this unit's
  # own outer bound (TimeoutStartSec, see systemd/zenoforge-agent.service --
  # `Type=oneshot` makes RuntimeMaxSec a no-op, verified live, see the
  # install-loop comment above) kills by cgroup, not by PID identity, so it
  # reaches this process the same way whether it replaced its own image via
  # `exec` or is parenting a child and waiting on it -- nothing here
  # depends on which shape this process's own PID takes.
  if "$repo_dir/engine/issue-pipeline.sh"; then
    :
  else
    scheduler_status=$?
    # Deliberately its own tag, not "unexpected" (the ERR trap's tag,
    # reserved for a failure in THIS script before the hand-off): a
    # refusal above is this script correctly protecting itself and
    # stopping before doing anything, likely to clear on its own; this is
    # the scheduler it handed off to actually crashing mid-run, which will
    # very likely fail the exact same way again on retry -- see refuse()'s
    # own case statement for the distinct, non-reassuring wording this
    # tag gets.
    refuse "scheduler-failed" "issue-pipeline.sh exited with status $scheduler_status from $repo_dir"
  fi

  # 2026-09-15: this reset used to run right after the git fast-forward
  # above succeeded, BEFORE ever invoking issue-pipeline.sh -- so a run
  # where the git checks passed but the hand-off then crashed reset the
  # counter to zero and then refuse() above bumped it right back to 1,
  # every single time. issue-pipeline.sh can crash on every tick forever
  # and the counter would never move past 1: caught live, not by reading --
  # a stub issue-pipeline.sh forced to fail three ticks in a row never
  # crossed the alert threshold until this block was moved to here, after
  # a confirmed genuine success (git guard cleared AND the hand-off itself
  # returned 0). Once it was moved: the same three failing ticks moved
  # tick-failure-count 1/2/3 and wrote one supervisor event; a fourth,
  # healthy tick records recovery and clears both files.
  trap - ERR
  if [ -f "$alerted_file" ]; then
    append_supervisor_event tick-recovery "" 2>/dev/null || true
    rm -f "$alerted_file"
  fi
  rm -f "$fail_count_file"
}

run_tick "$@"
