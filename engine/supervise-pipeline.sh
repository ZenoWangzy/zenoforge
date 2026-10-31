#!/usr/bin/env bash
# supervise-pipeline.sh -- the one place that computes SYSTEM-LEVEL facts
# about this pipeline, instead of a single ticket's own facts.
#
# Every other leg (run-triage.sh, run-advisor.sh, run-implement.sh,
# run-release.sh, run-recut.sh) looks at one ticket and decides about that
# ticket. issue-pipeline.sh's tick dispatches those legs but computes no
# system-level fact either -- it just asks "which labels have candidates"
# and fires one run per candidate. Nothing anywhere used to compute
# "throughput is zero", "this ticket has been going in circles", or "that
# PR has been green and unmerged for an hour". 2026-09-15/16's seven
# incidents (V102, V104, V107, V108, V109, V114, V117) were diagnosed by a
# human watching the whole system; six of those seven were invisible from
# inside any single ticket and obvious from a system view. This script is
# that view, running on its own timer, mechanized.
#
# Full design (the invariant table, the incident mapping, the action
# whitelist and never-list, the loop-safety argument, and what this
# deliberately does not cover): docs/agents/pipeline-supervisor.md. Read
# that before changing an invariant, a threshold, or the action set below --
# every number here is derived from real measured data, not picked round,
# and the comment next to it says from what.
#
# --- staged rollout: AGENT_SUPERVISOR, same shape as AGENT_PIPELINE/
# AGENT_IMPLEMENT_EXECUTOR (issue-pipeline.sh/lib.sh's read_implement_
# executor()) -- a gh repo variable, read fresh every run (never cached),
# validated against an explicit allowlist, fail-closed on anything it
# doesn't recognize. Three values:
#   off     -- exit immediately, check nothing.
#   observe -- evaluate every invariant, print/record findings, take
#              NO action (comment, email, or state write) of any kind.
#              The default on first landing.
#   act     -- observe's checks, plus the small bounded action whitelist
#              (docs/agents/pipeline-supervisor.md's "Action whitelist").
# Fails closed to `observe`, not `off`: unlike AGENT_PIPELINE (whose unsafe
# direction is doing MORE, so an unrecognized value must stop everything),
# this script's unsafe direction is doing something and nobody watching for
# it -- `observe` is strictly safer than `off` (it still tells a human what
# it found) and strictly safer than `act` (it writes nothing), so a typo or
# an unset variable should not go silent, it should downgrade to reporting
# only. `gh variable set AGENT_SUPERVISOR off` is the one-line kill switch;
# `gh variable set AGENT_SUPERVISOR observe` is the one-line revert from act.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
pause_guard="${ZF_EXECUTION_MODULE_DIR:-$SCRIPT_DIR}/execution-admission.py"
[[ -r "$pause_guard" ]] || { echo 'supervise-pipeline: execution admission unavailable' >&2; exit 75; }
if python3 "$pause_guard" paused; then
  echo "supervise-pipeline: operator PAUSE; no owner dispatch or recovery" >&2
  exit 0
fi
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"
if manual_pause_is_valid; then
  echo "supervise-pipeline: operator PAUSE; no owner dispatch or recovery" >&2
  exit 0
fi
# shellcheck source=./notify.sh
source "$SCRIPT_DIR/notify.sh"
# shellcheck source=./night/hand-agent-watchdog.sh
source "$SCRIPT_DIR/night/hand-agent-watchdog.sh"

read_supervisor_mode() {
  local mode
  mode="$(gh variable get AGENT_SUPERVISOR --repo "$REPO" 2>/dev/null || echo observe)"
  mode="$(echo "$mode" | tr -d '[:space:]')"
  case "$mode" in
    off|observe|act) echo "$mode" ;;
    *) echo observe ;;
  esac
}

MODE="$(read_supervisor_mode)"
echo "supervise-pipeline: AGENT_SUPERVISOR=$MODE" >&2
if [ "$MODE" = "off" ]; then
  echo "supervise-pipeline: off, exiting without checking anything" >&2
  exit 0
fi

# observe must never write ANYTHING -- an issue comment, an email, a state
# file, or even this script's own cooldown bookkeeping. Forcing DRY_RUN=1
# here makes that a property of every guarded_write()/state_merge() call
# below for free (lib.sh's own DRY_RUN short-circuit), on top of every
# action function below ALSO checking `[ "$MODE" = "act" ]` itself before
# doing anything -- two independent gates, neither trusting the other.
[ "$MODE" = "observe" ] && DRY_RUN=1

FOUND=0
finding() {
  FOUND=$((FOUND + 1))
  echo "supervise-pipeline: FINDING [$1] $2" >&2
}

# Pack module: INV-9, the shared-browser tab check (the product's signed-in browser). Sourced only when the pack ships it.
browser_check="$(zf_host_ops_file scripts/agent/supervise-browser-check.sh "${ZF_PACK_DIR:-$ZF_ENGINE_DIR}/supervise-browser-check.sh")"
[[ ( -n "${ZF_PACK_DIR-}" || "$browser_check" == "${ZF_HOST_OPS_DIR:-$AGENT_HOME/host-ops}/scripts/agent/supervise-browser-check.sh" ) && -r "$browser_check" ]] && source "$browser_check"

# --- cooldown bookkeeping for system-level checks with no single GitHub
# object to comment on -- a marker FILE under AGENT_HOME, sibling to
# quarantine/ and spend/, never
# touched in observe mode (mark_cooldown no-ops unless MODE=act, same
# discipline as every write below).
SUPERVISOR_COOLDOWN_DIR="$AGENT_HOME/supervisor-cooldowns"
cooldown_ready() {
  # Two statements, not one: under `set -u`, a `local` that reads a name it
  # is declaring in the SAME statement -- `local name="$1" f="$dir/$name"`
  # -- aborts with `name: unbound variable` even when the caller passed the
  # argument. Measured directly on this box, not inferred. It stayed latent
  # for as long as nothing reached this function: it first fired on
  # 2026-09-16 when INV-7 began alerting, and then killed every supervisor
  # run at the last invariant, after the earlier findings had already
  # printed -- which is what made it look like a new INV-7 defect rather
  # than an old one in shared bookkeeping.
  local name="$1" secs="$2" last f
  f="$SUPERVISOR_COOLDOWN_DIR/$name"
  [ -f "$f" ] || return 0
  last="$(cat "$f" 2>/dev/null || echo 0)"
  [ $(( $(date +%s) - last )) -ge "$secs" ]
}
mark_cooldown() {
  [ "$MODE" = "act" ] || return 0
  mkdir -p "$SUPERVISOR_COOLDOWN_DIR"
  date +%s > "$SUPERVISOR_COOLDOWN_DIR/$1"
}

# issue_has_live_unit <n> -- true iff ANY zf-<stage>-<n>.service is
# currently loaded (active/activating/deactivating). "Never take an action
# another leg is currently taking on that ticket": every per-ticket action
# below checks this first and skips if true, deferring to whichever leg is
# already in flight rather than racing it.
#
# 2026-09-16 fix: this discarded systemctl's own failure into the same
# empty-string "nothing loaded" result as the genuine, common "no live
# unit" answer -- a session-bus outage read as "safe to act", letting a
# supervisor mutation (heal_advisor_ruled_at_regression(), escalate_not_
# converging()) race a leg it could not even see. Same reasoning as lib.sh's
# stage_unit_count() (identical `list-units` shape): a real zero-match query
# exits 0 (measured live), so the exit code alone -- not output emptiness,
# which is also the normal no-units answer -- is what distinguishes a
# genuine query failure. Same fail-closed direction as stage_unit_active()/
# stage_unit_count(): unknown reads as "yes, a live unit exists", not as
# "confirmed none".
issue_has_live_unit() {
  local out
  if ! out="$(systemctl --user list-units --no-legend --plain "${UNIT_PREFIX_TRANSIENT}-*-$1.service" 2>&1)"; then
    echo "issue_has_live_unit: systemctl --user list-units could not be queried for #$1 -- treating as LIVE (fail-closed), not confirmed-idle: $out" >&2
    return 0
  fi
  [ -n "$out" ]
}

# issue_comment_has_marker <n> <marker> -- true iff a comment containing
# $marker already exists on issue $n. Same technique detect-label-churn.sh's
# already_alerted_for() uses: GitHub's own comment history is the durable
# dedup record, no local state needed, survives this script being
# reinstalled or its cooldown dir being wiped.
issue_comment_has_marker() {
  local n="$1" marker="$2" bodies
  # Captured first, then grepped -- see check_dispatch_stall()'s own
  # comment on why a live `producer | grep -q` pipe under `set -o
  # pipefail` is unsafe (grep exiting early on its first match can SIGPIPE
  # the still-writing producer, and pipefail then reports the whole
  # pipeline as failed even though grep matched).
  bodies="$(gh api "repos/$REPO/issues/$n/comments" --paginate --jq '.[].body' 2>/dev/null || true)"
  grep -qF "$marker" <<< "$bodies"
}

# =============================================================================
# INV-1(a): the exact V102/V113 regression signature -- an issue currently
# labeled needs-advisor whose state file still carries an OLDER
# advisor_ruled_at, meaning whatever relabeled it did NOT go through
# route_to_advisor() (lib.sh), so issue-pipeline.sh's own has("advisor_
# ruled_at") dispatch guard will skip it forever: zero live producers, no
# poller, no escalation. The fix (route_to_advisor()'s own state half) is
# well-understood, already-idempotent, and self-terminating: clearing the
# field removes the very condition this check looks for, so unlike the
# escalation-style actions below, this one needs no marker/cooldown to stop
# repeating -- the SAME signal cannot fire twice on the SAME ticket without
# something re-creating the stale field in between.
# =============================================================================
check_advisor_ruled_at_regression() {
  local n has
  for n in $(gh issue list --repo "$REPO" --label needs-advisor --state open --limit 1000 --json number -q '.[].number' 2>/dev/null); do
    [ -f "$(state_file "$n")" ] || continue
    has="$(state_read "$n" | jq -r 'has("advisor_ruled_at")' 2>/dev/null || echo false)"
    [ "$has" = "true" ] || continue
    finding inv1a "#$n is labeled needs-advisor but its state file already carries an advisor_ruled_at -- issue-pipeline.sh's dispatch guard (line ~413) will skip it forever unless something clears that field; zero live producers for this ticket right now"
    heal_advisor_ruled_at_regression "$n"
  done
}

heal_advisor_ruled_at_regression() {
  local n="$1" marker="<!-- vecta-supervisor-heal-advisor-ruled-at -->"
  [ "$MODE" = "act" ] || return 0
  # 2026-09-16 fix: this mutated (state_merge + a comment) an on-hold ticket
  # -- a human's explicit pause has to hold at every action boundary that
  # can touch that ticket, not just at issue-pipeline.sh's own scheduling
  # gate. Fails closed the same direction is_on_hold()'s own callers do.
  is_on_hold "$n" && { echo "supervise-pipeline: #$n is on-hold, leaving it for a human" >&2; return 0; }
  issue_has_live_unit "$n" && { echo "supervise-pipeline: #$n has a live unit right now, leaving it for that leg" >&2; return 0; }
  issue_comment_has_marker "$n" "$marker" && return 0
  # 2026-09-16 fix, same class as route_to_advisor()/route_to_recut()
  # (lib.sh): check the clear before posting the "already healed" comment.
  # Posting it unconditionally on a failed clear is worse than the plain
  # unchecked-side-effect bug those two have -- issue_comment_has_marker()
  # above means this function would then believe it already healed the
  # ticket on every future run and never try again, the healer's own dedup
  # marker permanently masking its own failure.
  # 2026-09-19: this filter must match route_to_advisor()'s (lib.sh) OWN
  # state-clearing half exactly, byte for byte -- this doc's own header
  # ("Action whitelist") promises exactly that ("the SAME write route_to_
  # advisor() already does"), and this healer starts what is, from issue-
  # pipeline.sh's dispatch guard's own point of view, a fresh advisor
  # episode -- the ticket becomes eligible for a brand-new advisor pass the
  # very next tick, same as any other route_to_advisor() call site. Before
  # this fix, this filter still read the pre-2026-09-19 `del(.advisor_
  # ruled_at)` alone: advisor_episode_seq (the guard advisor_persist_
  # pending()/advisor_resume_check(), engine/advisor-core.sh, use to
  # tell "this reasoning pass belongs to the CURRENT episode" from "it is a
  # stale leftover from one that already ended") never got bumped by a
  # heal, so a heal silently produced a "new" episode indistinguishable
  # from the one just healed away -- exactly the class of bug advisor-
  # core.sh's own episode-sequence guard exists to close, reopened here by
  # this one remaining hand copy of route_to_advisor()'s filter that never
  # got updated when that filter grew the episode_seq half. The del(.
  # pending_advisor_verdict) half is a no-op in THIS healer's own actual
  # trigger condition today (check_advisor_ruled_at_regression() only ever
  # calls this when advisor_ruled_at is present, and advisor_ruled_at/
  # pending_advisor_verdict are mutually exclusive by construction
  # everywhere else that writes either -- advisor-core.sh's own atomic-
  # completion comment) -- kept anyway so this stays byte-identical to
  # route_to_advisor()'s filter, the property this fix exists to restore,
  # not something a future change to either filter can silently drift out
  # of sync with again.
  state_merge "$n" 'del(.advisor_ruled_at, .pending_advisor_verdict) | .advisor_episode_seq = ((.advisor_episode_seq // 0) + 1)' || {
    echo "heal_advisor_ruled_at_regression: state_merge failed to clear advisor_ruled_at for #$n -- not posting the healed-it comment (it would falsely claim success and, via issue_comment_has_marker, permanently suppress retrying); see the state_merge error above" >&2
    return 1
  }
  guarded_write gh issue comment "$n" --repo "$REPO" --body "$BOT_DISCLAIMER
$marker
这条工单一直标着 needs-advisor，但状态文件里还留着上一轮顾问裁决的时间戳，导致流水线的顾问派发一直把它当成"已经裁决过"跳过，没有任何进程会再接手它。已经把这个过期字段清掉（并推进 advisor_episode_seq，同 route_to_advisor() 一致地开启新一轮 episode，防止旧一轮的裁决被误当作这次结果续用），让顾问派发这次 tick 能正常认领它，没有改动标签，也没有修改风险分类等其它字段。"
}

# check_recut_marker_regression -- the SAME shape check as INV-1(a) above,
# read-only, for the recut leg's own idempotency markers. Found LIVE while
# building this (2026-09-16): issue-pipeline.sh's own needs-recut
# pre-filter (`state_read "$next_recut" | jq -e 'has("recut_children") or
# has("recut_refused_at")' >/dev/null 2>&1 && continue`) is structurally
# identical to the guard V102 fixed for advisor_ruled_at. It remains
# deliberately report-only even in act mode: successful splits need a live
# child-by-child verification before their queue label is retired, while
# stale refusals need route_to_recut(). The reviewable reconciliation script
# owns that distinction and also refuses on-hold or live-unit tickets; this
# periodic scan must not guess from a marker alone.
check_recut_marker_regression() {
  local n has
  for n in $(gh issue list --repo "$REPO" --label needs-recut --state open --limit 1000 --json number -q '.[].number' 2>/dev/null); do
    [ -f "$(state_file "$n")" ] || continue
    has="$(state_read "$n" | jq -r '(has("recut_children") or has("recut_refused_at"))' 2>/dev/null || echo false)"
    [ "$has" = "true" ] || continue
    finding inv1a "#$n is labeled needs-recut but its state file already carries recut_children or recut_refused_at -- issue-pipeline.sh's own needs-recut pre-filter will skip it forever; report-only because the reconciliation must distinguish a verified completed split from a stale refusal before changing either side"
  done
}

# =============================================================================
# INV-1(b): coarse dispatch-queue stall -- a dispatch label with a
# meaningful backlog (>=STALL_POPULATION_FLOOR) and NO unit for its owning
# leg dispatched in the last DISPATCH_STALL_MINUTES. Report-only: unlike
# INV-1(a) this has no single diagnosed cause, so the safe action is
# telling a human, not guessing a fix -- a generic auto-remediation here
# would be inventing a state-machine rule the way V113's own "trust the
# newer path" mistake did.
#
# Deliberately an ACTIVITY-WINDOW check (journalctl: has a zf-<stage>-*
# unit STARTED recently), not an instantaneous "is one running right now"
# snapshot -- the first version of this check used the latter and, live
# against this exact repo, false-positived on needs-advisor: ADVISOR_CAP=2
# (issue-pipeline.sh) means the advisor leg is legitimately at zero running
# units for a few seconds between one finishing and the next tick
# dispatching the next one, even while cycling healthily every ~5 minutes.
# journalctl's own unit-glob matching (`-u 'zf-advisor-*'`) is used
# instead of a second stage_unit_count()-shaped systemctl query, since what
# this needs is "did anything start recently", not "is anything active
# right now" -- lib.sh's stage_unit_count() answers the second question,
# not the first, which is exactly why the first version of this check used
# it and got a false positive.
#
# STALL_POPULATION_FLOOR=5: normal cadence briefly leaves 1-2 tickets
# waiting between ticks; a floor of 5 stays clear of that while still
# catching a real pile-up. DISPATCH_STALL_MINUTES=60: comfortably above
# both ADVISOR_CAP and RECUT_CAP's normal ~5min per-dispatch cadence
# (issue-pipeline.sh: ADVISOR_CAP=2, RECUT_CAP=1 -- two advisor tickets and
# one recut ticket in flight per leg, next work starts on later ticks),
# comfortably below what a real stall looks like. A prior recut
# stall showed a substantial needs-recut queue whose tickets already carried
# recut_children or recut_refused_at (issue-pipeline.sh's own pre-dispatch
# filter, `state_read | jq -e 'has("recut_children") or
# has("recut_refused_at")' && continue`). The two fields now have audited,
# different repair paths:
# a successful split retains its permanent child marker but leaves the
# active queue, while a reopened refusal clears its old marker on entry.
# This supervisor still does not self-heal because only the reconciliation
# script performs the required live child verification and owner checks.
# =============================================================================
STALL_POPULATION_FLOOR="${STALL_POPULATION_FLOOR:-5}"
DISPATCH_STALL_MINUTES="${DISPATCH_STALL_MINUTES:-60}"
check_dispatch_stall() {
  local label stage population
  for pair in "needs-triage:triage" "ready-for-agent:implement" "needs-advisor:advisor" "needs-recut:recut"; do
    label="${pair%%:*}"; stage="${pair##*:}"
    population="$(gh issue list --repo "$REPO" --label "$label" --state open --limit 1000 --json number -q 'length' 2>/dev/null || echo 0)"
    [ "${population:-0}" -ge "$STALL_POPULATION_FLOOR" ] || continue
    # Captured into a variable BEFORE grep runs, not `journalctl | grep -q`:
    # under `set -o pipefail`, `grep -q` exits the instant it finds its
    # first match, SIGPIPEs the still-writing journalctl, and pipefail then
    # reports the WHOLE pipeline as failed (journalctl's own non-zero exit)
    # even though grep found exactly what it was looking for -- measured
    # live, this exact bug: with a real match count of 2/10/1 (implement/
    # advisor/recut), `journalctl | grep -q` still evaluated false every
    # time, so this check flagged all three as stalled including the two
    # that were actively dispatching every few minutes. Same shape as
    # detect-label-churn.sh's own churn_events_for(): capture first, grep
    # the captured text, never grep a live producer's pipe with `-q`.
    local activity
    activity="$(journalctl --user -u "${UNIT_PREFIX_TRANSIENT}-$stage-*" --since "-${DISPATCH_STALL_MINUTES} minutes" --no-pager -q 2>/dev/null || true)"
    if grep -q "Started ${UNIT_PREFIX_TRANSIENT}-$stage-" <<< "$activity"; then
      continue
    fi
    finding inv1b "$label has $population open ticket(s) and no ${UNIT_PREFIX_TRANSIENT}-$stage-* unit has started in the last ${DISPATCH_STALL_MINUTES}min -- throughput on this queue looks like zero, not a brief gap between ticks"
  done
}

# =============================================================================
# INV-10: the same implement gate repeatedly skips the same issue. A skip is
# normal once: another leg may be concluding its work. Repeating the same
# (issue, gate) decision means the ticket is structurally stuck. This is
# report-only; the supervisor must not guess whether to clear a gate or relabel
# a ticket.
#
# Findings deduplicate against this service's own journal, keyed by the first
# decision tick of the episode. A later non-skip or different gate resets that
# start tick, so a new stall can report once. This needs no local state and
# stays write-free in observe mode; emitting the finding is its durable marker.
# =============================================================================
IMPLEMENT_SKIP_STALL_TICKS="${IMPLEMENT_SKIP_STALL_TICKS:-3}"
IMPLEMENT_SKIP_STALL_JOURNAL_LINES="${IMPLEMENT_SKIP_STALL_JOURNAL_LINES:-600}"
case "$IMPLEMENT_SKIP_STALL_TICKS" in
  ''|*[!0-9]*) IMPLEMENT_SKIP_STALL_TICKS=3 ;;
esac
[ "$IMPLEMENT_SKIP_STALL_TICKS" -ge 2 ] || IMPLEMENT_SKIP_STALL_TICKS=2
case "$IMPLEMENT_SKIP_STALL_JOURNAL_LINES" in
  ''|*[!0-9]*) IMPLEMENT_SKIP_STALL_JOURNAL_LINES=600 ;;
esac
[ "$IMPLEMENT_SKIP_STALL_JOURNAL_LINES" -gt 0 ] || IMPLEMENT_SKIP_STALL_JOURNAL_LINES=600

check_repeating_implement_skips() {
  local decisions stalls n gate count start marker prior start_epoch start_iso
  if ! decisions="$(journalctl --user -u "${UNIT_PREFIX}-agent.service" -n "$IMPLEMENT_SKIP_STALL_JOURNAL_LINES" --no-pager -o cat 2>/dev/null)"; then
    echo "supervise-pipeline: could not read implement decisions; not inferring an implement-skip stall" >&2
    return 0
  fi
  stalls="$(awk -v threshold="$IMPLEMENT_SKIP_STALL_TICKS" '
    index($0, "issue-pipeline: implement-decision ") == 0 { next }
    {
      tick = issue = outcome = gate = ""
      for (i = 1; i <= NF; i++) {
        split($i, fields, "=")
        if (fields[1] == "tick") tick = fields[2]
        else if (fields[1] == "issue") issue = fields[2]
        else if (fields[1] == "outcome") outcome = fields[2]
        else if (fields[1] == "gate") gate = fields[2]
      }
      if (tick == "" || issue !~ /^#[0-9]+$/ || outcome == "") next
      n = substr(issue, 2)
      delete stalled[n]
      if (outcome != "skipped" || gate == "") {
        delete last_pair[n]
        delete count[n]
        delete start[n]
        next
      }
      if (gate == "open-blocker" || gate == "capacity" || gate == "package-scope-cap" \
        || gate == "active-implement" || gate == "dispatch-resources" || gate == "model-policy-transition") {
        delete last_pair[n]
        delete count[n]
        delete start[n]
        next
      }
      pair_key = n SUBSEP gate
      if (last_pair[n] == pair_key) count[n]++
      else {
        last_pair[n] = pair_key
        count[n] = 1
        start[n] = tick
      }
      if (count[n] >= threshold) stalled[n] = n "\t" gate "\t" count[n] "\t" start[n]
    }
    END { for (n in stalled) print stalled[n] }
  ' <<< "$decisions")"
  while IFS=$'\t' read -r n gate count start; do
    [ -n "$n" ] || continue
    if [[ ! "$start" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; then
      echo "supervise-pipeline: could not parse implement-skip stall start $start for #$n; not reporting it" >&2
      continue
    fi
    start_iso="${start:0:4}-${start:4:2}-${start:6:2} ${start:9:2}:${start:11:2}:${start:13:2} UTC"
    if ! start_epoch="$(agent_epoch -u "$start_iso" 2>/dev/null)"; then
      echo "supervise-pipeline: could not parse implement-skip stall start $start for #$n; not reporting it" >&2
      continue
    fi
    marker="implement-skip-stall issue=#$n gate=$gate start=$start"
    if ! prior="$(journalctl --user -u "${UNIT_PREFIX}-supervisor.service" --since "@$start_epoch" --no-pager -o cat 2>/dev/null)"; then
      echo "supervise-pipeline: could not read prior supervisor findings for #$n; not duplicating an implement-skip stall" >&2
      continue
    fi
    grep -qF "$marker" <<< "$prior" && continue
    finding inv10 "$marker has repeated $count consecutive tick(s) (threshold $IMPLEMENT_SKIP_STALL_TICKS); report once per stall"
  done <<< "$stalls"
}

# =============================================================================
# INV-10(b): repeated transport lease bails on one advisor ticket. One busy lease is
# normal contention; N consecutive bails mean the ticket is stalled. Keep this
# report-only and dedupe by episode start in the supervisor journal, matching
# INV-10's existing no-state-write pattern.
# =============================================================================
ADVISOR_LEASE_BAIL_STALL_TICKS="${ADVISOR_LEASE_BAIL_STALL_TICKS:-3}"
ADVISOR_LEASE_BAIL_JOURNAL_LINES="${ADVISOR_LEASE_BAIL_JOURNAL_LINES:-600}"
case "$ADVISOR_LEASE_BAIL_STALL_TICKS" in
  ''|*[!0-9]*) ADVISOR_LEASE_BAIL_STALL_TICKS=3 ;;
esac
[ "$ADVISOR_LEASE_BAIL_STALL_TICKS" -ge 2 ] || ADVISOR_LEASE_BAIL_STALL_TICKS=2
case "$ADVISOR_LEASE_BAIL_JOURNAL_LINES" in
  ''|*[!0-9]*) ADVISOR_LEASE_BAIL_JOURNAL_LINES=600 ;;
esac
[ "$ADVISOR_LEASE_BAIL_JOURNAL_LINES" -gt 0 ] || ADVISOR_LEASE_BAIL_JOURNAL_LINES=600

check_repeating_advisor_lease_bails() {
  local decisions stalls n count start marker prior start_epoch start_iso
  if ! decisions="$(journalctl --user -u "${UNIT_PREFIX_TRANSIENT}-advisor-*" -n "$ADVISOR_LEASE_BAIL_JOURNAL_LINES" --no-pager -o cat 2>/dev/null)"; then
    echo "supervise-pipeline: could not read advisor lease decisions; not inferring a lease-bail stall" >&2
    return 0
  fi
  stalls="$(awk -v threshold="$ADVISOR_LEASE_BAIL_STALL_TICKS" '
    index($0, "issue-pipeline: advisor-lease-decision ") == 0 { next }
    {
      tick = issue = outcome = ""
      for (i = 1; i <= NF; i++) {
        split($i, fields, "=")
        if (fields[1] == "tick") tick = fields[2]
        else if (fields[1] == "issue") issue = fields[2]
        else if (fields[1] == "outcome") outcome = fields[2]
      }
      if (tick == "" || issue !~ /^#[0-9]+$/ || outcome == "") next
      n = substr(issue, 2)
      delete stalled[n]
      if (outcome != "busy") {
        delete count[n]
        delete start[n]
        next
      }
      if (!(n in count)) start[n] = tick
      count[n]++
      if (count[n] >= threshold) stalled[n] = n "\t" count[n] "\t" start[n]
    }
    END { for (n in stalled) print stalled[n] }
  ' <<< "$decisions")"
  while IFS=$'\t' read -r n count start; do
    [ -n "$n" ] || continue
    if [[ ! "$start" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; then
      echo "supervise-pipeline: could not parse advisor lease-bail stall start $start for #$n; not reporting it" >&2
      continue
    fi
    start_iso="${start:0:4}-${start:4:2}-${start:6:2} ${start:9:2}:${start:11:2}:${start:13:2} UTC"
    if ! start_epoch="$(agent_epoch -u "$start_iso" 2>/dev/null)"; then
      echo "supervise-pipeline: could not parse advisor lease-bail stall start $start for #$n; not reporting it" >&2
      continue
    fi
    marker="advisor-lease-bail-stall issue=#$n start=$start"
    if ! prior="$(journalctl --user -u "${UNIT_PREFIX}-supervisor.service" --since "@$start_epoch" --no-pager -o cat 2>/dev/null)"; then
      echo "supervise-pipeline: could not read prior supervisor findings for #$n; not duplicating an advisor lease-bail stall" >&2
      continue
    fi
    grep -qF "$marker" <<< "$prior" && continue
    finding inv10b "$marker has repeated $count consecutive tick(s) (threshold $ADVISOR_LEASE_BAIL_STALL_TICKS); report once per stall"
  done <<< "$stalls"
}

# =============================================================================
# INV-2: ticket transition churn/cycling (a ticket bouncing between two
# labels repeatedly -- the V107/V108 trailing-slash class). A second,
# concurrent editor of lib.sh was building a general transition-bound
# mechanism that overlaps this invariant; it landed on origin/main
# (a53e57035, V119) while this script was being built: `loop_break_check()`
# (lib.sh), wired directly into route_to_advisor()/admit_guarded() -- the
# only two writers of the ready-for-agent/needs-advisor pair -- escalates
# ONCE per loop episode (a comment with the full trajectory, routed to the
# advisor with context to resolve, not re-classify) the instant a ticket
# crosses the threshold, as a SIDE EFFECT of the transition that would have
# repeated it, not a periodic scan. That is strictly earlier and more
# precise than anything this script could add on a 10-minute timer, so this
# check does not re-detect cycling -- it reads count_recent_loop_
# escalations() (lib.sh) and records the same fact at this script's own
# cadence. Report-only: the action (comment +
# advisor routing) already happened inside loop_break_check() itself by the
# time this runs.
# =============================================================================
check_ticket_cycling() {
  local n
  n="$(count_recent_loop_escalations 2>/dev/null || echo 0)"
  [ "${n:-0}" -gt 0 ] || return 0
  finding inv2 "$n ticket(s) were loop-escalated by loop_break_check() (lib.sh) in the last 24h -- already handled by that mechanism (a comment with the trajectory, routed to the advisor with context); surfaced here so a cluster is visible in HEALTH"
}

# =============================================================================
# INV-3: a stalled mergeable PR -- an open agent PR that has not changed in
# far longer than the autopilot's own merge lane should ever allow. Catches
# both the V104 class (no producer at all for the merge step) and the V117
# class (a draft PR whose `gh pr ready` step never ran): both present as "the
# same open PR, still here, tick after tick." Report-only: the merge gate is
# the place to fix a stuck PR, not this script guessing at one.
#
# Threshold = IMPLEMENT_RUNTIME_MAX_SEC + 2h buffer, so this only fires after
# the merge lane has had its full window and then some.
# =============================================================================
STALLED_PR_GRACE_SECONDS=$((IMPLEMENT_RUNTIME_MAX_SEC + 2 * 3600))
check_stalled_prs() {
  local now stream row n updated_at age draft mergeable
  now="$(date +%s)"
  stream="$(gh pr list --repo "$REPO" --state open --limit 1000 \
    --json number,headRefName,isDraft,mergeable,mergeStateStatus,updatedAt \
    -q '.[] | select(.headRefName | startswith("agent/issue-"))' 2>/dev/null | jq -c '.' 2>/dev/null || true)"
  [ -z "$stream" ] && return 0
  while IFS= read -r row; do
    [ -z "$row" ] && continue
    n="$(echo "$row" | jq -r '.number')"
    updated_at="$(echo "$row" | jq -r '.updatedAt')"
    age=$(( now - $(agent_epoch -u "$updated_at" 2>/dev/null || echo "$now") ))
    [ "$age" -ge "$STALLED_PR_GRACE_SECONDS" ] || continue
    draft="$(echo "$row" | jq -r '.isDraft')"
    mergeable="$(echo "$row" | jq -r '.mergeable')"
    finding inv3 "PR #$n has not changed in $((age / 3600))h (isDraft=$draft mergeable=$mergeable) -- longer than the ${STALLED_PR_GRACE_SECONDS}s grace window; the merge lane has had its full window and this PR is still here"
  done <<< "$stream"
}

# =============================================================================
# INV-4: scheduler/tick liveness -- the V114 class (a hung `gh` call holding
# the tick lock for 2h25m while every later tick exited 0 on a non-blocking
# lock, so nothing ever looked like a failure). V114's own fix
# (TimeoutStartSec=20min on zenoforge-agent.service) makes the ORIGINAL 2h25m
# shape structurally impossible now, but nothing currently re-verifies that
# fix is still installed and effective on THIS box -- this check is that
# re-verification, generalized: either the tick has been actively running
# for longer than its own hard cap should allow, or no tick has started at
# all for far longer than its 5-minute cadence.
#
# Thresholds: TICK_RUNNING_STALL_SECONDS=1800 (30min) sits above the
# service's own 20-minute TimeoutStartSec (so a tick genuinely about to be
# killed by its own timeout does not also trip this) and far below V114's
# actual 2h25m. TICK_SILENT_STALL_SECONDS=1800 sits at 6x the timer's own
# 5-minute cadence -- comfortably above single-tick jitter, comfortably
# below anything worth calling a stall.
# =============================================================================
TICK_RUNNING_STALL_SECONDS="${TICK_RUNNING_STALL_SECONDS:-1800}"
TICK_SILENT_STALL_SECONDS="${TICK_SILENT_STALL_SECONDS:-1800}"
check_tick_liveness() {
  local active_state enter_ts now age last_trigger
  now="$(date +%s)"
  active_state="$(systemctl --user show "${UNIT_PREFIX}-agent.service" -p ActiveState -p ActiveEnterTimestamp 2>/dev/null || true)"
  if grep -q '^ActiveState=active' <<< "$active_state"; then
    enter_ts="$(echo "$active_state" | sed -n 's/^ActiveEnterTimestamp=//p')"
    if [ -n "$enter_ts" ]; then
      age=$(( now - $(agent_epoch "$enter_ts" 2>/dev/null || echo "$now") ))
      if [ "$age" -ge "$TICK_RUNNING_STALL_SECONDS" ]; then
        finding inv4 "${UNIT_PREFIX}-agent.service has been running for ${age}s -- longer than its own 20min TimeoutStartSec should ever allow (V114's fix may not be installed/effective on this box right now)"
      fi
    fi
  fi
  last_trigger="$(systemctl --user show "${UNIT_PREFIX}-agent.timer" -p LastTriggerUSec 2>/dev/null | sed -n 's/^LastTriggerUSec=//p' || true)"
  if [ -n "$last_trigger" ] && [ "$last_trigger" != "n/a" ]; then
    age=$(( now - $(agent_epoch "$last_trigger" 2>/dev/null || echo "$now") ))
    if [ "$age" -ge "$TICK_SILENT_STALL_SECONDS" ] && ! grep -q '^ActiveState=active' <<< "$active_state"; then
      finding inv4 "${UNIT_PREFIX}-agent.timer's last trigger was ${age}s ago with no tick currently running -- 6x its own 5min cadence with nothing dispatched in between"
    fi
  fi
}

# =============================================================================
# INV-5: quarantine health -- the V109 class (an issue accumulating
# environment faults, e.g. Codex-can't-commit) is already turned into a
# bounded, self-lifting quarantine by record_env_fault()/quarantine_open()
# (lib.sh) -- this is NOT re-implementing that. The supervisor's own value
# here is the cross-cutting fact no existing leg computes: is the
# quarantine mechanism ITSELF still working, or has an open quarantine
# become a new silent parking lot because its own canary auto-lift stopped
# firing (e.g. because of an INV-4-class tick stall)?
#
# Threshold = QUARANTINE_CANARY_MAX_SECONDS (the mechanism's own ceiling on
# how long between canary probes, 4h) + 1h buffer, so this only fires once
# the mechanism's own promise ("every 15min-4h, doubling") has clearly
# stopped being kept.
# =============================================================================
QUARANTINE_STALE_SECONDS=$((QUARANTINE_CANARY_MAX_SECONDS + 3600))
check_quarantine_health() {
  local f scope since now age
  [ -d "$QUARANTINE_DIR" ] || return 0
  now="$(date +%s)"
  for f in "$QUARANTINE_DIR"/*.json; do
    [ -f "$f" ] || continue
    scope="$(jq -r '.scope // "?"' "$f" 2>/dev/null || echo '?')"
    since="$(jq -r '.since // 0' "$f" 2>/dev/null || echo 0)"
    age=$(( now - since ))
    [ "$age" -ge "$QUARANTINE_STALE_SECONDS" ] || continue
    if cooldown_ready "quarantine-$scope" "$QUARANTINE_STALE_SECONDS"; then
      finding inv5 "quarantine \"$scope\" has been open for $((age / 3600))h -- longer than its own canary ceiling (max $((QUARANTINE_CANARY_MAX_SECONDS / 3600))h between probes) plus a 1h buffer; either the fault is genuinely persistent or the auto-lift canary stopped running"
      mark_cooldown "quarantine-$scope"
    fi
  done
}

# INV-7: report-only spend velocity. Per-ticket call/token budgets are enforced
# at dispatch in issue-pipeline.sh and run-implement.sh.
# =============================================================================

# spend_rows_since <epoch> -- every spend-ledger row (today's + yesterday's
# day-file, covering any window up to 24h) at or after $1, tab-separated,
# oldest first. Reads only $SPEND_DIR's own files; empty if the directory
# or both files are absent (a quiet day, not an error).
spend_rows_since() {
  local since="$1" now day_file yesterday_file
  now="$(date +%s)"
  day_file="$(spend_file_for_day "$now")"
  yesterday_file="$(spend_file_for_day "$((now - 86400))")"
  # `cat a b` returns non-zero if EITHER file is missing, even though the
  # one that exists was read fine -- "yesterday" having no spend log at
  # all (a quiet day, or literally the first day this ever runs) is
  # completely normal, not an error. Under `set -o pipefail` a bare `cat
  # a b | awk ...` here would propagate that non-zero straight into this
  # function's own return status and, at the call site (`rows="$(spend_
  # rows_since ...)"`, a plain assignment -- NOT `&&`/`||`-guarded, so NOT
  # exempt from `set -e`), kill the whole script. Measured live while
  # testing this: exactly this shape, silently, mid-run, with zero error
  # output -- the script just stopped. `|| true` on the cat makes a
  # missing day-file read as "no rows from that file", not "this function
  # failed".
  { cat "$day_file" "$yesterday_file" 2>/dev/null || true; } | awk -F'\t' -v s="$since" '$1 >= s'
}

# CONCENTRATION_FLOOR=10 / CONCENTRATION_RATIO=3: the original 128-row
# sample's clean hours topped out at ratio 2.20 and incident hours ran
# 3.50-5.50. The 2026-09-23 ledger has 1,185 rows: both actionless six-call
# emails were 4/2 and 5/1 across two tickets; a verified incident window
# reached 11 calls at ratio 3.67. Ten keeps that incident signal and drops
# tiny-volume noise. INV-7 is report-only; per-ticket budgets own dispatch
# eligibility at the measured 10-call and 2.2M-token thresholds.
VELOCITY_WINDOW_SECONDS="${VELOCITY_WINDOW_SECONDS:-3600}"
VELOCITY_FLOOR_CALLS="${VELOCITY_FLOOR_CALLS:-10}"
VELOCITY_CONCENTRATION_RATIO="${VELOCITY_CONCENTRATION_RATIO:-3}"
check_spend_velocity() {
  local since rows total distinct top
  since=$(( $(date +%s) - VELOCITY_WINDOW_SECONDS ))
  rows="$(spend_rows_since "$since")"
  [ -z "$rows" ] && return 0
  total="$(echo "$rows" | grep -c . || true)"
  [ "$total" -ge "$VELOCITY_FLOOR_CALLS" ] || return 0
  distinct="$(echo "$rows" | awk -F'\t' '{print $4}' | sort -u | grep -c . || true)"
  [ "$distinct" -ge 1 ] || return 0
  ratio=$(( total / distinct ))
  [ "$ratio" -ge "$VELOCITY_CONCENTRATION_RATIO" ] || return 0
  # `| head -3` at the end of a longer pipeline is the same class of risk
  # check_dispatch_stall()/issue_comment_has_marker() already had fixed
  # elsewhere (`grep -q`): `head` closes its input after 3 lines, which
  # can SIGPIPE a still-writing `sort -rn` upstream when there are MORE
  # than 3 distinct tickets in the window (a healthy, real batch-advisor
  # sweep routinely has 10+) -- under pipefail that reads as this whole
  # assignment failing. `|| true` keeps a truncation-induced SIGPIPE from
  # taking down the script the same way the missing-yesterday-file case in
  # spend_rows_since() did.
  top="$(echo "$rows" | awk -F'\t' '{print $4}' | sort | uniq -c | sort -rn | head -3 | awk '{printf "#%s(%s) ", $2, $1}' || true)"
  finding inv7 "$total model calls in the last $((VELOCITY_WINDOW_SECONDS / 60))min concentrated on only $distinct distinct ticket(s) (ratio $ratio, threshold $VELOCITY_CONCENTRATION_RATIO) -- top: $top -- the advisor/implement leg's dispatch budget is going to repeats, not new work"
}

# =============================================================================
# 2026-09-22 #1599: watched-session hand dispatch recovery. A session scratch
# brief dies with its session, so dispatch-codex.sh first persists a record
# containing the brief, fixed model/effort/access, worktree, branch, PID start ticks,
# and PID-addressable log under $AGENT_HOME/hand-dispatch. This supervisor is
# the only recovery consumer. It never guesses from ps output alone.
# =============================================================================
HAND_DISPATCH_DIR="${AGENT_DISPATCH_DIR:-$AGENT_HOME/hand-dispatch}"
HAND_DISPATCH_STALL_SECONDS="${HAND_DISPATCH_STALL_SECONDS:-720}"

hand_dispatch_pid_state() {
  local pid="$1" expected_ticks="$2" worktree="$3" observed_ticks sid cmd
  case "$pid" in ''|*[!0-9]*) echo unknown; return 0 ;; esac
  case "$expected_ticks" in ''|*[!0-9]*) echo unknown; return 0 ;; esac
  if ! kill -0 "$pid" 2>/dev/null; then
    [ -e "/proc/$pid" ] && echo unknown || echo dead
    return 0
  fi
  if ! [ -r "/proc/$pid/stat" ] || ! [ -r "/proc/$pid/cmdline" ]; then
    echo unknown
    return 0
  fi
  observed_ticks="$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)"
  [ "$observed_ticks" = "$expected_ticks" ] || { echo unknown; return 0; }
  sid="$(ps -o sid= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
  [ "$sid" = "$pid" ] || { echo unknown; return 0; }
  hand_codex_pid_matches "$pid" "$worktree" || { echo unknown; return 0; }
  echo live
}

hand_dispatch_agent_is_stalled() {
  local pid="$1" ticks="$2" worktree="$3" log_file="$4" age now modified
  [ "$(hand_dispatch_pid_state "$pid" "$ticks" "$worktree")" = live ] || return 1
  [ -f "$log_file" ] || return 1
  now="$(date +%s)"
  modified="$(stat -c %Y "$log_file" 2>/dev/null || true)"
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  case "$modified" in ''|*[!0-9]*) return 1 ;; esac
  age=$((now - modified))
  [ "$age" -ge "$HAND_DISPATCH_STALL_SECONDS" ]
}

hand_dispatch_set_status() {
  local record="$1" status="$2" tmp now
  [ "$MODE" = act ] && [ "$DRY_RUN" != 1 ] || return 0
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp="$record.tmp"
  jq --arg status "$status" --arg updated_at "$now" \
    '.status = $status | .updated_at = $updated_at' "$record" > "$tmp" || return 1
  mv "$tmp" "$record"
}

# true means material exists or its safety could not be proven. Cleanup only
# runs on a clean, branch-owned worktree with no unique commits or stash.
hand_dispatch_worktree_has_output() {
  local worktree="$1" dirty stash unique
  dirty="$(git -C "$worktree" status --porcelain --untracked-files=all 2>/dev/null)" || return 0
  [ -z "$dirty" ] || return 0
  stash="$(git -C "$worktree" stash list 2>/dev/null)" || return 0
  [ -z "$stash" ] || return 0
  unique="$(git -C "$worktree" log --format=%H origin/main..HEAD 2>/dev/null)" || return 0
  [ -z "$unique" ] || return 0
  return 1
}

checkpoint_hand_dispatch_worktree() {
  local worktree="$1" branch="$2" record_id="$3" current dirty
  dirty="$(git -C "$worktree" status --porcelain --untracked-files=all 2>/dev/null)" || return 1
  [ -n "$dirty" ] || return 0
  current="$(git -C "$worktree" symbolic-ref --short HEAD 2>/dev/null || true)"
  [ "$current" = "$branch" ] || {
    echo "supervise-pipeline: refusing checkpoint for $worktree; branch $current does not match recorded $branch" >&2
    return 1
  }
  git -C "$worktree" add -A || return 1
  git -C "$worktree" diff --cached --quiet || \
    git -C "$worktree" commit -m "checkpoint(agent): preserve stalled dispatch $record_id"
}

cleanup_hand_dispatch_worktree() {
  local worktree="$1" branch="$2" current listed
  [ "$worktree" != "$REPO_DIR" ] || return 1
  listed="$(git -C "$REPO_DIR" worktree list --porcelain 2>/dev/null)" || return 1
  awk -v expected="$worktree" \
    '$1 == "worktree" && substr($0, 10) == expected { found = 1 } END { exit found ? 0 : 1 }' \
    <<< "$listed" || return 1
  current="$(git -C "$worktree" symbolic-ref --short HEAD 2>/dev/null || true)"
  [ "$current" = "$branch" ] || return 1
  if hand_dispatch_worktree_has_output "$worktree"; then
    echo "supervise-pipeline: keeping $worktree; uncommitted material, stash, unique commits, or an unreadable Git fact remains" >&2
    return 2
  fi
  bash "$SCRIPT_DIR/worktree-lifecycle.sh" finish "$REPO_DIR" "$worktree"
}

relaunch_hand_dispatch() {
  local record="$1" id="$2" kind="$3" model="$4" effort="$5" access="$6" worktree="$7" branch="$8" brief="$9" current
  [ "$MODE" = act ] && [ "$DRY_RUN" != 1 ] || return 0
  local role recorded_role recorded_step recorded_identity expected_identity expected_model expected_effort provider
  case "$kind" in work|hard) role=work ;; production) role=production ;; *) role="" ;; esac
  expected_identity="$(model_policy identity "$role" 2>/dev/null || true)"
  IFS=: read -r provider expected_model expected_effort <<< "$expected_identity"
  recorded_role="$(jq -r '.model_policy.role // empty' "$record" 2>/dev/null || true)"
  recorded_step="$(jq -r '.model_policy.step // empty' "$record" 2>/dev/null || true)"
  recorded_identity="$(jq -r '.model_policy.identity // empty' "$record" 2>/dev/null || true)"
  if [ "$provider" != codex ] || [ "$model" != "$expected_model" ] || [ "$effort" != "$expected_effort" ] \
    || { [ -n "$recorded_role" ] && { [ "$recorded_role" != "$role" ] || [ "$recorded_step" != "$role" ] || [ "$recorded_identity" != "$expected_identity" ]; }; }; then
    echo "supervise-pipeline: refusing replay for $id; persisted dispatch contract is invalid" >&2
    return 1
  fi
  case "$access" in investigation|delivery) ;; *) echo "supervise-pipeline: refusing replay for $id; persisted dispatch contract is invalid" >&2; return 1 ;; esac
  [ -r "$brief" ] || { echo "supervise-pipeline: refusing replay for $id; durable brief is unreadable: $brief" >&2; return 1; }
  current="$(git -C "$worktree" symbolic-ref --short HEAD 2>/dev/null || true)"
  [ "$current" = "$branch" ] || { echo "supervise-pipeline: refusing replay for $id; worktree branch drifted" >&2; return 1; }
  hand_dispatch_set_status "$record" recovery-pending || return 1
  if "$SCRIPT_DIR/dispatch-codex.sh" --kind "$kind" --access "$access" --prompt-file "$brief" --worktree "$worktree"; then
    hand_dispatch_set_status "$record" recovered
  else
    hand_dispatch_set_status "$record" recovery-failed || true
    return 1
  fi
}

reconcile_dead_hand_dispatch() {
  local record="$1" id="$2" kind="$3" model="$4" effort="$5" access="$6" worktree="$7" branch="$8" brief="$9"
  checkpoint_hand_dispatch_worktree "$worktree" "$branch" "$id" || {
    echo "supervise-pipeline: refusing recovery for $id; could not checkpoint its worktree" >&2
    return 1
  }
  if hand_dispatch_worktree_has_output "$worktree"; then
    relaunch_hand_dispatch "$record" "$id" "$kind" "$model" "$effort" "$access" "$worktree" "$branch" "$brief"
  elif cleanup_hand_dispatch_worktree "$worktree" "$branch"; then
    hand_dispatch_set_status "$record" collected
  else
    echo "supervise-pipeline: cleanup refused for dead hand dispatch $id; leaving its worktree intact" >&2
    return 1
  fi
}

# reconcile_stale_web_advisor_provider_jobs -- the advisor provider's orphan-job sweep,
# moved 2026-10-30 with the rest of the web-advisor-provider transport to
# providers/web-advisor-provider.sh (sourced through lib.sh's provider seam); main()
# below still calls it every run.

check_hand_dispatches() {
  local record id status pid ticks kind model effort access worktree branch brief log_file pid_state
  [ -d "$HAND_DISPATCH_DIR" ] || return 0
  for record in "$HAND_DISPATCH_DIR"/*.json; do
    [ -f "$record" ] || continue
    id="$(jq -r '.id // empty' "$record" 2>/dev/null || true)"
    status="$(jq -r '.status // empty' "$record" 2>/dev/null || true)"
    pid="$(jq -r '.pid // empty' "$record" 2>/dev/null || true)"
    ticks="$(jq -r '.pid_start_ticks // empty' "$record" 2>/dev/null || true)"
    kind="$(jq -r '.kind // empty' "$record" 2>/dev/null || true)"
    model="$(jq -r '.model // empty' "$record" 2>/dev/null || true)"
    effort="$(jq -r '.effort // empty' "$record" 2>/dev/null || true)"
    access="$(jq -r 'if has("access") then .access else "investigation" end' "$record" 2>/dev/null || true)"
    worktree="$(jq -r '.worktree // empty' "$record" 2>/dev/null || true)"
    branch="$(jq -r '.branch // empty' "$record" 2>/dev/null || true)"
    brief="$(jq -r '.brief_file // empty' "$record" 2>/dev/null || true)"
    log_file="$(jq -r '.log_file // empty' "$record" 2>/dev/null || true)"
    if [ -z "$id" ] || [ -z "$status" ] || [ -z "$pid" ] || [ -z "$ticks" ] \
      || [ -z "$kind" ] || [ -z "$model" ] || [ -z "$effort" ] || [ -z "$access" ] || [ -z "$worktree" ] \
      || [ -z "$branch" ] || [ -z "$brief" ] || [ -z "$log_file" ]; then
      finding incident1599-agent "invalid durable hand-dispatch record: $record"
      continue
    fi
    case "$status" in running|stopping) ;; *) continue ;; esac
    pid_state="$(hand_dispatch_pid_state "$pid" "$ticks" "$worktree")"
    case "$pid_state" in
      live)
        if ! hand_dispatch_agent_is_stalled "$pid" "$ticks" "$worktree" "$log_file"; then
          # A prior TERM may have been delayed. Never carry a stale kill
          # intent forward once this exact agent has resumed writing.
          if [ "$status" = stopping ]; then
            hand_dispatch_set_status "$record" running || true
          fi
          continue
        fi
        finding incident1599-agent "$id has a verified live Codex PID $pid but its own log has been silent for at least $((HAND_DISPATCH_STALL_SECONDS / 60))min"
        [ "$MODE" = act ] || continue
        checkpoint_hand_dispatch_worktree "$worktree" "$branch" "$id" || {
          echo "supervise-pipeline: refusing to terminate stalled $id; checkpoint failed" >&2
          continue
        }
        hand_dispatch_set_status "$record" stopping || continue
        # Check again after the potentially slow Git checkpoint. PID reuse is
        # rare, but exact start identity immediately before TERM is the
        # boundary that keeps an unrelated process out of this action.
        if ! hand_dispatch_agent_is_stalled "$pid" "$ticks" "$worktree" "$log_file"; then
          hand_dispatch_set_status "$record" running || true
          echo "supervise-pipeline: refusing TERM for $id; its exact process no longer proves stalled" >&2
          continue
        fi
        hand_agent_stop_session "$pid" || echo "supervise-pipeline: TERM failed for stalled hand dispatch $id PID $pid" >&2
        ;;
      dead)
        finding incident1599-reboot "$id has no live owner after a durable dispatch; reconciling its recorded worktree"
        if [ "$MODE" = act ]; then
          reconcile_dead_hand_dispatch "$record" "$id" "$kind" "$model" "$effort" "$access" "$worktree" "$branch" "$brief" || true
        fi
        ;;
      unknown)
        finding incident1599-agent "$id PID $pid cannot be proven to be its recorded Codex process; leaving it untouched"
        ;;
    esac
  done
}

# =============================================================================
# 2026-09-22 #1599: build/release reconciliation. This never deploys. It
# dispatches only the live main HEAD after that SHA's own Postsubmit is green;
# an older in-flight source is deliberately not awaited or retried.
# =============================================================================
RELEASE_RECOVERY_DIR="$AGENT_HOME/release-recovery"

release_record_file() { echo "$RELEASE_RECOVERY_DIR/$1.json"; }

release_record_write() {
  local sha="$1" status="$2" run_id="$3" conclusion="$4" kind="$5" step="$6" decisive_line="$7" live_sha="$8"
  local record tmp now
  [ "$MODE" = act ] && [ "$DRY_RUN" != 1 ] || return 0
  mkdir -p "$RELEASE_RECOVERY_DIR"
  record="$(release_record_file "$sha")"
  tmp="$record.tmp"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ -f "$record" ]; then
    jq --arg status "$status" --arg run_id "$run_id" --arg conclusion "$conclusion" \
      --arg kind "$kind" --arg step "$step" --arg decisive_line "$decisive_line" \
      --arg live_sha "$live_sha" --arg updated_at "$now" \
      'if $status == "dispatching" and .status == "capacity-wait" then
         .capacity_failure = {run_id:.run_id, conclusion:.conclusion, failure_kind:.failure_kind,
           failed_step:.failed_step, decisive_line:.decisive_line, detected_at:.updated_at}
         | .dispatched_at = $updated_at
       else . end
       | .status = $status | .run_id = $run_id | .conclusion = $conclusion | .failure_kind = $kind | .failed_step = $step | .decisive_line = $decisive_line | .live_sha = $live_sha | .updated_at = $updated_at' \
      "$record" > "$tmp" || return 1
  else
    jq -n --arg sha "$sha" --arg status "$status" --arg run_id "$run_id" --arg conclusion "$conclusion" \
      --arg kind "$kind" --arg step "$step" --arg decisive_line "$decisive_line" \
      --arg live_sha "$live_sha" --arg now "$now" \
      '{source_sha: $sha, status: $status, run_id: $run_id, conclusion: $conclusion, failure_kind: $kind, failed_step: $step, decisive_line: $decisive_line, live_sha: $live_sha, dispatched_at: $now, updated_at: $now}' \
      > "$tmp" || return 1
  fi
  mv "$tmp" "$record"
}

release_record_field() {
  local sha="$1" field="$2" record
  record="$(release_record_file "$sha")"
  [ -r "$record" ] || return 1
  jq -r ".$field // empty" "$record" 2>/dev/null
}

release_record_validation_write() {
  local sha="$1" run_id="$2" event="$3" record tmp now
  [ "$MODE" = act ] && [ "$DRY_RUN" != 1 ] || return 0
  [[ "$sha" =~ ^[0-9a-f]{40}$ && "$run_id" =~ ^[0-9]+$ ]] || return 1
  mkdir -p "$RELEASE_RECOVERY_DIR" || return 1
  record="$(release_record_file "$sha")"
  tmp="$record.tmp"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ -e "$record" ]; then
    jq --arg sha "$sha" --arg run_id "$run_id" --arg event "$event" --arg now "$now" \
      'if .source_sha != $sha then error("release record source SHA mismatch") else
        .validation = {workflow:"ci.yml", run_id:$run_id, event:$event, conclusion:"success", recorded_at:$now}
      end' "$record" > "$tmp" || return 1
  else
    jq -n --arg sha "$sha" --arg run_id "$run_id" --arg event "$event" --arg now "$now" \
      '{source_sha:$sha, validation:{workflow:"ci.yml", run_id:$run_id, event:$event, conclusion:"success", recorded_at:$now}}' \
      > "$tmp" || return 1
  fi
  mv "$tmp" "$record"
}

dispatch_postsubmit_for_sha() {
  local sha="$1" commit message request_state request_rc current_sha record attempts updated_at updated_epoch now_epoch age
  local retry_delay_seconds=600 max_attempts=3 matching_run matching_run_rc
  commit="$(ci_main_commit_for_sha "$sha")" || {
    finding incident1599-build "could not read commit metadata for $sha; Postsubmit dispatch was not attempted"
    return 0
  }
  message="$(jq -r '.commit.message // empty' <<< "$commit")"
  if ! grep -qiF '[skip ci]' <<< "$message"; then
    finding incident1599-build "live main $sha has no exact-SHA Postsubmit; commit does not carry [skip ci], so automatic dispatch waits"
    return 0
  fi
  if request_state="$(postsubmit_request_record_state "$sha")"; then request_rc=0; else request_rc=$?; fi
  if [ "$request_rc" = 0 ]; then
    case "$request_state" in
      dispatch-failed|dispatching)
        record="$(postsubmit_request_record_file "$sha")"
        attempts="$(jq -er --arg sha "$sha" '
          if type == "object" and .source_sha == $sha then
            (.dispatch_attempts // 1) as $attempts
            | if ($attempts | type) == "number" and $attempts >= 1 and $attempts == ($attempts | floor)
              then $attempts else error("invalid Postsubmit dispatch attempt count") end
          else error("invalid Postsubmit dispatch record") end' "$record" 2>/dev/null)" || {
          finding incident1599-build "Postsubmit dispatch record for $sha has an invalid retry count; duplicate dispatch refused"
          return 0
        }
        if [ "$attempts" -ge "$max_attempts" ]; then
          finding incident1599-build "Postsubmit dispatch recovery for $sha exhausted its $max_attempts attempts; exact-SHA validation remains blocked"
          return 0
        fi
        updated_at="$(jq -er --arg sha "$sha" '
          if .source_sha == $sha and (.updated_at | type == "string" and length > 0)
          then .updated_at else error("missing Postsubmit retry timestamp") end' "$record" 2>/dev/null)" || {
          finding incident1599-build "Postsubmit dispatch record for $sha has no valid retry timestamp; duplicate dispatch refused"
          return 0
        }
        updated_epoch="$(date -u -d "$updated_at" +%s 2>/dev/null)" || {
          finding incident1599-build "Postsubmit dispatch record for $sha has an unreadable retry timestamp; duplicate dispatch refused"
          return 0
        }
        now_epoch="$(date -u +%s)"
        age=$((now_epoch - updated_epoch))
        if [ "$age" -lt "$retry_delay_seconds" ]; then
          finding incident1599-build "Postsubmit dispatch recovery for $sha waits for the $retry_delay_seconds-second retry delay; recorded state is $request_state"
          return 0
        fi
        # The caller reached this recovery path only after the exact-SHA Actions
        # lookup succeeded and found no run. Recheck before retrying because a
        # previous dispatch may have been accepted while its response was lost.
        if matching_run="$(ci_main_postsubmit_run_for_sha "$sha")"; then
          matching_run_rc=0
        else
          matching_run_rc=$?
        fi
        if [ "$matching_run_rc" = 0 ]; then
          finding incident1599-build "Postsubmit recovery for $sha found exact-SHA run $(jq -r '.id // "unknown"' <<< "$matching_run"); duplicate dispatch refused"
          return 0
        fi
        if [ "$matching_run_rc" != 1 ]; then
          finding incident1599-build "Actions API could not confirm absence of an exact-SHA Postsubmit for $sha; recovery dispatch refused"
          return 0
        fi
        ;;
      *)
        finding incident1599-build "Postsubmit dispatch for $sha is already recorded as $request_state; waiting for its exact-SHA run"
        return 0
        ;;
    esac
  fi
  if [ "$request_rc" != 0 ] && [ "$request_rc" != 1 ]; then
    finding incident1599-build "Postsubmit dispatch record for $sha is unreadable or invalid; duplicate dispatch refused"
    return 0
  fi
  current_sha="$(main_head_sha)"
  if [ "$current_sha" != "$sha" ]; then
    finding incident1599-build "main tip changed from $sha to ${current_sha:-unreadable} before Postsubmit dispatch; retrying on the next pass"
    return 0
  fi
  [ "$MODE" = act ] && [ "$DRY_RUN" != 1 ] || return 0
  # Both the supervisor and direct-main take this per-SHA claim before the
  # GitHub side effect, so delayed Actions visibility cannot split ownership.
  if postsubmit_request_dispatch_claim "$sha" "$retry_delay_seconds" "$max_attempts"; then :; else
    local claim_rc=$?
    if [ "$claim_rc" = 1 ]; then
      finding incident1599-build "Postsubmit dispatch for $sha is already claimed by another entry point or waiting for its retry window"
    else
      finding incident1599-build "Postsubmit dispatch claim for $sha is invalid or unreadable; duplicate dispatch refused"
    fi
    return 0
  fi
  if guarded_write gh workflow run ci.yml -R "$REPO" --ref main -f "source_sha=$sha"; then
    postsubmit_request_record_write "$sha" requested "" "" || true
    finding incident1599-build "dispatched exact-tip Postsubmit for [skip ci] main SHA $sha; build remains blocked until its successful Postsubmit job is observable"
  else
    postsubmit_request_record_write "$sha" dispatch-failed "" "" || true
    finding incident1599-build "Postsubmit dispatch for $sha failed; build remains blocked and the SHA stays deduplicated"
  fi
}

build_failure_evidence() {
  local run_id="$1" failed_log
  BUILD_FAILURE_STEP="$(gh run view "$run_id" -R "$ZF_INFRA_REPO" --json jobs \
    --jq '[.jobs[]?.steps[]? | select(.conclusion == "failure") | .name][0] // empty' 2>/dev/null || true)"
  failed_log="$(gh run view "$run_id" -R "$ZF_INFRA_REPO" --log-failed 2>/dev/null || true)"
  # --log-failed is limited by gh to failed steps. Extract one concrete line
  # from that output, skipping the generic runner epilogue. Classification
  # below still requires its named workflow step; no whole-log heuristic.
  BUILD_FAILURE_LINE="$(awk '
    NF {
      line = $0
      sub(/\r$/, "", line)
      lower = tolower(line)
      if (line ~ /source_sha must be the current the product main HEAD/ ||
          lower ~ /curl: \(22\).*returned error: 401/ || lower ~ / -> 401:/ ||
          lower ~ /at least 60gib free disk is required/ ||
          line ~ /docker( compose)? is required/ ||
          lower ~ /container runtime/ || lower ~ /docker daemon/ ||
          (lower ~ /proxy/ && (lower ~ /timeout/ || lower ~ /timed out/))) {
        decisive = line
      } else if (line !~ /^(Error: )?Process completed with exit code [0-9]+$/ &&
                 line !~ /^##\[error\]/) {
        fallback = line
      }
    }
    END {
      output = decisive != "" ? decisive : fallback
      print substr(output, 1, 500)
    }
  ' <<< "$failed_log")"
}

classify_build_failure() {
  local conclusion="$1" step="$2" decisive_line="$3" source_sha="$4" live_sha="$5" line_lower
  case "$conclusion" in
    cancelled|canceled)
      [ "$source_sha" = "$live_sha" ] && echo environment:cancelled || echo environment:superseded
      return 0
      ;;
  esac
  line_lower="$(printf '%s' "$decisive_line" | tr '[:upper:]' '[:lower:]')"
  if [ "$step" = "Set up job" ] \
    && [[ "$line_lower" == *"container runtime"* || "$line_lower" == *"docker daemon"* ]]; then
    echo environment:runner-container-runtime
  elif [ "$step" = "Preflight production build runner" ] \
    && [[ "$line_lower" == *"docker is required"* || "$line_lower" == *"docker compose is required"* ]]; then
    echo environment:runner-container-runtime
  elif [ "$step" = "Preflight production build runner" ] \
    && [[ "$line_lower" == *"at least 60gib free disk is required"* ]]; then
    echo environment:build-capacity
  elif [[ "$step" = 'Ensure production Nexus is running' || "$step" = 'Provision production Nexus repositories' ]] \
    && [[ "$line_lower" == *'returned error: 401'* || "$line_lower" == *' -> 401:'* ]]; then
    echo environment:nexus-auth
  elif case "$step" in
      "Set up job"|"Configure git proxy"|"Checkout infra contract"|"Build and push production images") true ;;
      *) [[ -n "$step" && "|$ZF_INFRA_PROXY_STEPS|" == *"|$step|"* ]] ;;
    esac \
    && [[ "$line_lower" == *"proxy"* && ( "$line_lower" == *"timeout"* || "$line_lower" == *"timed out"* ) ]]; then
    echo environment:proxy-timeout
  elif [ "$step" = "Download selected the product source" ] \
    && [[ "$decisive_line" == *"source_sha must be the current the product main HEAD"* ]]; then
    echo environment:source-sha-superseded
  elif [ "$step" = "Build and push production images" ] && [ -n "$decisive_line" ]; then
    echo product
  else
    echo unknown
  fi
}

# A failed step can echo an auth header or tool configuration. Keep raw output
# only in this process long enough to classify it; every durable record and
# finding gets one of these fixed, credential-free evidence labels instead.
safe_build_failure_line() {
  local line="$1" line_lower
  line_lower="$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')"
  if [[ "$line" == *"source_sha must be the current the product main HEAD"* ]]; then
    echo source-sha-mismatch
  elif [[ "$line_lower" == *'returned error: 401'* || "$line_lower" == *' -> 401:'* ]]; then
    echo http-401
  elif [[ "$line_lower" == *"at least 60gib free disk is required"* ]]; then
    echo production-build-disk-capacity-gate
  elif [[ "$line_lower" == *"container runtime"* || "$line_lower" == *"docker daemon"* \
    || "$line_lower" == *"docker is required"* || "$line_lower" == *"docker compose is required"* ]]; then
    echo container-runtime-unavailable
  elif [[ "$line_lower" == *"proxy"* && ( "$line_lower" == *"timeout"* || "$line_lower" == *"timed out"* ) ]]; then
    echo proxy-timeout
  else
    echo failed-step-output-redacted
  fi
}

main_head_sha() {
  local commit
  commit="$(ci_main_current_commit 2>/dev/null)" || return 0
  jq -r '.sha' <<< "$commit" 2>/dev/null || true
}

postsubmit_green_for_sha() {
  ci_main_postsubmit_green_for_sha "$1" "${2:-}"
}

# The workflow_dispatch job runs only when its source_sha input equals
# github.sha. A dispatch sent for A can therefore appear under successor B
# (because --ref main resolves at arrival time) with this job skipped. That
# run is not evidence for B and must not occupy B's recovery slot.
postsubmit_dispatch_was_skipped_for_run() {
  local run="$1" run_id job
  [ "$(jq -r '.event // empty' <<< "$run")" = workflow_dispatch ] || return 1
  run_id="$(jq -r '.id // empty' <<< "$run")"
  [[ "$run_id" =~ ^[0-9]+$ ]] || return 2
  job="$(ci_main_postsubmit_job_for_run "$run_id")" || return 2
  jq -e '.status == "completed" and .conclusion == "skipped"' <<< "$job" >/dev/null 2>&1
}

release_find_run() {
  local after="$1"
  gh run list -R "$ZF_INFRA_REPO" --workflow "$ZF_INFRA_BUILD_WORKFLOW" --limit 20 \
    --json databaseId,createdAt,event --jq \
    "[.[] | select(.event == \"workflow_dispatch\" and .createdAt >= \"$after\")] | sort_by(.createdAt) | .[0].databaseId // empty" \
    2>/dev/null || true
}

record_build_result_on_issues() {
  local sha="$1" kind="$2" run_id="$3" conclusion="$4" step="$5" decisive_line="$6" base affected n patch env_recorded=0
  base="$(bash "$SCRIPT_DIR/production-deployment-read.sh" "$REPO" 1 2>/dev/null | jq -r '.[0].sha // empty' 2>/dev/null || true)"
  if ! git -C "$REPO_DIR" merge-base --is-ancestor "$base" "$sha" 2>/dev/null; then
    base="$(git -C "$REPO_DIR" rev-parse "$sha^" 2>/dev/null || true)"
  fi
  [ -n "$base" ] || return 0
  affected="$(issue_numbers_in_range "$base..$sha" "$REPO_DIR" 2>/dev/null | sort -un || true)"
  [ -n "$affected" ] || return 0
  patch="$(jq -cn --arg sha "$sha" --arg run_id "$run_id" --arg conclusion "$conclusion" \
    --arg kind "$kind" --arg step "$step" --arg decisive_line "$decisive_line" \
    '{release_build: {source_sha: $sha, run_id: $run_id, conclusion: $conclusion, failure_kind: $kind, failed_step: $step, decisive_line: $decisive_line}}')"
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    if issue_has_live_unit "$n"; then
      finding incident1599-build "build $run_id result for #$n waits for its live pipeline unit"
      continue
    fi
    state_merge "$n" ". + $patch" || continue
    case "$kind" in
      product) route_to_advisor "$n" || true ;;
      environment:build-capacity) : ;; # The system-level capacity episode is recorded once below.
      # A newer main replaced this build; nothing failed. 2026-10-05 04:57Z one superseded build
      # opened the release quarantine because it was recorded once per affected issue (28 hits).
      environment:superseded|environment:source-sha-superseded) : ;;
      environment:*)
        # One fault per build, not per issue: the quarantine threshold counts builds.
        [ "$env_recorded" = 1 ] || record_env_fault "env:production-image-build:${kind#environment:}" release "$n" "$step: $decisive_line"
        env_recorded=1
        ;;
    esac
  done <<< "$affected"
}

reconcile_build_record() {
  local source_sha="$1" live_sha="$2" status run_id observed_run row conclusion kind safe_line
  status="$(release_record_field "$source_sha" status 2>/dev/null || true)"
  case "$status" in success|failed|dispatch-failed|capacity-wait|"") return 0 ;; esac
  run_id="$(release_record_field "$source_sha" run_id 2>/dev/null || true)"
  if [ -z "$run_id" ]; then
    observed_run="$(release_find_run "$(release_record_field "$source_sha" dispatched_at 2>/dev/null || true)")"
    if [ -n "$observed_run" ]; then
      run_id="$observed_run"
      release_record_write "$source_sha" running "$run_id" "" "" "" "" "$live_sha" || true
    else
      finding incident1599-build "recorded build dispatch for $source_sha has no observable run yet; it will not be sent a second time"
      return 0
    fi
  fi
  row="$(gh run view "$run_id" -R "$ZF_INFRA_REPO" --json status,conclusion 2>/dev/null || true)"
  [ -n "$row" ] || { finding incident1599-build "build run $run_id for $source_sha could not be read"; return 0; }
  [ "$(jq -r '.status // empty' <<< "$row")" = completed ] || return 0
  conclusion="$(jq -r '.conclusion // empty' <<< "$row")"
  if [ "$conclusion" = success ]; then
    release_record_write "$source_sha" success "$run_id" success "" "" "" "$live_sha" || true
    return 0
  fi
  build_failure_evidence "$run_id"
  kind="$(classify_build_failure "$conclusion" "$BUILD_FAILURE_STEP" "$BUILD_FAILURE_LINE" "$source_sha" "$live_sha")"
  safe_line="$(safe_build_failure_line "$BUILD_FAILURE_LINE")"
  finding incident1599-build "build $run_id for $source_sha ended $conclusion; kind=$kind step=${BUILD_FAILURE_STEP:-unknown} line=$safe_line"
  [ "$MODE" = act ] || return 0
  if [ "$kind" = environment:build-capacity ]; then
    local capacity_detail
    capacity_detail="$BUILD_FAILURE_STEP: $safe_line (run $run_id)"
    record_env_fault env:build-capacity release 0 "$capacity_detail" "" "" 0 || return 1
    quarantine_open release env:build-capacity "$capacity_detail" 1 || return 1
    release_record_write "$source_sha" capacity-wait "$run_id" "$conclusion" "$kind" \
      "$BUILD_FAILURE_STEP" "$safe_line" "$live_sha" || return 0
    record_build_result_on_issues "$source_sha" "$kind" "$run_id" "$conclusion" "$BUILD_FAILURE_STEP" "$safe_line"
    return 0
  fi
  release_record_write "$source_sha" failed "$run_id" "$conclusion" "$kind" "$BUILD_FAILURE_STEP" "$safe_line" "$live_sha" || return 0
  record_build_result_on_issues "$source_sha" "$kind" "$run_id" "$conclusion" "$BUILD_FAILURE_STEP" "$safe_line"
}

check_release_reconciliation() {
  local live_sha current_sha record source_sha status postsubmit_history latest_postsubmit_run
  local postsubmit_run postsubmit_rc postsubmit_id postsubmit_event
  live_sha="$(main_head_sha)"
  case "$live_sha" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;; *)
    finding incident1599-build "could not read live main HEAD; build reconciliation did not guess from a stale local ref"
    return 0
    ;;
  esac
  # Reap terminal results for older requests first. A newer merge may have
  # invalidated their source SHA, but their failure still needs classification.
  if [ -d "$RELEASE_RECOVERY_DIR" ]; then
    for record in "$RELEASE_RECOVERY_DIR"/*.json; do
      [ -r "$record" ] || continue
      source_sha="$(jq -r '.source_sha // empty' "$record" 2>/dev/null || true)"
      if [ -z "$source_sha" ] || [ "$source_sha" = "$live_sha" ]; then
        continue
      fi
      reconcile_build_record "$source_sha" "$live_sha"
    done
  fi
  reconcile_build_record "$live_sha" "$live_sha"
  status="$(release_record_field "$live_sha" status 2>/dev/null || true)"
  case "$status" in
    ""|capacity-wait) ;;
    *) return 0 ;;
  esac
  if postsubmit_history="$(ci_main_postsubmit_run_history_for_sha "$live_sha")"; then
    latest_postsubmit_run="$(jq -c 'last' <<< "$postsubmit_history")"
    if postsubmit_run="$(ci_main_postsubmit_green_run_for_sha "$live_sha" "$postsubmit_history")"; then
      :
    else
      postsubmit_rc=$?
      if [ "$postsubmit_rc" = 2 ]; then
        finding incident1599-build "could not verify a successful Postsubmit validate job for an exact-SHA run of live main $live_sha; build dispatch remains blocked"
        return 0
      fi
      postsubmit_run="$latest_postsubmit_run"
      postsubmit_id="$(jq -r '.id // "unknown"' <<< "$postsubmit_run")"
      if postsubmit_dispatch_was_skipped_for_run "$postsubmit_run"; then
        finding incident1599-build "workflow_dispatch run $postsubmit_id is attached to live main $live_sha but its Postsubmit validate job was skipped; recovering with an independent exact-tip request"
        dispatch_postsubmit_for_sha "$live_sha"
        return 0
      else
        postsubmit_rc=$?
        if [ "$postsubmit_rc" = 2 ]; then
          finding incident1599-build "could not confirm whether workflow_dispatch run $postsubmit_id skipped Postsubmit validate; exact-SHA recovery and build remain blocked"
          return 0
        fi
      fi
      finding incident1599-build "exact-SHA Postsubmit has no completed successful validate job for live main $live_sha; build dispatch waits for its own evidence"
      return 0
    fi
    postsubmit_id="$(jq -r '.id' <<< "$postsubmit_run")"
    postsubmit_event="$(jq -r '.event' <<< "$postsubmit_run")"
    release_record_validation_write "$live_sha" "$postsubmit_id" "$postsubmit_event" || {
      finding incident1599-build "could not record exact-SHA Postsubmit run $postsubmit_id for $live_sha; build dispatch refused"
      return 0
    }
  else
    postsubmit_rc=$?
    if [ "$postsubmit_rc" = 1 ]; then
      dispatch_postsubmit_for_sha "$live_sha"
    else
      finding incident1599-build "Actions API could not establish an exact-SHA Postsubmit for $live_sha; verification and build dispatch both remain blocked"
    fi
    return 0
  fi
  if ! stage_dispatch_allowed release; then
    finding incident1599-build "live main $live_sha build dispatch waits for the release-stage capacity quarantine"
    return 0
  fi
  if [ "$status" = capacity-wait ]; then
    finding incident1599-build "live main $live_sha capacity precondition passed; resuming its recorded build"
  else
    finding incident1599-build "live main $live_sha has green Postsubmit but no recorded build dispatch"
  fi
  [ "$MODE" = act ] && [ "$DRY_RUN" != 1 ] || return 0
  current_sha="$(main_head_sha)"
  if [ "$current_sha" != "$live_sha" ]; then
    finding incident1599-build "main tip changed from $live_sha to ${current_sha:-unreadable} before build dispatch; build remains blocked"
    return 0
  fi
  # Persist before the GitHub mutation. If a reboot lands between dispatch and
  # discovery, the next pass finds the run instead of issuing a second SHA pin.
  release_record_write "$live_sha" dispatching "" "" "" "" "" "$live_sha" || return 0
  if ! guarded_write gh workflow run "$ZF_INFRA_BUILD_WORKFLOW" -R "$ZF_INFRA_REPO" \
    -f "source_sha=$live_sha" -f source_branch=main; then
    release_record_write "$live_sha" dispatch-failed "" "" environment:dispatch "" "" "$live_sha" || true
  fi
}

# 10-29: #4576/#4587/#4588 sat red for 5–6 h after a supervisor handover; idle hotfix PRs must be loud, not remembered.
check_hotfix_stale() {
  local out
  out="$(bash "$SCRIPT_DIR/hotfix/hf-stale.sh" 2>/dev/null)" && return 0
  [ -n "$out" ] && finding hotfix-stale "$(tr '\n' ' ' <<< "$out")"
  return 0
}

main() {
  check_hotfix_stale
  ! declare -F check_shared_browser_tabs >/dev/null || check_shared_browser_tabs
  check_advisor_ruled_at_regression
  check_recut_marker_regression
  check_dispatch_stall
  check_repeating_implement_skips
  check_repeating_advisor_lease_bails
  check_ticket_cycling
  check_stalled_prs
  check_tick_liveness
  check_quarantine_health
  check_spend_velocity
  check_hand_dispatches
  reconcile_stale_web_advisor_provider_jobs
  check_release_reconciliation
  echo "supervise-pipeline: done -- mode=$MODE findings=$FOUND" >&2
}

main "$@"
