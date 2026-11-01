#!/usr/bin/env bash
set -uo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$here/../config.sh"
[[ ${HF_SKIP_ACCEPT:-} == 1 ]] && { echo 'hf-accept: skipped (HF_SKIP_ACCEPT=1; the next install runs it)'; exit 0; }
config=$(zf_config_file hotfix.json) || {
  legacy=$(pack_file hotfix/hf-accept.sh) && exec bash "$legacy" "$@"
  echo 'hf-accept: configure acceptance in hotfix.json' >&2; exit 1
}
# The command is an argument vector, never evaluated as shell code.
if ! jq -e '.acceptance | (.command | type == "array" and length > 0 and all(.[]; type == "string" and length > 0 and (contains("\n") | not))) and (.person | type == "string" and length > 0) and (.target | type == "string" and length > 0) and ((.target_env // "") | type == "string" and (length == 0 or test("^[A-Za-z_][A-Za-z0-9_]*$"))) and ((.repo_env // "") | type == "string" and (length == 0 or test("^[A-Za-z_][A-Za-z0-9_]*$")))' "$config" >/dev/null; then
  echo 'hf-accept: configure acceptance command, person and target in hotfix.json' >&2; exit 1
fi
mapfile -t command < <(jq -r '.acceptance.command[]' "$config")
person=$(jq -r '.acceptance.person' "$config")
target=$(jq -r '.acceptance.target' "$config")
target_env=$(jq -r '.acceptance.target_env // ""' "$config")
repo_env=$(jq -r '.acceptance.repo_env // ""' "$config")
repo=$ZF_REPO_DIR
[[ -z $repo_env ]] || repo=${!repo_env:-$repo}
[[ -z $target_env ]] || target=${!target_env:-$target}
log=${HF_ACCEPT_LOG:-$AGENT_HOME/logs/hf-accept-$(date -u +%Y%m%dT%H%M%SZ).log}
resolved_repo=$repo
if physical_repo=$(cd -- "$repo" 2>/dev/null && pwd -P); then resolved_repo=$physical_repo; fi
live_checkout=
if physical_checkout=$(cd -- "$AGENT_HOME/checkout" 2>/dev/null && pwd -P); then live_checkout=$physical_checkout; fi
if ! harness_head=$(git -C "$repo" rev-parse HEAD 2>/dev/null); then harness_head=; fi
printf 'harness_path=%s\nharness_head=%s\n' "$resolved_repo" "$harness_head" > "$log"
record_attempt() {
  local rc=$1
  jq -cn --arg at "$(date -u +%FT%TZ)" --argjson rc "$rc" --arg set "${HF_ACCEPT_SET:-full}" --arg log "$log" \
    --arg harness_path "$resolved_repo" --arg harness_head "$harness_head" \
    '{at:$at,rc:$rc,set:$set,log:$log,harness_path:$harness_path,harness_head:$harness_head}' \
    >> "$AGENT_HOME/hf-demo-accept.jsonl"
}
refuse_acceptance() {
  local message=$1
  echo "hf-accept: $message" >&2
  printf 'hf-accept: %s\n' "$message" >> "$log"
  record_attempt 3
  exit 3
}
if [[ ${HF_ACCEPT_SET:-full} == demo && -n $live_checkout && $resolved_repo == "$live_checkout" ]]; then
  refuse_acceptance "refusing demo acceptance from the live checkout: $resolved_repo"
fi
if [[ -n ${HF_HARNESS_SHA+x} && ( -z $harness_head || $harness_head != "$HF_HARNESS_SHA" ) ]]; then
  refuse_acceptance "refusing harness SHA mismatch at $resolved_repo (expected '$HF_HARNESS_SHA', found '${harness_head:-unavailable}')"
fi
(cd "$repo" && "${command[@]}" --target "$target") >> "$log" 2>&1
rc=$?
tail -n 1 "$log"; echo "hf-accept: rc=$rc (0 accept, 1 regression, 2 hold) log=$log"
record_attempt "$rc"
if ((rc == 0)) && [[ -n ${HF_ISSUE:-} ]]; then
  pr=${HF_PR:-null}; [[ $pr =~ ^[0-9]+$ ]] || pr=null; at=$(date -u +%FT%TZ)
  for issue in $HF_ISSUE; do
    [[ $issue =~ ^[0-9]+$ ]] || continue
    jq -cn --argjson issue "$issue" --argjson pr "$pr" --arg sha "${HF_SHA:-}" --arg at "$at" --arg person "$person" \
      --arg harness_path "$resolved_repo" --arg harness_head "$harness_head" \
      '{kind:"hotfix-live",issue:$issue,pr:$pr,sha:$sha,at:$at,accepted_by:$person,harness_path:$harness_path,harness_head:$harness_head}' \
      >> "$AGENT_HOME/hotfix-live.jsonl"
  done
fi
exit "$rc"
