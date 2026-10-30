#!/usr/bin/env bash
# One implementer at a time. A startup failure may retry cold; work events
# mean the repair has started and its failure belongs to the normal pipeline.
set -uo pipefail
log="$1"; resume_id="$2"; fresh_count="$3"; shift 3
fresh=("${@:1:fresh_count}"); shift "$fresh_count"
capture="$(mktemp)" || exit 1
trap 'rm -f -- "$capture"' EXIT
jq -cn '{type:"pipeline.execution",mode:"resume",reason:"same-provider-model"}'
"$@" 2>&1 | tee "$capture"
status="${PIPESTATUS[0]}"
if (( status != 0 )) && ! jq -e -R 'fromjson? | select(.type == "item.started" or .type == "item.updated" or .type == "item.completed" or .type == "turn.completed")' "$capture" >/dev/null; then
  # Discard the failed startup's incomplete turn events before the existing
  # stream reader ingests the cold run's session and cumulative token counters.
  exec > "$log" 2>&1
  jq -cn --argjson status "$status" --arg sid "$resume_id" \
    '{type:"pipeline.execution",mode:"fresh",reason:"resume-startup-failed",resume_exit:$status,resume_session_id:$sid}'
  rm -f -- "$capture"
  exec "${fresh[@]}"
fi
exit "$status"
