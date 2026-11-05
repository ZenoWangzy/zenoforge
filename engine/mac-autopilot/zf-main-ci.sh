#!/usr/bin/env bash
# Sourced by bell.sh: file one incident per failing SHA when the newest finished engine-tests or cli-tests run on the engine repo's main is red.
# main_ci_incident_scan reads the product repo's CI snapshot, so a red engine main never reached it. The incident carries test names only, no log text.

# zf_main_ci_names <failed-log>: failing test files (tools/run-engine-tests.sh "FAIL <file> rc=N") and node:test names, one per line.
zf_main_ci_names() {
  { sed -nE 's/.*[[:space:]]FAIL ([^[:space:]]+) rc=[0-9]+.*/\1/p' <<<"$1"; ci_failed_test_ids "$1" | sed -E 's/^[^[:space:]]+[[:space:]]//'; } | sort -u | head -10
}

# Needs bell.sh's add_event, STATE_JSON, ENGINE_INCIDENT_REPO, gh_timeout and now. A run is reported once: its id lands in main_ci_runs_seen.
zf_main_ci_scan() {
  local runs run id sha wf log names key sha_names
  local -A by_sha=()
  runs="$(gh_timeout -k 1 8 run list --repo "$ENGINE_INCIDENT_REPO" --branch main --limit 20 \
    --json databaseId,workflowName,conclusion,headSha 2>/dev/null \
    | jq -c '[.[] | select((.workflowName == "engine-tests" or .workflowName == "cli-tests") and (.conclusion == "success" or .conclusion == "failure"))]
      | group_by(.workflowName) | .[] | .[0] | select(.conclusion == "failure")' 2>/dev/null)" || return 0
  while IFS= read -r run; do
    [[ -n $run ]] || continue
    id="$(jq -r '.databaseId' <<<"$run")"; sha="$(jq -r '.headSha' <<<"$run")"; wf="$(jq -r '.workflowName' <<<"$run")"
    key="zf:$id"
    [[ $id =~ ^[1-9][0-9]*$ && $sha =~ ^[0-9a-f]{40}$ ]] || continue
    ! jq -e --arg k "$key" '.main_ci_runs_seen[$k]' <<<"$STATE_JSON" >/dev/null || continue
    log="$(gh_timeout -k 1 8 run view "$id" --repo "$ENGINE_INCIDENT_REPO" --log-failed 2>/dev/null)" || continue
    names="$(zf_main_ci_names "$log" | paste -sd, -)"
    by_sha[$sha]+="$wf: ${names:-unreported-test-output}; "
    STATE_JSON="$(jq -c --arg k "$key" --argjson now "$now" '.main_ci_runs_seen[$k]=$now' <<<"$STATE_JSON")"
  done <<<"$runs"
  for sha in "${!by_sha[@]}"; do
    sha_names="${by_sha[$sha]}"
    add_event high "zf-main-red:${sha:0:12}" \
      "zenoforge main CI red commit=${sha:0:12} failed=${sha_names}" \
      "detected by engine/mac-autopilot/zf-main-ci.sh repo=$ENGINE_INCIDENT_REPO commit=$sha failed tests: ${sha_names}"
  done
}
