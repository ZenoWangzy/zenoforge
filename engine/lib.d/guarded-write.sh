
# 2026-09-12 review, item 3: issue-pipeline.sh section (a) used to test "does
# the comment CONTAIN BOT_COMMENT_MARKER anywhere" to decide whether a
# needs-info issue has been answered. GitHub's "Quote reply" copies the
# ENTIRE quoted comment — marker included — into the reporter's own new
# comment body, so a reporter's genuine answer that quote-replies to a bot
# comment carried the marker too and was misread as another bot comment,
# leaving the issue stuck on needs-info forever with nobody told.
#
# Test whether the comment STARTS WITH $BOT_DISCLAIMER instead: every bot
# comment in this pipeline puts the disclaimer as the very first thing in
# the body (see every `guarded_write gh issue comment` call site), and
# GitHub's quote-reply prefixes each quoted line with "> " before appending
# the replier's own text below it — so a quote-reply's body starts with
# "> <quoted first line>", not with the bare disclaimer text, and is
# correctly read as human-authored. This is string-slice comparison, not
# `[[ "$body" == "$BOT_DISCLAIMER"* ]]` glob matching: BOT_DISCLAIMER's own
# markdown contains literal `*` and `` ` `` characters that `[[ == ]]` would
# interpret as wildcards, silently widening the match instead of testing the
# literal text.
#
# Author login is deliberately NOT checked, even though it would be cheap to
# pull from the same `gh issue view --json comments` call already made: the
# bot has no GitHub account of its own (see BOT_COMMENT_MARKER's comment
# above), so every bot comment and every genuine reply from the maintainer
# himself carry the IDENTICAL login. A login comparison has no power to
# distinguish them here, so it would just be dead code.
comment_is_bot() {
  local body="$1"
  [ "${body:0:${#BOT_DISCLAIMER}}" = "$BOT_DISCLAIMER" ]
}

guarded_write() {
  reject_native_auto_merge "$@" || return $?
  local issue_number lane caller create_repo="${REPO:-}" has_lane_add=0 has_hold_remove=0 has_ready_add=0 has_edit=0 child_status i
  local status profile_source="" profile_function="" profile_line=0
  local -a command_args=("$@") filtered_args=()
  if [ "${ROADMAP_ISSUE_CREATE_INNER:-0}" != 1 ] \
    && [ "${command_args[0]:-}" = gh ] && [ "${command_args[1]:-}" = issue ] \
    && [ "${command_args[2]:-}" = create ]; then
    for ((i = 3; i < ${#command_args[@]}; i++)); do
      case "${command_args[i]}" in
        --repo|-R) ((i += 1)); create_repo="${command_args[i]:-}" ;;
        --repo=*) create_repo="${command_args[i]#*=}" ;;
      esac
    done
    if [[ "${create_repo,,}" == "${REPO,,}" ]]; then
      if ! declare -F roadmap_issue_create >/dev/null; then
        echo "guarded_write: refusing the product issue creation; roadmap helper is unavailable" >&2
        return 1
      fi
      roadmap_issue_create "${command_args[@]}"
      return $?
    fi
  fi
  if [ "$DRY_RUN" != 1 ] && [ "${command_args[0]:-}" = gh ] && [ "${command_args[1]:-}" = issue ] \
    && [ "${command_args[2]:-}" = edit ]; then
    issue_number="${command_args[3]:-}"
    if [[ "$issue_number" =~ ^[0-9]+$ ]]; then
      for ((i = 4; i < ${#command_args[@]}; i++)); do
        if [ "${command_args[i]:-}" = --remove-label ] \
          && [ "${command_args[i + 1]:-}" = on-hold ]; then
          has_hold_remove=1
        fi
        [ "${command_args[i]:-}" = --add-label ] || continue
        lane="${command_args[i + 1]:-}"
        case "$lane" in
          ready-for-agent|needs-advisor|needs-triage|needs-recut|awaiting-release)
            has_lane_add=1
            ;;
        esac
        [ "$lane" = ready-for-agent ] && has_ready_add=1
      done
      # Suppress only a hold that was actually read. is_on_hold fails closed on
      # an unreadable label (right for dispatch), but dropping awaiting-release
      # or ready-for-agent on a GitHub read hiccup strands the ticket off every lane.
      # An explicit same-write removal is the hold expiry/release transition.
      if [ "$has_lane_add" = 1 ] && [ "$has_hold_remove" = 0 ] && is_on_hold "$issue_number" \
        && [ "${ISSUE_LABEL_VIEW_STATE[$issue_number]:-}" != failed ]; then
        caller="${FUNCNAME[1]:-main}"
        if [ "$caller" = issue_transition ]; then
          echo "guarded_write: refusing partial stage transition for held #$issue_number" >&2
          return 1
        fi
        for ((i = 0; i < ${#command_args[@]}; i++)); do
          if [ "$i" -ge 4 ] && [ "${command_args[i]:-}" = --add-label ]; then
            lane="${command_args[i + 1]:-}"
            case "$lane" in
              ready-for-agent|needs-advisor|needs-triage|needs-recut|awaiting-release)
                printf 'guarded_write: suppressed %s on held #%s by %s\n' \
                  "$lane" "$issue_number" "$caller" >&2
                [ "$lane" = ready-for-agent ] && has_ready_add=0
                i=$((i + 1))
                continue
                ;;
            esac
          fi
          filtered_args+=("${command_args[i]}")
        done
        for ((i = 4; i < ${#filtered_args[@]}; i++)); do
          case "${filtered_args[i]}" in
            --repo) i=$((i + 1)) ;;
            --repo=*) ;;
            *) has_edit=1; break ;;
          esac
        done
        [ "$has_edit" = 1 ] || return 0
        set -- "${filtered_args[@]}"
      fi
      if [ "$has_ready_add" = 1 ]; then
        child_status=1
        if recut_parent_has_open_child "$issue_number" "${OPEN_ISSUE_BLOCKER_GRAPH_JSON:-[]}" "" 0; then child_status=0; else child_status=$?; fi
        if [ "$child_status" -eq 0 ] || [ "$child_status" -eq 2 ]; then
          caller="${FUNCNAME[1]:-main}"
          if [ "$child_status" -eq 0 ]; then
            printf 'guarded_write: suppressed ready-for-agent on parent #%s with open children by %s\n' \
              "$issue_number" "$caller" >&2
          else
            printf 'guarded_write: suppressed ready-for-agent on parent #%s; child state is unverified by %s\n' \
              "$issue_number" "$caller" >&2
          fi
          if [ "$caller" = issue_transition ]; then
            echo "guarded_write: refusing partial stage transition for parent #$issue_number" >&2
            return 1
          fi
          filtered_args=()
          for ((i = 0; i < ${#command_args[@]}; i++)); do
            if [ "$i" -ge 4 ] && [ "${command_args[i]:-}" = --add-label ] \
              && [ "${command_args[i + 1]:-}" = ready-for-agent ]; then
              i=$((i + 1))
              continue
            fi
            if [ "$i" -ge 4 ] && [ "${command_args[i]:-}" = --remove-label ]; then
              lane="${command_args[i + 1]:-}"
              case " ${ALL_STATE_LABELS[*]} " in
                *" $lane "*) i=$((i + 1)); continue ;;
              esac
            fi
            filtered_args+=("${command_args[i]}")
          done
          for ((i = 4; i < ${#filtered_args[@]}; i++)); do
            case "${filtered_args[i]}" in
              --repo) i=$((i + 1)) ;;
              --repo=*) ;;
              *) has_edit=1; break ;;
            esac
          done
          [ "$has_edit" = 1 ] || return 0
          set -- "${filtered_args[@]}"
        fi
      fi
    fi
  fi
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] $*" >&2
    if [ "${ZF_PIPELINE_CALL_PROFILE_ENABLED:-0}" = 1 ]; then
      _call_profile_guarded_dry_run "${command_args[@]}" || true
    fi
    return 0
  fi
  if [ "${ZF_PIPELINE_CALL_PROFILE_ENABLED:-0}" = 1 ] \
    && [ "${command_args[0]:-}" = systemd-run ]; then
    profile_source="${BASH_SOURCE[1]:-}"
    profile_function="${FUNCNAME[1]:-main}"
    profile_line="${BASH_LINENO[0]:-0}"
    profile_source="${profile_source##*/}"
    if _call_profile_external systemd-run "$profile_source" "$profile_function" "$profile_line" "${command_args[@]:1}"; then
      status=0
    else
      status=$?
    fi
  elif "$@"; then
    status=0
  else
    status=$?
  fi
  if [ "$status" -eq 0 ]; then
    if [ "${1:-}" = gh ] && [ "${2:-}" = issue ] && [ "${3:-}" = edit ]; then
      issue_label_cache_invalidate
    fi
    return 0
  fi
  return "$status"
}


# Keep issue-comment bodies out of argv. Besides avoiding shell substitution
# hazards, this lets callers pass evidence text without exposing it in a
# process list. The temporary file is removed on both real and dry-run paths.
guarded_issue_comment() {
  local n="$1" body="$2" body_file rc
  body_file="$(mktemp)" || return 1
  if ! printf '%s\n' "$body" > "$body_file"; then
    rm -f "$body_file"
    return 1
  fi
  guarded_write gh issue comment "$n" --repo "$REPO" --body-file "$body_file"
  rc=$?
  rm -f "$body_file"
  return "$rc"
}


# Defect 3, 2026-09-13: local pipeline-state writes that are a bare `echo >
# file` redirect, not a command guarded_write() can wrap (guarded_write runs
# "$@" as a command; a shell redirect isn't one). Same shape state_merge()/
# pause_for_backoff() already fixed for their own writes (2026-09-12) — "no
# writes happen under AGENT_DRY_RUN=1" has to cover local state too, not just
# gh/ssh/docker. Reproduced live: run-release.sh's bare marker write
# ($DEPLOY_BLOCKED_FILE) was the one remaining way a
# dry run touching the deploy section left a real trace on disk.
guarded_state_write() {
  local file="$1" content="$2"
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] write '$content' -> $file" >&2
    return 0
  fi
  echo "$content" > "$file"
}


# --- loop-break: a generic transition bound owned by the state machine, ---
# --- not any one leg (2026-09-16, lessons/RULES.md V112/V113/V114/V116) ----
# Tonight's #1204/#1206 incident: two writers -- the advisor's own `guarded`
# ruling (admit_guarded(), below) and the admission gate's dispatch-time
# recheck (issue-pipeline.sh section (c), which calls route_to_advisor() on
# a refusal) -- each applied a rule that was LOCALLY correct in isolation
# and produced a ready-for-agent<->needs-advisor ping-pong neither writer
# could see, because neither reads anything but its own single transition.
# The specific defect (the gate recheck ignoring an admission the ladder
# already granted) is fixed separately, in issue-pipeline.sh's own
# state_is_guarded() skip -- this is the general case: ANY two
# locally-correct writers can produce the same shape for a reason nobody has
# found yet, and fixing one incident does not retire that risk.
#
# What this adds is not a smarter router -- a smarter router is just another
# locally-reasoning writer that can itself be wrong someday. It is a BOUND:
# read the ticket's own trajectory (the one thing every individual writer
# above lacks) from the same durable, restart-proof signal
# detect-label-churn.sh already reads -- GitHub's own issue timeline, not a
# local counter. A local counter is exactly the class of signal #1180
# (lessons/RULES.md, "#1187, 7881d0fc1") showed can be silently zeroed by a
# restart or an out-of-band edit, and V113's own incident showed a
# state-file idempotency marker (advisor_ruled_at) can ALSO fail this way
# even without any of that -- a neighboring, entirely legitimate write path
# (route_to_advisor()'s own `del(.advisor_ruled_at)`, for a genuine second
# episode) clears it as a side effect of doing its own job correctly. A
# bound built the same way would be one edit away from the same defeat.
# Keep the label with each timestamp: duplicate adds can happen after an
# unlabeled/re-add without a real move, as in #3685. The first selected label
# establishes the baseline; only later alternations are flips.
label_transition_events() {
  local n="$1" label_a="$2" label_b="$3" since="$4"
  gh api "repos/$REPO/issues/$n/timeline" --paginate \
    --jq '.[] | select(.event=="labeled") | select(.label.name=="'"$label_a"'" or .label.name=="'"$label_b"'") | select(.created_at >= "'"$since"'") | [.created_at, .label.name] | @tsv' \
    2>/dev/null | awk -F '\t' -v label_a="$label_a" -v label_b="$label_b" '
      ($2 == label_a || $2 == label_b) {
        if (previous != "" && $2 != previous) print $1
        previous = $2
      }
    ' || true
}


# the project hash ban("all agents/skills/workflows are forbidden
# from computing, generating, verifying, comparing, recording, displaying,
# or explaining any hash/checksum/digest/fingerprint ... including Git
# object IDs, in the course of upload/sync/archive/copy/commit/push/
# verify/deliver/deploy") bans exactly this. Prose alone did not hold it:
# run-triage.sh's `model call` triage brief for issue #1140 quoted a Git
# commit id the reporter had written in the issue body straight into
# `brief_md`, and the wrapper published it verbatim to the GitHub comment
# and (as of today) the reporter's email. Measuring the same live state
# files this function runs over (~/.zenoforge/state/1131.json and
# 1132.json) turned up two more, undetected until now: a short and a full
# 40-char id for a rejected local prototype commit, in both `brief_md` and
# `notes_md`. Defect 8, 2026-09-13.
#
# Neutralizes rather than deletes, same shape as scrub_closing_keywords()
# above: a matched token becomes the literal marker below so a reader can
# tell something was removed instead of silently seeing a gap.
#
# This is deliberately NOT a general `\b[0-9a-f]{7,40}\b` scrubber -- that
# was tried first, against a corpus of every real brief_md/notes_md in
# ~/.zenoforge/state/*.json plus a sample of open issue bodies (the exact
# text this function runs over), and it also caught: bare-digit dates
# (`20260811` -- digits are valid hex too; fixed by requiring at least one
# real a-f letter in the match, which no date ever has) and, by design even
# though neither happened to occur in the measured corpus, this repo's
# prefixed ids such as `t-XXXXXXXX` and full-UUID business/event ids quoted
# from ops docs, both excluded below. Schema identifiers like `source_image_sha256`/`preview_hash` (also
# in the measured corpus) were never at risk: they sit inside one larger
# `\w` run that includes non-hex letters, so `\b` never lands inside them.
#
# Known gap, not fixed here: a BARE business/event id of the same shape as
# a short Git SHA (`016bf172`, no surrounding UUID dashes and no `t-`
# prefix) is structurally indistinguishable from a real object id and WILL
# be scrubbed. This did not occur in the measured corpus -- only the
# `t-`-prefixed and full-UUID forms are protected below.
scrub_git_object_ids() {
  perl -CSD -pe '
    s{
      (?<!\bt-)                            # t-XXXXXXXX prefixed id
      (?<![0-9a-fA-F]-)                    # left half of a UUID hex group
      \b
      (?=[0-9a-fA-F]{7,40}\b)              # git short-SHA length .. full SHA-1 length
      ([0-9a-fA-F]*[a-fA-F][0-9a-fA-F]*)   # must contain a real hex letter -- excludes bare-digit dates
      \b
      (?!-[0-9a-fA-F])                     # right half of a UUID hex group
    }{[object-id-redacted]}gx
  '
}


# trim_quoted_reply <body> — cuts a reply's plain-text body at the first
# line that looks like the start of a quoted original message (a ">"
# continuation, an "On ... wrote:" header or its Chinese "...写道："
# equivalent, or a "-----Original Message-----" separator), so a relayed
# comment (issue-pipeline.sh's read_needs_info_email_replies()) shows only
# what the person actually typed, not the whole original question quoted
# back underneath it.
# ponytail: a fixed set of known quote markers, not a general quoted-text
# detector — an unusual mail client's own quote header can slip through
# uncut. Upgrade if a real relayed comment is ever seen with the original
# question still attached.
trim_quoted_reply() {
  # 2026-09-13: `[:：]` (an ASCII colon and the full-width Chinese one in one
  # bracket expression) followed by `$` silently never matches under mawk
  # (the `awk` this box actually has -- no gawk installed) whenever the
  # bracket expression is preceded by anything else in the pattern,
  # multi-byte or not -- confirmed live: `/写道[:：]$/` and even the
  # all-ASCII `/ab[:：]$/` both matched nothing, while `/写道(:|：)$/`
  # (alternation instead of a bracket class) matched correctly. Alternation
  # it is; a `[...]` class next to `$` is a proven trap on this awk, not a
  # style choice.
  awk '
    BEGIN { IGNORECASE = 1 }
    /^>/ { exit }
    /^On .+ wrote:[ \t]*$/ { exit }
    /(写道|wrote)(:|：)[ \t]*$/ { exit }
    /^-{2,}[ \t]*Original Message[ \t]*-{2,}$/ { exit }
    { print }
  ' <<< "$1"
}
