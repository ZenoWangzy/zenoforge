#!/usr/bin/env bash

model_policy_fast_forward_alert() {
  local agent_home="$1" message="$2" at
  if declare -F append_supervisor_event >/dev/null; then
    append_supervisor_event model-policy-apply-failed "$message" && return 0
  fi
  if declare -F supervisor_inbox_append >/dev/null; then
    supervisor_inbox_append model-policy-apply-failed "$message" && return 0
  fi

  # lib.sh can fail to load when the old live policy became invalid under the new default.
  mkdir -p -- "$agent_home" || return 1
  at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
  {
    flock -x 9 || exit 1
    printf '%s model-policy-apply-failed %s\n' "$at" "$message" >> "$agent_home/supervisor-inbox"
  } 9>>"$agent_home/supervisor-inbox.lock"
}

sync_model_policy_default_after_fast_forward() {
  local repo_dir="$1" agent_home="$2" old_head="$3" new_head="$4" policy_file policy_path
  local diff_status apply_status apply_output reason

  policy_file="$(zf_config_file model-policy.default.json)" || return 0
  if [[ "$policy_file" == "$repo_dir/"* ]]; then
    policy_path="${policy_file#"$repo_dir"/}"
  else
    policy_path="${ZF_PACK_REL:-engine}/model-policy.default.json"
  fi
  if git -C "$repo_dir" diff --quiet "$old_head" "$new_head" -- "$policy_path"; then
    return 0
  else
    diff_status=$?
  fi
  if [[ "$diff_status" != 1 ]]; then
    reason="could not compare policy defaults across fast-forward (git status $diff_status)"
    model_policy_fast_forward_alert "$agent_home" "repo=$repo_dir reason=$reason" \
      || echo "model-policy-sync: supervisor inbox write failed" >&2
    echo "model-policy-sync: $reason" >&2
    return 1
  fi

  if apply_output="$(AGENT_HOME="$agent_home" ZF_REPO_DIR="$repo_dir" \
    bash "${ZF_ENGINE_LIVE:-$repo_dir/engine}/apply-model-policy-default.sh" 2>&1)"; then
    echo 'model-policy-sync: synchronized live model policy from deployed default' >&2
    return 0
  else
    apply_status=$?
  fi
  reason="$(tail -n 1 <<< "$apply_output" | tr '\r\n\t' '   ' | cut -c1-240)"
  [[ -n "$reason" ]] || reason="apply exited $apply_status"
  model_policy_fast_forward_alert "$agent_home" \
    "repo=$repo_dir status=$apply_status reason=$reason" \
    || echo "model-policy-sync: supervisor inbox write failed" >&2
  echo "model-policy-sync: apply failed (status=$apply_status reason=$reason)" >&2
  return 1
}
