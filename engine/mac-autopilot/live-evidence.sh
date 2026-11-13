#!/usr/bin/env bash
# Sourced by bell.sh. Uses its paths, timestamp and incident-event queue.
live_evidence_scan() {
  [[ "${BELL_LIVE_EVIDENCE_DISABLE:-0}" != 1 ]] || return 0
  local checker="$HERE/live-evidence.py" report row number pattern pin_at pin_sha raw class summary evidence
  local missing_count watching_count matched_count checked_count scan_line
  local -a args=(scan --state "$A/live-evidence-state.json" --repo "$ENGINE_INCIDENT_REPO"
    --runtime-dir "$A" --agent-home "$AGENT_HOME" --now "$now")
  [[ "$CHECK_ONLY" != 1 ]] || args+=(--check-only)
  if ! report="$(python3 "$checker" "${args[@]}" 2>&1)"; then
    if [[ "$CHECK_ONLY" == 1 ]]; then printf '%s\n' "$report" >&2
    else printf '[%s] live-evidence scan failed: %s\n' "$stamp" "$report" >> "$LOG"; fi
    return 0
  fi
  jq -e 'type == "object" and (.missing | type == "array")' <<<"$report" >/dev/null 2>&1 || return 0
  missing_count="$(jq '.missing_count' <<<"$report")"
  watching_count="$(jq '.watching' <<<"$report")"
  matched_count="$(jq '.matched' <<<"$report")"
  checked_count="$(jq '.checked' <<<"$report")"
  scan_line="live-evidence: scan-complete checked=$checked_count matched=$matched_count missing=$missing_count watching=$watching_count"
  if [[ "$CHECK_ONLY" == 1 ]]; then
    add_event info "$scan_line" "$scan_line" "$scan_line"
  else
    printf '[%s] %s\n' "$stamp" "$scan_line" >> "$LOG"
  fi
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    number="$(jq -r '.number // empty' <<<"$row")"
    pattern="$(jq -r '.pattern // empty' <<<"$row")"
    pin_at="$(jq -r '.pin_at // empty' <<<"$row")"
    pin_sha="$(jq -r '.pin_sha // empty' <<<"$row")"
    [[ "$number" =~ ^[1-9][0-9]*$ && -n "$pattern" && "$pin_sha" =~ ^[0-9a-f]{12,40}$ ]] || continue
    raw="live-evidence-pr-$number"
    class="$(incident_class "$(incident_fingerprint "$raw")")"
    jq -e --arg class "$class" '(.incident_stats // {}) | has($class)' <<<"$STATE_JSON" >/dev/null 2>&1 && continue
    summary="Live evidence was missing for engine PR #$number after pin ${pin_sha:0:12}"
    evidence="engine PR #$number expected log substring: $pattern; absent from the user journal and engine logs, including scheduler.log, for 24 hours after pin at $pin_at (engine commit $pin_sha)"
    add_event high "$raw" "$summary" "$evidence"
  done < <(jq -c '.missing[]' <<<"$report")
}
