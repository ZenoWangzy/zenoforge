#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-lib-helpers.sh"

export CLAUDE_QUOTA_SNAPSHOT_FILE="$AGENT_HOME/claude-quota.json"
export NOW_EPOCH="$(( $(date +%s) ))"

hold_marker() { printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$1"; }
claude_week() { jq -n --argjson now "$NOW_EPOCH" --argjson pct "$1" '{week_pct:$pct,week_reset:($now+3600)}' > "$CLAUDE_QUOTA_SNAPSHOT_FILE"; }
hold_all_markers() { hold_marker "$CLAUDE_EXHAUSTED_MARKER_FILE"; hold_marker "$CODEX_EXHAUSTED_MARKER_FILE"; hold_marker "$ZCODE_EXHAUSTED_MARKER_FILE"; }
clear_holds() { rm -f "$CLAUDE_EXHAUSTED_MARKER_FILE" "$CODEX_EXHAUSTED_MARKER_FILE" "$ZCODE_EXHAUSTED_MARKER_FILE" "$CLAUDE_QUOTA_SNAPSHOT_FILE" "$AGENT_HOME/model-routing.json"; unset CFG || true; }

spec_cell() {
  case "$1:$2" in
    claude:implement|claude:review|claude:recut|codex:implement|codex:review|codex:recut|codex:owner_session|zcode:implement|zcode:review|zcode:recut) printf block ;;
    *) printf allow ;;
  esac
}

assert_cell() {
  local marker="$1" station="$2" want="$3"
  if [ "$want" = block ]; then
    assert_true "default $marker $station blocks" quota_marker_blocks "$marker" "$station"
  else
    assert_false "default $marker $station allows" quota_marker_blocks "$marker" "$station"
  fi
}

check_18_cells() { check_18_cells_except ""; }

check_18_cells_except() {
  local flipped="${1:-}" marker station want
  for marker in claude codex zcode; do
    for station in implement review triage intake recut owner_session; do
      want="$(spec_cell "$marker" "$station")"
      if [ -n "$flipped" ] && [ "$marker:$station" = "$flipped" ]; then
        if [ "$want" = block ]; then want=allow; else want=block; fi
      fi
      assert_cell "$marker" "$station" "$want"
    done
  done
}

assert_false "claude implement allows while no marker is set" quota_marker_blocks claude implement
assert_false "codex implement allows while no marker is set" quota_marker_blocks codex implement
assert_false "zcode review allows while no marker is set" quota_marker_blocks zcode review

hold_all_markers
check_18_cells

reason="$(quota_marker_blocks claude implement)"
assert_eq "claude exhausted reason" "claude.exhausted:implement" "$reason"
rm -f "$CLAUDE_EXHAUSTED_MARKER_FILE"
assert_false "claude marker gone allows implement" quota_marker_blocks claude implement
claude_week 94
assert_false "claude week below the stop allows implement" quota_marker_blocks claude implement
claude_week 95
reason="$(quota_marker_blocks claude implement)"
assert_eq "claude week stop reason" "claude.week_stop:implement" "$reason"
reason="$(quota_marker_blocks claude recut)"
assert_eq "the bare claude entry governs both causes" "claude.week_stop:recut" "$reason"
assert_false "claude week stop leaves triage allowed" quota_marker_blocks claude triage

hold_marker "$ZCODE_EXHAUSTED_MARKER_FILE"
reason="$(quota_marker_blocks glm review)"
assert_eq "family glm maps to provider zcode" "zcode:review" "$reason"
assert_false "glm mapping keeps zcode triage allowed" quota_marker_blocks glm triage

status=0; quota_marker_blocks claude nowhere 2>/dev/null || status=$?
assert_eq "unknown station is refused loudly" 2 "$status"
status=0; quota_marker_blocks gemini implement 2>/dev/null || status=$?
assert_eq "unknown marker is refused loudly" 2 "$status"

clear_holds
CFG="{\"models\":{\"routing_file\":\"$AGENT_HOME/model-routing.json\"}}"
printf '{"quota_marker_scope":{"claude":{"triage":"block"}}}' > "$AGENT_HOME/model-routing.json"
hold_all_markers
rm -f "$CLAUDE_EXHAUSTED_MARKER_FILE"
claude_week 95
check_18_cells_except "claude:triage"

printf '{"quota_marker_scope":{"claude.week_stop":{"review":"allow"}}}' > "$AGENT_HOME/model-routing.json"
assert_false "a cause-specific entry overrides the bare claude entry" quota_marker_blocks claude review
reason="$(quota_marker_blocks claude implement)"
assert_eq "the bare entry still governs other stations" "claude.week_stop:implement" "$reason"

clear_holds
out="$(bash "$SCRIPT_DIR/bin/quota-scope")"
expected='claude implement blocked claude:implement
claude review blocked claude:review
claude triage allowed
claude intake allowed
claude recut blocked claude:recut
claude owner_session allowed
codex implement blocked codex:implement
codex review blocked codex:review
codex triage allowed
codex intake allowed
codex recut blocked codex:recut
codex owner_session blocked codex:owner_session
zcode implement blocked zcode:implement
zcode review blocked zcode:review
zcode triage allowed
zcode intake allowed
zcode recut blocked zcode:recut
zcode owner_session allowed'
assert_eq "bin quota-scope prints the default table with no routing file" "$expected" "$out"

lib_case_exit
