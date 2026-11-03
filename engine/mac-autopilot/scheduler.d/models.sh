
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
  done < <(jqf -r '.models // {} | to_entries[] | "\(.key)\t\(.value[0] // "")"' <<<"$CFG")
  (( skipped )) || return 0
  say "config models name forbidden model families (pick() skips these keys per model policy): ${bad%, }"
}
pick() { # role [unit-json] → PICK_MODEL/PICK_EFFORT；主模型不可用（禁用族或提供方冷却）时按序用下一个键；都不可用返回 1
  # 带 hotfix 标签的单元先用 models.<role>_hotfix（维护者 2026-10-29：生产热修单都给 terra high 做）。
  # 键序固定（hotfix → role → role_fallback），禁用族键永远跳过并记日志：同一配置每次解析到同一个模型。
  local key m keys=("$1" "$1_fallback") forbidden_hit=""
  jqf -e 'any(.labels[]?; . == "hotfix")' <<<"${2:-"{}"}" >/dev/null 2>&1 && keys=("$1_hotfix" "${keys[@]}")
  for key in "${keys[@]}"; do
    m="$(jqf -r --arg k "$key" '.models[$k][0] // empty' <<<"$CFG")"
    [[ -n "$m" ]] || continue
    local policy_role="$1"
    [[ "$key" != "${1}_fallback" ]] || policy_role="$key"
    if model_forbidden_by_policy "$m" "$policy_role"; then
      say "models.$key=$m is a forbidden family per model policy; skipping to the next key"
      forbidden_hit="$key=$m"
      continue
    fi
    cooling "$(provider_of "$m")" && continue
    PICK_MODEL="$m"; PICK_EFFORT="$(jqf -r --arg k "$key" '.models[$k][1] // empty' <<<"$CFG")"
    return 0
  done
  if [[ -n "$forbidden_hit" ]]; then
    say "no $1 model available ($forbidden_hit is forbidden and no allowed key is configured)"
  else
    say "no $1 model available (provider cooldown)"
  fi
  return 1
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
  else
    review_identity_for_model "$model" "$effort"
  fi
}

pick_review_for_unit() { # unit JSON → sets PICK_MODEL/PICK_EFFORT, or leaves the review pending and alerts once
  local unit_json="$1" id issue author author_family codex_identity glm_identity sonnet_identity selected status
  id="$(jqf -r '.id // "unknown"' <<<"$unit_json")"
  issue="$(jqf -r '.issue // empty' <<<"$unit_json")"
  if ! author="$(unit_review_author_identity "$unit_json")"; then
    author_family=unknown
    status=75
  else
    author_family="$(review_identity_family "$author" 2>/dev/null || echo unknown)"
    codex_identity="$(review_identity_for_model "$(jqf -r '.models.review[0] // empty' <<<"$CFG")" "$(jqf -r '.models.review[1] // empty' <<<"$CFG")" 2>/dev/null || true)"
    glm_identity="$(review_identity_for_model "$(jqf -r '.models.review_cross[0] // empty' <<<"$CFG")" "$(jqf -r '.models.review_cross[1] // empty' <<<"$CFG")" 2>/dev/null || true)"
    sonnet_identity="$(review_identity_for_model "$(jqf -r '.models.review_fallback[0] // empty' <<<"$CFG")" "$(jqf -r '.models.review_fallback[1] // empty' <<<"$CFG")" 2>/dev/null || true)"
    status=0
    selected="$(review_model_for_implementer "$issue" "$author" "$codex_identity" "$glm_identity" "$sonnet_identity" "$id")" || status=$?
  fi
  if (( status == 0 )) && [[ -n "$selected" ]]; then
    PICK_MODEL="${selected#*:}"; PICK_EFFORT="${PICK_MODEL##*:}"; PICK_MODEL="${PICK_MODEL%:*}"
    if [[ "$(jqf -r '.review_family_wait_alerted // false' <<<"$unit_json")" == true ]]; then
      set_unit "$id" 'del(.review_family_wait_alerted)'
    fi
    return 0
  fi
  if (( status != 75 )); then
    say "review-family refused unit=$id author=$author_family reviewer=unknown reason=identity-resolution-failed"
    return 1
  fi
  if [[ "$(jqf -r '.review_family_wait_alerted // false' <<<"$unit_json")" != true ]]; then
    say "review-family wait unit=$id author=$author_family reason=no available different-family reviewer"
    set_unit "$id" '.review_family_wait_alerted=true'
  fi
  return 1
}
worker_docs_text() { # 清单项（用途|路径）… → 用途（路径）、用途（路径）
  local entry out="" sep=""
  for entry in "$@"; do out+="${sep}${entry%%|*}（${entry#*|}）"; sep="、"; done
  printf '%s' "$out"
}
