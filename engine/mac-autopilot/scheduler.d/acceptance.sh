acceptance_block_from_body() { # stdin: issue 正文 → 首个带 acceptance 数组的 ```json 围栏块（canonical JSON），无则空
  local body block
  body="$(cat)"
  while [[ "$body" == *'```json'* ]]; do
    body="${body#*'```json'}"
    block="${body%%'```'*}"
    body="${body#*'```'}"
    jqf -ce 'if type=="object" and (.acceptance|type)=="array" then . else empty end' <<<"$block" && return 0
  done
  return 1
}

acceptance_live_event_ref() { # acceptance-json → live-event 项绑定的登记表机制 id
  local ref
  ref="$(jqf -r 'first(.acceptance[] | select(.id == "live-event") | .event // empty) // ""' <<<"$1")"
  if [[ -n "$ref" ]]; then
    printf '%s\n' "$ref"
    return 0
  fi
  [[ -r "$MECH_REGISTRY_FILE" ]] || return 1
  jqf -r --arg item "live-event" '
    [.mechanisms[] | select(any(.acceptance_item_ids[]?; . == $item)) | .id]
    | if length == 1 then .[0] else empty end
  ' "$MECH_REGISTRY_FILE"
}

acceptance_has_live_event() { # acceptance-json → 验收块是否含 live-event 项
  jqf -e 'any(.acceptance[]; .id == "live-event")' <<<"$1" >/dev/null 2>&1
}

mechanism_registry_entry() { # mechanism-id → 登记表机制 JSON，未知或登记表缺失为空
  [[ -r "$MECH_REGISTRY_FILE" ]] || return 1
  jqf -ce --arg id "$1" '[.mechanisms[] | select(.id == $id)][0] // empty' "$MECH_REGISTRY_FILE"
}

acceptance_live_event_registered() { # acceptance-json → 0 当 live-event 可解析到已登记机制
  local ref
  ref="$(acceptance_live_event_ref "$1")" || return 1
  [[ -n "$ref" ]] && mechanism_registry_entry "$ref" >/dev/null
}

mechanism_event_after() { # mechanism-json landed-epoch → stdout：晚于落地时间的事件行，无则非零
  local mech="$1" landed="$2" ev base root file pattern path line epoch
  while IFS= read -r ev; do
    base="$(jqf -r '.base // "runtime"' <<<"$ev")"
    file="$(jqf -r '.file // empty' <<<"$ev")"
    pattern="$(jqf -r '.pattern // empty' <<<"$ev")"
    [[ -n "$file" && -n "$pattern" ]] || continue
    if [[ "$base" == agent_home ]]; then root="${AGENT_HOME:-${HOME:-}/.zenoforge}"; else root="$A"; fi
    for path in "$root/$file" "$root/$file.1"; do
      [[ -r "$path" ]] || continue
      while IFS= read -r line; do
        [[ "$line" =~ ^\[([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)\] ]] || continue
        epoch="$(ap_iso_epoch "${BASH_REMATCH[1]}")"
        [[ "$epoch" =~ ^[0-9]+$ ]] || continue
        (( epoch > landed )) || continue
        printf '%s' "$line"
        return 0
      done < <(grep -E -- "$pattern" "$path" 2>/dev/null || true)
    done
  done < <(jqf -c '.events[]?' <<<"$mech")
  return 1
}

landed_live_event_wait() { # unit issue land-sha → 0=无 live-event 项，照旧立即关票；1=已转等待生产事件
  local stored
  stored="$(unit_field "$1" '.acceptance // empty')"
  if [[ -z "$stored" ]]; then
    # M5 之前派发的在途单没有存档：落地时读当前验收块作为基线；读不到按无验收块关票
    stored="$(gh issue view "$2" --json number,title,body,state,labels 2>/dev/null | jqf -r '.body // ""' | acceptance_block_from_body || true)"
  fi
  [[ -n "$stored" ]] || return 0
  acceptance_has_live_event "$stored" || return 0
  set_unit "$1" ".acceptance=$(jqf -ce . <<<"$stored") | .landed_at=$(js "$STAMP") | .stage=\"awaiting-live-event\""
  say "live-event wait unit=$1 issue=$2 sha=$3 已落地、待生效"
  ( source "$SCHEDULER_AGENT_LIB"; supervisor_inbox_append_once "live-event-wait:$2:$3" \
      "live-event-wait issue=#$2 status=已落地、待生效 sha=$3 unit=$1" ) \
    || say "live-event wait unit=$1: supervisor inbox unavailable"
  return 1
}

live_event_watch() { # 每拍：等待生产事件的直落单——事件出现关票、超沉默上限或验收块被改转 supervisor
  local u id issue stored ref mech bound landed landed_epoch evidence issue_json_now current state close_comment close_status
  jqf -e 'any(.units[]; .stage=="awaiting-live-event")' "$UNITS" >/dev/null || return 0
  while read -r u; do
    id="$(jqf -r .id <<<"$u")"
    issue="$(jqf -r '.issue // empty' <<<"$u")"
    stored="$(jqf -ce '.acceptance // empty' <<<"$u" 2>/dev/null)"
    landed="$(jqf -r '.landed_at // empty' <<<"$u")"
    landed_epoch="$(ap_iso_epoch "$landed")"
    if [[ -z "$issue" || -z "$stored" || -z "$landed" || ! "$landed_epoch" =~ ^[0-9]+$ ]]; then
      to_supervisor "$id" "awaiting-live-event 记录缺 issue、验收块存档或落地时间（台账被手工改动过？）"
      continue
    fi
    ref="$(acceptance_live_event_ref "$stored")"
    mech="$(mechanism_registry_entry "$ref")"
    if [[ -z "$ref" || -z "$mech" ]]; then
      ( source "$SCHEDULER_AGENT_LIB"; supervisor_inbox_append_once "live-event-unbound:$issue" \
          "live-event-unbound issue=#$issue status=已落地、待生效：live-event 项未引用登记表机制，无法自动观测，等 supervisor 处理" ) >/dev/null 2>&1 \
        || say "live-event wait unit=$id issue=$issue: unbound live-event, supervisor inbox unavailable"
      continue
    fi
    bound="$(jqf -r '.silence_hours // 24' <<<"$mech")"
    [[ "$bound" =~ ^[0-9]+$ ]] || bound=24
    if evidence="$(mechanism_event_after "$mech" "$landed_epoch")"; then
      issue_json_now="$(gh issue view "$issue" --json number,title,body,state,labels,comments 2>/dev/null)"
      if [[ -z "$issue_json_now" ]]; then
        say "live-event wait unit=$id issue=$issue: event observed but issue read failed; retry next tick"
        continue
      fi
      current="$(jqf -r '.body // ""' <<<"$issue_json_now" | acceptance_block_from_body || true)"
      if [[ "$current" != "$stored" ]]; then
        to_supervisor "$id" "M5：#$issue 验收块与派发/落地存档不一致，拒绝按 live-event 关票（验收项不得改动）"
        continue
      fi
      state="$(jqf -r '.state // ""' <<<"$issue_json_now")"
      if [[ "$state" != "OPEN" && "$state" != "CLOSED" ]]; then
        say "live-event wait unit=$id issue=$issue: event observed but issue state is unreadable; retry next tick"
        continue
      fi
      close_comment="结案：已落地 $(jqf -r '.land_sha // "见台账"' <<<"$u")（direct-main 车道）并观测到登记的生产事件 ${ref}。证据：${evidence:0:400}"
      if ! (
        source "$SCHEDULER_AGENT_LIB" || exit 1
        pipeline_system_close_comment_valid "$ROOT" "$issue" "$close_comment" false "${MAIN_HEAD:-origin/main}"
      ); then
        to_supervisor "$id" "M5：#$issue 已观测到 ${ref}，但落地 SHA 不满足 pipeline-system 结案证据，拒绝自动关票"
        continue
      fi
      close_status=0
      if [[ "$state" == "CLOSED" ]]; then
        if ! jqf -e --arg comment "$close_comment" 'any(.comments[]?; .body == $comment)' <<<"$issue_json_now" >/dev/null; then
          ( source "$SCHEDULER_AGENT_LIB" && guarded_write gh issue comment "$issue" --repo "${ZF_REPO:-example-maintainer/example-repo}" --body "$close_comment" ) >/dev/null 2>&1 || close_status=$?
        fi
      else
        ( source "$SCHEDULER_AGENT_LIB" && guarded_write gh issue close "$issue" --repo "${ZF_REPO:-example-maintainer/example-repo}" --reason completed --comment "$close_comment" ) >/dev/null 2>&1 || close_status=$?
      fi
      if (( close_status == 0 )); then
        set_unit "$id" "$(hist live-event-closed "$ref") | .stage=\"closed\""
        say "live-event close issue=$issue unit=$id event=$ref evidence=$(js "${evidence:0:200}")"
      else
        say "live-event wait unit=$id issue=$issue: event observed but gh issue close failed; retry next tick"
      fi
    elif (( NOW_EPOCH - landed_epoch > bound * 3600 )); then
      to_supervisor "$id" "M5：#$issue 落地后超过沉默上限 ${bound}h 仍未出现登记事件 ${ref}，已落地、待生效转 supervisor"
    fi
  done < <(jqf -c '.units[] | select(.stage=="awaiting-live-event")' "$UNITS")
}
