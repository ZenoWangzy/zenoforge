#!/usr/bin/env bash
# One-time (but idempotent, safe to re-run) backfill: guarded_brief()/
# advisor_superseded_brief() used to PREPEND a new banner onto brief_md on
# every call instead of replacing it (lessons/RULES.md V112/V113/V116/V119)
# -- fixed at the write path (strip_brief_banner(), lib.sh), but that fix
# only runs the NEXT time either function is called on a given ticket. A
# ticket that already accumulated stacked banners before the fix landed,
# and never re-enters the advisor after, keeps the bloat on disk forever.
# #1204/#1206 (31/29 stacked banners, 65-68K/47-49K brief_md) are both
# ready-for-agent right now -- the implement leg would feed the model the
# full bloated brief on its next dispatch, the exact payload problem V116
# measured and trimmed for the batch advisor.
#
# Scans every state file and, for a ticket with 2+ stacked layers, writes
# back via the SAME state_merge() atomic temp-file+rename every other write
# path uses -- but not by strip_brief_banner() alone. This does NOT
# collapse to zero banners: it regenerates exactly the ONE current banner by
# calling guarded_brief()/advisor_superseded_brief() (lib.sh) directly on
# the ticket's existing (stacked) brief_md, with the risk_class/level/
# merge_conditions_md already stored in its OWN state file -- the identical
# call the live write path would make if admit_guarded()/a misclassified
# correction ran again right now. Those two functions already strip any
# existing banner(s) internally (strip_brief_banner(), lib.sh) before
# wrapping fresh, so this is one call, not strip-then-separately-rewrap.
#
# 2026-09-16 correction, same day this was built: an earlier version called
# strip_brief_banner() directly and wrote its bare result -- reducing a
# stacked ticket to ZERO banners instead of one. That is wrong and was
# caught before it could reach the implement leg: a single banner is
# load-bearing, current content (the guarded contract, the supersession
# notice overriding a stale "route to ready-for-human" conclusion still
# sitting in the ORIGINAL brief text underneath) -- deleting it entirely is
# strictly worse than the 31-deep stack this script exists to fix, because
# it removes the one thing telling the model that stale conclusion no
# longer applies. Regenerating from the ticket's OWN current state fields
# (not stale text recovered from a stacked layer) keeps the banner in sync
# with whatever the CURRENT risk_class/level/merge_conditions_md actually
# are, exactly as if the advisor had just ruled again.
#
# Idempotent: a ticket whose brief_md carries no banner, exactly one banner
# already matching what would be regenerated, or is already correct, is a
# byte-identical no-op -- safe to run again, on a cron, or by hand, forever;
# this is why it is a permanent script, not a one-off thrown away after
# tonight.
#
# Only a ticket with TWO OR MORE stacked layers is touched at all. A single
# banner is the normal, correct, CURRENT state of any guarded/superseded
# ticket, not a defect -- rewriting it every run would also perturb its
# timestamp for no reason. Detection peels exactly ONE layer (bash's
# `${var#*pattern}`, the non-greedy/first-match sibling of strip_brief_
# banner()'s own loop) and checks whether what remains STILL starts with a
# banner prefix -- true only when 2+ layers were stacked. A live scan of the
# real backlog the night this was written found 53 tickets with exactly one
# (untouched) banner and 18 genuinely stacked (2-31 layers, only #1204/#1206
# anywhere near the 31/29-deep incident that prompted this) -- confirming
# naive "any banner present" would have wrongly rewritten dozens of healthy
# tickets, and naive "strip to nothing" would have silently discarded all 18
# tickets' current guarded/superseded contract.
#
# Live-pipeline safety: skips (and does not even back up) any ticket with
# an active zf-<stage>-<n> unit for ANY stage (stage_unit_active(),
# lib.sh, read-only -- systemctl --user is-active, never starts/stops
# anything). That leg may already have this state loaded in its own
# process memory; racing its own eventual write is exactly what this
# pipeline's atomic-write discipline exists to avoid. A skipped ticket is
# picked up on this sweep's next run once its unit finishes -- deferred,
# not lost.
#
# Backs up every file it is about to actually rewrite (never the ones it
# skips, and never under AGENT_DRY_RUN=1) to
# $AGENT_HOME/state-backfill-backups/<run-timestamp>/<n>.json before
# writing -- runtime evidence, not version-controlled, same shape as
# ENV_FAULT_DIR/QUARANTINE_DIR (lib.sh) already uses under $AGENT_HOME.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

STAGES=(triage implement advisor recut release)
BACKUP_ROOT="${SWEEP_BRIEF_BANNERS_BACKUP_ROOT:-$AGENT_HOME/state-backfill-backups}"
RUN_TS="$(date -u +%Y%m%dT%H%M%SZ)"

ticket_unit_active() {
  local n="$1" stage
  for stage in "${STAGES[@]}"; do
    stage_unit_active "$stage" "$n" && return 0
  done
  return 1
}

# has_stacked_banner <brief_md> -- true only for 2+ layers (see header
# comment for why "any banner at all" is the wrong test). Peels exactly one
# layer with the non-greedy `${var#*pattern}` and checks whether a SECOND
# banner is still sitting under it.
#
# Must check the separator's PRESENCE before peeling, exactly like strip_
# brief_banner()'s own defensive check (lib.sh) -- `${var#*pattern}` on a
# pattern that is not found returns the ORIGINAL string unchanged, which
# still trivially matches the prefix it started with and would misread as
# "a second layer sitting under itself". This is not hypothetical: a
# guarded ticket admitted with an EMPTY old_brief (an untriaged recut
# parent, admit_guarded()'s own documented case) produces a banner whose
# trailing "\n---\n\n" has its trailing newlines silently stripped by the
# `$(...)` command substitution every write path already captures brief_md
# through -- the stored string ends in a bare "---" with nothing after, so
# the two-newline separator this function looks for is genuinely absent.
# Caught live: #1165/#1167/#1168/#1169/#1170/#1171 all hit exactly this
# shape and would otherwise have been "regenerated" into a real second
# stacked layer by this script's own write path -- the bug this script
# exists to fix, reintroduced by a detection false positive.
has_stacked_banner() {
  local text="$1" sep=$'\n---\n\n' layer1
  case "$text" in
    "$GUARDED_BANNER_PREFIX"* | "$SUPERSEDED_BANNER_PREFIX"*) : ;;
    *) return 1 ;; # no banner at all
  esac
  case "$text" in
    *"$sep"*) layer1="${text#*"$sep"}" ;;
    *) return 1 ;; # banner prefix present but no separator -- single truncated banner, not stacked
  esac
  case "$layer1" in
    "$GUARDED_BANNER_PREFIX"* | "$SUPERSEDED_BANNER_PREFIX"*) return 0 ;;
    *) return 1 ;;
  esac
}

sweep_one() {
  local f="$1" n state_json old_brief guarded_flag risk level conditions new_brief backup_dir brief_file patch
  n="$(basename "$f" .json)"
  if ! state_json="$(cat "$f" 2>/dev/null)" || ! echo "$state_json" | jq -e . >/dev/null 2>&1; then
    echo "sweep-brief-banners: #$n -- state file is not valid JSON, skipping" >&2
    return 0
  fi
  old_brief="$(echo "$state_json" | jq -r '.brief_md // empty')"
  [ -z "$old_brief" ] && return 0 # no brief_md at all -- nothing to strip

  has_stacked_banner "$old_brief" || return 0 # 0 or 1 banner -- healthy, leave alone

  if ticket_unit_active "$n"; then
    echo "sweep-brief-banners: #$n -- has an active zf-*-$n unit, leaving its ${#old_brief}-byte brief_md untouched this run" >&2
    return 0
  fi

  # Regenerate the ONE current banner from the ticket's OWN current state
  # fields (not text recovered from a stacked layer, which may be stale) --
  # guarded_brief()/advisor_superseded_brief() (lib.sh) already strip
  # whatever banner(s) $old_brief carries internally before wrapping fresh.
  guarded_flag="$(echo "$state_json" | jq -r '.guarded // false')"
  risk="$(echo "$state_json" | jq -r '.risk_class // ""')"
  level="$(echo "$state_json" | jq -r '.level // ""')"
  conditions="$(echo "$state_json" | jq -r '.merge_conditions_md // ""')"
  if [ "$guarded_flag" = "true" ]; then
    new_brief="$(guarded_brief "$old_brief" "$risk" "$level" "$conditions")"
  else
    new_brief="$(advisor_superseded_brief "$old_brief" "$risk" "$level" "$conditions")"
  fi

  if [ "$new_brief" = "$old_brief" ]; then
    return 0 # defensive: nothing actually changed
  fi

  if [ "$DRY_RUN" = "1" ]; then
    echo "sweep-brief-banners: #$n -- [dry-run] would regenerate brief_md ${#old_brief} -> ${#new_brief} bytes (guarded=$guarded_flag)" >&2
    return 0
  fi

  backup_dir="$BACKUP_ROOT/$RUN_TS"
  mkdir -p "$backup_dir"
  cp -p "$f" "$backup_dir/$n.json"

  brief_file="$(jq_arg_file "$new_brief")"
  patch="$(jq -n --rawfile b "$brief_file" '{brief_md: $b}')"
  rm -f "$brief_file"
  if state_merge "$n" ". + $patch"; then
    echo "sweep-brief-banners: #$n -- regenerated brief_md ${#old_brief} -> ${#new_brief} bytes, guarded=$guarded_flag (backup: $backup_dir/$n.json)" >&2
  else
    echo "sweep-brief-banners: #$n -- state_merge failed, original untouched (backup also at $backup_dir/$n.json)" >&2
  fi
}

main() {
  local f
  [ -d "$STATE_DIR" ] || {
    echo "sweep-brief-banners: no $STATE_DIR -- nothing to do" >&2
    return 0
  }
  for f in "$STATE_DIR"/*.json; do
    [ -f "$f" ] || continue
    sweep_one "$f"
  done
}

main "$@"
