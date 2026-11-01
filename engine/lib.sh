#!/usr/bin/env bash
# Shared helpers for engine/*.sh. Source this, do not execute it.
# ponytail: one small shared file beats the same jq/state snippet copy-pasted
# into issue-pipeline.sh, run-triage.sh, run-implement.sh, and run-release.sh.

_AGENT_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$_AGENT_LIB_DIR/closing-keywords.sh"
[[ -r "$_AGENT_LIB_DIR/platform-env.sh" ]] && source "$_AGENT_LIB_DIR/platform-env.sh"
[[ -r "$_AGENT_LIB_DIR/proc.sh" ]] && source "$_AGENT_LIB_DIR/proc.sh" # host_boot_id: macOS has no /proc
# Test fixtures that copy lib.sh alone (nine suites) do not carry systemd/; a real checkout always does.
[[ -r "$_AGENT_LIB_DIR/systemd/build-capacity-gate.sh" ]] && source "$_AGENT_LIB_DIR/systemd/build-capacity-gate.sh"
[[ -r "$_AGENT_LIB_DIR/ci-runner-disk-floor.sh" ]] && source "$_AGENT_LIB_DIR/ci-runner-disk-floor.sh"
[[ -r "$_AGENT_LIB_DIR/supervisor-holds.sh" ]] && source "$_AGENT_LIB_DIR/supervisor-holds.sh"
[[ -r "$_AGENT_LIB_DIR/roadmap.sh" ]] && source "$_AGENT_LIB_DIR/roadmap.sh"
[[ -r "$_AGENT_LIB_DIR/land-queue-state.sh" ]] && source "$_AGENT_LIB_DIR/land-queue-state.sh"
[[ -r "$_AGENT_LIB_DIR/hand-codex-liveness.sh" ]] && source "$_AGENT_LIB_DIR/hand-codex-liveness.sh"
[[ -r "$_AGENT_LIB_DIR/runtime-reload.sh" ]] && source "$_AGENT_LIB_DIR/runtime-reload.sh"
[[ -r "$_AGENT_LIB_DIR/matt-skills.sh" ]] && source "$_AGENT_LIB_DIR/matt-skills.sh"
source "${ZF_EXECUTION_MODULE_DIR:-$_AGENT_LIB_DIR}/execution-admission.sh"

source "$(dirname -- "${BASH_SOURCE[0]}")/config.sh" # AGENT_HOME, ZF_ENGINE_DIR, ZF_REPO_DIR
source "$(dirname -- "${BASH_SOURCE[0]}")/coord.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/write-guard.sh"
agent_pipeline_write_guard 'lib.sh initialization' "$AGENT_HOME" || return 1
# Host capacity tuning (non-secret) beats the credentials env file. On 2026-10-06 that file pinned
# AGENT_DISPATCH_LOAD_LIMIT_MULTIPLIER=2 into every with-credentials child, so an implement unit held
# the head of the FIFO preflight queue in a 45-minute load-admission wait and every landing waited behind it.
if [ -r "$AGENT_HOME/capacity.env" ]; then set -a; . "$AGENT_HOME/capacity.env"; set +a; fi
STATE_DIR="$AGENT_HOME/state"
LOG_DIR="$AGENT_HOME/logs"
# One systemd unit-name prefix for the whole engine, set by ZF_UNIT_PREFIX. Long-lived units are
# "$UNIT_PREFIX-agent.service", "$UNIT_PREFIX-supervisor.timer", ...; transient worker units started with
# systemd-run are "$UNIT_PREFIX_TRANSIENT-implement-<n>", "$UNIT_PREFIX_TRANSIENT-release-batch", ... .
# Two names for one setting so the two kinds can have different defaults.
UNIT_PREFIX="${ZF_UNIT_PREFIX:-zenoforge}"
UNIT_PREFIX_TRANSIENT="${ZF_UNIT_PREFIX:-zf}"

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.d/env-fault.sh"

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.d/worktree.sh"

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.d/supervisor-inbox.sh"

ON_HOLD_QUERY_FAILURE_COUNT=0
ON_HOLD_QUERY_FAILURE_ISSUES=""
LOCK_FILE="$AGENT_HOME/lock"
PAUSE_FILE="$AGENT_HOME/PAUSE"
# Distinct from LOCK_FILE above. LOCK_FILE serializes one tick's dispatch
# decisions; this lock serializes only the `gh pr merge` mutation across
# implementers and the merge sweeper.
MERGE_LOCK_FILE="$AGENT_HOME/merge-lock"
# The implement unit's outer deadline is separate from merge handoff. The
# sweeper checks unit liveness and can take over a green PR as soon as its
# implement unit exits.
IMPLEMENT_RUNTIME_MAX_SEC="${IMPLEMENT_RUNTIME_MAX_SEC:-$((9 * 60 * 60))}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-$((3 * 60))}"
NEEDS_INFO_QUESTION_TIMEOUT_SECONDS="${NEEDS_INFO_QUESTION_TIMEOUT_SECONDS:-$((72 * 60 * 60))}"
# A merge sweep runs about once per tick (roughly every six minutes). Three
# identical skips therefore surfaces a PR after about 18 minutes, while one
# transient tick cannot page an issue. Transport failures are excluded below.
MERGE_SWEEP_ESCALATION_THRESHOLD="${MERGE_SWEEP_ESCALATION_THRESHOLD:-3}"
# 2026-09-12: written by run-release.sh the moment a deploy fails and rolled
# back (see deploy_is_blocked() below); read by both run-release.sh itself
# and issue-pipeline.sh section (d) before ever attempting another deploy.
# The exact failed SHA remains blocked; fix-forward descendants are eligible
# for the normal release checks and do not require a marker clear.
DEPLOY_BLOCKED_FILE="$AGENT_HOME/deploy-blocked-sha"
MAIN_RED_DIR="$AGENT_HOME/main-red"
# 2026-09-17: derive the checkout root from this file's own location instead
# of a hardcoded $HOME path -- the CI runner (and any second machine) has no
# $HOME, and the old fallback made every bare `source lib.sh` there
# die on `cd "$REPO_DIR"` (PR #1355 CI, full-script regression). An explicit
# ZF_REPO_DIR still wins, so production systemd units are unaffected.
REPO_DIR="$ZF_REPO_DIR"
# The target repository as owner/name: ZF_REPO, else derived from the checkout's origin remote. Exported for child processes. A checkout with neither stays empty (|| true: no origin remote is exit 2, which set -e would turn into a silent exit).
REPO="${ZF_REPO:-$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null | sed -E 's#^(git@[^:]+:|[a-z+]+://([^/@]+@)?[^/]+/)##; s#\.git$##' || true)}"
export ZF_REPO="$REPO"

# Model choice has one persistent source: the operator file, seeded from this
# versioned policy. Launchers pass role names; this helper owns validation,
# identity formatting, and escalation transitions.
# A target-repo policy override wins, followed by the migration pack and then the engine default.
MODEL_POLICY_DEFAULT="$(zf_config_file model-policy.default.json)" || MODEL_POLICY_DEFAULT="$_AGENT_LIB_DIR/model-policy.default.json"
MODEL_POLICY_FILE="$AGENT_HOME/model-policy.json"
# Line B (2026-10-30 flip): the live policy names the advisor provider web-advisor-provider, the Zenoforge engine's id, and
# this tree's validator only knows web-advisor-provider. Scripts still run from this tree read the policy through a view mapped back to
# web-advisor-provider; a write lands in the view, never the live file (which the Zenoforge engine owns now). Remove at D2 with the old engine.
if [ -f "$MODEL_POLICY_FILE" ] && grep -q '"web-advisor-provider"' "$MODEL_POLICY_FILE" 2>/dev/null; then
  _model_policy_view="$AGENT_HOME/.model-policy.web-advisor-provider-view.json"
  if jq '(.. | objects | select(.provider? == "web-advisor-provider") | .provider) = "web-advisor-provider"' "$MODEL_POLICY_FILE" > "$_model_policy_view.$$" \
    && chmod 600 "$_model_policy_view.$$" && mv -f "$_model_policy_view.$$" "$_model_policy_view"; then
    MODEL_POLICY_FILE="$_model_policy_view"
  else
    rm -f "$_model_policy_view.$$"
  fi
  unset _model_policy_view
fi

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.d/model-policy.sh"
# shellcheck source=./dispatch-load-guard.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/dispatch-load-guard.sh"
# Read-only policy probes set this before sourcing so library initialization
# cannot seed or migrate the host file before model_policy source-check runs.
if [[ "${MODEL_POLICY_SOURCE_CHECK_ONLY:-0}" != 1 ]]; then
  if ! model_policy identity work >/dev/null; then
    echo "lib.sh: model policy cannot resolve the work role" >&2
    return 1 2>/dev/null || exit 1
  fi
  for _model_policy_override in AGENT_MODEL ${!AGENT_MODEL_@}; do
    [ -n "${!_model_policy_override:-}" ] || continue
    model_policy_require_role_identity work "${!_model_policy_override}" || {
      echo "lib.sh: $_model_policy_override does not match the policy work role" >&2
      return 1 2>/dev/null || exit 1
    }
  done
  # Role aliases remain optional overrides, validated by the same policy helper.
  AGENT_MODEL="$(model_policy resolve work AGENT_MODEL)"
  AGENT_MODEL_RETRY="$(model_policy resolve work AGENT_MODEL_RETRY)"
  AGENT_MODEL_REVIEW="$(model_policy resolve work AGENT_MODEL_REVIEW)"
  AGENT_MODEL_ADVISOR="$(model_policy resolve work AGENT_MODEL_ADVISOR)"
  AGENT_MODEL_ADVISOR_FLOOR="$(model_policy resolve work AGENT_MODEL_ADVISOR_FLOOR)"
fi

# Cross-provider review (maintainer ruling 2026-10-07, pipeline-node-execution-
# model): the independent review of a diff runs on the model provider that did
# NOT implement it -- a codex implementer is reviewed through the policy's
# zcode review role, a zcode implementer by the codex work role. When the
# other provider is unavailable (quota hold, missing runtime or provider
# config, or a live policy that predates the review role), fall back to the
# implementer's own provider and record .review_provider_fallback in the
# issue state so the bell can see it. Every identity stays policy-resolved;
# these helpers name roles, never models.
ZCODE_PROVIDER_CONFIG_FILE="$HOME/.zcode/v2/provider_config.json"

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.d/implement-gates.sh"

# 2026-09-12: the bot has no GitHub account of its own — every comment posts
# as the maintainer's own authenticated account (see README's "Bot
# account" note). BOT_COMMENT_MARKER is an HTML comment (invisible when
# rendered) appended to every bot comment so issue-pipeline.sh's needs-info
# bounce-back can tell "the bot posted this" from "a human posted this" by
# comment CONTENT, not by comparing the commenter's login to the bot's login
# — those logins are the same account, so a login comparison can never tell
# the maintainer's own genuine reply-as-reporter apart from the bot's own
# comment, and silently never fires on the maintainer's own issues.
BOT_COMMENT_MARKER='<!-- vecta-agent-comment -->'
# Sandbox mode for every pipeline codex call. Maintainer, 2026-10-06: [...]. The sandbox
# also made every run depend on bubblewrap, which vanished with the 2026-10-05 codex reinstall and
# blocked implement for an hour. The implement call still strips GH_TOKEN, and the wrapper pushes.
CODEX_SANDBOX_MODE="${ZF_CODEX_SANDBOX:-danger-full-access}"
CHECKS_BLOCKED_MAX_AGE_SECONDS=21600
_BOT_DISCLAIMER_DEFAULT='> *This was generated by AI during triage.* This comment is posted by the automated the product agent pipeline under the maintainer'"'"'s GitHub account — it is not the maintainer writing personally. '"$BOT_COMMENT_MARKER"
if ! BOT_DISCLAIMER="$(zf_advisor_comment_disclaimer "$_BOT_DISCLAIMER_DEFAULT")"; then
  echo "lib.sh: advisor.json commentDisclaimer must be a non-empty string" >&2
  return 1 2>/dev/null || exit 1
fi
unset _BOT_DISCLAIMER_DEFAULT

# Defect 6, 2026-09-13 (#1094): issue-pipeline.sh's read_needs_info_email_replies()
# relays a reporter's EMAIL reply onto the issue as a comment (see notify.sh).
# That comment gets its own disclaimer-plus-marker, deliberately NOT
# BOT_DISCLAIMER/BOT_COMMENT_MARKER: comment_is_bot() (above) treats
# anything starting with BOT_DISCLAIMER as the pipeline's own comment, and
# this relayed comment is exactly the human answer the needs-info ->
# needs-triage resume (section (a), unmodified) is watching for -- reusing
# the same marker would make it invisible to that check and leave the
# issue stuck on needs-info forever, the identical failure mode
# BOT_COMMENT_MARKER's own comment above describes for quote-replies.
EMAIL_COMMENT_MARKER='<!-- vecta-agent-email-relay -->'

# Shared wording for notify_email()'s "对用户有什么影响" section (see
# notify.sh's build_report_body): every "needs a human" email lands here for
# the identical reason -- nothing has shipped yet -- so this is one string,
# not eleven near-identical ones drifting apart across four files.
NOTIFY_IMPACT_BLOCKED="问题还在，用户暂时看不到变化。"

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.d/guarded-write.sh"

# Either switch set to 1 means dry, and neither silently overrides the other. lib.sh used to assign
# DRY_RUN from AGENT_DRY_RUN alone, so `DRY_RUN=1 run-release.sh N` ran a real production release
# (several times on 2026-10-22). AGENT_DRY_RUN is exported so children that read only it agree.
if [ "${AGENT_DRY_RUN:-0}" = 1 ] || [ "${DRY_RUN:-0}" = 1 ]; then
  DRY_RUN=1
  export AGENT_DRY_RUN=1
else
  DRY_RUN=0
fi

# The full triage state-label vocabulary, shared so run-triage.sh's active
# lifecycle-label invariant and give_up_on_issue()'s cleanup below can never
# drift apart. A successful recut parent is intentionally unlabeled: its
# recut_children record makes it an open umbrella, not active pipeline work.
# needs-triage is not a valid model output (see triage.schema.json)
# but is the real starting label on every issue that reaches triage, so it
# still has to be in the removal set.
# needs-advisor (2026-09-15): the advisor leg's own entry label -- an issue
# enforce_autonomy_gate() refuses lands here now instead of going straight to
# ready-for-human, so run-advisor.sh (the configured advisor pass) gets first
# look. needs-recut: run-recut.sh's entry label, same day -- previously
# ready-for-human was overloaded as both "categorically too big, needs
# splitting" and "a human must decide"; splitting the vocabulary means
# ready-for-human now means only the latter, the one state this pipeline
# never automates past.
# `awaiting-release` is the open state after a successful merge; `released`
# survives alongside `concluded` on a proven production close so GitHub shows
# both terminal outcome and deploy position. Every transition out of either
# still strips both, including reopen recovery.
ALL_STATE_LABELS=(needs-triage needs-info ready-for-agent ready-for-human needs-owner checks-blocked duplicate finish-first wontfix needs-advisor needs-recut awaiting-release awaiting-pipeline-sync awaiting-pipeline-health released concluded)

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.d/issue-state.sh"

# 2026-09-12: same drift risk as ALL_STATE_LABELS, one level up — bug/
# enhancement must also stay exclusive so triage doesn't leave both on an
# issue across a re-triage.
CATEGORY_LABELS=(bug enhancement)

mkdir -p "$STATE_DIR" "$LOG_DIR"
# ADVISOR_LOCKS_DIR: declared far below (Advisor execution locking section)
# alongside the locking primitives that use it, but created here with the
# other shared AGENT_HOME directories -- try_lock_nonblocking() also
# mkdir -p's its own lock file's parent defensively, so this line is not
# load-bearing, just consistent with STATE_DIR/LOG_DIR's own "declared once,
# created once, at source time" convention.
mkdir -p "$AGENT_HOME/locks"

# Every caller (systemd, a bare shell, another wrapper) gets a known cwd, so
# a bare `node scripts/some-check.mjs` (no -C equivalent, it reads process
# cwd) behaves the same regardless of who invoked this script.
cd "$REPO_DIR"

# One row per persisted state; tracker retirement is a reason-gated exit from every state.
# `on-hold -> *` and terminal requeues are narrowed further by reason below.
declare -gA ISSUE_TRANSITION_TABLE=(
  [untracked]="needs-triage needs-info ready-for-agent ready-for-human needs-owner checks-blocked duplicate finish-first wontfix needs-advisor needs-recut awaiting-release awaiting-pipeline-sync awaiting-pipeline-health released concluded on-hold tracker"
  [needs-triage]="needs-triage needs-info ready-for-agent ready-for-human needs-owner checks-blocked duplicate finish-first wontfix needs-advisor needs-recut awaiting-release awaiting-pipeline-sync awaiting-pipeline-health concluded on-hold tracker"
  [needs-info]="needs-info needs-triage ready-for-agent ready-for-human needs-advisor needs-recut checks-blocked concluded on-hold tracker"
  [ready-for-agent]="ready-for-agent needs-triage needs-info ready-for-human needs-owner checks-blocked duplicate finish-first wontfix needs-advisor needs-recut awaiting-release awaiting-pipeline-sync awaiting-pipeline-health concluded on-hold tracker"
  [ready-for-human]="ready-for-human needs-triage needs-info ready-for-agent needs-advisor needs-recut checks-blocked concluded on-hold tracker"
  [needs-owner]="needs-owner needs-advisor ready-for-agent needs-info concluded on-hold tracker"
  [checks-blocked]="checks-blocked ready-for-agent needs-advisor needs-info concluded on-hold tracker"
  [duplicate]="duplicate concluded needs-triage ready-for-agent on-hold tracker"
  [finish-first]="finish-first concluded needs-triage needs-info ready-for-agent awaiting-release on-hold tracker"
  [wontfix]="wontfix concluded needs-triage ready-for-agent on-hold tracker"
  [needs-advisor]="needs-advisor ready-for-agent needs-triage needs-info needs-recut tracker checks-blocked concluded on-hold"
  [needs-recut]="needs-recut ready-for-agent needs-advisor needs-triage needs-info tracker released concluded on-hold"
  [awaiting-release]="awaiting-release released concluded duplicate finish-first wontfix on-hold ready-for-agent tracker"
  [awaiting-pipeline-sync]="awaiting-pipeline-sync ready-for-agent awaiting-pipeline-health concluded on-hold tracker"
  [awaiting-pipeline-health]="awaiting-pipeline-health released ready-for-agent concluded on-hold tracker"
  [released]="released concluded ready-for-agent needs-triage on-hold tracker"
  [concluded]="concluded awaiting-release released needs-triage ready-for-agent needs-info needs-advisor needs-recut duplicate finish-first wontfix on-hold tracker"
  [on-hold]="on-hold needs-triage needs-info ready-for-agent ready-for-human needs-owner checks-blocked duplicate finish-first wontfix needs-advisor needs-recut awaiting-release awaiting-pipeline-sync awaiting-pipeline-health released concluded tracker"
  [tracker]="tracker needs-triage ready-for-agent released concluded on-hold"
)

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.d/holds.sh"

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.d/conclude-run.sh"

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.d/pipeline-system.sh"

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.d/model-calls.sh"

# pause_for_backoff [issue] [call_output] [exit_status] [pause_nonquota=1] [provider=codex] [model] [caller] [log_path] [termination_class] [termination_source] [termination_evidence] [transcript_empty] [stage]
#
# Provider transport failures and quota refusals are not issue failures.
# Keep the model-policy rung, refund the dispatch attempt, and retry later;
# repeated Codex transport failures open the shared provider circuit below.
# Exit 124 remains a local wall-clock timeout. Deterministic configuration
# errors stay blocked until role configuration changes; other failures back off
# only this issue for 60 minutes.
BACKOFF_QUOTA_PROVIDER=""

# gh()/git_fetch_bounded() -- 2026-09-15 incident: `gh issue edit 1204 ...`
# (route_to_advisor(), below) connected and then simply never returned, for
# 2h25m -- not a network failure text `gh` ever printed, a genuine
# indefinite hang. issue-pipeline.sh's own tick lock (LOCK_FILE, `flock -n
# 9`) was held by that one wedged tick the entire time, so every
# subsequent tick hit the NON-blocking `flock -n 9 || exit 0` and exited 0
# -- a successful-looking no-op, not a failure -- so nothing anywhere
# (run-tick.sh's own fail-count/alert machinery included) ever saw this as
# broken. Recovered by hand with `kill -TERM` on the wedged `gh` process.
#
# Every `gh` invocation in every script that sources this file now goes
# through gh() below, which shadows the real binary by name: bash resolves
# a bareword command against defined functions before PATH, so all ~200
# existing `gh <subcommand> ...` call sites across issue-pipeline.sh and
# every run-*.sh wrapper are covered with zero per-call-site edits -- a
# `timeout` prefix hand-added at 200 sites is exactly the kind of N-site
# patch this codebase avoids (see guarded_write() right below for the same
# discipline applied to dry-run safety). `git fetch` has no comparable
# single choke point -- it is one of many git subcommands, most of them
# local and legitimately allowed to take as long as they need (`git
# worktree add`, `git commit`, `git log` are deliberately NOT wrapped
# here, only the one that reaches the network), so its handful of call
# sites (issue-pipeline.sh, run-implement.sh x2, run-release.sh x2, plus
# run-tick.sh, which sources this file only in a child subshell to keep
# its cwd and shared state setup out of the launcher) each call
# git_fetch_bounded() explicitly.
#
# 60s, for both: this box has no recorded telemetry for normal `gh`/`git
# fetch` latency, so the bound is reasoned from shape, not measured from a
# sample. A single round-trip mutation like `gh issue edit` or a small
# `git fetch` against a repo whose main branch moves every few minutes
# normally completes in low single-digit seconds; even a slow proxy hop or
# a `gh`-internal rate-limit retry (gh_failure_is_transient() below
# already expects "HTTP 429") should clear well inside 60s -- an order of
# magnitude of headroom above a healthy call, generous enough that this
# must never fire on a working network, while bounding the failure
# actually observed (a connection that succeeds and then never answers)
# to a fixed, small wait instead of the 2h25m this incident ran. A
# legitimately long-running wait already has its own deadline instead of
# needing a single call's timeout raised to match: the CI/release
# polls in this file poll a SNAPSHOT (`gh pr checks`, never `--watch` --
# checked, nothing in engine uses `--watch` or an equivalent
# self-blocking mode) inside a `while` loop already bounded by
# POLL_INTERVAL_SECONDS and its caller's own deadline, so bounding the
# individual snapshot call only makes one stuck poll iteration fail fast
# instead of freezing the whole wait.
#
# Exit 124 is `timeout`'s own reserved "command was killed after the time
# limit" code -- nothing else in these scripts produces it -- so
# _bounded_call_timed_out() below keys off the exit status directly
# instead of inspecting output text.
GH_CALL_TIMEOUT_SEC="${GH_CALL_TIMEOUT_SEC:-60}"
GIT_FETCH_TIMEOUT_SEC="${GIT_FETCH_TIMEOUT_SEC:-60}"

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.d/transport.sh"

# Every mutating call in issue-pipeline.sh/run-*.sh — gh issue/pr writes,
# `git push`, `gh pr merge`, and (run-release.sh) the ssh/docker compose calls
# that actually touch production — routes through this instead of a
# `--dry-run` check at each call site. With AGENT_DRY_RUN=1 (or a script's own
# --dry-run flag exporting it before sourcing this file) it prints what
# would have run and returns 0 without running it. Native auto-merge is
# refused before dry-run or execution; other commands pass their exit status
# through. This makes "no write
# happened" a property of one function, not of every call site remembering
# to check a flag. Reads (gh issue view, docker inspect, docker compose
# config, ...) never go through this — only things that change state do.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/gh-auto-merge-guard.sh"

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.d/hand-dependency.sh"

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.d/merge-lane.sh"

# Same threshold/window/recency reasoning as detect-label-churn.sh's own
# (former) CHURN_THRESHOLD/WINDOW_HOURS/RECENCY_MINUTES -- one set of knobs
# now, not two, since that detector calls this same function for its own
# periodic scan (see its own header) instead of keeping duplicated logic that can
# drift the way risk-class.mjs's pattern list once did
# (advisor_footprint_risky()'s comment, above).
LOOP_BREAK_THRESHOLD="${LOOP_BREAK_THRESHOLD:-4}"
LOOP_BREAK_WINDOW_HOURS="${LOOP_BREAK_WINDOW_HOURS:-6}"
LOOP_BREAK_RECENCY_MINUTES="${LOOP_BREAK_RECENCY_MINUTES:-90}"
LOOP_ESCALATION_MARKER="<!-- vecta-loop-escalation -->"

# route_to_advisor <n> -- the one write path for sending an issue into a
# NEW advisor episode. issue-pipeline.sh's own advisor-dispatch loop skips
# any issue whose state file `has("advisor_ruled_at")`, on the stated
# assumption that the label is only ever applied once per issue lifetime --
# a human (or a bug) re-applying needs-advisor to something already ruled
# on. That assumption is false: needs-advisor is legitimately re-applied to
# the SAME issue for a genuinely new episode (a second NOT_READY verdict, a
# second P2/L4 hit, a second blast-radius miss, ...), and advisor_ruled_at
# is a single permanent field written once by run-advisor.sh and never
# cleared -- so a second episode's needs-advisor label was silently
# undispatchable forever: not ready-for-agent (implement will not
# redispatch it) and not advisor-eligible (this guard skips it). Zero live
# producers, no poller, no escalation, no email. Measured live 2026-09-15:
# 15 of 21 open needs-advisor issues were stuck this way, one of them
# (#1215) wedging its own open PR's file footprint against two unrelated
# ready-for-agent tickets via open_pr_file_collision. Every call site that
# starts a new advisor episode must clear the stale verdict here, in the
# same write, so line 413's guard only ever catches what it was meant to
# catch: a re-apply that did NOT go through this function.
#
# $2 (remove_label, default ready-for-agent): the label the issue is
# carrying when it climbs to the advisor. Five call sites climb from
# ready-for-agent (run-implement.sh, issue-pipeline.sh's autonomy-gate
# recheck); sweep-parked-backlog.sh climbs from ready-for-human (a ticket
# parked there before the ladder existed, found in flight). Same defect,
# same fix -- a second parameter is cheaper than a second copy of this
# function.
# 2026-09-16 fix (V102's third recurrence): the del() above used to run as a
# bare statement. `state_merge` returns 1 on a real failure (malformed state
# JSON, mktemp/jq trouble) WITHOUT writing -- but a bare call only aborts the
# script via `set -e` when nothing between here and the top of the process is
# an if/while/&&/|| condition. Live proof it is not: run-advisor-batch.sh
# calls this from inside `if apply_one_ruling ...; then`, which disables `-e`
# for everything apply_one_ruling runs, this function included (confirmed by
# direct test -- a `false` deep inside a chain like that never stops the
# script). #1245 wedged this exact way: the clear failed, nothing checked it,
# and the label moved anyway with the stale marker still on disk. Checking
# the return value here does not depend on the caller's own `set -e`
# context, so it closes the bug regardless of how future callers invoke this.
ISSUE_VERDICT_GUARD_REASON=""
ISSUE_VERDICT_GUARD_SKIPPED=0

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.d/route-advisor.sh"

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.d/model-units.sh"

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.d/recut.sh"

# One REST read gives this process the live native child list for each parent.
# GitHub caps native children at 100, matching the endpoint's per-page maximum.
declare -gA NATIVE_PARENT_SUBISSUES_CACHE=()

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.d/release-close.sh"

# The bound every conclude_run "not-completed" refusal is measured against --
# the same give-up-at-4 threshold fail_attempt() (run-implement.sh) already
# enforces everywhere else; not re-derived, just named once here so both
# sides read the identical number.
CONCLUDE_RUN_ATTEMPT_CAP=4

# --- blind-rerun gate (2026-10-08) -------------------------------------------
# Issue 2695 ran implement four times (~440k tokens each) to the same
# BLOCKED-CHECKS network timeout, and 2731 four times to the same lesson
# delivery refusal; the repeat-dispatch bell rang at run 2 and nothing stopped
# runs 3 and 4. A ticket whose last two implement failures share a stage and a
# failure class is not dispatched again until an input changed: a main commit
# touching the failing area or the run environment, a non-pipeline issue
# comment, a supervisor hold release, or a newer env file. Otherwise it is
# parked once (one inbox line, one comment) with the decisive reason.
BLIND_RERUN_ENV_PATHS="${ZF_BLIND_RERUN_ENV_PATHS:-engine/dispatch-codex.sh engine/test-env.sh engine/night/dispatch.sh}"

# is_on_hold <n> -- true (0) if #n carries the on-hold label OR the read
# itself failed. 2026-09-16 fix: this used to be `gh ... 2>/dev/null |
# grep -qx on-hold`, which throws away gh's own exit status inside the
# pipe -- a transient gh failure (network, rate limit, auth) produces the
# exact same empty stdout as "this issue genuinely has no labels", so
# `grep -qx` returned 1 (not on-hold) either way, and every caller took
# the permissive branch on an unreadable fact. Every caller of this
# function (issue-pipeline.sh's candidate-selection loops, run-advisor-
# batch.sh, run-recut.sh, sweep-acceptor-backlog.sh, sweep-parked-
# backlog.sh, this file's own sweep_reopened_issues()) uses the SAME
# direction -- true blocks the action -- so a read failure can safely fail
# closed the same way here: unknown must never look like "confirmed not on
# hold". See lessons/RULES.md's "unreadable fact treated as a permissive
# answer" entry.
declare -gA ISSUE_LABEL_SNAPSHOT_STATE=()
declare -gA ISSUE_LABEL_SNAPSHOT_IDS=()
declare -gA ISSUE_LABEL_SNAPSHOT_AT=()
declare -gA ISSUE_LABEL_VIEW_STATE=()
declare -gA ISSUE_LABEL_VIEW_LABELS=()
declare -gA ISSUE_LABEL_VIEW_AT=()
declare -gA ISSUE_LABEL_VIEW_ERROR=()
ISSUE_LABEL_BULK_QUERY_COUNT=0
ISSUE_LABEL_POINT_QUERY_COUNT=0

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.d/sweeps.sh"

# Founder-authored product issues are test/demo work unless pipeline evidence
# says a script created them. The bot uses the maintainer's GitHub account, so
# author alone is not enough to classify its generated issues.
MAINTAINER_TEST_CANDIDATE_FILTER='
    (((.author.login // .user.login // "") | ascii_downcase) == ($maintainer | ascii_downcase))
    and (($maintainer | length) > 0)
    and (([.labels[]?.name] | any(. == "pipeline-system" or . == "supervisor-created")) | not)
    and (((.title // "") | ascii_downcase | test("^(\\[recut\\]|\\[prerequisite\\]|\\[supervisor\\]|recut:|prerequisite:|pipeline brief:)")) | not)
    and ((.title // "") | contains("concluded-root-prerequisite-") | not)
    and ((.body // "") | contains($bot_marker) | not)
    and ((.body // "") | contains($recut_marker) | not)
    and ((.body // "") | contains("本票是流水线把 #") | not)
    and ((.body // "") | contains("这张票范围太大，流水线拆成了") | not)
    and ([.comments[]?.body // ""] | all(contains($bot_marker) | not))
'

MAINTAINER_TEST_LABEL_READY=0

# --- 批次 STATE（#4363）-------------------------------------------------------
# 每批工作的父票正文带一段机器可读 STATE（完成标准、关键路径、各 ticket 的延迟成本
# 等级），格式见 docs/agents/issue-pipeline.md「批次 STATE 与延迟成本排序」。队列排序
# 只认标签（生产事故 > 关键路径 > 功能 > 遗留）；本 sweep 周期性把 STATE 同步成
# critical-path / legacy 标签，选择站点因此不需要额外读父票。STATE 没列到的票不动。
BATCH_STATE_SWEEP_SECONDS="${BATCH_STATE_SWEEP_SECONDS:-3600}"
DELAY_COST_LABEL_READY=0

# Why reconcile_blocking_issue_root last failed: one line the blocker-root
# sweep copies into its supervisor-inbox alert. Set at the deepest point that
# knows why; a callee's reason outranks its caller's (set-if-empty), so the
# sweep never blames a phase for a failure one level deeper already explained.
# Empty while a reconcile succeeds, so only the sweep's failure branch reads it.
BLOCKER_ROOT_FAIL_REASON=""

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.d/blockers.sh"

# Refresh only after a mutation: recut-parent edges may expose a concluded
# child that was not a blocker when the first snapshot was taken.
# The sweep is recovery, not latency-critical: at ~1.5s per root it took 300-530s per tick from
# 2026-10-04 12:35Z and starved implement for 8 hours. It stops at its budget and resumes after the last
# root it reconciled on the next tick, so every root is still visited.
BLOCKER_ROOT_SWEEP_BUDGET_SECONDS="${BLOCKER_ROOT_SWEEP_BUDGET_SECONDS:-150}"

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.d/selection-scope.sh"

# Repo-rooted path mentions, one pattern for the structured-section scan and
# the whole-text fallback that free-form brief notes need (#4722).
ISSUE_BODY_PATH_REGEX='(\.github/workflows|\.agents|\.claude|lessons|packages|apps|scripts|engine|docs|infra|deploy|templates|migrations)/[[:alnum:]_.-]+(/[[:alnum:]_.-]+)*|Dockerfile([.][[:alnum:]_-]+)?|package\.json|pnpm-lock\.yaml|pnpm-workspace\.yaml|package-lock\.json'

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.d/dispatch-gates.sh"

# Open blockers labeled awaiting-release or released are clear for implement;
# every other open blocker still blocks.
MERGED_BLOCKER_LABELS=(awaiting-release released)

OPEN_BLOCKER_SNAPSHOT_ACTIVE=0
declare -gA OPEN_BLOCKER_SNAPSHOT_STATE=()
declare -gA OPEN_BLOCKER_SNAPSHOT_IDS=()

PROSE_BLOCKER_SNAPSHOT_ACTIVE=0
declare -gA PROSE_BLOCKER_VIEW_CACHE=()

# --- the ladder: provenance, rungs, guarded admission ----------------------
# 2026-09-15 maintainer ruling: high-risk work may proceed through the configured
# review and advisor path instead of being stopped at admission.
# enforce_autonomy_gate() above stays exactly what it is -- a pure admission
# predicate for the STANDARD rung -- but a refusal is no longer an outcome.
# The rungs, each entered only when the one below cannot admit:
#   0 standard  P0/P1 with L0/L1 (L2 at phase 3): work implements and reviews.
#               risk-class.mjs + gate 4 + CI + head-SHA pin.
#   1 advisor   any refusal or judgment call: advisor re-measures impact on a
#               fresh index against the symbols actually modified, corrects
#               the classification or rules on the engineering question.
#   2 recut     categorically oversized (P2, or L3/L4) or a durable-write
#               footprint: split on the write/read boundary into children
#               that each climb from rung 0 on their own merits.
#   3 guarded   cannot be split (recut refused, or the advisor judged every
#               piece still needs the risky part): admit_guarded() below --
#               policy-resolved implementation + independent review, merge conditions
#               (counter-example tests, untouched functions) carried in the
#               brief for both to enforce.
# The honest terminal is not a rung: a ticket that exhausts rung 3's four
# attempts reaches needs-owner via give_up_on_issue() with a REPORT of what
# every rung measured -- not a question. ready-for-human is reserved for
# the advisor's own `maintainer` verdict (a product/business fact only the
# maintainer holds) and nothing else in this pipeline applies it for risk.

# What a `/to-tickets` ticket looks like on the wire, so the pipeline can
# tell it from a raw bug report without a new label or a schema change.
# The manifest-managed to-tickets skill (.agents/skills/to-tickets/SKILL.md,
# issue-template) writes `## What to build`; the issue form
# (.github/ISSUE_TEMPLATE/bug-report.yml) never does. run-recut.sh's own
# children ALSO carry `## What to build` (prompts/recut.md), and those are
# deliberately born needs-triage for a fresh measurement -- so recut stamps
# every child with RECUT_CHILD_MARKER (its `## Parent` sentence) and the
# predicate excludes it. Measured against #1193-#1208 (18 tickets the
# maintainer cut on 2026-09-15): every body has the heading; every raw report
# on the tracker lacks it.
RECUT_CHILD_MARKER="会走正常的分诊流程判定风险等级和处理方式"

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.d/briefs.sh"

# strip_brief_banner <text> -- shared by guarded_brief() and
# advisor_superseded_brief() below (V112/V113/V116, lessons/RULES.md).
# Both functions prepend a banner ("current truth" + a "\n---\n\n" separator)
# in front of whatever brief_md they are handed. Called again on the SAME
# ticket -- a second guarded episode, a second misclassification correction,
# or one of each -- the old code prepended onto whatever was already there,
# so every call stacked another full banner without ever removing the
# previous one. Two real tickets (#1204, #1206) accumulated 31 and 29
# stacked banners this way, brief_md growing from a normal 5-8K to
# 65-68K/47-49K bytes and eventually overrunning state_merge's own
# argv-size fix (state_merge()'s own 2026-09-15 comment, above).
#
# Detection: both banner texts are hardcoded literals that always begin with
# one of these two prefixes and always end in the same "\n---\n\n" separator
# immediately before the nested content -- these are the ONLY two producers
# of a brief_md prepend in this codebase (grep 'guarded_brief\|advisor_
# superseded_brief' confirms it). If $1 starts with either prefix, it
# already carries a banner (of either kind -- a ticket can legitimately go
# guarded once, get corrected once, then go guarded again, so this strips
# EITHER, not just the caller's own). If $1 does NOT start with either
# prefix, it has no banner yet (first admission ever, or genuinely original
# brief_md) and is returned unchanged -- this branch is required, not an
# optimization: unconditionally stripping through some "---" would silently
# truncate an ordinary brief whose own prose happens to contain a markdown
# horizontal rule, discarding a real ruling instead of a stale one.
#
# 2026-09-16 correction: the first version of this function used bash's
# `${var##*pattern}` (greedy prefix strip -- jump straight to the LAST
# occurrence of the separator ANYWHERE in the string) to unwrap however many
# layers had accumulated in one pass. That is wrong whenever the TRUE
# original content beneath the banner(s) itself contains a "\n---\n\n" --
# an ordinary markdown horizontal rule, which real triage briefs do use --
# because the last occurrence in the whole string is then inside the real
# content, not at the true outermost boundary, and greedy-stripping through
# it discards real brief text along with the banner. Caught live backfilling
# #1202 (6 genuinely stacked banners): the greedy version cut its 2,762-byte
# original core down to 1,270 bytes, silently eating real content, because
# the core itself contains one more "---" of its own. Fixed by walking
# forward one layer at a time instead of jumping to the last separator:
# peel with the NON-greedy `${var#*pattern}` (first occurrence) and re-check
# the prefix after each peel, stopping the instant what remains is not
# itself banner-prefixed -- so the walk only ever consumes text that is
# actually a banner layer, never a coincidental "---" sitting in real
# content past the last real banner. Re-verified against #1204/#1206 (still
# 6,276/4,206 bytes) and #1202 (now correctly 2,762 bytes, not 1,270).
GUARDED_BANNER_PREFIX='**这张票按「加强看护」'
SUPERSEDED_BANNER_PREFIX='**顾问已改判'

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.d/advisor-batch.sh"

# One batch job belongs to the advisor queue, not to any one issue. Keep its
# job id, member snapshots, and byte-budget deferrals in one atomic local
# record so a later tick can poll exactly the job it started. Per-issue state
# deliberately keeps only normal pending verdicts: run-advisor.sh must never
# mistake a batch NDJSON response for its one-ticket JSON job.
ADVISOR_BATCH_STATE_FILE="${ADVISOR_BATCH_STATE_FILE:-$AGENT_HOME/advisor-batch.json}"

# --- systemic environmental faults: ledger, quarantine, probe, canary --------
# 2026-09-15. The implement leg now classifies a test-gate failure whose
# OUTPUT is environmental (no Docker, connection refused, a missing binary)
# as not-the-diff's-fault and stops charging the ticket an attempt -- with a
# per-ISSUE cap. That granularity is wrong for the failure it was built for:
# tonight's two faults (no Docker, no git author identity) hit every ticket
# that reached the relevant step, so per-issue counters would have had each
# ticket independently burn its strikes and independently give up, in
# parallel, and nothing would have noticed one cause was destroying the
# whole queue. A human watched and hand-held eight tickets -- the exact
# intervention this pipeline exists to remove. Model failures now use
# provider holds for quota and issue-scoped backoff otherwise; environmental
# faults need their own shared ledger and quarantine.
#
# The shape chosen, and why not a broad pause:
#   1. LEDGER  record_env_fault() -- every wrapper that proves a failure was
#      environmental appends one line, keyed by a SIGNATURE (what broke,
#      e.g. env:git-identity, env:test-gate:docker) and a SCOPE (which
#      class of ticket it hits: a stage, or a stage plus one package
#      directory). No issue counter: the ledger is the counter.
#   2. DETECT  env_fault_is_systemic() -- the same signature from >=2
#      distinct issues, or >=3 hits, inside an hour. Pure over the file.
#   3. QUARANTINE the SCOPE, never the pipeline. issue-pipeline.sh stops
#      dispatching only that stage (or only tickets whose expected_packages
#      touch that package); triage, advisor, recut keep preparing the
#      backlog. This is what "quarantine the affected class" means here: a
#      package whose integration tests need Docker does not stop a
#      docs-only ticket in another package.
#   4. REPAIR  env_fault_repair() -- the most dangerous rung, so the
#      tightest bound: an explicit allowlist of signatures whose fix is
#      DERIVABLE by the machine without a secret or a human value, run at
#      most once per quarantine, only appending never overwriting, and
#      immediately re-probed. Exactly one entry today (git identity from
#      the authenticated GitHub account, GitHub's own noreply form, written
#      to the EnvironmentFile outside version control). Docker cannot be
#      installed by this pipeline and has no entry.
#   5. WAKE-UP has a defined exit, always -- the PAUSE lesson (a pause with
#      no defined exit is the slow version of parking): a signature with a
#      known PROBE lifts the moment the probe passes; every signature also
#      gets a CANARY -- one dispatch allowed through after 15 minutes,
#      doubling to a 4-hour cap -- and a canary that is not followed by a
#      new fault line within a grace period lifts the quarantine.
#   6. RECORD  quarantine and canary state locally. HEALTH and the env-fault
#      ledger carry the current status; automatic probes lift it on recovery.
# Attempts: issue-pipeline.sh bumps `.attempts` at implement dispatch. An
# environmental fault normally must not be charged (lessons/RULES.md V79),
# so record_env_fault() refunds that bump for stage=implement by default.
# A real wall-clock timeout passes refund_attempt=0: model work really ran.
ENV_FAULT_DIR="$AGENT_HOME/env-faults"
QUARANTINE_DIR="$AGENT_HOME/quarantine"
ENV_FAULT_WINDOW_SECONDS=$((60 * 60))
ENV_FAULT_SYSTEMIC_DISTINCT_ISSUES=2
ENV_FAULT_SYSTEMIC_TOTAL_HITS=3
QUARANTINE_CANARY_INITIAL_SECONDS=$((15 * 60))
QUARANTINE_CANARY_MAX_SECONDS=$((4 * 60 * 60))
QUARANTINE_CANARY_GRACE_SECONDS=$((30 * 60))
QUARANTINE_NOTIFICATION_WINDOW_SECONDS="${QUARANTINE_NOTIFICATION_WINDOW_SECONDS:-3600}"
QUARANTINE_NOTIFICATION_DIR="$AGENT_HOME/quarantine-notifications"

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.d/quarantine.sh"

CODEX_CONFIG_PROBE_OUTPUT=""
CODEX_CONFIG_PROBE_STATUS=0

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.d/main-red.sh"

# Every dispatched role records spend after its call. The ledger is reporting
# only; policy, not spend data, controls identity and escalation.

SPEND_DIR="$AGENT_HOME/spend"
CODEX_PROBE_MARKER="$AGENT_HOME/codex-probe-passed"

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.d/spend-budget.sh"

# issue_spend_budget_status <issue> [now] -> clear|over|unknown<TAB>calls<TAB>tokens.
# The sixth ledger field is a floor when older producers left it empty. Batch
# rows count once for every member issue because each member paid for that call.
ISSUE_CALL_BUDGET_THRESHOLD="${ISSUE_CALL_BUDGET_THRESHOLD:-10}"
ISSUE_TOKEN_BUDGET_THRESHOLD="${ISSUE_TOKEN_BUDGET_THRESHOLD:-2200000}"

ISSUE_SPEND_BUDGET_MARKER='<!-- vecta-issue-spend-budget-routed'

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.d/codex-budget.sh"

# Codex quota is shared across work and production model roles. Keep work
# below the production-only reserve; active launches reserve their existing
# per-issue token ceiling so concurrent hand dispatch cannot spend the same
# remaining allowance repeatedly.
# 2026-10-11: the first default (8M/day, each hand reserving the whole 6M work share) refused every hand
# dispatch once real use reached 32M by noon with no provider hold. The provider quota hold is the hard cap
# (maintainer 2026-09-25: quota ample, concurrency by memory); this budget only keeps the production reserve.
CODEX_DAILY_TOKEN_BUDGET="${CODEX_DAILY_TOKEN_BUDGET:-200000000}"
CODEX_PRODUCTION_TOKEN_RESERVE="${CODEX_PRODUCTION_TOKEN_RESERVE:-20000000}"
CODEX_BUDGET_RESERVATION_TOKENS="${CODEX_BUDGET_RESERVATION_TOKENS:-2200000}"
CODEX_PRODUCTION_RESERVATION_TOKENS="${CODEX_PRODUCTION_RESERVATION_TOKENS:-1000000}"
CODEX_HAND_DISPATCH_RESERVATION_TOKENS="${CODEX_HAND_DISPATCH_RESERVATION_TOKENS:-6000000}"
CODEX_BUDGET_DIR="$AGENT_HOME/codex-budget"
CODEX_BUDGET_RESERVATIONS_FILE="$CODEX_BUDGET_DIR/reservations.tsv"

# The advisor role uses the configured web session. Failures follow the
# persisted transition policy; there is no model-switch fallback.
#
# The advisor's transport (config variables, the sync/async call machinery,
# health checks, fault classification) is an optional provider module,
# sourced only when present. This distribution ships none.
_AGENT_WEB_ADVISOR_PROVIDER="$_AGENT_LIB_DIR/providers/web-advisor-provider.sh"
[[ -r "$_AGENT_WEB_ADVISOR_PROVIDER" ]] && source "$_AGENT_WEB_ADVISOR_PROVIDER"
if ! declare -F web_advisor_provider_usable >/dev/null; then
  # No provider module is installed (a distribution dropped
  # providers/web-advisor-provider.sh). Every entry point the pipeline calls fails closed
  # instead of dying on "command not found", which under set -e would kill
  # the whole tick: nothing is dispatched or polled, model calls report an
  # unsupported provider (exit 64, which callers already classify as a
  # configuration fault through pause_for_backoff), and the dispatch gate
  # records one env fault.
  WEB_ADVISOR_PROVIDER_JOB_DIR="$AGENT_HOME/web-advisor-provider-jobs"
  WEB_ADVISOR_PROVIDER_JOB_TIMEOUT_SECONDS=0
  web_advisor_provider_unavailable() { echo "web-advisor-provider advisor provider is not installed" >&2; return 64; }
  web_advisor_provider_job_ids() { :; }
  web_advisor_provider_job_candidates() { :; }
  reconcile_stale_web_advisor_provider_jobs() { :; }
  web_advisor_provider_per_ticket_topic() { :; }
  web_advisor_provider_clear_job_state() {
    state_merge "$1" 'del(.web_advisor_provider_job_id, .web_advisor_provider_job_started_at, .web_advisor_provider_job_episode_seq)'
  }
  web_advisor_provider_usable() { return 1; }
  web_advisor_provider_env_fault_probe() { return 2; }
  web_advisor_provider_env_fault_repair() { return 1; }
  record_web_advisor_provider_fault() {
    record_env_fault env:web-advisor-provider:not-installed advisor "$1" "$2" "" "${3:-}"
  }
  web_advisor_provider_dispatch_allowed() {
    stage_dispatch_allowed advisor "[]" "${1:-$(date +%s)}" || return 1
    record_web_advisor_provider_fault 0 "no web-advisor-provider advisor provider is installed; advisor dispatch refused"
    return 1
  }
  web_advisor_provider_dispatch_async() { web_advisor_provider_unavailable; }
  web_advisor_provider_dispatch_ndjson_async() { web_advisor_provider_unavailable; }
  web_advisor_provider_normalize_batch_json() { web_advisor_provider_unavailable; }
  run_web_advisor_provider_ndjson() { web_advisor_provider_unavailable; }
  # Status 2 is "still running": a leftover job marker ages out through
  # run-advisor.sh's ceiling branch (env fault, marker cleared).
  web_advisor_provider_poll() { return 2; }
  run_web_advisor_provider_json() {
    jq -nc '{is_error: true, subtype: "unsupported_model_provider", result: "web-advisor-provider advisor provider is not installed"}'
    return 64
  }
fi

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.d/ci-checks.sh"

# 2026-09-12 defect 2: run-implement.sh's CI poll treated any check with
# bucket=="skipping" as a failure. Every PR in this repo always carries
# `skipping` rows, because ci.yml's push-triggered and pull_request-triggered
# workflow runs each skip the other's jobs (GitHub still reports both run's
# rows on the PR) — measured live on PR #1099: pass:5, skipping:7, fail:0,
# cancel:0, which the old `bucket=="skipping"` check classified `fail`,
# meaning no agent PR could ever merge. Dropping `skipping` from the failure
# condition outright would open a real hole instead: ci.yml:378's
# pr-touched-packages job (and the repo's four other PR-gate jobs) each carry
# an `if:` condition, and a bad edit there that makes a job skip on every PR
# would then sail through unnoticed.
#
# REQUIRED_PR_CHECKS pins the aggregate gates (alls-green rows, #4484); a future rename
# without updating the definition still fails CLOSED.
if [[ -z "${REQUIRED_PR_CHECKS_FILE:-}" ]]; then
  REQUIRED_PR_CHECKS_FILE="$(zf_config_file mac-autopilot/required-pr-checks.json)" \
    || REQUIRED_PR_CHECKS_FILE="$_AGENT_LIB_DIR/mac-autopilot/required-pr-checks.json"
fi
REQUIRED_PR_CHECKS=("required-pr-checks.json unreadable")
if _agent_required_pr_checks="$(jq -ce '
  select((.required | type) == "array" and (.required | length) > 0)
' "$REQUIRED_PR_CHECKS_FILE" 2>/dev/null)"; then
  mapfile -t REQUIRED_PR_CHECKS < <(jq -r '.required[]' <<< "$_agent_required_pr_checks")
fi
unset _agent_required_pr_checks _AGENT_LIB_DIR

# Does any currently OPEN agent/issue-* PR's actual changed files overlap $1
# (selection scope: optional exact paths or normalized packages, JSON array)?
# $2 is the raw `gh pr list ... -q '.[] |
# select(...)'` stream (multiple JSON objects, not one array — jq handles
# that as separate inputs either way) already computed once per tick. This
# is the one window stage_unit_active() can't see: a wrapper that already
# exited, leaving its PR open.
# 2026-09-12 bug this replaces: `grep -qF "$pkg"` was a raw substring match,
# so an expected_packages entry of "packages/example-service" collided with an
# unrelated PR touching "packages/example-service-admin/...". Use the
# selection scope's exact prefix rule instead of grepping for a substring.
OPEN_PR_FILE_COLLISION_CACHE_SOURCE=""
OPEN_PR_FILE_COLLISION_CACHE_JSON='[]'
OPEN_PR_FILE_COLLISION_CACHE_READY=0
OPEN_PR_FILE_COLLISION_CACHE_COMPLETE=0

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.d/open-pr-collision.sh"

# 2026-09-12 defect 4: run-implement.sh's merge-queue wait used to poll
# `node scripts/branch-delivery-preflight.mjs --mode release` (which calls
# verify-branch-promotion-evidence.mjs) as its "is main green" circuit
# breaker. Measured two independent reasons that predicate can never pass
# under the systemd unit's own environment (engine/systemd/
# zenoforge-agent.service's EnvironmentFile + proxy vars, not just an interactive
# shell):
#   1. Node's global `fetch` ignores HTTP(S)_PROXY entirely (a known Node
#      limitation; fixed only by the experimental NODE_USE_ENV_PROXY=1). This
#      box has no direct outbound path — confirmed live under the exact env
#      the unit sets: `fetch('https://api.github.com/')` throws
#      "TypeError: fetch failed" without NODE_USE_ENV_PROXY=1, returns 200
#      with it.
#   2. Even with that fixed, verify-branch-promotion-evidence.mjs requires a
#      workflow run for the EXACT current `origin/main` SHA. GitHub never
#      creates a workflow run at all for a `[skip ci]` commit (its own
#      native push/pull_request skip, not something ci.yml configures) — and
#      this repo's dev-system fast lane (CONTRIBUTING.md) means 22 of the
#      last 30 commits on main carry `[skip ci]`. Confirmed live:
#      `gh api repos/$REPO/actions/runs?head_sha=<a [skip ci] HEAD>` returns
#      zero runs, vs one for the last non-skip-ci commit. An exact-SHA check
#      structurally can never see evidence for those SHAs.
#
# main_merge_clear() asks the optimistic merge question: is there a completed,
# non-cancelled PUSH-triggered ci.yml failure on `main`? A pending tip does not
# erase the last completed verdict, and no completed verdict leaves the gate
# open. A `[skip ci]` commit produces no run, so the last real push remains
# authoritative until a later verdict arrives. It uses `gh api`, not node's
# fetch: gh is already proxy-env-aware under the systemd unit environment.
#
# Deliberately does NOT touch scripts/verify-branch-promotion-evidence.mjs or
# scripts/branch-delivery-preflight.mjs: run-release.sh's own `--mode
# release` call gates an actual production deploy, where "evidence for the
# EXACT SHA being shipped" is a stricter and correctly different bar than
# "has main produced a completed red verdict" — the question this merge
# gate exists to answer. The two predicates diverge on purpose.
#
# --- The main-red bisect state machine (#4356, #4477) -----------------------
#
# One bounded step per tick (issue-pipeline.sh's maintenance runs this). The
# states, and what advances them:
#
#   rerun-requested  session opened; the red run's failed jobs were rerun
#                    once through `gh run rerun --failed` in its source
#                    workflow. When that run
#                    re-completes green the red is FLAKY (recorded, terminal,
#                    no revert); when it re-completes red, the window is
#                    deterministic and the bisect starts.
#   bisecting       midpoint probes of (last_green..red]: reuse any existing
#                    completed verdict from the source workflow for that SHA,
#                    otherwise dispatch that workflow on a train/bisect-* ref.
#                    ci.yml receives source_sha for its Postsubmit probe;
#                    pipeline-suites.yml runs the suite on the train ref.
#                    Green midpoint moves the green bound up,
#                    red midpoint moves the red bound down; a one-commit
#                    window names the culprit.
#   culprit-found   the culprit's direct landing request (one unique owner)
#                    or its `fix(#N):` subject names the ticket. Ambiguous
#                    ownership or an un-revertable commit -> unattributed.
#   revert-open     direct-main landings receive an exact git-revert commit
#                    through a fast-forward compare-and-swap; conflicts go to
#                    supervisor arbitration. PR landings use the dedicated
#                    `agent/revert-main-<issue>-<sha12>` PR through
#                    sweep-merges.sh. A Postsubmit red keeps ordinary merges
#                    held until a later Postsubmit verdict is green; a
#                    suites-only red does not change that gate.
#   reverted        the direct revert landed or the revert PR merged; the
#                    existing Postsubmit merge gate still owns ordinary merge
#                    admission.
#   flaky           terminal record of a red that reran green.
#   unattributed    terminal: no culprit could be named. A Postsubmit red
#                   stays behind its merge gate; every unattributed red sends
#                   one supervisor event for human follow-up.
MAIN_RED_PROBE_DISPATCH_ATTEMPTS=2
MAIN_RED_PROBE_RETRY_DELAY_SECONDS=600
MAIN_RED_REVERT_ATTEMPTS=3

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.d/main-red-bisect.sh"

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.d/fix-forward.sh"

# 2026-09-13 fix: a real race, not a residual risk — the merge-queue wait
# once polled for a green main and then called `gh pr merge` with nothing
# holding the two steps together, so two concurrent runs could both merge
# off the same stale green. The mutex closed that.
#
# 2026-10-28 (#4356, optimistic merging): the mutex no longer has a CI wait
# to protect. It surrounds only the `gh pr merge` API call in
# merge_pr_and_reconcile(); every gate read and other mutation runs outside
# it. A red main blocks ordinary merges until the revert's Postsubmit is
# green; sweep-merges.sh admits only the matching revert PR while red.
# guarded_pr_merge() still pins the exact head and treats an already-merged
# PR as done.
#
# 2026-09-12 review, item 2: this used to block with plain `flock 8` (no
# -w), same "hung stage holds its cap slot forever" shape as the other four
# gaps in the same review — a run stuck waiting here forever (the other
# holder itself wedged, e.g. mid `gh pr merge` hang) pins an implement slot
# permanently, and nothing pages anyone.
# MERGE_LOCK_WAIT_SECONDS bounds it instead: 70 minutes, comfortably above
# the worst observed legitimate hold (a `gh` call wedged behind the proxy
# for 14+ minutes, ci.yml's own record), so a timeout here really does mean
# "wedged," not "still working." A timed-out wait is a normal outcome, not a
# crash — callers treat it like any other merge-gate refusal, not a bare
# non-zero exit under `set -e`.
#
# acquire_merge_lock() blocks (bounded by $2/MERGE_LOCK_WAIT_SECONDS) until
# it gets fd 8 on $MERGE_LOCK_FILE (or $1, for lib.test.sh to point at a
# throwaway file instead) — fd 8 specifically so it can never collide with
# issue-pipeline.sh's own fd 9 tick-decision lock even if somehow held in
# the same process (they never are; different processes entirely, but a
# fixed, distinct fd per lock is the same discipline that lock already
# uses). Released explicitly by release_merge_lock() immediately after the
# merge API call — and released anyway, automatically, if the holding
# process dies before calling it, because closing an fd releases its flock;
# the OS does this on any process exit, `set -e` included, so there is no
# code path that can leak this lock forever the way a hand-rolled "touch a
# marker file" lock could.
MERGE_LOCK_WAIT_SECONDS=$((70 * 60))

# GitNexus' index is shared by triage and advisor units. One dedicated checkout
# is indexed per AGENT_HOME, so keep both the mutex and refresh markers there.
# Refresh at most once per 30 minutes; analysis runs on cihost so WSL only needs
# the standing 3 GiB safety floor. Only the units that read
# the graph (triage/advisor) refresh it. The scheduler never drains implement
# or hand dispatch for it: on 2026-10-08 that drain paused implement 30 min
# per stale cycle while its own in-tick refresh failed every time.
GITNEXUS_REFRESH_LOCK_WAIT_SECONDS=20
GITNEXUS_REFRESH_MIN_INTERVAL_SECONDS=$((30 * 60))
TRIAGE_FRESHNESS_MAX_DEFER_SECONDS="${TRIAGE_FRESHNESS_MAX_DEFER_SECONDS:-$((2 * 60 * 60))}"

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.d/gitnexus.sh"

# A target may provide its own release gate module; otherwise migration settings
# select the generic engine module and legacy pack gates remain available during migration.
if _ZF_MIGRATION_GATE_FILE="$(zf_migration_gate_file)"; then
  source "$_ZF_MIGRATION_GATE_FILE"
else
  _zf_gate_status=$?
  if [[ $_zf_gate_status -ne 1 ]]; then
    echo "lib.sh: could not resolve configured migration gate" >&2
    return "$_zf_gate_status"
  fi
fi

# 2026-09-12 review, item 4: notify.sh's send_email() returns 0 on every
# failure BY DESIGN (a notification must never fail the pipeline run it's
# reporting on) — which also means a permanently broken alert channel is
# indistinguishable from a quiet week with nothing to report. The
# Application Default Credentials notify.sh mints tokens from are an
# `authorized_user` refresh token from an OAuth client whose consent screen
# may still be in "Testing" mode, in which case that refresh token expires
# after 7 days with no warning anywhere in this pipeline. One heartbeat a
# day makes silence itself the alert.
CODEX_EXHAUSTED_MARKER_FILE="$AGENT_HOME/codex-exhausted-until"
CODEX_PROVIDER_FAILURE_THRESHOLD=3
CODEX_PROVIDER_FAILURE_WINDOW_SECONDS=900
CODEX_PROVIDER_BACKOFF_SECONDS=90
CODEX_PROVIDER_FAILURE_EVENTS_FILE="$AGENT_HOME/codex-provider-outage-events.log"
CODEX_PROVIDER_PROBE_REQUIRED_FILE="$CODEX_EXHAUSTED_MARKER_FILE.probe-required"
CODEX_PROVIDER_PROBE_NOTICE_FILE="$CODEX_EXHAUSTED_MARKER_FILE.probe-notice-sent"
# Each provider's quota marker is independent, so recovery in one provider
# cannot clear another provider's active hold.
WEB_ADVISOR_PROVIDER_EXHAUSTED_MARKER_FILE="$AGENT_HOME/web-advisor-provider-exhausted-until"
ZCODE_EXHAUSTED_MARKER_FILE="$AGENT_HOME/zcode-exhausted-until"
# Provider-wide quota holds are recorded separately from issue-local model
# failures, so an account outage does not consume an issue's attempts.
#
# The damage was not the refusal, it was the bookkeeping. issue-pipeline.sh
# bumps a ticket's attempt counter at DISPATCH time, and the quota branches
# in run-implement.sh/run-advisor.sh only suppressed the backoff pause, not
# the attempt, for whichever provider they already recognized. So a refusal
# that the ticket had nothing to do with still spent one of its four
# attempts, and at four the ticket concludes `not-completed` and leaves an
# issue comment saying the pipeline could not do the work.
#
# So: record the outage, and refuse to dispatch that provider's work into it
# rather than spending attempts discovering it one ticket at a time. The
# marker is a deadline in epoch seconds; an absent, empty or non-numeric
# file means "not exhausted" (fail OPEN here on purpose -- the cost of a
# wrong "not exhausted" is one wasted dispatch, while a wrong "exhausted"
# would idle that provider's whole leg on a corrupt file).
PREMIUM_QUOTA_BACKOFF_SECONDS=$((60 * 30))

# Ticks with free implement capacity and ready work but no dispatch before
# HEALTH calls the stage STUCK. Measured 2026-10-01..08: healthy ticks run
# 14-18 min apart and every no-dispatch run of 3+ ticks was this starvation
# class (budget-exhausted, 2026-10-04 and 2026-10-08), so 3 ticks is ~45 min.
IMPLEMENT_NO_DISPATCH_STUCK_TICKS="${IMPLEMENT_NO_DISPATCH_STUCK_TICKS:-3}"

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.d/locks.sh"

# A web session is shared by automation. This is a
# process-owned flock lease, never a stale marker: closing the fd (including
# on a crash) releases it. The blocking form intentionally reuses the merge
# queue's existing bound instead of adding another wait policy.
WEB_SESSION_LEASE_FILE="${WEB_SESSION_LEASE_FILE:-$AGENT_HOME/cdp-agent-browser.lock}"
WEB_SESSION_LEASE_WAIT_SECONDS="${WEB_SESSION_LEASE_WAIT_SECONDS:-$MERGE_LOCK_WAIT_SECONDS}"

ADVISOR_LOCKS_DIR="$AGENT_HOME/locks"

# comms-format.sh: the maintainer-communication formatter (maintainer timezone,
# Chinese-output gate inputs, local artifact paths) loaded before notify.sh
# so its pre-send checks exist by the time mail is built.
# shellcheck source=./comms-format.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/comms-format.sh"

# notify_email()/notify_maintainer()/resolve_recipients(): see notify.sh. Sourced
# last (not first) purely so every function/variable above already exists by
# the time a script that sources lib.sh runs anything — notify.sh itself only
# depends on REPO and AGENT_HOME, both set at the top of this file, so load
# order relative to them doesn't matter either way.
# shellcheck source=./notify.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/notify.sh"

# Persist the shared latest implement-failure record and legacy prompt fields.
# reset_streak=1 is reserved for refunded/transient provider failures.
IMPLEMENT_FAILURE_STREAK=0

# Every pipeline child sources lib.sh; disabled profiling needs no helper file.
ZF_PIPELINE_CALL_PROFILE_ENABLED=0
if [ -n "${ZF_PIPELINE_CALL_PROFILE_FILE:-}" ]; then
  # shellcheck source=./call-profile.sh
  source "${BASH_SOURCE[0]%/*}/call-profile.sh"
fi
