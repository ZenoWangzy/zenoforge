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
