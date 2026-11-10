source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../lib.d" && pwd -P)/model-not-found-cache.bash"

unit_is_critical() {
  jqf -r 'if .critical == true then "true" else "false" end' <<<"$1"
}

has_critical_label() {
  jqf -e 'map(ascii_downcase) | index("critical") != null' <<<"${1:-[]}" >/dev/null
}

flush_focus_alert() {
  ((${#FOCUS_SKIPPED[@]} > 0)) || return 0
  local ids="" id candidate seen state="$A/focus-alert-state.json" last_ids last_epoch now
  local -a unique=()
  for id in "${FOCUS_SKIPPED[@]}"; do
    seen=false
    for candidate in ${unique[@]+"${unique[@]}"}; do [[ "$candidate" == "$id" ]] && seen=true; done
    [[ "$seen" == true ]] || unique+=("$id")
  done
  ids="$(printf '%s\n' "${unique[@]}" | LC_ALL=C sort | awk 'BEGIN{ORS=","}{print}')"
  ids="${ids%,}"
  now="${NOW_EPOCH:-$(date +%s)}"
  last_ids=""
  last_epoch=0
  last_ids="$(jqf_optional_file "$state" -r '.ids // empty' 2>/dev/null || true)"
  last_epoch="$(jqf_optional_file "$state" -r '.epoch // 0' 2>/dev/null || true)"
  [[ "$last_epoch" =~ ^[0-9]+$ ]] || last_epoch=0
  if [[ "$ids" == "$last_ids" ]] && (( now - last_epoch < 1800 )); then return 0; fi
  echo "[$STAMP] focus: ${#unique[@]} units queued ($ids)" >> "$A/alerts/focus.md"
  jqf -cn --arg ids "$ids" --argjson epoch "$now" '{ids:$ids,epoch:$epoch}' > "$state.tmp" \
    && mv "$state.tmp" "$state"
}

# 会话按角色分开复用（L18 + 评审独立性）：rereview 只续评审会话，repair 只续修复会话。
session_role() { case "$1" in review|rereview) echo review ;; *) echo repair ;; esac; }
PICK_PROVIDER="${PICK_PROVIDER:-}"
PICK_ROUTE_PROVIDER="${PICK_ROUTE_PROVIDER:-}"
PICK_HARD="${PICK_HARD:-false}"
PICK_REASON="${PICK_REASON:-configured}"
PICK_SERVICE_TIER="${PICK_SERVICE_TIER:-}"
provider_of() {
  case "$(review_identity_family "$1" 2>/dev/null || true)" in
    codex) echo codex ;;
    glm) echo zcode ;;
    claude) echo claude ;;
    *) echo unknown ;;
  esac
}
cooling() { # provider → 成功(0) 表示仍在冷却
  local until read_status
  if until="$(jqf_optional_file "$COOLDOWN" -r --arg p "$1" '.[$p] // 0' 2>/dev/null)"; then :
  else
    read_status=$?
    (( read_status == 64 )) || return "$read_status"
    until=0
  fi
  [[ "$until" =~ ^[0-9]+$ ]] && (( until > NOW_EPOCH ))
}
start_cooldown() { # provider reason
  # 账号会话/用量上限按小时重置，冷却 30 分钟；模型满载/过载/429 是几分钟的瞬时状态，冷却 5 分钟
  # （10-22 一次 luna "at capacity" 让全部 codex worker 停了 30 分钟）。
  local min=30
  [[ "$2" =~ (hit\ your|usage\ limit|quota) ]] || min=5
  [[ -f "$COOLDOWN" ]] || echo '{}' > "$COOLDOWN"
  jqf --arg p "$1" --argjson u "$((NOW_EPOCH + min * 60))" '.[$p]=$u' "$COOLDOWN" | write_state "$COOLDOWN"
  echo "[$STAMP] PROVIDER-COOLDOWN provider=$1 ${min}min: $2" >> "$A/alerts/waste.md"
  say "provider $1 cooling down ${min}min: $2"
}
# 模型族禁用名单与 lib.d/model-policy.sh 同源（目标配置 → pack → 引擎默认的 model-policy.default.json）。
# 调度器的 models.* 是运维配的，可能点名 policy 禁用的族（11-03：models.review=claude-haiku-5-5 对
# claude 禁用族）：这里按整个词元匹配（claude-haiku-5-5 含 claude、gpt-6.1-terra 含 terra），与
# model_policy live 扫描的 prohibited() 同一语义。
declare -a MODEL_POLICY_FORBIDDEN_WORDS=()
model_policy_forbidden_words() { # → 0；首次调用把禁用词读进 MODEL_POLICY_FORBIDDEN_WORDS
  local f
  (( ${#MODEL_POLICY_FORBIDDEN_WORDS[@]} )) && return 0
  f="${MODEL_POLICY_FORBIDDEN_FILE:-$(sched_config_file model-policy.default.json 2>/dev/null || true)}"
  [[ -n "$f" && -r "$f" ]] || return 0
  mapfile -t MODEL_POLICY_FORBIDDEN_WORDS < <(jq -r '.forbidden[]?' "$f" 2>/dev/null || true)
  return 0
}
model_forbidden_by_policy() { # model [role] → 0 = 禁用族；1 = 允许
  local word role="${2:-}"
  if [[ -n "$role" ]]; then
    model_policy_model_allowed_for_role "$1" "$role" && return 1
    return 0
  fi
  model_policy_forbidden_words
  for word in ${MODEL_POLICY_FORBIDDEN_WORDS[@]+"${MODEL_POLICY_FORBIDDEN_WORDS[@]}"}; do
    [[ "$word" =~ ^[A-Za-z0-9.-]+$ ]] || continue
    grep -Eiq "(^|[^a-z0-9])${word//./\\.}([^a-z0-9]|$)" <<<"$1" && return 0
  done
  return 1
}
# 配置加载时的坏组合检查：models.* 点名禁用族只说一次（按 models 配置状态去重）——派发点 pick() 会
# 跳过禁用键，这里让运维在配置一落地就看见，而不是从「评审换了模型」倒查。
warn_forbidden_model_config() { # → say 一行点名全部违规键；无违规或已告警过同状态则静默
  local sig key m bad="" skipped=0
  sig="$(jqf -cS '.models // {}' <<<"$CFG" | cksum | cut -d' ' -f1)"
  [[ "$(cat "$A/.models-policy-warned" 2>/dev/null || true)" == "$sig" ]] && return 0
  printf '%s' "$sig" > "$A/.models-policy-warned"
  while IFS=$'\t' read -r key m; do
    [[ -n "$m" ]] || continue
    if model_forbidden_by_policy "$m" "$key"; then bad+="models.$key=$m "; skipped=1; fi
  done < <(jqf -r '.models // {} | to_entries[] | select(.value | type == "array") | "\(.key)\t\(.value[0] // "")"' <<<"$CFG")
  (( skipped )) || return 0
  say "config models name forbidden model families (pick() skips these keys per model policy): ${bad%, }"
}
model_tuple_field() { # models key + tuple index → field; non-array model settings are skipped
  jqf -r --arg k "$1" --argjson index "$2" '(.models[$k] | select(type == "array"))[$index] // empty' <<<"$CFG"
}
pick_configured_model() { # role [unit-json] → PICK_MODEL/PICK_EFFORT；主模型不可用（禁用族或提供方冷却）时按序用下一个键；都不可用返回 1
  # 带 hotfix 标签的单元先用 models.<role>_hotfix（维护者 2026-10-29：生产热修单都给 terra high 做）。
  # 键序固定（hotfix → role → role_fallback），禁用族键永远跳过并记日志：同一配置每次解析到同一个模型。
  local key m effort service_tier fallback_tuple fallback_model fallback_effort keys=("$1" "$1_fallback") forbidden_hit=""
  jqf -e 'any(.labels[]?; . == "hotfix")' <<<"${2:-"{}"}" >/dev/null 2>&1 && keys=("$1_hotfix" "${keys[@]}")
  for key in "${keys[@]}"; do
    m="$(model_tuple_field "$key" 0)"
    [[ -n "$m" ]] || continue
    local policy_role="$1"
    [[ "$key" != "${1}_fallback" ]] || policy_role="$key"
    if model_forbidden_by_policy "$m" "$policy_role"; then
      say "models.$key=$m is a forbidden family per model policy; skipping to the next key"
      forbidden_hit="$key=$m"
      continue
    fi
    cooling "$(provider_of "$m")" && continue
    [[ "$(provider_of "$m")" != codex ]] || ! codex_week_stopped || continue
    effort="$(model_tuple_field "$key" 1)"; service_tier="$(model_tuple_field "$key" 2)"
    if [[ "$key" == implement_hotfix ]] && model_not_found_cache_has "$m"; then
      fallback_tuple="$(model_not_found_fallback_tuple)" || continue
      IFS=$'\t' read -r fallback_model fallback_effort <<<"$fallback_tuple"
      say "model-not-found cache swap key=$key from=$m to=$fallback_model effort=$fallback_effort"
      m="$fallback_model"; effort="$fallback_effort"; service_tier=""
    fi
    PICK_MODEL="$m"; PICK_EFFORT="$effort"
    PICK_PROVIDER="$(provider_of "$m")"; PICK_HARD=false; PICK_REASON="configured-$key"
    PICK_SERVICE_TIER="$service_tier"
    return 0
  done
  if [[ -n "$forbidden_hit" ]]; then
    say "no $1 model available ($forbidden_hit is forbidden and no allowed key is configured)"
  else
    say "no $1 model available (provider cooldown)"
  fi
  return 1
}

model_policy_role_fields() { # role -> provider, model, effort, service tier for an enabled policy role
  command jq -er --arg role "$1" '
    .roles[$role] as $r
    | select(($r | type) == "object" and $r.disabled != true
        and ($r.provider | type) == "string" and ($r.model | type) == "string"
        and ($r.effort | type) == "string")
    | [$r.provider, $r.model, $r.effort, ($r.service_tier // "")] | @tsv
  ' <<<"${SCHED_MODEL_POLICY_JSON:-{}}"
}

# A tick outlives a quota read, and a read newer than a tick-start NOW_EPOCH reads as unknown: callers pass the current time.
zcode_paced() { # command... -> run it with the current time, not the tick's start
  NOW_EPOCH="$(date +%s)" "$@"
}

pick_zcode_implementer() { # [unit JSON], configured hand-zcode identity -> PICK_* only with a fresh, available quota
  local fields provider model effort tier status
  fields="$(model_policy_role_fields hand-zcode 2>/dev/null || true)"
  [[ -n "$fields" ]] || return 1
  IFS=$'\t' read -r provider model effort tier <<<"$fields"
  [[ "$provider" == zcode ]] || return 1
  model_policy_model_allowed_for_role "$model" hand-zcode || return 1
  zf_zcode_bin_argv >/dev/null 2>&1 || return 1
  zcode_provider_config_model_matches "zcode:$model:$effort" || return 1
  status="$(zcode_paced zcode_quota_status)"
  [[ "$status" == available ]] || return 1
  cooling zcode && return 1
  PICK_PROVIDER=zcode; PICK_MODEL="$model"; PICK_EFFORT="$effort"; PICK_HARD=false; PICK_SERVICE_TIER="$tier"
  return 0
}

pick_claude_implementer() { # hand-claude policy identity -> PICK_* unless the CLI is missing, the policy refuses it, or Claude is held
  local fields provider model effort tier
  fields="$(model_policy_role_fields hand-claude 2>/dev/null || true)"
  [[ -n "$fields" ]] || return 1
  IFS=$'\t' read -r provider model effort tier <<<"$fields"
  [[ "$provider" == claude ]] || return 1
  model_policy_model_allowed_for_role "$model" hand-claude || return 1
  command -v claude >/dev/null 2>&1 || return 1
  provider_quota_exhausted claude && return 1
  cooling claude && return 1
  PICK_PROVIDER=claude  # own line: the source scan flags a forbidden family name beside a model assignment
  PICK_MODEL="$model"; PICK_EFFORT="$effort"; PICK_HARD=false; PICK_SERVICE_TIER=""
  return 0
}

# codex_week_stopped lives in lib.d/codex-budget.sh (shared with run-triage*.sh); scheduler.sh and the tests source it first.
pick_codex_work_identity() { # work policy role, with legacy models.implement as an install-compatible fallback
  local fields provider model effort tier
  if jqf -e 'any(.labels[]?; . == "hotfix")' <<<"$1" >/dev/null 2>&1; then
    if pick_configured_model implement "$1" && [[ "$PICK_PROVIDER" == codex ]]; then
      command -v codex >/dev/null 2>&1 || return 1
      codex_week_stopped "${CODEX_IMPLEMENT_STOP_PCT:-101}" && return 1
      cooling codex && return 1
      return 0
    fi
  fi
  fields="$(model_policy_role_fields work 2>/dev/null || true)"
  if [[ -n "$fields" ]]; then
    IFS=$'\t' read -r provider model effort tier <<<"$fields"
    [[ "$provider" == codex ]] || return 1
    model_policy_model_allowed_for_role "$model" work || return 1
    PICK_PROVIDER=codex; PICK_MODEL="$model"; PICK_EFFORT="$effort"; PICK_HARD=false; PICK_SERVICE_TIER="$tier"
  else
    pick_configured_model implement "$1" || return 1
    [[ "$PICK_PROVIDER" == codex ]] || return 1
  fi
  command -v codex >/dev/null 2>&1 || return 1
  codex_week_stopped "${CODEX_IMPLEMENT_STOP_PCT:-101}" && return 1
  cooling codex && return 1
  return 0
}

hard_implementer_fields() { # optional models.hard; otherwise use the production policy role
  local hard model effort provider tier fields fallback_tuple fallback_model fallback_effort
  hard="$(jqf -c '.models.hard // empty' <<<"$CFG")"
  if [[ -n "$hard" ]]; then
    case "$(command jq -r 'type' <<<"$hard")" in
      array)
        model="$(command jq -r '.[0] // empty' <<<"$hard")"
        effort="$(command jq -r '.[1] // empty' <<<"$hard")"
        tier="$(command jq -r '.[2] // empty' <<<"$hard")"
        ;;
      object)
        model="$(command jq -r '.model // empty' <<<"$hard")"
        effort="$(command jq -r '.effort // empty' <<<"$hard")"
        tier="$(command jq -r '.service_tier // empty' <<<"$hard")"
        provider="$(command jq -r '.provider // empty' <<<"$hard")"
        ;;
      *) return 1 ;;
    esac
    if [[ "$model" == codex:* || "$model" == zcode:* ]]; then
      provider="${model%%:*}"; model="${model#*:}"
    fi
    [[ -n "${provider:-}" ]] || provider="$(provider_of "$model")"
    [[ -n "$model" && -n "$effort" ]] || return 1
  else
    fields="$(model_policy_role_fields production 2>/dev/null || true)"
    [[ -n "$fields" ]] || return 1
    IFS=$'\t' read -r provider model effort tier <<<"$fields"
  fi
  if model_not_found_cache_has "$model"; then
    fallback_tuple="$(model_not_found_fallback_tuple)" || return 1
    IFS=$'\t' read -r fallback_model fallback_effort <<<"$fallback_tuple"
    say "model-not-found cache swap hard-tier from=$model to=$fallback_model effort=$fallback_effort"
    model="$fallback_model"; effort="$fallback_effort"; provider=codex; tier=""
  fi
  [[ "$provider" == codex || "$provider" == zcode || "$provider" == claude ]] || return 1
  PICK_PROVIDER="$provider"; PICK_MODEL="$model"; PICK_EFFORT="$effort"; PICK_SERVICE_TIER="${tier:-}"
}

provider_runtime_ready() { # provider model [role] [unit JSON] -> runnable, policy-authorized and not held
  local provider="$1" model="$2" role="${3:-work}"
  # production is the explicitly configured hard tier; its family can differ
  # from work's allowed families (for example Terra), by design.
  [[ "$role" == production ]] || model_policy_model_allowed_for_role "$model" "$role" || return 1
  cooling "$provider" && return 1
  case "$provider" in
    codex) codex_week_stopped && return 1; command -v codex >/dev/null 2>&1 ;;
    zcode)
      [[ "$(zcode_paced zcode_quota_status)" == available ]] || return 1
      zf_zcode_bin_argv >/dev/null 2>&1 && zcode_provider_config_model_matches "zcode:$model:${PICK_EFFORT:-max}"
      ;;
    claude) ! provider_quota_exhausted claude && command -v claude >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

unit_hard_escalated() { # unit JSON -> true after the two-repair cap or supervisor arbiter
  command jq -e '(.hard_escalated // false) == true
    or any((.history // [])[]?; .stage == "hard-escalation" or .stage == "supervisor-arbiter" or .stage == "supervisor-arbiter-round")' \
    <<<"$1" >/dev/null 2>&1
}

# scheduler.sh runs once per tick; this process-local cache avoids repeating provider probes across units.
declare -A IMPLEMENT_ROUTE_REVIEWABILITY_CACHE=()

implement_route_review_identity_available() { # identity role author-family -> check route reviewability without starting a recovery probe
  local identity="$1" role="$2" author_family="$3" provider="${1%%:*}" model="${1#*:}"; model="${model%:*}"
  if [[ "$provider" == codex ]]; then
    model_policy_model_allowed_for_role "$model" "$role" || { IMPLEMENT_REVIEWER_REASON=policy-refused; return 1; }
    cooling codex && { IMPLEMENT_REVIEWER_REASON=codex-hold; return 1; }
    [[ -e "${CODEX_PROVIDER_PROBE_REQUIRED_FILE:-}" ]] && { IMPLEMENT_REVIEWER_REASON=codex-probe-required; return 1; }
    if provider_quota_exhausted codex && { [[ "$author_family" != glm ]] || ! codex_credits_open review; }; then
      IMPLEMENT_REVIEWER_REASON=codex-hold
      return 1
    fi
    codex_probe_ok || { IMPLEMENT_REVIEWER_REASON=codex-probe-missing; return 1; }
    command -v codex >/dev/null 2>&1 || { IMPLEMENT_REVIEWER_REASON=codex-cli-missing; return 1; }
    IMPLEMENT_REVIEWER_REASON=""
    return 0
  fi
  if review_identity_available "$identity" "$role" "$author_family"; then
    IMPLEMENT_REVIEWER_REASON=""
    return 0
  fi
  IMPLEMENT_REVIEWER_REASON="$(review_identity_unavailable_reason "$identity" "$role")"
  return 1
}

implement_family_has_other_reviewer() { # family -> 0 when review dispatch can select another family now
  local family="$1" codex_identity glm_identity sonnet_identity cross other="" candidate candidate_family candidate_role reason first_reason=""
  codex_identity="$(review_identity_for_model "$(model_tuple_field review 0)" "$(model_tuple_field review 1)" 2>/dev/null || true)"
  glm_identity="$(review_identity_for_model "$(model_tuple_field review_cross 0)" "$(model_tuple_field review_cross 1)" 2>/dev/null || true)"
  sonnet_identity="$(review_identity_for_model "$(model_tuple_field review_fallback 0)" "$(model_tuple_field review_fallback 1)" 2>/dev/null || true)"
  case "$family" in
    codex) cross="$glm_identity" ;; glm) cross="$codex_identity" ;;
    claude)
      cross="${glm_identity:-$codex_identity}"
      case "$(review_identity_family "$cross" 2>/dev/null || true)" in glm) other="$codex_identity" ;; codex) other="$glm_identity" ;; esac
      [[ "$other" == "$cross" ]] && other=""
      ;;
    *) IMPLEMENT_REVIEWER_REASON=review-config; return 1 ;;
  esac
  for candidate in "$cross" "$other" "$sonnet_identity"; do
    candidate_family="$(review_identity_family "$candidate" 2>/dev/null || true)"; [[ -n "$candidate_family" && "$candidate_family" != "$family" ]] && candidate_role=review || continue
    if [[ "$candidate_family" == claude ]]; then candidate_role=review_fallback; [[ "$family" != claude && "$candidate" =~ ^claude:claude-(haiku|sonnet)- ]] || continue; fi
    if implement_route_review_identity_available "$candidate" "$candidate_role" "$family"; then return 0; fi
    reason="$IMPLEMENT_REVIEWER_REASON"; [[ -z "$first_reason" && -n "$reason" ]] && first_reason="${reason// /-}"
  done
  IMPLEMENT_REVIEWER_REASON="${first_reason:-review-config}"
  return 1
}

implement_route_family_reviewable() { # family -> log the skip and alert head-watch once per family/hour
  local family="${1/zcode/glm}" reason
  if [[ -n "${IMPLEMENT_ROUTE_REVIEWABILITY_CACHE[$family]+x}" ]]; then
    IMPLEMENT_REVIEWER_REASON="${IMPLEMENT_ROUTE_REVIEWABILITY_CACHE[$family]}"
  elif zcode_paced implement_family_has_other_reviewer "$family"; then
    IMPLEMENT_ROUTE_REVIEWABILITY_CACHE[$family]=available
    IMPLEMENT_REVIEWER_REASON=available
  else
    IMPLEMENT_ROUTE_REVIEWABILITY_CACHE[$family]="${IMPLEMENT_REVIEWER_REASON:-review-config}"
  fi
  [[ "$IMPLEMENT_REVIEWER_REASON" == available ]] && return 0
  if [[ " ${IMPLEMENT_ROUTE_SKIPS:-} " != *" $family "* ]]; then
    IMPLEMENT_ROUTE_SKIPS="${IMPLEMENT_ROUTE_SKIPS:-} $family"
    reason="${IMPLEMENT_REVIEWER_REASON:-review-config}"; reason="${reason// /-}"
    say "implement-route unreviewable family=$family reason=$reason"
    mkdir -p "$AGENT_HOME/logs"
    grep -F "${STAMP:0:13}" "$AGENT_HOME/logs/head-watch.alerts" 2>/dev/null | grep -Fq "IMPLEMENT-ROUTE-UNREVIEWABLE family=$family " \
      || printf '%s IMPLEMENT-ROUTE-UNREVIEWABLE family=%s reason=%s\n' "$STAMP" "$family" "$reason" >> "$AGENT_HOME/logs/head-watch.alerts"
  fi
  return 1
}

pick_implementer() { # unit JSON -> deterministic sticky assignment plus quota failover
  local u="$1" assigned actual preferred reason issue hash bucket zcode_share claude_share codex_share sum=0 status arbiter=false
  local route_start route_candidate route_share selected="" IMPLEMENT_ROUTE_SKIPS=""
  local -a route_order=(zcode claude codex)
  if unit_hard_escalated "$u"; then
    hard_implementer_fields || { say "no hard implementation identity available"; return 1; }
    actual="$PICK_PROVIDER"
    [[ "$(command jq -r '.hard_escalated // false' <<<"$u")" == true ]] || arbiter=true
    implement_route_family_reviewable "$actual" && provider_runtime_ready "$actual" "$PICK_MODEL" production "$u" || {
      if [[ "$(jqf -r '.models.implement_share.claude // 0' <<<"$CFG")" != 0 ]] \
          && implement_route_family_reviewable claude && pick_claude_implementer; then
        PICK_ROUTE_PROVIDER=claude; PICK_HARD=true; PICK_REASON=hard-fallback-claude
        return 0
      fi
      if implement_route_family_reviewable glm && pick_zcode_implementer "$u"; then
        PICK_ROUTE_PROVIDER=zcode; PICK_HARD=true; PICK_REASON=hard-fallback-zcode
        return 0
      fi
      say "hard implementation provider unavailable provider=$actual unit=$(jqf -r '.id // empty' <<<"$u")"
      return 1
    }
    PICK_ROUTE_PROVIDER="$actual"; PICK_HARD=true
    if [[ "$arbiter" == true ]]; then PICK_REASON=supervisor-arbiter-hard; else PICK_REASON=hard-production; fi
    return 0
  fi

  assigned="$(jqf -r '.implement_route_provider // empty' <<<"$u")"
  actual="$(jqf -r '.implement_provider // empty' <<<"$u")"
  claude_share="$(jqf -r '.models.implement_share.claude // 0' <<<"$CFG")"  # absent = off: an engine upgrade alone never routes to Claude
  zcode_share="$(jqf -r '.models.implement_share.zcode // 0' <<<"$CFG")"
  codex_share="$(jqf -r '.models.implement_share.codex // 100' <<<"$CFG")"
  if [[ "$zcode_share" =~ ^[0-9]+$ && "$claude_share" =~ ^[0-9]+$ && "$codex_share" =~ ^[0-9]+$ ]] \
      && (( zcode_share <= 100 && claude_share <= 100 && codex_share <= 100 )); then
    sum=$((zcode_share + claude_share + codex_share))
  fi
  if [[ "$assigned" != codex && "$assigned" != zcode && "$assigned" != claude ]]; then
    if [[ "$actual" == codex || "$actual" == zcode || "$actual" == claude ]]; then
      assigned="$actual"
      reason="sticky-$actual"
    else
      if (( sum == 100 )); then
        issue="$(jqf -r '.issue // .id // empty' <<<"$u")"
        hash="$(printf '%s' "$issue" | cksum | awk '{print $1 % 100}')"
        # Buckets are laid out zcode, claude, codex: claude=0 leaves every unit where the two-way split put it.
        if (( hash < zcode_share )); then assigned=zcode
        elif (( hash < zcode_share + claude_share )); then assigned=claude
        else assigned=codex; fi
      else
        assigned=codex
      fi
      reason="share-$assigned"
    fi
  else
    reason="sticky-$assigned"
  fi
  preferred="$assigned"
  if [[ "$actual" == codex || "$actual" == zcode || "$actual" == claude ]]; then
    preferred="$actual"
    reason="sticky-$actual"
  fi
  case "$preferred" in
    zcode) route_start=0 ;; claude) route_start=1 ;; codex) route_start=2 ;;
    *) say "no implementation family with an eligible other-family reviewer"; return 1 ;;
  esac
  local -A route_shares=([zcode]="$zcode_share" [claude]="$claude_share" [codex]="$codex_share")
  if [[ "$preferred" == claude && "$claude_share" == 0 ]]; then
    selected="$preferred" # the share-off branch below checks only its Codex/GLM fallbacks
  else
    for route_candidate in "${route_order[@]:route_start}" "${route_order[@]:0:route_start}"; do
      [[ "$route_candidate" == "$preferred" || "$sum" == 100 ]] || continue
      route_share="${route_shares[$route_candidate]}"
      if [[ "$route_candidate" != "$preferred" ]]; then
        [[ "$route_share" =~ ^[0-9]+$ ]] && (( route_share > 0 )) || continue
      fi
      if implement_route_family_reviewable "$route_candidate"; then selected="$route_candidate"; break; fi
    done
  fi
  if [[ -z "$selected" ]]; then
    reason="${IMPLEMENT_REVIEWER_REASON:-review-config}"; reason="${reason// /-}"
    say "no implementation family has an eligible other-family reviewer reason=$reason"
    return 1
  fi
  if [[ "$selected" != "$preferred" ]]; then
    assigned="$selected"; preferred="$selected"; reason="reviewer-fallback-$selected"
  fi
  PICK_ROUTE_PROVIDER="$assigned"; PICK_HARD=false

  if [[ "$preferred" == claude && "$claude_share" != 0 ]]; then
    if pick_claude_implementer; then PICK_REASON="$reason"; return 0; fi
    if provider_quota_exhausted claude || cooling claude; then reason=quota-fallback-claude-to-codex
    else reason=claude-unavailable-fallback-to-codex; fi
    if implement_route_family_reviewable codex && pick_codex_work_identity "$u"; then PICK_REASON="$reason"; return 0; fi
  elif [[ "$preferred" == claude ]]; then
    # Share 0 is the kill switch: sticky Claude units go to Codex, or ZCode over its stop (a fresh session; repair never resumes across providers).
    reason=claude-share-off-codex
    implement_route_family_reviewable codex && pick_codex_work_identity "$u" && { PICK_REASON="$reason"; return 0; }
    implement_route_family_reviewable glm && pick_zcode_implementer "$u" && { PICK_REASON=claude-share-off-zcode; return 0; }
  elif [[ "$preferred" == zcode ]]; then
    status="$(zcode_quota_status)"
    if pick_zcode_implementer "$u"; then PICK_REASON="$reason"; return 0; fi
    if [[ "$status" == exhausted ]]; then reason=quota-fallback-zcode-to-codex
    elif [[ "$status" == unknown ]]; then reason=quota-unknown-zcode-to-codex
    else reason=zcode-unavailable-fallback-to-codex; fi
    if implement_route_family_reviewable codex && pick_codex_work_identity "$u"; then PICK_REASON="$reason"; return 0; fi
  else
    if pick_codex_work_identity "$u"; then PICK_REASON="$reason"; return 0; fi
    status="$(zcode_quota_status)"
    if implement_route_family_reviewable glm && pick_zcode_implementer "$u"; then
      if provider_quota_exhausted codex; then reason=quota-fallback-codex-to-zcode
      else reason=codex-unavailable-fallback-to-zcode; fi
      PICK_REASON="$reason"; return 0
    fi
    [[ "$status" == exhausted ]] || say "zcode implement route unavailable status=$status"
  fi
  if [[ "$claude_share" != 0 ]] && implement_route_family_reviewable claude && pick_claude_implementer; then PICK_REASON=quota-fallback-to-claude; return 0; fi
  say "no implementation provider available (quota, snapshot freshness, or runtime/config unavailable)"
  return 1
}

pick() { # role [unit-json] -> implementation role, otherwise preserve configured model selection
  if [[ "$1" == implement ]]; then
    local unit_json="${2:-}"
    [[ -n "$unit_json" ]] || unit_json='{}'
    pick_implementer "$unit_json"
    return $?
  fi
  # Keep the configured hotfix model path while normal implementation follows the work policy role.
  if [[ "$1" == implement_hotfix ]]; then
    pick_configured_model "$@"
    return $?
  fi
  pick_configured_model "$@"
}

review_identity_for_model() { # model effort → backend:model:effort, or empty for an unclassified model
  local model="$1" effort="$2" family provider
  family="$(review_identity_family "$model" 2>/dev/null || true)"
  case "$family" in
    codex) provider=codex ;;
    glm) provider=zcode ;;
    claude) provider=claude ;;
    *) return 1 ;;
  esac
  [[ -n "$model" && -n "$effort" ]] || return 1
  printf '%s:%s:%s\n' "$provider" "$model" "$effort"
}

unit_review_author_identity() { # unit JSON → the model/backend that last wrote its current head
  local unit_json="$1" identity backend model effort unit_id worker
  identity="$(jqf -r '.implement_identity // empty' <<<"$unit_json")"
  [[ -n "$identity" ]] && { review_identity_family "$identity" >/dev/null 2>&1 && { printf '%s\n' "$identity"; return 0; }; }
  backend="$(jqf -r '.implement_backend // empty' <<<"$unit_json")"
  model="$(jqf -r '.implement_model // empty' <<<"$unit_json")"
  effort="$(jqf -r '.implement_effort // empty' <<<"$unit_json")"
  if [[ -n "$model" && -n "$effort" ]]; then
    if [[ "$backend" == codex || "$backend" == zcode || "$backend" == claude ]]; then
      printf '%s:%s:%s\n' "$backend" "$model" "$effort"
      return 0
    fi
    review_identity_for_model "$model" "$effort" && return 0
  fi
  unit_id="$(jqf -r '.id // empty' <<<"$unit_json")"
  [[ -n "$unit_id" && -r "${WORKERS:-}" ]] || return 1
  worker="$(jqf -c --arg id "$unit_id" '[.workers[]? | select(.unit==$id and (.type=="implement" or .type=="repair"))] | sort_by(.started // .finished_at // "") | last // {}' "$WORKERS")"
  model="$(jqf -r '.model // empty' <<<"$worker")"
  effort="$(jqf -r '.effort // empty' <<<"$worker")"
  backend="$(jqf -r '.provider // empty' <<<"$worker")"
  [[ -n "$effort" ]] || effort="$(jqf -r '.implement_effort // "max"' <<<"$unit_json")"
  if [[ -n "$backend" && -n "$model" ]]; then
    printf '%s:%s:%s\n' "$backend" "$model" "$effort"
  elif [[ -z "$model" && "$unit_id" == pr-* ]]; then
    # No worker wrote this PR, so only its commits can name the author: all of them must carry Claude's trailer, else the review waits.
    [[ "$(gh pr view "${unit_id#pr-}" --json commits -q '[.commits[] | any(.authors[]; .email=="noreply@anthropic.com")] | all' 2>/dev/null)" == true ]] \
      && printf 'claude:unknown:max\n'
  else
    review_identity_for_model "$model" "$effort"
  fi
}

review_wait_reason() { # author codex-identity glm-identity -> one word for why the cross-family reviewer cannot start now
  local cross reason
  cross="$(review_cross_identity_for "$1" "$2" "$3" 2>/dev/null || true)"
  [[ -n "$cross" ]] || { echo no-cross-reviewer; return 0; }
  reason="$(zcode_paced review_identity_unavailable_reason "$cross" review)"
  [[ "$reason" != 'glm hold' ]] || reason+=":$(zcode_paced zcode_quota_status)"
  echo "${reason// /-}"
}

review_wait_summary() { # the waits of this pass, by reason
  local reasons
  reasons="$(tr ' ' '\n' <<<"${TICK_REVIEW_WAITS:-}" | grep . | sort | uniq -c | awk '{printf "%s%s=%s", sep, $2, $1; sep=","}')"
  printf 'review_waits=%s review_wait_reasons=%s' "$(wc -w <<<"${TICK_REVIEW_WAITS:-}")" "${reasons:-none}"
}

pick_review_for_unit() { # unit JSON → sets PICK_MODEL/PICK_EFFORT, or leaves the review pending and alerts once
  local unit_json="$1" id issue author author_family codex_identity glm_identity sonnet_identity selected status wait_reason=author-unknown
  id="$(jqf -r '.id // "unknown"' <<<"$unit_json")"
  issue="$(jqf -r '.issue // empty' <<<"$unit_json")"
  if ! author="$(unit_review_author_identity "$unit_json")"; then
    author_family=unknown
    status=75
  else
    author_family="$(review_identity_family "$author" 2>/dev/null || echo unknown)"
    codex_identity="$(review_identity_for_model "$(model_tuple_field review 0)" "$(model_tuple_field review 1)" 2>/dev/null || true)"
    glm_identity="$(review_identity_for_model "$(model_tuple_field review_cross 0)" "$(model_tuple_field review_cross 1)" 2>/dev/null || true)"
    sonnet_identity="$(review_identity_for_model "$(model_tuple_field review_fallback 0)" "$(model_tuple_field review_fallback 1)" 2>/dev/null || true)"
    status=0
    selected="$(zcode_paced review_model_for_implementer "$issue" "$author" "$codex_identity" "$glm_identity" "$sonnet_identity" "$id")" || status=$?
  fi
  if (( status == 0 )) && [[ -n "$selected" ]]; then
    PICK_MODEL="${selected#*:}"; PICK_EFFORT="${PICK_MODEL##*:}"; PICK_MODEL="${PICK_MODEL%:*}"
    PICK_PROVIDER="${selected%%:*}"
    [[ "$PICK_PROVIDER" != codex ]] || codex_credits_log review "$id"
    PICK_SERVICE_TIER="$(jqf -r --arg m "$PICK_MODEL" '[.models[] | select(type=="array") | select(.[0]==$m) | .[2] // empty][0] // empty' <<<"$CFG")"
    if [[ "$(jqf -r '.review_family_wait_alerted // false' <<<"$unit_json")" == true ]]; then
      set_unit "$id" 'del(.review_family_wait_alerted)'
    fi
    return 0
  fi
  if (( status != 75 )); then
    say "review-family refused unit=$id author=$author_family reviewer=unknown reason=identity-resolution-failed"
    return 1
  fi
  [[ "$author_family" == unknown ]] || wait_reason="$(review_wait_reason "$author" "$codex_identity" "$glm_identity")"
  TICK_REVIEW_WAITS+=" $wait_reason" # the alert below fires once per wait; this counts every pass
  if [[ "$(jqf -r '.review_family_wait_alerted // false' <<<"$unit_json")" != true ]]; then
    say "review-family wait unit=$id author=$author_family reason=no available different-family reviewer detail=$wait_reason"
    set_unit "$id" '.review_family_wait_alerted=true'
  fi
  return 1
}
worker_docs_text() { # 清单项（用途|路径）… → 用途（路径）、用途（路径）
  local entry out="" sep=""
  for entry in "$@"; do out+="${sep}${entry%%|*}（${entry#*|}）"; sep="、"; done
  printf '%s' "$out"
}
