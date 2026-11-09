# A model-policy template the running engine's validator refuses must never stop the pipeline. A tick resolves its
# engine once and keeps it for minutes, so a template that lands mid-tick (target checkout fast-forward) can be
# newer than the engine that reads it (2026-11-07: pre-#593 validator, new template, "cannot resolve the work role"),
# and an engine whose validator tightened can meet a template behind it. Apply then publishes that template to the
# live policy seconds later, so the older engine can refuse the live file too. Callers source this after lib.d/model-policy.sh.
#
# The GLM CLI resolver lives in config.sh, which lib.sh sources before this file; the
# autopilot scheduler sources model-policy.sh directly without config.sh (its comment at
# mac-autopilot/scheduler.sh keeps config.sh's directory variables out of its process),
# so bridge the resolver the same way scheduler.d/core.sh's sched_config_file bridges
# zf_config_file: a subshell sources config.sh and runs the real function.
declare -F zf_zcode_bin_argv >/dev/null 2>&1 || zf_zcode_bin_argv() {
  ( source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/config.sh" && zf_zcode_bin_argv "$@" )
}

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

# The GLM runtime bell (2026-11-03: repeated `review-family fallback ... reviewer=sonnet
# reason=glm cli missing` lines while mode was claude-saving, and nothing paged). N
# consecutive Sonnet fallbacks whose reason is a GLM runtime problem (`glm cli missing`
# / `glm config mismatch`) file ONE incident through the shared pipeline-issue-upsert.
GLM_FALLBACK_STREAK_FILE="${AGENT_HOME}/glm-fallback-streak"

glm_fallback_incident_threshold() {
  local config="${ZF_CONFIG_ROOT:-}/config.json" threshold
  if [[ -n "${ZF_CONFIG_ROOT:-}" && -f "$config" ]]; then
    threshold="$(jq -r '.engine.glm_fallback_incident_threshold | select(type == "number" and . >= 1) | floor' "$config" 2>/dev/null)" || threshold=""
    if [[ "$threshold" =~ ^[1-9][0-9]*$ ]]; then printf '%s' "$threshold"; return 0; fi
  fi
  printf '5'
}

glm_fallback_streak_set() { # <count> -- best-effort write, never fails the review path
  (
    flock -w 5 9
    printf '%s\n' "$1" > "$GLM_FALLBACK_STREAK_FILE"
  ) 9>"$GLM_FALLBACK_STREAK_FILE.lock" 2>/dev/null || true
}

glm_fallback_streak_bump() { # -> the new consecutive count (0 when state is unreadable)
  (
    flock -w 5 9
    count=0
    read -r count < "$GLM_FALLBACK_STREAK_FILE" 2>/dev/null || count=0
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    count=$(( count + 1 ))
    printf '%s\n' "$count" > "$GLM_FALLBACK_STREAK_FILE"
    printf '%s\n' "$count"
  ) 9>"$GLM_FALLBACK_STREAK_FILE.lock" 2>/dev/null || echo 0
  return 0
}

glm_fallback_incident_file() { # <reason> <streak> -- one incident through the shared upsert
  local reason="$1" streak="$2" body_file engine_dir repo status
  # The scheduler process sources this file without lib.sh: derive both paths from this
  # file's own location the way config.sh derives the engine and lib.sh derives ZF_REPO.
  engine_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
  [[ -f "$engine_dir/pipeline-issue-upsert.sh" ]] || return 1
  repo="${ZF_REPO:-$(git -C "$engine_dir/.." remote get-url origin 2>/dev/null | sed -E 's#^(git@[^:]+:|[a-z+]+://([^/@]+@)?[^/]+/)##; s#\.git$##' || true)}"
  [[ -n "$repo" ]] || return 1
  body_file="$(mktemp 2>/dev/null)" || return 1
  {
    printf 'The GLM review runtime was unusable for %s consecutive review-family fallbacks (reason: `%s`), so cross-family reviews kept landing on the Sonnet fallback.\n\n' "$streak" "$reason"
    printf -- '- log signature: `review-family fallback ... reviewer=sonnet reason=%s`\n' "$reason"
    printf -- '- CLI resolution order: config `engine.zcode_bin` -> env `ZF_ZCODE_BIN` -> the worker bundle zc-src (bin/zcode + the CLI entry script) -> `zcode` on PATH\n'
    printf -- '- fix the GLM CLI location (or set `engine.zcode_bin`), then close this issue; the streak counter reset when this was filed\n'
  } > "$body_file"
  bash "$engine_dir/pipeline-issue-upsert.sh" --lane pipeline-system --class glm-cli-fallback \
    --title "GLM CLI unavailable: reviews keep falling back to Sonnet (${reason})" \
    --body-file "$body_file" --repo "$repo" >/dev/null 2>&1
  status=$?
  rm -f -- "$body_file"
  if [ "$status" -eq 0 ]; then
    review_family_log "glm fallback bell: filed glm-cli-fallback incident after ${streak} consecutive '${reason}' fallbacks"
  fi
  return "$status"
}

glm_fallback_bell() { # <primary fallback reason> -- counts, and files once at the threshold
  local reason="$1" threshold streak
  case "$reason" in
    'glm cli missing'|'glm config mismatch') ;;
    *) glm_fallback_streak_set 0; return 0 ;;
  esac
  threshold="$(glm_fallback_incident_threshold)"
  streak="$(glm_fallback_streak_bump)"
  if (( streak >= threshold )) && glm_fallback_incident_file "$reason" "$streak"; then
    glm_fallback_streak_set 0
  fi
  return 0
}

review_family_candidate_selected() { # <role> <issue> <unit> <author> <model> <reason> <candidate>
  local role="$1" issue="$2" unit="$3" author="$4" model="$5" reason="${6:-}" candidate="$7"
  if [[ "$role" == review_fallback ]]; then
    reason="${reason:-cross reviewer unavailable}"
    review_family_log "review-family fallback unit=$unit author=$author reviewer=$model reason=$reason"
    record_review_provider_fallback "$issue" "cross-family-reviewer" "$candidate" "$reason" 2>/dev/null || true
    glm_fallback_bell "${6:-}" || true
  else
    glm_fallback_streak_set 0
  fi
}
