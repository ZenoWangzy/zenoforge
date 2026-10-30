_AGENT_LIB_DIR="${_AGENT_LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}" # a module sourced without lib.sh (land snapshot) still finds the lib dir

# --- advisor leg helpers shared between run-advisor.sh (one ticket) and ----
# --- run-advisor-batch.sh (many tickets in one call) -----------------------
# Both moved here 2026-09-16 when the batch sweep was built: they were
# originally local to run-advisor.sh, but the batch leg needs the identical
# POLICY (what counts as a risky footprint, how a corrected classification
# supersedes a stale brief) applied to every ticket it rules on, and a
# second hand-copy of either is exactly the kind of drift risk-class.mjs's
# own pattern list already suffered once (see advisor_footprint_risky()'s
# own comment below) -- one source of truth, imported by both legs, not
# retyped by the second one.

# --- The hard footprint gate: enforced here in bash, never trusted to the --
# --- prompt. See enforce_autonomy_gate() comment (#1098) for the documented
# --- incident behind "prompt prose is not enforcement": a model returned a
# --- self-contradicting risk_class/state pair in the same response and the
# --- wrapper applied it verbatim until this exact pattern was re-derived in
# --- code. This is that same discipline applied to a second, independent
# --- gate.
#
# enforce_autonomy_gate() only re-checks risk_class/level/phase -- it says
# nothing about the DIFF'S FOOTPRINT. risk-class.mjs is the pipeline's other
# P2/L4 gate: it classifies by actual changed paths and runs twice inside the
# implement leg (run-implement.sh, right before push and again right before
# merge). An issue the advisor waves through on a clean risk_class/level
# alone can still get implemented, reviewed, and only THEN bounced by
# risk-class.mjs -- strictly worse than parking it up front. expected_
# packages (declared by the original triage run) is the only pre-
# implementation footprint signal there is, so this checks it against
# risk-class.mjs's own rules by CALLING classify(), never by restating its
# patterns here.
#
# This function deliberately keeps no hand-copied list of risk-class.mjs's
# patterns: that second copy drifts. It has exactly one source of truth for what
# counts as risky, imported, not re-typed. See risk-class.mjs itself for the
# live pattern list -- do not restate it here or in prompts/advisor.md/
# prompts/advisor-batch.md.
#
# What this function actually proves, and what it does NOT: it catches
# expected_packages entries declared with enough precision to already match
# a current risk-class.mjs pattern (a trailing "/" is appended to each
# candidate so `^prefix/`-anchored patterns can match a bare declared path
# the way they'd match a real file beneath it). It CANNOT catch a purely
# package-granularity declaration ("packages/foo") against a pattern that
# only matches a specific subdirectory of that package, and it cannot catch
# a filename-anywhere pattern (ledger, rls|policy, Dockerfiles, .env, ...)
# that a package-level declaration gives no visibility into at all.
# Clearing this check is therefore NOT proof an issue is safe -- it is a
# best-effort pre-filter on top of the real, authoritative gate, which stays
# in run-implement.sh, unchanged and un-bypassed by this leg. risk-class.
# mjs's own pattern coverage is being audited and fixed separately; this
# function inherits whatever it says, automatically, with no edit here.
advisor_footprint_risky() {
  local expected_json="$1" count lib_dir
  count="$(echo "$expected_json" | jq 'length' 2>/dev/null || echo 0)"
  [ "${count:-0}" -gt 0 ] 2>/dev/null || return 0

  # risk-class.mjs has its own `if (import.meta.url === file://${process.
  # argv[1]})` CLI self-invocation guard -- passing its own path as argv[1]
  # here would make THAT condition true (argv[1] would equal the very file
  # being imported) and fire its CLI block as an unwanted side effect of the
  # import. An env var, not an argv position, sidesteps the collision
  # entirely rather than depending on argument order never accidentally
  # matching that guard again. lib_dir (not SCRIPT_DIR, a caller-only
  # variable this file must not depend on) is this file's OWN directory --
  # risk-class.mjs always lives right next to lib.sh, by construction.
  lib_dir="$(cd "$(dirname "$_AGENT_LIB_DIR/lib.sh")" && pwd)"
  RISK_CLASS_MODULE="$lib_dir/risk-class.mjs" node --input-type=module -e '
    const { classify } = await import(process.env.RISK_CLASS_MODULE);
    const pkgs = JSON.parse(process.argv[1]);
    const candidates = pkgs.map((p) => (p.endsWith("/") ? p : p + "/"));
    process.exit(classify(candidates).length > 0 ? 0 : 1);
  ' "$expected_json"
}


# advisor_superseded_brief <old_brief_md> <new_risk_class> <new_level>
#
# 2026-09-15: measured live the same night this leg was built -- a manual
# advisor pass corrected risk_class/level and the GitHub label on seven
# tickets via state_merge, but never touched `.state` or the STORED
# brief_md's own narrative conclusion. run-implement.sh reads brief_md
# verbatim as the model's own instructions (`BRIEF="$(state_read "$N" | jq
# -r '.brief_md')"`) -- so issue #1144's brief still concluded "the outcome
# is unchanged: ready-for-human" and told the implementer in plain language
# this ticket would not be auto-implemented, while an autonomous implement
# run was dispatched for it anyway: the model was told, in the same prompt,
# both to implement the ticket and that it would not be implemented.
# Whether that specific contradiction caused that run's own failure (it
# failed at the dirty-worktree check before the transcript could confirm
# either way) is NOT claimed here -- the incoherence is a defect on its own
# terms regardless of what it caused. The state file holds both
# machine-readable fields and human-readable narrative generated from them;
# correcting a field without correcting the narrative leaves the narrative
# lying, and the narrative is what the model actually reads. Every write
# path that changes classification owns both.
#
# This does not parse or strip whatever the old brief_md's own stale
# conclusion says -- fragile against arbitrary prior wording, and this
# function has no way to know what shape that conclusion took. It prepends
# an unambiguous, hard-to-miss supersession banner instead, so a stale
# "this needs a human"/"will not be implemented automatically" sentence
# below it is explicitly overridden, not silently left standing.
#
# 2026-09-16: this used to prepend onto $old_brief UNCONDITIONALLY, same bug
# as guarded_brief() above and same fix -- strip_brief_banner() first, so a
# second (or twelfth) misclassification correction replaces the previous
# banner instead of stacking on it. See strip_brief_banner()'s own comment
# (above guarded_brief()) for why this strips either banner kind, not just
# this function's own.
advisor_superseded_brief() {
  local old_brief new_risk="$2" new_level="$3" conditions="${4:-}"
  old_brief="$(strip_brief_banner "$1")"
  echo "**顾问已改判（$(date -u +%Y-%m-%dT%H:%M:%SZ)），这张票现在按无人值守处理。** 下面这份分诊简报是改判前写的，当前真实状态是 risk_class=$new_risk, level=$new_level, state=ready-for-agent——简报正文里如果出现「维持 ready-for-human」「不会自动写代码」「需要人工」这类结论，那是改判前的旧结论，已经不成立，以这一行为准。
$([ -n "$conditions" ] && printf '\n**顾问给出的合并条件（实现者必须做进 diff，评审者必须逐条核对）：**\n\n%s\n' "$conditions")
---

$old_brief"
}


# advisor_prune_own_comments <issue_json> -- drop this pipeline's own past
# comments from `gh issue view`'s .comments before any of it reaches an
# advisor prompt.
#
# Extracted 2026-09-19 from run-advisor-batch.sh, where it was built
# 2026-09-16 after a live sizing failure: a batch prompt measured
# 1,104,128 characters against Codex's own 1,048,576-character input cap,
# root-caused to two tickets stuck the same night in a label-flip loop
# (state_merge()'s own 2026-09-15 comment) that had each racked up 90+ of
# this pipeline's OWN restated comments (guarded-brief banners, relabel
# notices, advisor rulings -- ~90% of their comment bytes) -- the advisor
# was mostly being shown itself talking to itself. Moved here so
# run-advisor.sh's single-ticket leg can apply the identical rule instead
# of feeding the model its own past chatter on every dispatch, unmeasured
# only because one ticket's own noise rarely alone trips the batch leg's
# hard input cap -- it was never free, just not the call that failed loud.
#
# comment_is_bot()'s own $BOT_DISCLAIMER prefix test (above) is reused
# verbatim, not reinvented: every comment this pipeline posts itself starts
# with the literal $BOT_DISCLAIMER text, so filtering on that prefix can
# only drop the pipeline's own restated noise, never a genuine reporter/
# human comment -- including a GitHub "quote reply" that copies a bot
# comment's $BOT_COMMENT_MARKER into a human's own new comment underneath
# it (see comment_is_bot()'s own comment for exactly why this is a prefix
# test and not a marker-presence test).
#
# `(. // [])` before map(): a ticket with zero comments, or an $issue_json
# missing `.comments` entirely, must trim to an empty list, not crash the
# caller's `set -e` -- both are ordinary inputs (a freshly opened ticket
# has no comments yet), not malformed ones.
#
# <<< not --arg/--argjson for the big side of this: $issue_json is
# untrusted-size (a long human thread) -- same MAX_ARG_STRLEN concern
# jq_arg_file()'s own comment documents, same reason run-advisor-batch.sh's
# own ticket-assembly loop routes through it instead of argv.
advisor_prune_own_comments() {
  local issue_json="$1"
  [ -n "$issue_json" ] || issue_json='{}'
  jq -c --arg prefix "$BOT_DISCLAIMER" \
    '.comments |= ((. // []) | map(select((.body // "") | startswith($prefix) | not)))' \
    <<< "$issue_json"
}


# advisor_current_brief_md <prior_state_json> -- cut prior_state.brief_md
# down to only its current (most recent) classification narrative before
# any of it reaches an advisor prompt.
#
# Extracted 2026-09-19 from run-advisor-batch.sh (built 2026-09-16, same
# incident as advisor_prune_own_comments() above): advisor_superseded_
# brief() PREPENDS a fresh banner every time a ticket is re-classified, and
# that banner tells the reader in plain language that any stale conclusion
# below it no longer applies -- so only the text before the first such
# banner boundary ("\n---\n\n", the exact string advisor_superseded_
# brief() joins on) is this ticket's current, authoritative narrative. Two
# real tickets had 30 and 29 stacked banners (65,137 and 47,985 chars of
# brief_md, measured) -- an ever-growing chain of text the pipeline itself
# had already marked superseded. A ticket classified once, the common
# case, has no such boundary at all and this is a no-op.
#
# This is deliberately NOT strip_brief_banner() (above): that function
# peels a banner OFF to recover the original content underneath (so a NEW
# banner can be prepended in its place) -- the opposite direction from what
# a prompt needs, which is the newest banner's own "current truth"
# statement and nothing stale beneath it.
#
# `if . == null` guards a ticket with no brief_md yet (never triaged, or a
# fresh episode) -- left unchanged (null), not coerced into a crash or a
# stray "null" string.
advisor_current_brief_md() {
  local prior_json="$1"
  [ -n "$prior_json" ] || prior_json='{}'
  jq -c '.brief_md |= (if . == null then . else (split("\n---\n\n")[0]) end)' \
    <<< "$prior_json"
}


# advisor_pending_orphan_candidates -- every issue number under $STATE_DIR
# whose local state still carries an unresolved .pending_advisor_verdict.
# The scheduler also uses this list for roadmap parents removed from the
# fresh batch even while their GitHub label still says needs-advisor.
# 2026-09-19: closes the recovery gap left after advisor_persist_pending()/
# the atomic-completion write (advisor-core.sh, c8d802867): if a verdict's
# Apply sequence swaps the GitHub label away from needs-advisor but a LATER
# step in that same Apply run fails before the final atomic completion
# write, the ticket is stuck -- .pending_advisor_verdict sits in its local
# state forever, but issue-pipeline.sh's ordinary candidate query (`gh issue
# list --label needs-advisor`) can never find it again, because the label
# it keys on is already gone.
#
# "Present" already means "this exact episode's Apply never finished": the
# SAME state_merge call that ever clears .pending_advisor_verdict either
# finishes the episode (sets advisor_ruled_at, advisor-core.sh's own
# atomic-completion comment) or starts a fresh one (route_to_advisor()/
# give_up_on_issue(), which clear it in the same call as advisor_ruled_at) --
# so nothing else ever leaves it sitting on disk once an episode is done.
# No episode-seq cross-check needed here: advisor_resume_check() (advisor-
# core.sh) already re-validates that atomically against the CURRENT episode
# the moment a dispatch actually picks this ticket back up; this function's
# only job is surfacing the candidate, not re-deciding its eligibility.
#
# Reads state files directly (same $STATE_DIR/*.json glob idiom count_
# recent_loop_escalations()/sweep-brief-banners.sh already use above and in
# their own files), not a GitHub query -- this IS the recovery path for a
# ticket whose GitHub label already moved off needs-advisor while its local
# pending marker is still sitting there, so a query keyed on that label
# would miss it by definition. A state file that fails to parse (jq -e
# itself failing) is skipped, not fatal to the rest of the scan -- one
# corrupt file must not hide every other ticket's own orphaned verdict.
# One issue number per line, numerically sorted for a deterministic
# dispatch order across ticks.
advisor_pending_orphan_candidates() {
  local f
  [ -d "$STATE_DIR" ] || return 0
  for f in "$STATE_DIR"/*.json; do
    [ -f "$f" ] || continue
    jq -e '.pending_advisor_verdict != null' "$f" >/dev/null 2>&1 || continue
    basename "$f" .json
  done | sort -n
}


advisor_batch_state_read() {
  if [ -f "$ADVISOR_BATCH_STATE_FILE" ]; then
    cat "$ADVISOR_BATCH_STATE_FILE"
  else
    echo '{}'
  fi
}


advisor_batch_state_write() {
  local json="$1" tmp
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] advisor batch state -> $ADVISOR_BATCH_STATE_FILE" >&2
    return 0
  fi
  if ! jq -e . >/dev/null 2>&1 <<< "$json"; then
    echo "advisor_batch_state_write: refusing invalid JSON for $ADVISOR_BATCH_STATE_FILE" >&2
    return 1
  fi
  mkdir -p "$(dirname "$ADVISOR_BATCH_STATE_FILE")"
  tmp="$(mktemp "${ADVISOR_BATCH_STATE_FILE}.tmp.XXXXXX")" || return 1
  if ! printf '%s\n' "$json" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$ADVISOR_BATCH_STATE_FILE"
}


advisor_batch_state_transform() {
  local filter="$1" filter_file updated
  filter_file="$(mktemp)" || return 1
  printf '%s\n' "$filter" > "$filter_file"
  if ! updated="$(advisor_batch_state_read | jq -f "$filter_file")"; then
    rm -f "$filter_file"
    return 1
  fi
  rm -f "$filter_file"
  advisor_batch_state_write "$updated"
}


advisor_batch_job_json() {
  advisor_batch_state_read | jq -c '.job // empty'
}


advisor_batch_job_active() {
  advisor_batch_state_read | jq -e '(.job.job_id? // "") | (type == "string" and length > 0)' >/dev/null
}


advisor_batch_state_set_job() {
  local job_json="$1" job_file updated
  job_file="$(jq_arg_file "$job_json")"
  if ! updated="$(advisor_batch_state_read | jq --slurpfile job "$job_file" '. + {job: $job[0]}')"; then
    rm -f "$job_file"
    return 1
  fi
  rm -f "$job_file"
  advisor_batch_state_write "$updated"
}


advisor_batch_state_clear_job() {
  advisor_batch_state_transform 'del(.job)'
}


advisor_batch_deferred_candidates() {
  local n state
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    state="$(state_read "$n")"
    echo "$state" | jq -e 'has("advisor_ruled_at") or (.state // "") == "concluded"' >/dev/null 2>&1 && continue
    echo "$n"
  done < <(advisor_batch_state_read | jq -r '.deferred_issue_ids[]? | select(type == "number")')
}


advisor_batch_defer_issues() {
  local ids_file updated
  [ "$#" -gt 0 ] || return 0
  ids_file="$(mktemp)" || return 1
  printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0) | tonumber)' > "$ids_file"
  if ! updated="$(advisor_batch_state_read | jq --slurpfile ids "$ids_file" \
    '.deferred_issue_ids = (((.deferred_issue_ids // []) + $ids[0]) | unique)')"; then
    rm -f "$ids_file"
    return 1
  fi
  rm -f "$ids_file"
  advisor_batch_state_write "$updated"
}


advisor_batch_lock_file() {
  echo "$AGENT_HOME/locks/advisor-batch.lock"
}
