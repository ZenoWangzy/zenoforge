# A model-policy template the running engine's validator refuses must never stop the pipeline. A tick resolves its
# engine once and keeps it for minutes, so a template that lands mid-tick (target checkout fast-forward) can be
# newer than the engine that reads it (2026-11-07: pre-#593 validator, new template, "cannot resolve the work role"),
# and an engine whose validator tightened can meet a template behind it. Apply then publishes that template to the
# live policy seconds later, so the older engine can refuse the live file too. Callers source this after lib.d/model-policy.sh.
#
# model_policy_default_fallback <engine default>: when MODEL_POLICY_DEFAULT (target, pack or engine copy chosen by
# zf_config_file / sched_config_file) fails model_policy_validate_file, use the engine's own default instead, print one
# greppable stderr line, and alert once per template content. MODEL_POLICY_DEFAULT_REFUSED then names the refused file,
# which blocks every write to the live policy (see model_policy_migrate_live and the seed in model_policy) and keeps
# `model_policy source-check` failing on the refused template.
# Only when the template was refused too, a live policy this engine also refuses (invalid, or a schema version above the
# engine default) is replaced for this process by the engine default: MODEL_POLICY_FILE points at it, read-only (nothing
# else writes MODEL_POLICY_FILE), with one stderr line and one alert per live content. Both refusals together are the
# evidence that this engine is older than its config; a bad live file under a valid template still fails as before.
# No change when the template validates, when the engine default is also invalid (the hard failure stays), when the live
# file is missing (not seeded), under MODEL_POLICY_SOURCE_CHECK_ONLY=1, or under MODEL_POLICY_STRICT_DEFAULT=1 (set by
# apply-model-policy-default.sh, which publishes the template and must refuse a bad one).
model_policy_default_fallback() {
  MODEL_POLICY_DEFAULT_REFUSED=""
  [[ "${MODEL_POLICY_STRICT_DEFAULT:-0}" != 1 && "${MODEL_POLICY_SOURCE_CHECK_ONLY:-0}" != 1 ]] || return 0
  [[ "$MODEL_POLICY_DEFAULT" -ef "$1" ]] && return 0
  local refused="$MODEL_POLICY_DEFAULT"
  model_policy_validate_file "$refused" >/dev/null 2>&1 && return 0
  MODEL_POLICY_DEFAULT="$1" # the validator reads this file as its canonical policy
  if ! model_policy_validate_file "$1" >/dev/null 2>&1; then
    MODEL_POLICY_DEFAULT="$refused"
    return 0
  fi
  MODEL_POLICY_DEFAULT_REFUSED="$refused"
  echo "model-policy-template-refused file=$refused using=engine-default" >&2
  model_policy_refused_alert model-policy-template-refused "$refused" || true
  [[ -s "$MODEL_POLICY_FILE" ]] || return 0
  # The same checks model_policy runs on the live file; writes are already blocked, and the subshell keeps the rest out.
  ( model_policy_migrate_live \
    && model_policy_validate_json <<< "$(model_policy_effective_live_json "$MODEL_POLICY_FILE")" ) >/dev/null 2>&1 && return 0
  local live="$AGENT_HOME/model-policy.json"
  MODEL_POLICY_FILE="$1"
  echo "model-policy-live-refused file=$live using=engine-default" >&2
  model_policy_refused_alert model-policy-live-refused "$live" || true
}

# One supervisor-inbox line per kind and file content (a marker named by the content hash). lib.sh sources
# supervisor-inbox.sh before this point; the scheduler does not, so load it in a subshell there. A failed alert is
# retried on the next load.
model_policy_refused_alert() {
  local kind="$1" file="$2" sha marker dir
  [[ "${MODEL_POLICY_READ_ONLY:-0}" != 1 ]] || return 0
  sha="$(sha256sum -- "$file" | cut -c1-12)" || return 1
  marker="$AGENT_HOME/.$kind.$sha"
  [[ ! -e "$marker" ]] || return 0
  dir="$(dirname -- "${BASH_SOURCE[0]}")"
  if declare -F supervisor_inbox_append >/dev/null; then
    supervisor_inbox_append "$kind" "file=$file sha=$sha using=engine-default"
  else
    ( declare -F agent_pipeline_write_guard >/dev/null || source "$dir/../write-guard.sh"
      source "$dir/supervisor-inbox.sh"
      supervisor_inbox_append "$kind" "file=$file sha=$sha using=engine-default" )
  fi && : > "$marker"
}

# The reviewers a head's author may have, in order: the different-family rule and the Claude tier rule applied, availability not.
# Prints "role<TAB>identity" per candidate. A sixth argument "quiet" suppresses the refusal log lines (for a count, not a dispatch).
review_allowed_candidates() { # unit author codex glm sonnet [quiet]
  local unit="${1:-unknown}" author_identity="$2" codex_identity="${3-}" glm_identity="${4-}" sonnet_identity="${5-}" quiet="${6:-}"
  local author_family cross candidate candidate_family candidate_role candidate_model
  local -a candidates=()
  author_family="$(review_identity_family "$author_identity" 2>/dev/null || true)"
  if (( $# >= 5 )); then
    cross="$(review_cross_identity_for "$author_identity" "$codex_identity" "$glm_identity" 2>/dev/null || true)"
  else
    cross="$(review_cross_identity_for "$author_identity" 2>/dev/null || true)"
  fi
  [[ -z "$cross" ]] || candidates+=("$cross")
  # A Claude-authored head is unusual and cannot use Sonnet. Try the other
  # configured independent family after the preferred family for resilience.
  if [[ "$author_family" == claude ]]; then
    local second=""
    [[ "$(review_identity_family "$cross" 2>/dev/null || true)" == glm ]] && second="$codex_identity"
    [[ "$(review_identity_family "$cross" 2>/dev/null || true)" == codex ]] && second="$glm_identity"
    [[ -z "$second" || "$second" == "$cross" ]] || candidates+=("$second")
  fi
  [[ -z "$sonnet_identity" ]] || candidates+=("$sonnet_identity")
  for candidate in "${candidates[@]}"; do
    [[ -n "$candidate" ]] || continue
    candidate_family="$(review_identity_family "$candidate" 2>/dev/null || true)"
    if [[ -z "$candidate_family" || "$candidate_family" == "$author_family" ]]; then
      [[ "$quiet" == quiet ]] || review_family_log "review-family refused unit=$unit author=${author_family:-unknown} reviewer=${candidate_family:-unknown} reason=same-family-or-unknown"
      continue
    fi
    candidate_role=review
    if [[ "$candidate_family" == claude ]]; then
      candidate_role=review_fallback
      candidate_model="${candidate#*:}"; candidate_model="${candidate_model%:*}"
      if [[ "$author_family" == claude || ! "$candidate_model" =~ ^claude-(haiku|sonnet)- ]]; then
        [[ "$quiet" == quiet ]] || review_family_log "review-family refused unit=$unit author=$author_family reviewer=claude reason=fallback-must-be-claude-tier-and-cross-family"
        continue
      fi
    fi
    printf '%s\t%s\n' "$candidate_role" "$candidate"
  done
}

# Reviewers a failed review may still hand to: allowed by the family rule and by policy, and not in the failed list (provider:model keys).
review_untried_candidates() { # author codex glm sonnet failed-keys → identity per line
  local author_identity="$1" codex_identity="${2-}" glm_identity="${3-}" sonnet_identity="${4-}" failed="${5-}" role candidate model
  while IFS=$'\t' read -r role candidate; do
    [[ -n "$candidate" ]] || continue
    model="${candidate#*:}"; model="${model%:*}"
    model_policy_model_allowed_for_role "$model" "$role" || continue
    [[ " $failed " != *" ${candidate%:*} "* ]] || continue
    printf '%s\n' "$candidate"
  done < <(review_allowed_candidates unknown "$author_identity" "$codex_identity" "$glm_identity" "$sonnet_identity" quiet)
}
