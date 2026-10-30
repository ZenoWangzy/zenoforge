_AGENT_LIB_DIR="${_AGENT_LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}" # a module sourced without lib.sh (land snapshot) still finds the lib dir

# 2026-09-15 00:14:51 PDT, zf-triage-1203.service: the two labels above
# were added to ALL_STATE_LABELS by the advisor-leg commit, so EVERY triage
# run's final `gh issue edit` started passing `--remove-label needs-advisor
# --remove-label needs-recut` -- and gh resolves every named label before
# applying any, so on a repo where those labels did not exist yet the whole
# edit failed ("'needs-advisor' not found"), `set -e` killed the run before
# state_merge, and the issue was left with TWO state labels (the add half
# had already applied). The only self-heal lived in run-advisor.sh, which
# cannot run until a triage run has first applied needs-advisor -- a
# chicken-and-egg that guaranteed the first triage after that commit died.
# Shared here so every leg that edits state labels (triage, advisor, the
# scheduler) heals them before its first label edit. `|| true` on each:
# "already exists" is the common case, and DRY_RUN short-circuits
# guarded_write to a 0 that never called gh.
# Covers the WHOLE array, not the two labels that happened to be new
# tonight: the strip loop's dependency is on every name in ALL_STATE_LABELS
# existing, so any future addition would fail the same way. One `gh label
# list` read, then a create only for what is missing -- fails loud (a
# created label is visible on the repo) rather than silently tolerating a
# missing one at removal time.
ensure_state_labels() {
  local existing name
  existing="$(gh label list --repo "$REPO" --limit 200 --json name -q '.[].name' 2>/dev/null)" || existing=""
  for name in "${ALL_STATE_LABELS[@]}"; do
    grep -qx -- "$name" <<< "$existing" && continue
    guarded_write gh label create "$name" --repo "$REPO" --color ededed \
      --description "the product issue pipeline state label" >/dev/null 2>&1 || true
  done
}


# jq_arg_file <value> -- writes $value to a fresh temp file and prints its
# path on stdout. The caller pairs the path with jq's own --rawfile NAME
# <path> (a byte-for-byte drop-in for --arg NAME "$value": --rawfile binds
# $NAME to the identical plain scalar string --arg does, just read from
# disk instead of argv, so no filter rewrite is needed) or --slurpfile NAME
# <path> (the --argjson replacement for a JSON object/array/etc value --
# --slurpfile always binds $NAME to an ARRAY of every JSON value the file
# contains, so a filter written against it reads $NAME[0], never bare
# $NAME, since this always writes exactly one). Caller removes the file
# right after its own jq call, the same lifecycle state_merge's own
# filter_file already has (mktemp, use, rm -f) -- see this file's other
# 2026-09-15 comment on state_merge for why that shape (not a wrapper that
# hides the temp file) is the house style.
#
# 2026-09-16 (lessons/RULES.md, this same defect class as state_merge's
# 89e205846 fix, found the THIRD time in one day): state_merge's fix put
# the jq FILTER PROGRAM in a file instead of argv, but every call site that
# builds that filter by splicing a $PATCH object together first --
# `jq -n --arg b "$new_brief" --arg c "$merge_conditions" ... '{...}'` --
# still handed jq's own --arg/--argjson flags the caller's raw DATA
# (a brief_md, a decision_md, a whole ISSUE_JSON/PRIOR state object, a
# base64 MIME email) through argv, unfixed. Same failure shape either way:
# once one value crosses Linux's MAX_ARG_STRLEN (128KiB per argv element,
# independent of and much smaller than ARG_MAX), `execve` refuses to even
# start jq -- exit 126, "Argument list too long" -- and the caller's own
# `set -e` (or, worse, a bare loop-body assignment with no `if` around it
# at all, see run-advisor-batch.sh's own per-ticket assembly fix the same
# day) dies before anything is written. A fix applied to ONE function
# (state_merge) is not applied to its siblings just because they rhyme --
# this helper exists so every site with data too big to trust to argv
# routes through the SAME seam, not a fourth bespoke workaround. See
# jq-arg-safety.test.sh for the static guard that keeps a converted call
# site from regressing back to --arg/--argjson on a value this convention
# already knows is unbounded.
jq_arg_file() {
  local f
  f="$(mktemp)" || return 1
  printf '%s' "$1" > "$f"
  echo "$f"
}


state_file() { echo "$STATE_DIR/$1.json"; }


# Prints the issue's state JSON, defaulting to attempts=0 if none exists yet.
state_read() {
  local f
  f="$(state_file "$1")"
  if [ -f "$f" ]; then cat "$f"; else echo '{"attempts":0}'; fi
}


ticket_stage_is_label() {
  local candidate="$1" label
  for label in "${ALL_STATE_LABELS[@]}"; do
    [ "$candidate" = "$label" ] && return 0
  done
  return 1
}


efficiency_metrics_append_rows() {
  local rows="${1:-}" first month file lock_fd row status=0
  [ -n "$rows" ] || return 0
  first="${rows%%$'\n'*}"
  month="$(jq -r '.ts[0:7] // empty' <<< "$first" 2>/dev/null)" || return 1
  [[ "$month" =~ ^[0-9]{4}-[0-9]{2}$ ]] || return 1
  mkdir -p -- "$AGENT_HOME/metrics" || return 1
  chmod 700 -- "$AGENT_HOME/metrics" || return 1
  file="$AGENT_HOME/metrics/efficiency-$month.jsonl"
  exec {lock_fd}>>"$file.lock" || return 1
  flock -x "$lock_fd" || { exec {lock_fd}>&-; return 1; }
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    printf '%s\n' "$row" >> "$file" || { status=1; break; }
  done <<< "$rows"
  [ ! -f "$file" ] || chmod 600 -- "$file" || status=1
  flock -u "$lock_fd" || true
  exec {lock_fd}>&-
  return "$status"
}


efficiency_metrics_sync_issue_lifecycle() {
  local issue="$1" script_dir
  script_dir="$(cd -- "$(dirname -- "$_AGENT_LIB_DIR/lib.sh")" && pwd -P)" || return 0
  [[ -r "$script_dir/night/efficiency-regression.mjs" ]] || return 0
  node "$script_dir/night/efficiency-regression.mjs" sync-issue --home "$AGENT_HOME" --issue "$issue" >/dev/null \
    || echo "efficiency metrics: lifecycle sync failed for issue #$issue" >&2
  return 0
}


efficiency_metrics_record_implement_decision() {
  local issue="$1" tick="$2" outcome="$3" gate="$4" reason="$5" object="$6" ts boot_id retry_reason="${7:-}"
  local values_file row
  ts="$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" || return 1
  boot_id="$(host_boot_id)" || return 1
  values_file="$(mktemp)" || return 1
  if ! printf '%s\0' "$issue" "$tick" "$outcome" "$gate" "$reason" "$object" "$ts" "$boot_id" "$retry_reason" > "$values_file"; then
    rm -f -- "$values_file"
    return 1
  fi
  row="$(jq -cn --rawfile values "$values_file" '
    ($values|split("\u0000")) as $v |
    def category($gate):
      if $gate == "capacity" then "agent_cap"
      elif $gate == "dispatch-resources" then "memory"
      elif $gate == "quarantine" then "quarantine"
      elif ($gate | test("budget|spend|quota|repeat-cap|attempt-cap")) then "budget"
      elif ($gate | test("block|parent")) then "blocked_by"
      elif ($gate | test("advisor")) then "advisor"
      elif ($gate | test("review")) then "review"
      elif ($gate | test("ci|check")) then "ci_queue"
      elif ($gate | test("land|merge|pr-file-collision")) then "land_queue"
      else "other" end;
    {schema_version:1,record_type:"event",event_type:(if $v[2] == "dispatched" then "dispatch" else "limiter" end),
     ts:$v[6],issue:($v[0]|tonumber),tick:$v[1],outcome:$v[2],gate:$v[3],reason:$v[4],
     object:$v[5],boot_id:$v[7],retry_reason:(if $v[8] == "" then null else $v[8] end),category:(if $v[2] == "dispatched" then null else category($v[3]) end),
     event_id:($v[6]+"|"+$v[0]+"|"+$v[1]+"|"+$v[3]+"|"+$v[2])}')"
  local status=$?
  rm -f -- "$values_file"
  [ "$status" -eq 0 ] || return "$status"
  efficiency_metrics_append_rows "$row"
}


ticket_stage_record() {
  (($# >= 6)) || return 2
  local n="$1" from="$2" to="$3" writer="$4" kind="$5" progress="$6"
  local event_id="${7:-}" ts="${8:-}" event_file="$AGENT_HOME/state/ticket-transitions.jsonl"
  local row lock_fd seed status
  [[ "$n" =~ ^[0-9]+$ ]] || return 2
  [ -n "$ts" ] || ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
  if [ -z "$event_id" ]; then
    seed="$n|$from|$to|$ts|$(date +%s%N)|$RANDOM"
    event_id="$(printf '%s' "$seed" | sha256sum | awk '{print $1}')" || return 1
  fi
  row="$(jq -cn --arg ts "$ts" --argjson issue "$n" --arg from "$from" --arg to "$to" \
    --arg writer "$writer" --arg kind "$kind" --arg event_id "$event_id" \
    --argjson progress "$progress" \
    '{ts:$ts,issue:$issue,from_stage:$from,to_stage:$to,writer:$writer,kind:$kind,progress:$progress,event_id:$event_id}')" || return 1
  exec {lock_fd}>>"$event_file.lock" || return 1
  if ! flock -x "$lock_fd"; then
    exec {lock_fd}>&-
    return 1
  fi
  if [ -f "$event_file" ] && grep -Fq -- "\"event_id\":\"$event_id\"" "$event_file"; then
    flock -u "$lock_fd" || true
    exec {lock_fd}>&-
    return 0
  fi
  if printf '%s\n' "$row" >> "$event_file"; then
    local metric_rows
    metric_rows="$(jq -c '
      . as $event |
      (if .from_stage != "" and .from_stage != "untracked" then
        {schema_version:1,record_type:"event",event_type:"stage-exited",ts:.ts,issue:.issue,stage:.from_stage,
         writer:.writer,kind:.kind,progress:.progress,event_id:(.event_id+":exit"),source_event_id:.event_id}
       else empty end),
      (if .from_stage == "untracked" then
        {schema_version:1,record_type:"event",event_type:"ticket-created",ts:.ts,issue:.issue,stage:.to_stage,
         writer:.writer,kind:.kind,event_id:(.event_id+":created"),source_event_id:.event_id}
       else empty end),
      (if .to_stage != "" and .to_stage != "untracked" then
        {schema_version:1,record_type:"event",event_type:"stage-entered",ts:.ts,issue:.issue,stage:.to_stage,
         writer:.writer,kind:.kind,progress:.progress,event_id:(.event_id+":enter"),source_event_id:.event_id}
       else empty end),
      (if .to_stage == "closed" then
        {schema_version:1,record_type:"event",event_type:"ticket-closed",ts:.ts,issue:.issue,stage:.to_stage,
         writer:.writer,kind:.kind,event_id:(.event_id+":closed"),source_event_id:.event_id}
       else empty end),
      (if .to_stage == "released" then
        {schema_version:1,record_type:"event",event_type:"ticket-released",ts:.ts,issue:.issue,stage:.to_stage,
         writer:.writer,kind:.kind,event_id:(.event_id+":released"),source_event_id:.event_id}
       else empty end)
    ' <<< "$row")" || metric_rows=""
    if [ -z "$metric_rows" ] || ! efficiency_metrics_append_rows "$metric_rows"; then
      echo "ticket_stage_record: efficiency metrics append failed for #$n" >&2
    fi
    flock -u "$lock_fd" || true
    exec {lock_fd}>&-
    return 0
  else
    status=$?
  fi
  flock -u "$lock_fd" || true
  exec {lock_fd}>&-
  return "$status"
}


# A hard WSL reset leaves the unflushed tail of this append-only log as NUL
# bytes (2026-09-28 06:09Z: 223 bytes), and every jq reader then rejects the
# whole file. Rows are whole-line appends, so dropping the NULs recovers every
# row that reached the disk.
ticket_transitions_repair() {
  local event_file="$AGENT_HOME/state/ticket-transitions.jsonl" lock_fd
  [ -f "$event_file" ] || return 0
  [ "$(tr -cd '\000' < "$event_file" | wc -c)" -gt 0 ] || return 0
  exec {lock_fd}>>"$event_file.lock" || return 1
  flock -x "$lock_fd" || { exec {lock_fd}>&-; return 1; }
  tr -d '\000' < "$event_file" > "$event_file.repair" && mv -f "$event_file.repair" "$event_file"
  local status=$?
  flock -u "$lock_fd" || true
  exec {lock_fd}>&-
  [ "$status" -eq 0 ] && echo "ticket-transitions: removed NUL bytes left by an unclean shutdown" >&2
  return "$status"
}


ticket_stage_latest() {
  local n="$1" event_file="$AGENT_HOME/state/ticket-transitions.jsonl"
  [ -f "$event_file" ] || return 0
  jq -sr --argjson issue "$n" '[.[] | select(.issue == $issue)][-1].to_stage // empty' "$event_file" 2>/dev/null
}


ticket_stage_record_labels() {
  local n="$1" arg label state_json state_to state_from state_changed_at
  local from="" to="" kind="${TICKET_STAGE_WRITE_KIND:-}" progress=true event_id="" hold_added=0
  local -a added=() removed=()
  shift
  while (($#)); do
    arg="$1"
    shift
    case "$arg" in
      --add-label|--remove-label)
        (($#)) || break
        label="$1"
        shift
        if [ "$arg" = --add-label ] && ticket_stage_is_label "$label"; then added+=("$label"); fi
        if [ "$arg" = --remove-label ] && ticket_stage_is_label "$label"; then removed+=("$label"); fi
        if [ "$arg" = --add-label ] && [ "$label" = on-hold ]; then hold_added=1; fi
        ;;
    esac
  done
  ((${#added[@]} || ${#removed[@]} || hold_added)) || return 0
  state_json="$(state_read "$n")" || state_json='{}'
  state_to="$(jq -r '.state // empty' <<< "$state_json" 2>/dev/null)"
  state_from="$(jq -r '.state_changed_from // empty' <<< "$state_json" 2>/dev/null)"
  state_changed_at="$(jq -r '.state_changed_at // empty' <<< "$state_json" 2>/dev/null)"
  # A deployment writes both released and concluded; released is the stage
  # advancement and concluded is its terminal marker.
  for label in "${added[@]}"; do
    if [ "$label" = released ]; then to=released; break; fi
    [ -n "$to" ] || to="$label"
  done
  [ "$hold_added" = 0 ] || to=on-hold
  if [ -z "$to" ]; then to=unrouted; fi
  if [ "$kind" = requeue ] && [ "$state_to" = "$to" ] && ((${#removed[@]} == 0)); then
    from="$to"
  elif [ "$state_to" = "$to" ] && [ -n "$state_from" ] \
    && [[ " ${removed[*]} " == *" $state_from "* ]]; then
    from="$state_from"
    if [ -n "$state_changed_at" ]; then
      event_id="$(printf '%s' "$n|$from|$to|$state_changed_at" | sha256sum | awk '{print $1}')"
    fi
  elif [ "$to" = needs-triage ] && [ "$(ticket_stage_latest "$n")" = closed ]; then
    from=closed
  elif [ "$state_to" != "$to" ] && [[ " ${removed[*]} " == *" $state_to "* ]]; then
    from="$state_to"
  else
    from="${removed[0]:-${state_from:-untracked}}"
  fi
  if [ "$from" = "$to" ] && [ "$kind" != requeue ]; then return 0; fi
  if [ -n "${TICKET_STAGE_WRITE_KIND:-}" ]; then
    kind="$TICKET_STAGE_WRITE_KIND"
  elif { [ "$from" = ready-for-agent ] && [ "$to" = needs-advisor ]; } \
    || { [ "$from" = needs-advisor ] && [ "$to" = ready-for-agent ]; }; then
    kind=flip
  elif [ "$to" = unrouted ] || [ "$to" = on-hold ]; then
    kind=park
  else
    kind=advance
  fi
  case "$kind" in flip|requeue|park) progress=false ;; *) progress=true ;; esac
  # A closed ticket may receive its terminal display labels after close. Those
  # are metadata; do not record a backwards stage transition.
  if [ "$(jq -r '.closed_by_pipeline // false' <<< "$state_json" 2>/dev/null)" = true ] \
    && { [ "$to" = released ] || [ "$to" = concluded ]; }; then
    return 0
  fi
  ticket_stage_record "$n" "$from" "$to" "${0##*/}" "$kind" "$progress" "$event_id"
}


ticket_stage_record_close() {
  local n="$1" state_json from latest
  state_json="$(state_read "$n")" || state_json='{}'
  latest="$(ticket_stage_latest "$n")"
  from="${latest:-$(jq -r '.state // .state_changed_from // "untracked"' <<< "$state_json" 2>/dev/null)}"
  [ -n "$from" ] || from=untracked
  [ "$from" = closed ] && return 0
  ticket_stage_record "$n" "$from" closed "${0##*/}" close 1
}


ticket_stage_record_gh_write() {
  case "${1:-}:${2:-}" in
    issue:edit)
      ticket_stage_record_labels "${3:-}" "${@:4}"
      ;;
    issue:close)
      ticket_stage_record_close "${3:-}"
      ;;
    *) return 0 ;;
  esac
}


# Merges $2 (a jq filter producing an object to merge) into issue $1's state.
# 2026-09-12 bug: a "read-only" --dry-run triage run gave a real issue
# attempts:1 and paused the live pipeline, because this wrote to disk
# unconditionally. Under AGENT_DRY_RUN=1 it now computes and prints what it
# would have written instead of writing it — same DRY_RUN short-circuit as
# guarded_write, just for local state instead of gh/ssh/docker.
#
# 2026-09-15 bug (#1204/#1206 live, measured): $filter used to go straight
# into jq's own argv (`jq "$filter"`). Every "merge this whole verdict"
# call site (run-advisor.sh's `". + $PATCH"` etc.) builds $filter by
# splicing model-authored JSON -- an advisor ruling's reasoning_md/
# decision_md -- directly into that string. Once a ruling's text pushed the
# resulting argv element past Linux's MAX_ARG_STRLEN (128KiB per argument,
# independent of the much larger ARG_MAX), `execve` refused to even start
# jq: exit 126, "Argument list too long", the run dying mid-function under
# this script's `set -e` before it ever reached its own state write --
# silently, from the caller's side, because the failure looked exactly like
# any other killed unit. #1204's stored ruling alone was 127.7K by the time
# this was caught. Fix the function, not every call site: jq's `-f/
# --from-file` reads the PROGRAM from a file instead of argv, so $filter's
# size is bounded only by disk, never by exec's argument limit -- no call
# site changes needed, since a filter string that was valid as an argv
# element is byte-identical and equally valid read from a file.
#
# This fixed $filter (the PROGRAM); it does not fix a caller's own
# --arg/--argjson DATA (a brief_md, a whole ISSUE_JSON) reaching jq's argv
# on the way to building that $filter -- see jq_arg_file() just above for
# the sibling seam that closes that half, added 2026-09-16 once the same
# argv-size failure turned up a third time in sites this fix did not touch.
#
# A failed merge must not fail silently and must never leave $f half
# written: check jq's own exit status (and guard against an empty $new,
# which pipefail alone would not catch if jq somehow exited 0 with nothing
# on stdout) BEFORE ever touching $f, and return non-zero so the caller's
# `set -e` still stops the run -- now with a diagnostic on stderr naming the
# issue, instead of a bare exec error with no issue number attached. The
# final write itself was already atomic (temp file + rename) and stays so.
# Serialize the full read/merge/rename for each issue: concurrent writers
# otherwise share `$f.tmp`, and one can move that path before another does.
# The subshell releases the per-state lock on every return path.
state_merge() (
  local n="$1" filter="$2" lock_mode="${3:-}" f new filter_file previous_state previous_json legacy_epoch lock_fd
  local old_pr new_pr progress_stage
  f="$(state_file "$n")"
  mkdir -p -- "$STATE_DIR" || { echo "state_merge: could not create state directory for issue #$n -- state file $f NOT written" >&2; return 1; }
  if [ -n "$lock_mode" ] && [ "$lock_mode" != __issue_transition_lock_held ]; then
    echo "state_merge: invalid internal lock mode for issue #$n -- state file $f NOT written" >&2
    return 64
  fi
  if [ "$lock_mode" != __issue_transition_lock_held ]; then
    if ! exec {lock_fd}>"$f.lock"; then
      echo "state_merge: could not open state lock for issue #$n -- state file $f NOT written" >&2
      return 1
    fi
    if ! flock -x "$lock_fd"; then
      echo "state_merge: could not lock state for issue #$n -- state file $f NOT written" >&2
      return 1
    fi
  fi
  previous_json="$(state_read "$n")"
  previous_state="$(jq -r '.state // empty' <<< "$previous_json" 2>/dev/null || true)"
  legacy_epoch="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
  filter_file="$(mktemp)" || { echo "state_merge: mktemp failed for issue #$n -- state file $f NOT written" >&2; return 1; }
  printf '%s\n' "$filter" > "$filter_file"
  # Keep this in the existing atomic state write: counters and merge-sweep
  # bookkeeping must not refresh the progress clock. A legacy file's mtime is
  # copied once as its baseline, before later bookkeeping can change mtime.
  printf '%s\n' ' | if (.state // "") != $previous_state then .state_changed_from = $previous_state | .state_changed_at = (now | todate) elif (.state_changed_at // "") == "" and $legacy_epoch > 0 then .state_changed_at = ($legacy_epoch | todate) else . end' >> "$filter_file"
  if ! new="$(jq --arg previous_state "$previous_state" --argjson legacy_epoch "$legacy_epoch" -f "$filter_file" <<< "$previous_json")" || [ -z "$new" ]; then
    rm -f "$filter_file"
    echo "state_merge: jq failed for issue #$n -- state file $f NOT written (filter kept in a file, out of argv, precisely so this diagnostic -- not an exec error -- is what shows up)" >&2
    return 1
  fi
  rm -f "$filter_file"
  # A stage label cannot reconstruct merge identity after local state loss.
  if ! printf '%s\n%s\n' "$previous_json" "$new" | jq -se '
    def release_identity:
      .run.outcome == "merged" and
      (.run.evidence.pr_number | tostring | test("^[1-9][0-9]*$")) and
      (.deploy_state == "pending" or .deploy_state == "deployed");
    .[0] as $old | .[1] as $new |
    $new.state != "awaiting-release" or ($new | release_identity) or
    ($old.state == "awaiting-release" and ($old | release_identity | not))
  ' >/dev/null; then
    echo "state_merge: refusing incomplete release handoff for issue #$n; reconcile through conclude_merged_run with verified PR/main ancestry -- state file $f NOT written" >&2
    return 1
  fi
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] state_merge $n -> $new" >&2
    return 0
  fi
  printf '%s\n' "$new" > "$f.tmp" || return 1
  # Rename alone leaves unflushed state vulnerable to NUL loss on a hard WSL reset.
  python3 - "$f.tmp" "$f" <<'PY' || return 1
import os, sys
source, target = sys.argv[1:]
with open(source, 'rb') as state:
    os.fsync(state.fileno())
os.replace(source, target)
directory = os.open(os.path.dirname(target), os.O_RDONLY)
try:
    os.fsync(directory)
finally:
    os.close(directory)
PY
  old_pr="$(jq -r '.run.evidence.pr_number // empty' <<< "$previous_json")"
  new_pr="$(jq -r '.run.evidence.pr_number // empty' <<< "$new")"
  if [ -n "$new_pr" ] && [ "$new_pr" != "$old_pr" ]; then
    progress_stage="$(jq -r '.state // .state_changed_from // "untracked"' <<< "$new")"
    ticket_stage_record "$n" "$progress_stage" "$progress_stage" "${0##*/}" implement true "implement:$n:$new_pr" || {
      echo "state_merge: PR progress record failed for issue #$n PR #$new_pr" >&2
      return 1
    }
  fi
)


issue_transition_state_is_valid() {
  local state="${1:-}"
  [ -n "$state" ] || return 1
  [ -n "${ISSUE_TRANSITION_TABLE[$state]+set}" ]
}


issue_transition_allowed() {
  local from="$1" to="$2" reason="$3"
  issue_transition_state_is_valid "$from" && issue_transition_state_is_valid "$to" || return 1
  case "$reason" in
    close-reconcile:*)
      case "$to" in concluded|duplicate|wontfix) ;; *) return 1 ;; esac
      case "$from" in concluded|duplicate|wontfix|released|closed) return 1 ;; esac
      return 0
      ;;
  esac
  # Last-child release retires umbrella parents from their current lane.
  if [ "$to" = released ] && [ "$reason" = all-children-released ]; then return 0; fi
  [[ " ${ISSUE_TRANSITION_TABLE[$from]} " == *" $to "* ]] || return 1
  case "$from:$to" in
    on-hold:awaiting-release)
      case "$reason" in ops-acceptance-passed|merged-pr) ;; *) return 1 ;; esac
      ;;
    *:awaiting-release)
      [ "$reason" = merged-pr ] || return 1
      ;;
    *:tracker)
      case "$reason" in
        recut-parent-retired) ;;
        intake-parent:roadmap-container:*)
          case "$from" in untracked|ready-for-agent) ;; *) return 1 ;; esac
          ;;
        *) return 1 ;;
      esac
      ;;
    awaiting-release:ready-for-agent|released:ready-for-agent)
      case "$reason" in revert|failed-deploy|reopened-by-human|main-red-revert|continuation-requeue) ;; *) return 1 ;; esac
      ;;
    awaiting-release:released)
      [ "$reason" = deployment-proven ] || return 1
      ;;
    awaiting-pipeline-health:released)
      [ "$reason" = deployment-proven ] || return 1
      ;;
    tracker:released)
      [ "$reason" = all-children-released ] || return 1
      ;;
    concluded:released)
      [ "$reason" = deployment-proven ] || return 1
      ;;
    on-hold:concluded|on-hold:duplicate|on-hold:finish-first|on-hold:wontfix)
      [[ "$reason" == conclude:* || "$reason" == close-* ]] || return 1
      ;;
    on-hold:*)
      case "$reason" in hold-applied|hold-expired|hold-dead-owner|hold-release|hold-requeue|hold-backfill|hold-supervisor-release|recut-parent-retired|merged-pr|deployment-proven|all-children-released|pipeline-system-verification|main-red-revert) ;; *) return 1 ;; esac
      ;;
    finish-first:needs-triage)
      [ "$reason" = blocking-pr-cleared ] || return 1
      ;;
    finish-first:needs-info)
      [ "$reason" = supervisor-needs-info ] || return 1
      ;;
    finish-first:awaiting-release)
      # The issue's own PR merged while it waited (the autopilot merge lane
      # lands PRs regardless of issue state); #4061 sat refused 2026-10-22.
      [ "$reason" = merged-pr ] || return 1
      ;;
    concluded:needs-triage|duplicate:needs-triage|wontfix:needs-triage|released:needs-triage)
      case "$reason" in reopened-by-human|prod-anomaly-recurred) ;; *) return 1 ;; esac
      ;;
    concluded:ready-for-agent)
      case "$reason" in conclusion-requeue|revert|failed-deploy|reopened-by-human|main-red-revert|continuation-requeue) ;; *) return 1 ;; esac
      ;;
  esac
  return 0
}


# issue_transition <issue> <state-label> <reason> [state-merge-filter] [skip-label-write] [issue-json] [source-issue] [open-issue]
# Keep state JSON and GitHub stage labels serialized by state_merge's lock.
# GitHub and local disk cannot share a transaction; a failed label write rolls
# the local snapshot back, and HEALTH reports any remote drift it cannot undo.
# skip-label-write is for callers that already know the destination label is set.
issue_transition() (
  local n="${1:-}" to="${2:-}" reason="${3:-}" patch="${4:-.}" skip_label_write="${5:-0}" intake_json="${6:-}" source_issue="${7:-}" open_issue="${8:-0}" expected_hold="${9:-}" lock_mode="${10:-}" f before from add_label label restore_status=0 transition_lock_fd release_hold_overlay=0
  local had_state=0 requeue_epoch started_epoch merged_epoch merged_at reason_file requeue_transition=0 hold_json write_kind="label write"
  local -a add_labels=() edit_args=() api_args=() issue_labels=()
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || { echo "issue_transition: valid issue number required" >&2; return 64; }
  [ -n "$reason" ] || { echo "issue_transition: reason required for #$n -> $to" >&2; return 64; }
  [[ "$skip_label_write" == 0 || "$skip_label_write" == 1 ]] || { echo "issue_transition: skip-label-write must be 0 or 1 for #$n" >&2; return 64; }
  [[ "$open_issue" == 0 || "$open_issue" == open ]] || { echo "issue_transition: open-issue must be 0 or open for #$n" >&2; return 64; }
  if [ "$open_issue" = open ] && [ "$skip_label_write" = 1 ]; then
    echo "issue_transition: reopening cannot skip the remote label write for #$n" >&2
    return 64
  fi
  if [ "$open_issue" = open ] && ! jq -e '((.state // "") | ascii_downcase) == "closed" and (.labels | type == "array")' <<< "$intake_json" >/dev/null 2>&1; then
    echo "issue_transition: reopening requires a closed issue snapshot with labels for #$n" >&2
    return 64
  fi
  issue_transition_state_is_valid "$to" || { echo "issue_transition: unknown target state '$to' for #$n" >&2; return 64; }
  if [[ "$reason" == close-reconcile:* ]] && ! jq -e --arg issue "$n" '
    (.number | tostring) == $issue and ((.state // "") | ascii_downcase) == "closed" and
    ((.labels | type) == "array" or (.labels.nodes | type) == "array")
  ' <<< "$intake_json" >/dev/null 2>&1; then
    echo "issue_transition: close reconciliation requires a closed issue snapshot for #$n" >&2
    return 64
  fi

  f="$(state_file "$n")" || return 1
  mkdir -p -- "$STATE_DIR" || return 1
  if [ "$lock_mode" != __issue_transition_lock_held ]; then
    exec {transition_lock_fd}>"$f.lock" || { echo "issue_transition: could not open state lock for #$n" >&2; return 1; }
    flock -x "$transition_lock_fd" || { echo "issue_transition: could not lock state for #$n" >&2; return 1; }
  fi
  [ -f "$f" ] && had_state=1
  before="$(state_read "$n")" || return 1
  if [ -n "$expected_hold" ] && ! jq -e --argjson expected "$expected_hold" '.state == "on-hold" and (.hold | del(.aging_window)) == ($expected | del(.aging_window))' <<< "$before" >/dev/null; then
    echo "issue_transition: hold for #$n changed before release; retry from the current hold" >&2
    return 1
  fi
  if ! from="$(jq -r '.state // "untracked"' <<< "$before" 2>/dev/null)"; then
    echo "issue_transition: invalid state JSON for #$n" >&2
    return 1
  fi
  if [ "$from" = on-hold ] && [ "$to" = awaiting-release ] && [ "$reason" = ops-acceptance-passed ]; then
    jq -e '
      .ops_acceptance_after_release.required == true
      and .ops_acceptance_after_release.status == "passed"
      and (.deployed_sha // "") != ""
      and .ops_acceptance_after_release.release_sha == .deployed_sha
      and (.ops_acceptance_after_release.evidence // "" | length > 0)
    ' <<< "$before" >/dev/null 2>&1 || {
      echo "issue_transition: refusing ops acceptance release for #$n without evidence for the deployed SHA" >&2
      return 1
    }
  fi
  if jq -e '.tracker_parent == true or .state == "tracker"' <<< "$before" >/dev/null 2>&1; then
    case "$to" in
      needs-triage|needs-info|ready-for-agent|ready-for-human|needs-owner|checks-blocked|needs-advisor|needs-recut|awaiting-release|awaiting-pipeline-sync|awaiting-pipeline-health)
        echo "issue_transition: refused tracker parent #$n -> active state $to" >&2
        return 1
        ;;
    esac
  fi
  if ! issue_transition_allowed "$from" "$to" "$reason"; then
    echo "issue_transition: refused #$n $from -> $to (reason=$reason)" >&2
    return 1
  fi
  if [ "$to" != on-hold ] && [ "$from" != on-hold ]; then
    case "$to:$reason" in
      concluded:conclude:*|concluded:close-*|duplicate:close-*|duplicate:conclude:*|\
      finish-first:close-*|finish-first:conclude:*|\
      wontfix:close-*|wontfix:conclude:*|\
      awaiting-release:merged-pr|\
      ready-for-agent:hold-requeue|\
      ready-for-agent:revert|ready-for-agent:failed-deploy|ready-for-agent:reopened-by-human|ready-for-agent:main-red-revert)
        # A PR merged to main ends the held episode; releasing the hold through
        # state_requeue first stamped requeued_at after the merge (2026-10-09).
        # Explicit hold requeue also clears a stale remote label after local state advanced.
        release_hold_overlay=1
        ;;
    esac
    if [ "$DRY_RUN" != 1 ] && is_on_hold "$n" \
      && [ "${ISSUE_LABEL_VIEW_STATE[$n]:-}" != failed ] \
      && [ "$release_hold_overlay" != 1 ]; then
      echo "issue_transition: refused held #$n $from -> $to (reason=$reason)" >&2
      return 1
    fi
  fi
  if [ "$to" = concluded ] && [[ "$reason" == conclude:* ]]; then
    requeue_epoch="$(agent_epoch "$(jq -r '.requeued_at // empty' <<< "$before")" 2>/dev/null || echo 0)"
    started_epoch="$(agent_epoch "$(jq -r '.run.implement_started_at // empty' <<< "$before")" 2>/dev/null || echo 0)"
    # Only deployed conclusions may use the exact PR's actual merge evidence.
    # run.merged_at is handoff time and can be newer than a human requeue.
    reason_file="$(jq_arg_file "$reason")" || return 1
    merged_at="$(jq -r --rawfile reason "$reason_file" '
      select($reason == "conclude:deployed" and .run.outcome == "merged" and .deploy_state == "deployed"
        and (.run.evidence.merged_pr.number | tostring) == (.run.evidence.pr_number | tostring)
        and (.run.evidence.merged_pr.merge_sha // "") != "")
      | .run.evidence.merged_pr.merged_at // empty
    ' <<< "$before")" || merged_at=""
    rm -f -- "$reason_file"
    merged_epoch="$(agent_epoch "$merged_at" 2>/dev/null || echo 0)"
    if [[ "$requeue_epoch" =~ ^[0-9]+$ && "$started_epoch" =~ ^[0-9]+$ ]] \
      && (( requeue_epoch > 0 && (started_epoch == 0 || started_epoch < requeue_epoch) && merged_epoch <= requeue_epoch )); then
      echo "issue_transition: refused stale conclusion for #$n after requeue" >&2
      return 1
    fi
  fi
  case "$reason" in *requeue*|revert|failed-deploy|main-red-revert) requeue_transition=1 ;; esac

  if declare -F roadmap_ensure_issue_parent >/dev/null; then
    roadmap_ensure_issue_parent "$n" "$to" "$intake_json" "$source_issue" || return $?
  fi

  case "$to:$reason" in
    concluded:conclude:deployed) add_labels=(concluded released) ;;
    concluded:conclude:duplicate) add_labels=(concluded duplicate) ;;
    concluded:close-reconcile:deployed) add_labels=(concluded released) ;;
    concluded:*) add_labels=(concluded) ;;
    tracker:*) add_labels=() ;;
    *) add_labels=("$to") ;;
  esac
  [ "$DRY_RUN" = 1 ] || ensure_state_labels
  local target_json
  target_json="$(jq -cn --arg state "$to" '$state')" || return 1
  local filter="$patch | .state = $target_json"
  if { [ "$from" = on-hold ] || [ "$release_hold_overlay" = 1 ]; } \
    && [ "$to" != on-hold ] && ! [[ "$patch" == *".hold ="* ]]; then filter+=" | .hold = null"; fi
  if [ "$requeue_transition" = 1 ]; then
    state_merge_attempt_transition "$n" "$filter" __issue_transition_lock_held || {
      echo "issue_transition: state write failed for #$n" >&2
      return 1
    }
  elif ! state_merge "$n" "$filter" __issue_transition_lock_held; then
    echo "issue_transition: state write failed for #$n" >&2
    return 1
  fi
  if [ "$to" = on-hold ]; then
    hold_json="$(state_read "$n" | jq -c '.hold // {}')" || return 1
    if hold_durable_record_valid "$hold_json"; then
      if ! jq -e '.durable_record == true' <<< "$hold_json" >/dev/null 2>&1; then
        if ! hold_durable_record_publish "$n" "$hold_json" \
          || ! state_merge "$n" '.hold.durable_record = true' __issue_transition_lock_held; then
          if [ "$had_state" = 1 ]; then
            printf '%s\n' "$before" > "$f.tmp" && mv -f -- "$f.tmp" "$f" || restore_status=2
          else
            rm -f -- "$f" "$f.tmp" || restore_status=2
          fi
          echo "issue_transition: durable hold record failed for #$n; state rollback status=$restore_status" >&2
          return 1
        fi
      fi
    elif jq -e '.durable_record == true' <<< "$hold_json" >/dev/null 2>&1; then
      state_merge "$n" '.hold.durable_record = false' __issue_transition_lock_held || return 1
    fi
  fi
  [ "$skip_label_write" != 1 ] || return 0

  edit_args=(gh issue edit "$n" --repo "$REPO")
  for label in "${ALL_STATE_LABELS[@]}" on-hold; do
    [ "$label" != on-hold ] || [ "$from" = on-hold ] || [ "$release_hold_overlay" = 1 ] || continue
    local keep=0
    for add_label in "${add_labels[@]}"; do [ "$label" != "$add_label" ] || keep=1; done
    [ "$keep" = 1 ] || edit_args+=(--remove-label "$label")
  done
  edit_args+=(--remove-label in-progress)
  [ "$reason" != conclude:deployed ] || edit_args+=(--remove-label evidence-gate)
  for add_label in "${add_labels[@]}"; do edit_args+=(--add-label "$add_label"); done
  if [ "$open_issue" = open ]; then
    # Reopen and stage labels share one remote PATCH, so failure cannot leave a partially reopened ticket.
    write_kind="open and label write"
    api_args=(gh api --method PATCH "repos/$REPO/issues/$n" -f state=open)
    while IFS= read -r label; do
      [ -n "$label" ] || continue
      case "$label" in
        in-progress) continue ;;
        evidence-gate) [ "$reason" != conclude:deployed ] || continue ;;
        on-hold)
          if [ "$from" != on-hold ] && [ "$release_hold_overlay" != 1 ]; then
            issue_labels+=("$label")
            continue
          fi
          ;;
      esac
      local state_label is_state_label=0
      for state_label in "${ALL_STATE_LABELS[@]}"; do [ "$label" != "$state_label" ] || is_state_label=1; done
      if [ "$is_state_label" = 0 ]; then issue_labels+=("$label"); fi
    done < <(jq -r '.labels[]?.name // empty' <<< "$intake_json")
    issue_labels+=("${add_labels[@]}")
    for label in "${issue_labels[@]}"; do api_args+=(-f "labels[]=$label"); done
    guarded_write "${api_args[@]}" || restore_status=$?
  elif [ "$requeue_transition" = 1 ]; then
    TICKET_STAGE_WRITE_KIND=requeue guarded_write "${edit_args[@]}" || restore_status=$?
  else
    guarded_write "${edit_args[@]}" || restore_status=$?
  fi
  if [ "$restore_status" -ne 0 ]; then
    if [ "$had_state" = 1 ]; then
      printf '%s\n' "$before" > "$f.tmp" && mv -f -- "$f.tmp" "$f" || restore_status=2
    else
      rm -f -- "$f" "$f.tmp" || restore_status=2
    fi
    echo "issue_transition: $write_kind failed for #$n; state rollback status=$restore_status" >&2
    return 1
  fi
  [ "$open_issue" != open ] || issue_label_cache_invalidate || true
  return 0
)


# Reconcile GitHub-side closes that bypassed pipeline close callers. The
# snapshot is the authority for close reason and labels; issue_transition
# remains the only durable-state and stage-label writer.
issue_reconcile_closed_state() {
  local n="$1" issue_json="$2" file state_json from close_reason closed_at target transition_reason labels patch transition_snapshot
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || return 64
  if ! jq -e --arg issue "$n" '
    (.number | tostring) == $issue and ((.state // "") | ascii_downcase) == "closed" and
    ((.labels | type) == "array" or (.labels.nodes | type) == "array") and
    ((.stateReason // .state_reason // null) == null or (.stateReason // .state_reason | type) == "string")
  ' <<< "$issue_json" >/dev/null 2>&1; then
    echo "issue_reconcile_closed_state: invalid closed issue snapshot for #$n" >&2
    return 1
  fi
  file="$(state_file "$n")" || return 1
  [ -f "$file" ] || return 0
  state_json="$(state_read "$n")" || return 1
  from="$(jq -r '.state // "untracked"' <<< "$state_json")" || return 1
  case "$from" in concluded|duplicate|wontfix|released|closed) return 0 ;; esac

  close_reason="$(jq -r '(.stateReason // .state_reason // "UNKNOWN") | ascii_upcase' <<< "$issue_json")" || return 1
  closed_at="$(jq -r '.closedAt // .closed_at // empty' <<< "$issue_json")" || return 1
  labels="$(jq -r 'if (.labels | type) == "array" then .labels[]? | if type == "string" then . else .name end else .labels.nodes[]?.name end' <<< "$issue_json")" || return 1
  ISSUE_LABEL_VIEW_STATE[$n]=loaded
  ISSUE_LABEL_VIEW_LABELS[$n]="$labels"
  ISSUE_LABEL_VIEW_AT[$n]="$SECONDS"
  ISSUE_LABEL_VIEW_ERROR[$n]=""

  if grep -Fqx duplicate <<< "$labels"; then
    target=duplicate; transition_reason=close-reconcile:duplicate
  elif [ "$close_reason" = NOT_PLANNED ]; then
    target=wontfix; transition_reason=close-reconcile:not-planned
  elif [ "$(jq -r '.released // false' <<< "$state_json")" = true ]; then
    target=concluded; transition_reason=close-reconcile:deployed
  else
    target=concluded; transition_reason=close-reconcile:completed
  fi
  patch="$(jq -cn --arg state_reason "$close_reason" --arg closed_at "$closed_at" \
    '{state_reason:$state_reason,closed_at:(if $closed_at == "" then null else $closed_at end),reconciled_at:(now|todate)}')" || return 1
  transition_snapshot="$(jq -c '
    .labels = (if (.labels | type) == "array" then .labels else [.labels.nodes[]?] end)
  ' <<< "$issue_json")" || return 1
  issue_transition "$n" "$target" "$transition_reason" ".closed_issue_reconciliation = $patch" 0 "$transition_snapshot"
}


# Apply attempt changes and re-aim saved pipeline work in the same state write.
# Invalid or partial checkpoints start fresh instead of blocking dispatch.
state_merge_attempt_transition() {
  local n="$1" filter="$2" lock_mode="${3:-}"
  local alignment='if .pipeline_system.enabled == true then
    if ((.pipeline_system.resume_artifact_sha // "") | test("^[0-9a-f]{40,64}$"))
    then .pipeline_system.resume_artifact_attempt = (.attempts // 0)
    else del(.pipeline_system.resume_artifact_sha, .pipeline_system.resume_artifact_attempt)
    end
  else . end'
  state_merge "$n" "$filter | $alignment" "$lock_mode"
}


state_attempts() { state_read "$1" | jq -r '.attempts // 0'; }


# state_requeue <n> -- start a new implement episode for an issue.
# Keep the state reset and queue-label transition together so a requeue cannot
# leave the old conclude rung attached to fresh work.
# state_requeue N [release-hold]: release-hold also removes on-hold in the same write, the
# hold guard's release transition; without it a held issue's requeue is suppressed.
state_requeue() {
  local n="$1" release_hold="${2:-}" reason="${3:-}" patch="${4:-.}" expected_hold="${5:-}" initial initial_json filter child_status=1
  [ -n "$reason" ] || { [ "$release_hold" = release-hold ] && reason=hold-requeue || reason=pipeline-requeue; }
  [[ "$n" =~ ^[0-9]+$ ]] || { echo "state_requeue: invalid issue number '$n'" >&2; return 64; }
  if recut_parent_has_open_child "$n" "${OPEN_ISSUE_BLOCKER_GRAPH_JSON:-[]}" "" 0; then child_status=0; else child_status=$?; fi
  case "$child_status" in
    0)
      if [ "$release_hold" = release-hold ]; then
        retire_tracker_parent "$n"
        return $?
      fi
      echo "state_requeue: keeping parent #$n out of ready-for-agent while children remain open" >&2
      return 0
      ;;
    2) echo "state_requeue: cannot verify children for #$n; refusing ready-for-agent" >&2; return 1 ;;
  esac
  initial="$(model_policy initial-step)" || return 1
  initial_json="$(jq -nc --arg step "$initial" '$step')" || return 1
  filter="$patch | .model_policy as \$old | .attempts = 0 | .requeued_at = (now | todate) | .model_policy = {unit:\"implement\",step:$initial_json,history:((\$old.history // []) + (if ((\$old.unit // \"\") != \"\" or (\$old.step // \"\") != \"\") then [{unit:\$old.unit,step:\$old.step,failure:\$old.failure,advisor_decision:\$old.advisor_decision,completed_at:(now|todate),requeued:true}] else [] end))}"
  [ "$release_hold" != release-hold ] || filter+=" | .hold = null | .hold_released_at = (now | todate)"
  issue_transition "$n" ready-for-agent "$reason" "$filter" 0 "" "" 0 "$expected_hold" || return $?
  if [ "$release_hold" = release-hold ] && [[ "${ZF_AGENT_NAME:-}" =~ ^(supervisor|hand-) ]]; then
    local resume_row
    resume_row="$(jq -cn --argjson issue "$n" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" '
      {schema_version:1,record_type:"event",event_type:"attempt-resumed",issue:$issue,ts:$ts,
       retry_reason:"supervisor-resume",event_id:($ts+"|resume|"+($issue|tostring))}')" || return 1
    efficiency_metrics_append_rows "$resume_row" || return 1
  fi
}


refund_implement_attempt() {
  state_merge_attempt_transition "$1" '.attempts = (if (.attempts // 0) > 0 then (.attempts - 1) else 0 end)'
}


state_bump_attempts() { state_merge "$1" '.attempts = ((.attempts // 0) + 1)'; }

# state_unbump_attempts: give back one attempt, floored at zero. Only for a
# failure the TICKET did not cause -- a provider-wide quota window is the
# case this exists for (note_provider_quota_exhausted). Never use it to forgive
# a run that actually tried and failed; the give-up budget is what stops a
# ticket cycling forever, and quietly refunding real attempts would remove it.
state_unbump_attempts() { state_merge_attempt_transition "$1" '.attempts = (if (.attempts // 0) > 0 then (.attempts - 1) else 0 end)'; }


# --- concluding a run: an account of itself, never a park with a label ------
# docs/agents/issue-pipeline.md "Every run concludes with an account of
# itself" -- maintainer ruling, verbatim, 2026-09-15: [...]
#  Built here
# (2026-09-15) by run-implement.sh's own owner, for run-implement.sh's own
# need -- the two primitives the doc specifies and marks "routed, not made
# [t]here": record_run_decision (an append-only log entry) and conclude_run
# (the one guarded terminal). Scope, stated plainly, as of the 2026-09-15
# build: this did NOT rewrite give_up_on_issue() (used, unchanged, by
# run-triage.sh/run-advisor.sh/run-recut.sh -- files that session did not
# own or test) or wire rung tracking into those legs' own dispatch code (the
# doc's own routing: "run-advisor.sh/run-recut.sh/run-triage.sh -- one
# record_run_decision call at each verdict", not built there).
# run-implement.sh calls conclude_run directly at its own terminal points
# instead of calling give_up_on_issue(). Since converted (2026-09-15, same
# night): run-advisor.sh's own fail_attempt() also calls conclude_run
# directly now, same as run-implement.sh -- see run-advisor.sh's fail_attempt
# for its own not-completed guard. give_up_on_issue() is still live: called
# by run-triage.sh and run-recut.sh (both still give-up-after-3, at their own
# gate-side terminal -- ownership/scope resolution, not an in-flight stop),
# and by run-implement.sh's own fail_attempt() up until this same commit,
# whose 4-attempt terminal was the one give_up_on_issue() call site missed
# when the rest of this file converted (see run-implement.sh's fail_attempt()
# for the fix and #1221 for the live incident it caused).

# record_run_decision <n> <by> <what> [forced] -- appends one entry to the
# run's decision log (.run.decisions[]), never overwrites a prior one.
# $by: advisor|wrapper|reviewer|recut (who actually decided, on the
# maintainer's behalf). $forced ("1"/"0", default "0"): was this decision
# forced by a cap/fault/missing capability rather than chosen.
record_run_decision() {
  local n="$1" by="$2" what="$3" forced="${4:-0}" entry forced_json what_file
  [ "$forced" = "1" ] && forced_json=true || forced_json=false
  # $what is untrusted-size: callers splice a model's own reasoning_md/
  # decision_md into it (e.g. run-advisor-batch.sh's duplicate-verdict call)
  # -- jq_arg_file() (above), not --arg, so a long one never risks argv.
  what_file="$(jq_arg_file "$what")"
  entry="$(jq -n --arg by "$by" --rawfile what "$what_file" --argjson forced "$forced_json" \
    '{at: (now | todate), by: $by, what: $what, forced: $forced}')"
  rm -f "$what_file"
  state_merge "$n" ".run.entered_at = (.run.entered_at // (now | todate)) | .run.decisions = ((.run.decisions // []) + [$entry])"
}


# recorded_failure_reason_from_state <state-json> -- prefer the current guard
# or failure reason, then the persisted review/failure evidence.
recorded_failure_reason_from_state() {
  jq -r '
    [.guard_reason, .last_failure_reason,
     .model_policy.failure.normalized_reason, .model_policy.failure.reason,
     .last_failure_tail, .review_verdict]
    | map(select(type == "string" and length > 0))
    | first // ""
  ' <<< "$1"
}
