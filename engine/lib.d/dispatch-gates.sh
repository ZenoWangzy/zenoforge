_AGENT_LIB_DIR="${_AGENT_LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}" # a module sourced without lib.sh (land snapshot) still finds the lib dir

# 2026-09-12 issue #1098: the triage model returned risk_class=P2 together
# with state=ready-for-agent in the SAME response — directly contradicting
# prompts/triage.md's own rule that ready-for-agent requires P0/P1. run-
# triage.sh applied the label verbatim; the only thing that stopped an
# unauthorized implement dispatch was a human manually flipping the
# AGENT_PIPELINE repo variable back to `triage`. The autonomy set (which
# risk_class/level/phase combinations may ever reach ready-for-agent) is the
# maintainer's safety boundary, and enforcing it with prose inside a prompt
# measures under 2% compliance (a standing project ruling on
# this exact pattern: enforce rules with hooks, not prose) — so it is
# re-derived here in code from the same three fields the prompt's own rule
# is defined over, independent of whatever state the model claims.
#
# Only ever narrows: a $state that isn't already ready-for-agent is returned
# unchanged, because this gate exists to catch an over-admission, never to
# grant autonomy the model itself withheld. Unrecognized or empty risk_class/
# level fails closed (falls through to the `*` case below), the same
# fail-closed shape run-triage.sh already uses for a garbage/unset
# AGENT_PHASE. Phase 3's L2 admission still requires the GitNexus impact
# check described in prompts/triage.md step 5 — that check runs inside the
# model's own triage pass (it has no way to invoke gitnexus from here), so
# this function only re-checks the level/phase shape, not the impact result.
# Same fail-closed pattern run-triage.sh has always used for AGENT_PHASE:
# unset, unreadable, or any value other than 2/3 falls back to 2, the
# conservative default, never 3. Shared (2026-09-12 review, item 1) so
# run-triage.sh's per-run read and issue-pipeline.sh's dispatch-time gate
# recomputation (section (c), below) read this exactly the same way and can
# never drift onto two different fallback values.
read_agent_phase() {
  local phase
  phase="$(gh variable get AGENT_PHASE --repo "$REPO" 2>/dev/null || echo 2)"
  case "$phase" in
    2|3) echo "$phase" ;;
    *) echo 2 ;;
  esac
}


enforce_autonomy_gate() {
  local state="$1" risk_class="$2" level="$3" phase="$4"
  if [ "$state" != "ready-for-agent" ]; then
    echo "$state"
    return 0
  fi
  case "$risk_class" in
    P0|P1) ;;
    *) echo "ready-for-human"; return 0 ;;
  esac
  case "$level" in
    L0|L1) ;;
    L2) [ "$phase" = "3" ] || { echo "ready-for-human"; return 0; } ;;
    *) echo "ready-for-human"; return 0 ;;
  esac
  echo "ready-for-agent"
}


# 2026-09-13 issues #1130-#1137: a Mac-side /wayfinder -> to-spec -> to-tickets
# run stamps ready-for-agent on every ticket it creates, with no triage ever
# having run -- these issues have NO state file at all. issue-pipeline.sh's
# section (c) used to read risk_class/level straight off state_read()'s
# default ({"attempts":0}, both fields empty) and hand that to
# enforce_autonomy_gate(), which fails closed on empty fields exactly the
# same way it fails closed on a genuinely oversized P2/L3 issue -- both
# landed on ready-for-human plus an email telling the maintainer something was
# "outside the permitted range" and asking him to adjust permissions, which
# is not actionable for an issue nobody ever measured. "Not yet measured" and
# "measured and too big" are different situations and need different
# destinations; this function is what tells them apart.
#
# Deliberately three-way, not a boolean: "no state file" and "a state file
# that exists but was never classified" (an attempts-only file left by a
# failed prior triage or implement-dispatch attempt -- state_bump_attempts()
# only ever touches .attempts, never risk_class/level) are both genuinely
# UNmeasured and route the same way (see issue-pipeline.sh's call site). A
# state file that fails to parse as JSON at all is real corruption and is
# kept as its own "malformed" outcome on purpose, NOT folded into
# "unmeasured": routing corruption straight back into needs-triage risks (a)
# state_merge()'s own read-modify-write of the SAME file next time triage
# runs on it, under this script's `set -e -o pipefail`, and (b), if the
# corruption is a symptom of a real bug in whatever wrote it rather than a
# one-off, silently re-triaging the same broken file forever with no human
# ever told -- exactly the loop this whole gate exists to avoid. "Malformed"
# instead falls through to the existing gate unchanged: empty risk_class/
# level (the same defaults a missing key already produced before this fix)
# hit enforce_autonomy_gate's `*` branch, landing on ready-for-human -- an
# existing terminal state, not a new silent loop.
# A state file that DOES carry both keys is "measured" regardless of
# whether the values are admissible -- that judgment is enforce_autonomy_
# gate's job, not this function's; garbage values there already fail closed.
triage_unmeasured_issue_ids() {
  python3 -c '
import json, pathlib, sys
states = pathlib.Path(sys.argv[1])
for issue in sys.stdin.read().split():
    if not issue.isdecimal() or int(issue) <= 0:
        continue
    path = states / (issue + ".json")
    if not path.is_file():
        print(issue)
        continue
    try:
        state = json.loads(path.read_text())
    except (OSError, ValueError):
        continue  # Same malformed exclusion as triage_classification_status.
    if not isinstance(state, dict) or not ("risk_class" in state and "level" in state):
        print(issue)
' "$STATE_DIR" <<< "$1"
}


triage_classification_status() {
  local f="$1"
  [ -f "$f" ] || { echo unmeasured; return 0; }
  jq -e . "$f" >/dev/null 2>&1 || { echo malformed; return 0; }
  if jq -e 'has("risk_class") and has("level")' "$f" >/dev/null 2>&1; then
    echo measured
  else
    echo unmeasured
  fi
}


# --- 2026-09-12: bounded-concurrency scheduler helpers ----------------------
# issue-pipeline.sh dispatches stage work via `systemd-run --user --unit
# zf-<stage>-<N> --collect` instead of running a wrapper script inline.
# The transient units ARE the ledger — no PID file, no lease file, no
# stale-PID reaper: `--collect` releases a unit's registration the instant
# the dispatched process exits, however it exits (normal, killed, crashed),
# which is exactly the bookkeeping a hand-rolled PID file would have to
# reimplement and could get wrong.

# "Is issue $2 already running at stage $1?" First-class in candidate
# selection for all three stages, not an afterthought: an implement run
# doesn't push for up to 2 hours and a triage run doesn't clear
# needs-triage until late in run-triage.sh, so a file-based check (an open
# PR, a stale label) can't see a still-running attempt — only the live unit
# can. Without this, a later tick would re-dispatch the same issue on top of
# an attempt that is merely still running, not stuck.
#
# 2026-09-16 fix: this used to be a bare `systemctl --user is-active
# --quiet ...`, so systemctl itself failing to even reach the user service
# manager (session bus down, XDG_RUNTIME_DIR missing) returned the SAME
# non-zero exit as "confirmed not active" -- every caller of this function
# (merge_agent_pr()'s two active-unit checks, the sweeper's CONFLICTING/
# active checks, every issue-pipeline.sh candidate loop, sweep-brief-
# banners.sh) uses the same direction, "active blocks the action", so an
# unreadable answer now fails closed the same way: treated as active,
# never treated as confirmed-inactive.
#
# Distinguishing the two needs no error-text pattern list (fragile across
# systemd versions): measured live on this box, `--quiet` suppresses
# is-active's normal state output entirely, success or not -- a query for a
# unit that plainly is not active prints NOTHING on stdout OR stderr (just
# a non-zero exit); a query that cannot even reach the service manager
# (session bus down) prints "Failed to connect ..." on stderr regardless of
# --quiet. So ANY output at all on a non-zero exit already means "systemctl
# itself is complaining", not "confirmed inactive" -- checking for that is
# simpler and more robust than matching the exact wording of a failure.
agent_memory_available_kib() {
  awk '$1 == "MemAvailable:" { print $2; found=1; exit } END { if (!found) exit 1 }' /proc/meminfo
}


agent_memory_floor_allows() {
  local stage="$1" floor_mib="${2:-2048}" available_kib floor_kib
  floor_kib=$((floor_mib * 1024))
  if ! available_kib="$(agent_memory_available_kib)" || [[ ! "$available_kib" =~ ^[0-9]+$ ]]; then
    echo "issue-pipeline: refusing $stage dispatch: cannot read MemAvailable (${floor_mib}MiB floor)" >&2
    return 1
  fi
  if [ "$available_kib" -lt "$floor_kib" ]; then
    echo "issue-pipeline: refusing $stage dispatch: MemAvailable $((available_kib / 1024))MiB is below ${floor_mib}MiB floor" >&2
    return 1
  fi
}


agent_implement_dispatch_resources_allow() {
  # Ruling crash-guard-is-memory-not-load: implement admission is memory only.
  # On 2026-10-08 a 4*nproc load check refused every implement tick at load
  # 50-62 (hand-agent tests and landing suites) with 5.7 GB free. Hand
  # dispatch keeps its own load refusal in night/dispatch.sh.
  agent_memory_floor_allows implement 3072
}


triage_single_unit_active() {
  local out
  if out="$(systemctl --user is-active --quiet "${UNIT_PREFIX_TRANSIENT}-triage-$1" 2>&1)"; then
    return 0
  fi
  if [ -n "$out" ]; then
    echo "triage_single_unit_active: systemctl --user is-active could not be queried for ${UNIT_PREFIX_TRANSIENT}-triage-$1 -- treating as ACTIVE (fail-closed): $out" >&2
    return 0
  fi
  return 1
}


triage_batch_unit_active() {
  local out
  if ! out="$(systemctl --user list-units --no-legend --plain "${UNIT_PREFIX_TRANSIENT}-triage-batch.service" 2>&1)"; then
    if [ -n "$out" ]; then
      echo "triage_batch_unit_active: systemctl --user list-units could not be queried -- treating batch as ACTIVE (fail-closed): $out" >&2
      return 0
    fi
    return 1
  fi
  printf '%s\n' "$out" | awk -v unit="${UNIT_PREFIX_TRANSIENT}-triage-batch.service" '$1 == unit { found=1 } END { exit !found }'
}


stage_unit_active() {
  local out
  if [ "$1" = triage ] && [ "$2" = batch ]; then
    triage_batch_unit_active
    return $?
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    # A host without systemd (the cihost macOS CI runner, issue #3869 family) has no
    # transient units at all: nothing can be active, so requeue must proceed.
    # Treating the missing binary as a failed query kept every Mac-hosted requeue
    # pinned on-hold and red the concluded-root-unblock suite.
    return 1
  fi
  if out="$(systemctl --user is-active --quiet "${UNIT_PREFIX_TRANSIENT}-$1-$2" 2>&1)"; then
    return 0
  fi
  if [ -n "$out" ]; then
    echo "stage_unit_active: systemctl --user is-active could not be queried for ${UNIT_PREFIX_TRANSIENT}-$1-$2 -- treating as ACTIVE (fail-closed), not confirmed-inactive: $out" >&2
    return 0
  fi
  if [ "$1" = triage ] && [ "$2" != batch ] && triage_batch_issue_active "$2"; then
    return 0
  fi
  return 1
}


# A batch is one transient unit, so its issue members need an explicit active
# snapshot for implement selection and single-issue triage checks. The file is
# only authoritative while the batch unit is active; a killed run cannot leave
# tickets stuck behind a stale marker.
triage_batch_issue_active() {
  local n="$1" marker="$AGENT_HOME/triage-batch-active.json"
  [ -f "$marker" ] || return 1
  jq -e --argjson n "$n" 'any(.issues[]?; . == $n)' "$marker" >/dev/null 2>&1 || return 1
  triage_batch_unit_active
}


# Validate one triage result against the checked-in schema using the schema's
# current required/types/enums/items rules. Missing or malformed external
# judgment is normalized to false on the validation copy, so it cannot strand
# an otherwise valid ticket outside the implement lane. jq remains the only
# runtime dependency.
triage_result_matches_schema() {
  local result_file="$1" schema_file="${2:-$(zf_config_file prompts/triage.schema.json)}"
  jq -e --slurpfile schema "$schema_file" '
    def has_external_judgment:
      (.external_deliverable | type) == "object"
      and (.external_deliverable.required | type) == "boolean"
      and (.external_deliverable.location | type) == "string"
      and (.external_deliverable.reason | type) == "string"
      and (.external_deliverable | keys | sort) == ["location", "reason", "required"];
    def matches($s):
      . as $v
      | ((($s.type // null) == null) or
          (if $s.type == "integer" then
             ($v | type) == "number" and $v == ($v | floor)
           else
             ($v | type) == $s.type
           end))
      and ((($s.enum // null) == null) or any($s.enum[]; . == $v))
      and (if $s.minimum == null then true
           else ($v | type) == "number" and $v >= $s.minimum end)
      and (if ($v | type) == "object" then
             all(($s.required // [])[]; . as $key | ($v | has($key)))
             and (if $s.additionalProperties == false then
                    all(($v | keys[]); . as $key | (($s.properties // {}) | has($key)))
                  else true end)
             and all((($s.properties // {}) | to_entries[]);
                     . as $property |
                     if ($v | has($property.key)) then
                       $v[$property.key] | matches($property.value)
                     else true end)
           elif ($v | type) == "array" then
             if $s.items == null then true
             else all($v[]; matches($s.items)) end
           else true end);
    . as $input
    | (if has_external_judgment then $input
       else $input + {external_deliverable:{required:false,location:"",reason:""}}
       end) as $result
    | ($schema[0] as $contract | $result | matches($contract))
  ' "$result_file" >/dev/null 2>&1
}


# Stage occupancy for the cap check: how many zf-<stage>-* units are
# currently loaded at all (active, activating, or deactivating)? `--collect`
# means a finished unit is gone from this count the instant it exits, not
# lingering as "inactive" — the ledger self-cleans, nothing here prunes it.
#
# 2026-09-16 fix: the old `2>/dev/null | wc -l` discarded systemctl's own
# failure, so a session-bus outage read as "zero units loaded" -- the
# scheduler's cap arithmetic (cap_slots_remaining()) then saw every stage
# as empty and over-dispatched into an outage it could not even observe.
# Unlike stage_unit_active() above, `list-units` genuinely can print
# nothing on a NORMAL success too (zero matching units, the common case) --
# so the signal here is the exit code, not output emptiness: measured live,
# a real zero-match query exits 0, only a genuine manager-unreachable
# failure exits non-zero. On that failure this prints a huge sentinel count
# instead of 0: cap_slots_remaining() clamps `cap - count` at 0, so every
# caller sees zero free slots (fail closed) with no call-site change
# needed.
stage_unit_count() {
  local out
  if ! out="$(systemctl --user list-units --no-legend --plain "${UNIT_PREFIX_TRANSIENT}-$1-*" 2>&1)"; then
    echo "stage_unit_count: systemctl --user list-units could not be queried for stage $1 -- treating occupancy as FULL (fail-closed), not zero: $out" >&2
    echo 999999999
    return 1
  fi
  # `grep -c .` exits 1 when it counts zero lines. Zero running units is a
  # legitimate answer here, not an error, but that exit status used to be this
  # function's own -- and a BARE assignment (`x=$(stage_unit_count ...)`)
  # inherits the command substitution's status, so under `set -e` an idle
  # stage killed the caller outright. The five call sites in
  # issue-pipeline.sh survived only because they pass this through as an
  # ARGUMENT to cap_slots_remaining, where the outer command's status wins;
  # local metrics' bare-assignment site, so it was the one that died -- and
  # only on an idle stage, which is why this sat latent.
  # A real grep failure (exit 2+) still fails closed like the systemctl one
  # above; only the count-was-zero exit is absorbed.
  local count status=0
  # The autopilot release train runs as zf-release-train.service; it delegates to the release slice and is
  # not a release slot. Counting it made RELEASE_CAP=1 always full (2026-10-22: every candidate
  # gate=capacity slots-exhausted while only the train ran).
  count="$(printf '%s\n' "$out" | grep -vc -e '^$' -e "^${UNIT_PREFIX_TRANSIENT}-release-train\\.service")" || status=$?
  if [ "$status" -gt 1 ]; then
    echo "stage_unit_count: grep failed (exit $status) counting units for stage $1 -- treating occupancy as FULL (fail-closed), not zero" >&2
    echo 999999999
    return 1
  fi
  printf '%s\n' "${count:-0}"
}


# A freshness-blocked triage result stays in its current label. Keep it out of
# both triage selection pools until the shared GitNexus refresh window opens,
# so a priority:top ticket cannot consume the only slot on every timer tick.
triage_retry_deferred() {
  local n="$1" now="$2" retry_after
  [[ "$now" =~ ^[0-9]+$ ]] || return 1
  retry_after="$(state_read "$n" | jq -r '.triage_retry_after_epoch // 0')"
  [[ "$retry_after" =~ ^[0-9]+$ ]] || return 1
  [ "$retry_after" -gt "$now" ]
}


# Return the last three completed analyze exit codes only when all failed.
gitnexus_recent_analyze_failure_codes() {
  local memory_log="${1:-$AGENT_HOME/night/gitnexus-analyze-memory.tsv}"
  [ -r "$memory_log" ] || return 1
  awk -F '\t' '
    $1 == "run" {
      if ($7 ~ /^[0-9]+$/ && ($7 + 0) > 0) {
        codes = codes (codes == "" ? "" : ",") $7
        consecutive++
        if (consecutive > 3) {
          sub(/^[^,]*,/, "", codes)
          consecutive = 3
        }
      } else {
        codes = ""
        consecutive = 0
      }
    }
    END {
      if (consecutive >= 3) print codes
      else exit 1
    }
  ' "$memory_log"
}


# Record the first failed L2 freshness window for an unchanged issue. Return 0
# while its bounded deferral remains active, 1 after expiry, and 2 on state or
# clock failure.
triage_freshness_deferral_active() {
  local n="$1" issue_updated_at="$2" now="${3:-$(date +%s)}" prior_updated_at since updated_at_json age failure_codes
  TRIAGE_FRESHNESS_DEFERRAL_SKIP_REASON=""
  if failure_codes="$(gitnexus_recent_analyze_failure_codes)"; then
    TRIAGE_FRESHNESS_DEFERRAL_SKIP_REASON="last 3 GitNexus analyze runs failed (exit codes $failure_codes)"
    return 1
  fi
  [[ "$now" =~ ^[0-9]+$ && -n "$issue_updated_at" ]] || return 2
  prior_updated_at="$(state_read "$n" | jq -r '.triage_freshness_deferred_issue_updated_at // empty')" || return 2
  since="$(state_read "$n" | jq -r '.triage_freshness_deferred_since_epoch // empty')" || return 2
  if [ "$prior_updated_at" != "$issue_updated_at" ] || ! [[ "$since" =~ ^[0-9]+$ ]]; then
    since="$now"
    updated_at_json="$(jq -nc --arg value "$issue_updated_at" '$value')" || return 2
    state_merge "$n" ". + {triage_freshness_deferred_issue_updated_at: $updated_at_json, triage_freshness_deferred_since_epoch: $since}" || return 2
  fi
  age=$((now - since))
  (( age < TRIAGE_FRESHNESS_MAX_DEFER_SECONDS ))
}


# An unchanged issue stays out of the batch while its bounded deferral is
# active. Once expired, send it through triage with the L2 gate fail-closed.
triage_freshness_redefer_unchanged_issue() {
  local n="$1" issue_snapshot_file="$2" freshness_note="$3" issue_updated_at prior_updated_at live_issue_json live_updated_at now retry_after
  local active_status failure_codes
  [[ "$freshness_note" == "NOT confirmed"* ]] || return 1
  issue_updated_at="$(jq -r '.updatedAt // empty' "$issue_snapshot_file" 2>/dev/null)" || return 1
  [ -n "$issue_updated_at" ] || return 1
  prior_updated_at="$(state_read "$n" | jq -r '.triage_freshness_deferred_issue_updated_at // empty')"
  [ "$issue_updated_at" = "$prior_updated_at" ] || return 1
  if failure_codes="$(gitnexus_recent_analyze_failure_codes)"; then
    echo "run-triage-batch: #$n freshness deferral skipped: last 3 GitNexus analyze runs failed (exit codes $failure_codes); triaging with the phase-3 L2 gate closed" >&2
    return 1
  fi
  if ! live_issue_json="$(gh_timeout 30s issue view "$n" --repo "$REPO" --json updatedAt 2>/dev/null)"; then
    echo "run-triage-batch: #$n could not confirm unchanged issue version; keeping it in this batch" >&2
    return 1
  fi
  live_updated_at="$(jq -r '.updatedAt // empty' <<< "$live_issue_json" 2>/dev/null)" || return 1
  [ "$live_updated_at" = "$issue_updated_at" ] || return 1
  now="$(date +%s)" || return 1
  [[ "$now" =~ ^[0-9]+$ ]] || return 1
  if triage_freshness_deferral_active "$n" "$issue_updated_at" "$now"; then
    :
  else
    active_status=$?
    if [ "$active_status" -eq 1 ]; then
      echo "run-triage-batch: #$n freshness deferral expired; triaging with the phase-3 L2 gate closed" >&2
      return 1
    fi
    return 2
  fi
  retry_after=$((now + GITNEXUS_REFRESH_MIN_INTERVAL_SECONDS))
  state_merge "$n" ". + {triage_retry_after_epoch: $retry_after}" || return 2
  echo "run-triage-batch: #$n unchanged after prior L2 freshness deferral; freshness still unconfirmed, retry after $retry_after" >&2
  return 0
}


# Issue numbers behind every currently active zf-<stage>-* unit, one per
# line. Used to derive (never store) implement's package-exclusion set — see
# expected_packages_collide() below.
stage_active_issues() {
  systemctl --user list-units --no-legend --plain "${UNIT_PREFIX_TRANSIENT}-$1-*" 2>/dev/null \
    | awk '{print $1}' | sed -E "s/^${UNIT_PREFIX_TRANSIENT}-$1-([0-9]+)\\.service\$/\\1/"
}


# How many more of this stage's cap are free right now? Clamped at 0 so a
# cap lowered below the current in-flight count never goes negative and
# wraps a `for`-loop's `[ "$slots" -le 0 ] && break` guard into "unlimited."
cap_slots_remaining() {
  local cap="$1" count="$2" slots
  slots=$((cap - count))
  [ "$slots" -lt 0 ] && slots=0
  echo "$slots"
}
