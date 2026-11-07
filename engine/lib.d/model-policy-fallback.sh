# A model-policy template the running engine's validator refuses must never stop the pipeline. A tick resolves its
# engine once and keeps it for minutes, so a template that lands mid-tick (target checkout fast-forward) can be
# newer than the engine that reads it (2026-11-07: pre-#593 validator, new template, "cannot resolve the work role"),
# and an engine whose validator tightened can meet a template behind it. Callers source this after lib.d/model-policy.sh.
#
# model_policy_default_fallback <engine default>: when MODEL_POLICY_DEFAULT (target, pack or engine copy chosen by
# zf_config_file / sched_config_file) fails model_policy_validate_file, use the engine's own default instead, print one
# greppable stderr line, and alert once per template content. MODEL_POLICY_DEFAULT_REFUSED then names the refused file,
# which blocks every write to the live policy (see model_policy_migrate_live and the seed in model_policy) and keeps
# `model_policy source-check` failing on the refused template. No change when the template validates, when the engine
# default is also invalid (the hard failure stays), under MODEL_POLICY_SOURCE_CHECK_ONLY=1, or under
# MODEL_POLICY_STRICT_DEFAULT=1 (set by apply-model-policy-default.sh, which publishes the template and must refuse a bad one).
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
  model_policy_template_refused_alert "$refused" || true
}

# One supervisor-inbox line per template content (a marker named by the content hash). lib.sh sources supervisor-inbox.sh
# before this point; the scheduler does not, so load it in a subshell there. A failed alert is retried on the next load.
model_policy_template_refused_alert() {
  local file="$1" sha marker dir
  [[ "${MODEL_POLICY_READ_ONLY:-0}" != 1 ]] || return 0
  sha="$(sha256sum -- "$file" | cut -c1-12)" || return 1
  marker="$AGENT_HOME/.model-policy-template-refused.$sha"
  [[ ! -e "$marker" ]] || return 0
  dir="$(dirname -- "${BASH_SOURCE[0]}")"
  if declare -F supervisor_inbox_append >/dev/null; then
    supervisor_inbox_append model-policy-template-refused "file=$file sha=$sha using=engine-default"
  else
    ( declare -F agent_pipeline_write_guard >/dev/null || source "$dir/../write-guard.sh"
      source "$dir/supervisor-inbox.sh"
      supervisor_inbox_append model-policy-template-refused "file=$file sha=$sha using=engine-default" )
  fi && : > "$marker"
}
