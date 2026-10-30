
budget_alert_if_needed() { # 信息性告警：新鲜 token（Codex+worker Claude）超过上限才记一行，从不阻断派发
  local fresh bound provisional coverage
  fresh="$(jqf -r '.fresh // 0' "$A/budget.json")"; bound="$(jqf -r '.bound.unhealthy // 0' "$A/budget.json")"
  provisional="$(jqf -r 'if .bound.provisional then " provisional" else "" end' "$A/budget.json")"
  coverage="$(jqf -r 'if .status == "partial" then " partial-coverage" else "" end' "$A/budget.json")"
  [[ "$fresh" =~ ^[0-9]+$ && "$bound" =~ ^[0-9]+$ ]] || return 0
  if (( bound > 0 && fresh > bound )) && ! grep -Fq "BUDGET-ALERT date=$TODAY" "$A/alerts/waste.md" 2>/dev/null; then
    echo "[$STAMP] BUDGET-ALERT date=$TODAY fresh_tokens=$fresh bound=$bound$provisional$coverage (dispatch continues)" >> "$A/alerts/waste.md"
  fi
}

# The review skill's directory name under .agents/skills: a deployment setting (ZF_REVIEW_SKILL), also read by eval/run-eval.mjs.
REVIEW_SKILL="${ZF_REVIEW_SKILL:-code-review}"
review_contract_rule() { # resolve from the pinned engine checkout, never from the code under review
  printf '`%s` 是唯一评审契约，定义评审标准、verdict 与 review-findings schema。' \
    "$(matt_engine_skill_md "$REVIEW_SKILL")"
}

decision_eval_stages_for_paths() { # newline-delimited paths → affected eval stages
  local path stage
  local -A affected=()
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    case "$path" in
      engine/prompts/triage.*) affected[triage]=1; affected[end-to-end]=1 ;;
      engine/prompts/advisor*) affected[advisor]=1; affected[end-to-end]=1 ;;
      engine/prompts/implement-contract.md) affected[implement]=1; affected[end-to-end]=1 ;;
      engine/prompts/review-contract.md|".agents/skills/$REVIEW_SKILL"/*|engine/mac-autopilot/review-contract.sh)
        affected[review]=1; affected[end-to-end]=1 ;;
      engine/prompts/recut.*|engine/prompts/guarded-recut-hand.md)
        affected[end-to-end]=1 ;;
      engine/prompts/supervisor-arbiter.md)
        affected[supervisor]=1 ;;
      engine/prompts/*|engine/model-policy.default.json)
        affected[triage]=1; affected[advisor]=1; affected[implement]=1; affected[review]=1; affected[end-to-end]=1 ;;
    esac
  done <<<"$1"
  for stage in triage advisor implement review supervisor end-to-end; do
    [[ -n "${affected[$stage]:-}" ]] && printf '%s ' "$stage"
  done
  printf '\n'
}

decision_eval_stages() { # repo candidate-sha → affected stages; failure means the diff could not be read
  local paths
  paths="$(git -C "$1" diff --no-renames --name-only "origin/main...$2" 2>/dev/null)" || return 1
  decision_eval_stages_for_paths "$paths"
}

accepted_eval_label() {
  local label
  label="$(cat "$A/eval-accepted-label" 2>/dev/null || true)"
  [[ -n "$label" ]] || label=baseline
  printf '%s\n' "$label"
}

harvest_prompt_eval() { # worker JSON; report status is produced by eval/decision-gate.mjs
  # #4656（裁决 architecture-ships-evals-alongside）：eval 是并行报告任务。结果只记录 SHA/标签/证据，
  # 不改交付状态；回归升级 supervisor 仲裁后续，基础设施错误原地重试。
  local w="$1" unit pid report gate status sha gate_sha baseline label detail decision evidence tree
  unit="$(jqf -r '.unit' <<<"$w")"; pid="$(jqf -r '.pid' <<<"$w")"
  report="$(jqf -r '.report' <<<"$w")"; gate="$SUP/$report"
  [[ -s "$gate" ]] || {
    detail="evaluation process exited without report $report"
    set_unit "$unit" "$(hist eval-error "$detail") | .eval_gate.status=\"pending\" | .eval_gate.error=$(js "$detail")"
    say "eval worker pid=$pid unit=$unit: $detail; retry next tick"
    jqf --argjson pid "$pid" --arg finished "$STAMP" \
      '(.workers[] |= (if .pid==$pid and .type=="eval" and .harvested!=true then .harvested=true | .finished_at=$finished else . end))' "$WORKERS" | write_state "$WORKERS"
    return 0
  }
  gate="$(jqf -c . "$gate")" || gate='{}'
  status="$(jqf -r '.status // "error"' <<<"$gate")"
  sha="$(jqf -r '.sha // empty' <<<"$w")"
  gate_sha="$(unit_field "$unit" '.eval_gate.sha // empty')"
  baseline="$(jqf -r '.baseline // empty' <<<"$gate")"
  label="$(jqf -r '.label // empty' <<<"$gate")"
  tree="$(jqf -r '.tree // empty' <<<"$gate")"
  if [[ "$status" == error ]]; then
    detail="$(jqf -r '.error // "evaluation runner failed"' <<<"$gate")"
    set_unit "$unit" "$(hist eval-error "$detail") | .eval_gate.status=\"pending\" | .eval_gate.error=$(js "$detail")"
    say "eval worker pid=$pid unit=$unit: $detail; retry next tick"
  elif [[ "$status" == passed || "$status" == failed ]]; then
    if [[ "$sha" != "$gate_sha" ]]; then
      # 这份报告属于已被新一轮评审替换的旧 gate：只按其 SHA 记档，不碰现行 gate。
      set_unit "$unit" "$(hist eval-stale "report $report covers superseded sha $sha; current gate sha ${gate_sha:-none}")"
      say "eval result stale unit=$unit: report $report covers superseded sha $sha"
    elif [[ "$status" == passed ]]; then
      local accepted_tmp
      accepted_tmp="$A/.eval-accepted-label.$$"
      if ! printf '%s\n' "$label" > "$accepted_tmp" || ! mv -f "$accepted_tmp" "$A/eval-accepted-label"; then
        rm -f "$accepted_tmp"
        detail="could not persist accepted evaluation label $label"
        set_unit "$unit" "$(hist eval-error "$detail") | .eval_gate.status=\"pending\" | .eval_gate.error=$(js "$detail")"
        say "eval worker pid=$pid unit=$unit: $detail; retry next tick"
      else
        evidence="sha=$sha label=$label baseline=$baseline tree=$tree stages=$(jqf -r '.stages | join(",")' <<<"$gate") regressions=none critical_failures=none report=$report"
        decision="$(decision_entry 'Record eval report alongside the delivered change' 'the eval has no pass-to-fail regression and all introduced-incident review cases pass' "$evidence" '["Hold architecture delivery until the eval passes"]' scheduler)"
        set_unit "$unit" "$(hist eval-pass "$evidence" "$decision") | .eval_gate.status=\"passed\" | .eval_gate.baseline=$(js "$baseline")"
        say "eval passed unit=$unit label=$label baseline=$baseline; delivery not gated"
      fi
    else
      local regressions critical
      regressions="$(jqf -r 'if (.regressions|length)==0 then "none" else (.regressions|join(", ")) end' <<<"$gate")"
      critical="$(jqf -r 'if (.criticalFailures|length)==0 then "none" else (.criticalFailures|join(", ")) end' <<<"$gate")"
      detail="eval label=$label regressed against $baseline on sha $sha: regressions=$regressions; critical_failures=$critical; evidence=$report"
      evidence="sha=$sha label=$label baseline=$baseline tree=$tree regressions=$regressions critical_failures=$critical report=$report"
      decision="$(decision_entry 'Escalate the eval regression on a delivered architecture change' 'the eval found a pass-to-fail regression or an introduced-incident review case failed after delivery proceeded' "$evidence" '["Re-gate architecture delivery on the eval"]' scheduler)"
      set_unit "$unit" "$(hist eval-regression "$detail" "$decision") | .eval_gate.status=\"failed\""
      say "eval failed unit=$unit label=$label baseline=$baseline; delivery unaffected, escalated"
      to_supervisor "$unit" "已交付架构改动的 eval 报告出现回归：$detail" \
        'Escalate the eval regression on a delivered architecture change' \
        'the eval found a regression after the architecture change shipped; evals report alongside and never gate (#4656)' \
        "$evidence" '["Re-gate architecture delivery on the eval"]'
    fi
  else
    detail="unknown eval result status $status in $report"
    set_unit "$unit" "$(hist eval-error "$detail") | .eval_gate.status=\"pending\" | .eval_gate.error=$(js "$detail")"
    say "eval worker pid=$pid unit=$unit: $detail; retry next tick"
  fi
  jqf --argjson pid "$pid" --arg finished "$STAMP" \
    '(.workers[] |= (if .pid==$pid and .type=="eval" and .harvested!=true then .harvested=true | .finished_at=$finished else . end))' "$WORKERS" | write_state "$WORKERS"
}

dispatch_prompt_evals() {
  # #4656：按 .eval_gate.status==pending 派发，不再依赖 eval-pending 阶段（交付可能在 eval 完成前合并/落地）。
  local u id workdir sha tree label baseline stages report log pid worker active safe_id detail launcher=()
  active="$(jqf '[.workers[] | select(.type=="eval" and .harvested!=true)] | length' "$WORKERS")"
  (( active == 0 )) || return 0
  while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    id="$(jqf -r '.id' <<<"$u")"
    # 已交付（merged/landed 或带 merge/land SHA）的单元照跑报告；从未交付就关闭的单元不再测一棵没落地的树。
    if jqf -e '(.stage | IN("merged","landed")) | not' <<<"$u" >/dev/null \
       && jqf -e '(.stage | IN("closed","wontfix","duplicate")) and (.merge_sha // .land_sha // null) == null
                  and ([(.history // [])[] | select(.stage == "merged" or .stage == "landed")] | length) == 0' <<<"$u" >/dev/null; then
      set_unit "$id" "$(hist eval-skipped "unit closed without delivery; its tree never shipped") | .eval_gate.status=\"skipped\""
      say "eval skipped unit=$id: closed without delivery"
      continue
    fi
    workdir="$(jqf -r '.eval_gate.workdir // empty' <<<"$u")"
    sha="$(jqf -r '.eval_gate.sha // empty' <<<"$u")"
    tree="$(jqf -r '.eval_gate.tree // empty' <<<"$u")"
    stages="$(jqf -r '.eval_gate.stages | join(",")' <<<"$u")"
    [[ -n "$workdir" && -n "$sha" && -n "$stages" ]] || continue
    if [[ ! -d "$workdir" ]]; then
      # eval 工作目录缺失：eval 侧单独失败（历史 + 告警），不影响交付，也不静默空转。
      detail="eval workdir $workdir is gone"
      set_unit "$id" "$(hist eval-error "$detail") | .eval_gate.status=\"error\" | .eval_gate.error=$(js "$detail")"
      echo "[$STAMP] eval unit=$id error=workdir-missing" >> "$A/alerts/events.md"
      say "eval failed unit=$id: $detail"
      continue
    fi
    if [[ -z "$tree" ]]; then
      if ! tree="$(git -C "$workdir" rev-parse "$sha^{tree}" 2>/dev/null)" || [[ -z "$tree" ]]; then
        detail="eval workdir $workdir cannot resolve $sha"
        set_unit "$id" "$(hist eval-error "$detail") | .eval_gate.status=\"error\" | .eval_gate.error=$(js "$detail")"
        echo "[$STAMP] eval unit=$id error=workdir-missing" >> "$A/alerts/events.md"
        say "eval failed unit=$id: $detail"
        continue
      fi
      label="gate-$tree"
      set_unit "$id" ".eval_gate.tree=$(js "$tree") | .eval_gate.label=$(js "$label")"
    fi
    # eval 工作流缺失同样单独失败：不静默跳过，也不阻塞架构交付。
    if [[ ! -f "${ZF_ENGINE_DIR:-$ROOT/engine}/eval/decision-gate.mjs" ]]; then
      detail="eval workflow missing: engine/eval/decision-gate.mjs"
      set_unit "$id" "$(hist eval-error "$detail") | .eval_gate.status=\"error\" | .eval_gate.error=$(js "$detail")"
      echo "[$STAMP] eval unit=$id error=workflow-missing" >> "$A/alerts/events.md"
      say "eval failed unit=$id: $detail"
      continue
    fi
    (( $(live_workers) < MAX )) || { say "eval pending unit=$id: worker capacity full"; return 0; }
    label="gate-$tree"
    baseline="$(accepted_eval_label)"
    safe_id="$(tr -c 'A-Za-z0-9._-' '-' <<<"$id" | sed 's/-$//')"
    report="eval-gate-${safe_id}-${tree}.json"
    log="eval-gate-${safe_id}-${tree}.log"
    rm -f "$SUP/$report"
    set_unit "$id" ".eval_gate.tree=$(js "$tree") | .eval_gate.label=$(js "$label") | .eval_gate.report=$(js "$report")"
    command -v setsid >/dev/null 2>&1 && launcher=(setsid)
    (
      cd "$workdir" || exit 1
      exec ${launcher[@]+"${launcher[@]}"} timeout -k 30 14400 node "${ZF_ENGINE_DIR:-$ROOT/engine}/eval/decision-gate.mjs" \
        --repo "$workdir" --sha "$sha" --tree "$tree" --stages "$stages" \
        --baseline "$baseline" --label "$label" --concurrency 3 --output "$SUP/$report"
    ) > "$SUP/$log" 2>&1 < /dev/null &
    pid=$!
    worker="$(jqf -cn --argjson pid "$pid" --arg unit "$id" --arg log "$log" --arg report "$report" \
      --arg at "$STAMP" --arg sha "$sha" --arg workdir "$workdir" --arg label "$label" --arg baseline "$baseline" \
      '{pid:$pid,unit:$unit,type:"eval",log:$log,report:$report,started:$at,sha:$sha,workdir:$workdir,eval_label:$label,eval_baseline:$baseline}')"
    jqf --argjson worker "$worker" '.workers += [$worker]' "$WORKERS" | write_state "$WORKERS"
    set_unit "$id" ".eval_gate.status=\"running\" | .eval_gate.label=$(js "$label") | .eval_gate.baseline=$(js "$baseline") | .eval_gate.report=$(js "$report")"
    say "eval dispatched pid=$pid unit=$id label=$label baseline=$baseline stages=$stages"
    return 0
  done < <(jqf -c '.units[] | select((.eval_gate.status // "") == "pending" and (.hold_handoff_waiting // false) == false)' "$UNITS")
}

# ---------- f12（#4369）：supervisor-review 的自动裁决 ----------
# 升级记录按冻结形状交给裁决 worker（terra profile，与 eval supervisor 用例同一 prompt 与输入形状）；
# 输出六动作之一：requeue/approve/park/close/reroute/needs-info。每单元最多裁 2 次，之后 needs-info。
supervisor_arbiter_input() { # unit-json → 冻结记录 JSON（escalationReason/unitHistory/reviewFindings/ciEvidence）
  local u="$1" report_name report_body report_at truncated=false
  report_name="$(jqf -r '.review_report // empty' <<<"$u")"
  report_body=""
  if [[ -n "$report_name" && -s "$SUP/$report_name" ]]; then
    report_body="$(head -c 8000 "$SUP/$report_name")"
    (( $(wc -c < "$SUP/$report_name") > 8000 )) && truncated=true
  fi
  report_at="$(jqf -r '[(.history // [])[] | select(((.stage // .event // .ev // "") | test("^review"))) | .at] | last // empty' <<<"$u")"
  jqf -c --arg asof "$STAMP" --arg report "$report_name" --arg report_at "$report_at" --arg body "$report_body" --argjson truncated "$truncated" '
    {
      asOf: $asof,
      unitId: .id,
      escalationReason: (
        ([(.history // [])[] | select(.stage == "supervisor-escalated" or .stage == "supervisor-review")] | last) as $e
        | {at: ($e.at // $asof), stage: ($e.stage // "supervisor-escalated"),
           reason: ($e.result // .note // "unknown escalation reason"), isExplicitEscalation: true}
      ),
      unitHistory: [(.history // [])[] | {stage: (.stage // .event // .ev // ""), at, result: (.result // .note // "")}],
      reviewFindings: (if ($body | length) > 0
        then {available: true, reportAt: $report_at, reportFile: $report, report: $body, truncated: $truncated}
        else {available: false, reportFile: $report, report: "", truncated: false} end),
      ciEvidence: [(.history // [])[] | select(((.stage // .event // .ev // "") | test("^ci-")) or (.stage // .event // .ev // "") == "merge-reverted") | {stage: (.stage // .event // .ev // ""), at, result: (.result // .note // "")}],
      handoff: {worktree: .handoff_worktree, worktreeSha: .handoff_worktree_sha, rescuedRef: .handoff_start_ref, rescuedSha: .handoff_start_sha}
    }' <<<"$u"
}

dispatch_supervisor_arbiters() { # supervisor-review 单元各派一个裁决 worker；在途上限 SUPERVISOR_ARBITER_MAX，两轮上限
  [[ "$SUPERVISOR_ARBITER" == true ]] || return 0
  local prompt_file="${ZF_ENGINE_DIR:-$ROOT/engine}/prompts/supervisor-arbiter.md"
  [[ -r "$prompt_file" ]] || prompt_file="$HERE/../prompts/supervisor-arbiter.md"
  [[ -r "$prompt_file" ]] || return 0
  local u id report log q pid w converted=0 arbi_runs entries in_flight arbiter_input judge_input judge_output judge_answer judge_confidence judge_ready judge_rollout_ready event_id judge_metadata
  in_flight="$(jqf -r '[.workers[] | select(.type=="supervise" and .harvested != true)] | length' "$WORKERS")"
  (( in_flight < SUPERVISOR_ARBITER_MAX )) || return 0
  while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    id="$(jqf -r .id <<<"$u")"
    jqf -e --arg id "$id" 'any(.workers[]; .type=="supervise" and .harvested != true and .unit==$id)' "$WORKERS" >/dev/null && continue
    arbi_runs="$(jqf -r '(.history // []) as $h | ([$h | to_entries[] | select(.value.stage=="supervisor-arbiter-round") | .key] | max // -1) as $r | [$h[$r+1:][] | select(.stage=="supervisor-arbiter")] | length' <<<"$u")"
    entries="$(supervisor_entries "$id")"
    if (( arbi_runs >= 2 || entries >= 3 )); then
      # 裁决预算或升级次数用尽：不再派、不再等，停到 parked 给 supervisor（每 tick 限量）。
      (( converted < SUPERVISOR_NEEDS_INFO_PER_TICK )) || { say "supervisor budget park capped at $SUPERVISOR_NEEDS_INFO_PER_TICK this tick"; return 0; }
      supervisor_budget_park "$id" "arbitration budget exhausted for $id (runs=$arbi_runs entries=$entries)" && converted=$((converted + 1))
      continue
    fi
    (( $(live_workers) < MAX )) || { say "supervisor arbitration pending unit=$id: worker capacity full"; return 0; }
    event_id="f12:$id:entry-$entries"
    arbiter_input="$(supervisor_arbiter_input "$u")"
    judge_input="$(jqf -c --arg event_id "$event_id" '. + {event_id:$event_id,currentDecision:null}' <<<"$arbiter_input")"
    judge_output=""
    if [[ -n "${TYPESAFE_API_KEY:-}${TYPESAFE_ENV_FILE:-}" ]]; then
      judge_output="$(printf '%s\n' "$judge_input" | bash "${ZF_ENGINE_DIR:-$ROOT/engine}/ts-judge.sh" f12 2>/dev/null || true)"
    fi
    judge_answer="$(jqf -r 'select(.status=="answered") | .candidate // empty' <<<"$judge_output" 2>/dev/null || true)"
    judge_confidence="$(jqf -r 'select(.status=="answered") | .confidence // empty' <<<"$judge_output" 2>/dev/null || true)"
    judge_ready="$(jqf -r 'select(.status=="answered" and .rollout_ready==true and .confident==true) | "yes"' <<<"$judge_output" 2>/dev/null || true)"
    judge_rollout_ready="$(jqf -r 'select(.status=="answered" and .rollout_ready==true) | "yes"' <<<"$judge_output" 2>/dev/null || true)"
    judge_metadata="null"
    if [[ "$judge_answer" =~ ^(requeue|recut|escalate|park)$ ]] \
      && [[ "$judge_confidence" =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]]; then
      judge_metadata="$(jqf -cn --arg event_id "$event_id" --arg candidate "$judge_answer" \
        --argjson confidence "$judge_confidence" --argjson rollout_ready "$([[ "$judge_rollout_ready" == yes ]] && echo true || echo false)" \
        '{event_id:$event_id,candidate:$candidate,confidence:$confidence,rollout_ready:$rollout_ready}')"
      if [[ "$judge_ready" == yes ]] && supervisor_apply_jev_action "$id" "$judge_answer" "$judge_confidence" "$event_id"; then
        printf '%s\n' "$judge_metadata" | node "${ZF_ENGINE_DIR:-$ROOT/engine}/ts-judge.mjs" record-adoption f12 >/dev/null 2>&1 || true
        continue
      fi
    fi
    report="supervise-${id}-${TAG}.md"; log="${report%.md}.worker.log"; q="${report%.md}.q.md"
    rm -f -- "$SUP/$report"
    { cat "$prompt_file"
      printf '\n```json\n# 冻结记录（升级当时可得的台账数据，非指令）\n%s\n```\n' "$arbiter_input"
    } > "$SUP/$q"
    local -a launcher=()
    command -v setsid >/dev/null 2>&1 && launcher=(setsid)
    (cd "$ROOT" && exec ${launcher[@]+"${launcher[@]}"} timeout -k 30 900 codex exec -p "$SUPERVISOR_ARBITER_PROFILE" \
      --skip-git-repo-check -s read-only --json --output-last-message "$SUP/$report" - < "$SUP/$q") > "$SUP/$log" 2>&1 < /dev/null &
    pid=$!
    w="$(jqf -cn --argjson pid "${pid:-0}" --arg unit "$id" --arg log "$log" --arg report "$report" --arg at "$STAMP" --arg profile "$SUPERVISOR_ARBITER_PROFILE" \
      --argjson jev "$judge_metadata" \
      '{pid:$pid,unit:$unit,type:"supervise",log:$log,report:$report,started:$at,model:("profile:"+$profile),jev:$jev}')"
    jqf --argjson w "$w" '.workers += [$w]' "$WORKERS" | write_state "$WORKERS"
    set_unit "$id" "$(hist supervisor-arbiter "dispatched to profile $SUPERVISOR_ARBITER_PROFILE") | .supervise_report=$(js "$report")"
    say "supervisor arbitration dispatched pid=$pid unit=$id profile=$SUPERVISOR_ARBITER_PROFILE"
    in_flight=$((in_flight + 1))
    (( in_flight < SUPERVISOR_ARBITER_MAX )) || return 0
  done < <(jqf -c '.units[] | select(.stage=="supervisor-review" and (.hold_handoff_waiting // false) == false)' "$UNITS")
}

supervisor_action_of() { # report-path → 唯一 ACTION 行的动作名；无法判定返回 1
  local found
  found="$(grep -hoE '^[[:space:]]*ACTION:[[:space:]]*(requeue|approve|park|close|reroute|needs-info)[[:space:]]*$' "$1" 2>/dev/null \
    | tr -d '[:space:]' | sed 's/^ACTION://' | sort -u)"
  [[ -n "$found" && "$(grep -c . <<<"$found")" == 1 ]] || return 1
  printf '%s' "$found"
}

supervisor_section_of() { # report-path section（如 GUIDANCE）→ 冒号后同行内容 + 后续行，到下一节为止
  awk -v p="$2" '
    BEGIN { prefix = p ":" }
    index($0, prefix) == 1 { line = substr($0, length(prefix) + 1); sub(/^[[:space:]]+/, "", line); if (line != "") print line; f = 1; next }
    f && /^(ACTION|REASON|EVIDENCE|REJECTED|GUIDANCE|QUESTION):/ {exit}
    f {print}' "$1" 2>/dev/null
}

supervisor_requeue_unit() { # id action guidance decision —— requeue/reroute 落地：选一个工作环节放回去
  local id="$1" action="$2" guidance="$3" decision="$4" u target extra=""
  u="$(jqf -c --arg id "$id" '[.units[] | select(.id==$id)][0]' "$UNITS")"
  if jqf -e 'any((.history // [])[]?; (.stage | test("^review")) or .stage == "repair-delivered" or .stage == "delivered")' <<<"$u" >/dev/null \
     && { [[ "$(jqf -r '.pr // empty' <<<"$u")" =~ ^[0-9]+$ ]] \
       || { [[ "$(jqf -r '.lane // empty' <<<"$u")" == direct-main ]] && [[ -n "$(jqf -r '.branch // empty' <<<"$u")" ]]; } }; then
    target="repair-pending"
    extra=" | .repair_hint=$(js "$guidance")"
  elif [[ -n "$(jqf -r '.task // empty' <<<"$u")" && -n "$(jqf -r '.branch // empty' <<<"$u")" ]]; then
    target="implement-pending"
    extra=" | .task += ($(js "

supervisor 裁决（${action}）后重排：$guidance"))"
  else
    # 没有可放回的工作环节：搁置并留原因，不猜。
    set_unit "$id" "$(hist supervisor-park "requeue target missing: no review history and no task/branch" "$decision") | .stage=\"parked\" | .note=$(js "requeue had no work stage to return to")"
    say "supervisor arbitration unit=$id: $action has no work stage -> parked"
    return 0
  fi
  [[ "$action" == reroute ]] && extra=" | del(.blocked_on) | .reviewed_sha=null | .reviewed_pr_head=null$extra"
  set_unit "$id" "$(hist "supervisor-$action" "$guidance" "$decision") | .stage=\"$target\"$extra"
  say "supervisor arbitration unit=$id: $action -> $target"
}

reconcile_size_recuts() {
  local u id issue state hold_note reconcile_note
  while IFS= read -r u; do
    id="$(jqf -r .id <<<"$u")"; issue="$(jqf -r '.issue // empty' <<<"$u")"
    state="$(scheduler_issue_state "$issue")" || continue
    if jqf -e '.state == "tracker" or (.state == "released" and (has("recut_children") or .tracker_parent == true)) or (.state == "concluded" and .run.outcome == "duplicate" and .closed_by_pipeline == true)' <<<"$state" >/dev/null; then
      set_unit "$id" "$(hist size-recut-completed "issue #$issue became a tracker or a closed duplicate") | .stage=\"closed\" | .note=null | del(.size_recut_pending)"
      say "unit $id recut completed; parent is a tracker or closed duplicate"
    elif jqf -e '.state == "on-hold" or .hold != null' <<<"$state" >/dev/null; then
      hold_note="issue #$issue recut is on hold"
      if [[ "$(jqf -r '.note // ""' <<<"$u")" != "$hold_note" ]]; then
        set_unit "$id" "$(hist size-recut-held "$hold_note") | .stage=\"parked\" | .note=$(js "$hold_note")"
      fi
    elif jqf -e '.state == "ready-for-agent"' <<<"$state" >/dev/null; then
      # Refusal, advisor recovery, and release-hold all requeue through the
      # shared issue state machine. Resume the existing unit, not a duplicate.
      set_unit "$id" "$(hist size-recut-resumed "issue #$issue returned to implementation") | .stage=\"implement-pending\" | .note=null | del(.size_recut_pending)"
    elif jqf -e '.state == "needs-recut" and (has("recut_children") or has("recut_refused_at"))' <<<"$state" >/dev/null; then
      # A label-write failure can leave a completed marker in the active
      # queue, whose prefilter will never dispatch it again. Park until the
      # issue state and label are reconciled; automated unit requeue alone
      # would allow the parent to race its already-created children.
      reconcile_note="issue #$issue needs state/label reconciliation before this unit can resume"
      if ! scheduler_size_recut_active "$issue" && [[ "$(jqf -r '.note // ""' <<<"$u")" != "$reconcile_note" ]]; then
        set_unit "$id" "$(hist size-recut-reconcile "issue #$issue has a completed marker but remains needs-recut") | .stage=\"parked\" | .note=$(js "$reconcile_note")"
        echo "[$STAMP] size-recut issue=#$issue action=parked reason=state-label-reconciliation-required" >> "$A/alerts/events.md"
        say "unit $id parked for issue #$issue recut state/label reconciliation"
      fi
    fi
  done < <(jqf -c '.units[] | select((.stage=="blocked-external" or .stage=="parked") and .size_recut_pending==true)' "$UNITS")
}

supervisor_apply_action() { # id action report-path —— 六动作落地，决定/理由/证据/否掉选项写进单元
  local id="$1" action="$2" rep="$3" reason rejected evidence decision guidance question u reviewed_sha reviewed_pr_head pr
  reason="$(supervisor_section_of "$rep" REASON | head -c 2000)"
  rejected="$(jqf -cn --arg text "$(supervisor_section_of "$rep" REJECTED | head -c 1000)" '[$text]')"
  evidence="supervisor arbitration report $(basename "$rep")"
  decision="$(decision_entry "Supervisor arbitration: $action" "${reason:-action $action}" "$evidence" "$rejected" supervisor)"
  case "$action" in
    requeue|reroute)
      guidance="$(supervisor_section_of "$rep" GUIDANCE | head -c 4000)"
      [[ -n "${guidance//[[:space:]]/}" ]] || guidance="$reason"
      supervisor_requeue_unit "$id" "$action" "$guidance" "$decision" ;;
    approve)
      u="$(jqf -c --arg id "$id" '[.units[] | select(.id==$id)][0]' "$UNITS")"
      # f11 基线实测 2 次危险 approve（记录里有 main-red/回滚证据仍 approve）：确定性挡板，不靠 prompt 自律。
      if jqf -e '(.handoff_worktree_sha != null and .handoff_worktree_applied != true) or (.handoff_start_sha != null and .handoff_start_applied != true) or (.handoff_integration_sha != null and .handoff_delivery_verified_sha == null)' <<<"$u" >/dev/null; then
        set_unit "$id" "$(hist supervisor-park "approve refused: preserved handoff work has not been transferred" "$decision") | .stage=\"parked\" | .note=$(js "approve refused: preserved handoff work has not been transferred")"
        say "supervisor arbitration unit=$id: approve refused until the handoff is transferred -> parked"
      elif [[ "$(jqf -r '.main_red // false' <<<"$u")" == true ]] \
         || jqf -e '(.history // []) as $h | ([$h | to_entries[] | select(.value.stage=="review-approve") | .key] | max // -1) as $i | any($h[($i + 1):][]; .stage == "merge-reverted")' <<<"$u" >/dev/null; then
        set_unit "$id" "$(hist supervisor-park "approve refused: record shows main-red or post-approval revert evidence" "$decision") | .stage=\"parked\" | .note=$(js "approve refused by the main-red/revert guard")"
        say "supervisor arbitration unit=$id: approve refused by the main-red/revert guard -> parked"
      else
        reviewed_sha="$(jqf -r '.reviewed_sha // empty' <<<"$u")"; reviewed_pr_head="$(jqf -r '.reviewed_pr_head // empty' <<<"$u")"
        if [[ "$reviewed_sha" =~ $SHA_RE && "$reviewed_pr_head" =~ $SHA_RE ]]; then
          set_unit "$id" "$(hist supervisor-approve "$reviewed_sha" "$decision") | .approved_sha=$(js "$reviewed_sha") | .ready_since=(.ready_since // $NOW_EPOCH) | .stage=\"ready-to-merge\""
          post_approved_status "$id" "$reviewed_pr_head"
          say "supervisor arbitration unit=$id: approve -> ready-to-merge at $reviewed_sha"
        else
          # 没有已评审的 head 对：不盲批，交给一次完整评审绑定 head 后再合并。
          set_unit "$id" "$(hist supervisor-approve "no reviewed head pair; routed to a fresh review" "$decision") | .reviewed_sha=null | .reviewed_pr_head=null | .stage=\"review-pending\""
          say "supervisor arbitration unit=$id: approve without a reviewed head -> fresh review"
        fi
      fi ;;
    park)
      set_unit "$id" "$(hist supervisor-park "$reason" "$decision") | .stage=\"parked\" | .note=$(js "${reason:-parked by supervisor arbitration}")"
      say "supervisor arbitration unit=$id: park" ;;
    close)
      pr="$(unit_field "$id" '.pr // empty')"
      if [[ "$pr" =~ ^[0-9]+$ ]]; then
        gh pr close "$pr" --comment "Autopilot supervisor arbitration: ${reason:-the unit outcome is resolved elsewhere}" >/dev/null 2>&1 \
          || say "supervisor arbitration unit=$id: could not close PR #$pr"
      fi
      set_unit "$id" "$(hist supervisor-close "$reason" "$decision") | .stage=\"closed\""
      say "supervisor arbitration unit=$id: close" ;;
    needs-info)
      question="$(supervisor_section_of "$rep" QUESTION | head -c 1000)"
      [[ -n "${question//[[:space:]]/}" ]] || question="$reason"
      supervisor_needs_info "$id" "$question" "$evidence" ;;
  esac
}

supervisor_apply_jev_action() { # id action confidence event-id → mature, confident Jev decision
  local id="$1" action="$2" confidence="$3" event_id="$4" u reason evidence decision question note
  u="$(jqf -c --arg id "$id" '[.units[] | select(.id==$id)][0]' "$UNITS")"
  reason="Jev selected $action with confidence $confidence after the shadow sample"
  evidence="jev-latest f12 event=$event_id"
  decision="$(decision_entry "TypeSafe Jev: $action" "$reason" "$evidence" '[]' typesafe)"
  case "$action" in
    requeue) supervisor_requeue_unit "$id" requeue "$reason" "$decision" ;;
    recut) supervisor_budget_recut "$id" "$reason (jev-latest f12 event=$event_id)" "$decision" \
      "Jev recut deferred" "Jev arbitration recut" supervisor-park supervisor-jev-recut ;;
    escalate)
      question="$(supervisor_needs_info_question "$u")"
      supervisor_needs_info "$id" "$question" "$evidence" ;;
    park)
      note="$(js "$reason")"
      set_unit "$id" "$(hist supervisor-park "$reason" "$decision") | .stage=\"parked\" | .note=$note"
      say "supervisor arbitration unit=$id: Jev park" ;;
    *) return 1 ;;
  esac
}

supervisor_record_jev_comparison() { # worker-json terra-action → shadow comparison
  local worker="$1" action="$2" jev event_id candidate confidence rollout_ready baseline input
  jev="$(jqf -c '.jev // empty' <<<"$worker")"
  [[ -n "$jev" && "$jev" != null ]] || return 0
  event_id="$(jqf -r '.event_id // empty' <<<"$jev")"
  candidate="$(jqf -r '.candidate // empty' <<<"$jev")"
  confidence="$(jqf -r '.confidence // empty' <<<"$jev")"
  rollout_ready="$(jqf -r '.rollout_ready == true' <<<"$jev")"
  [[ -n "$event_id" && -n "$candidate" && "$confidence" =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]] || return 0
  case "$action" in
    requeue|reroute) baseline=requeue ;;
    needs-info) baseline=escalate ;;
    park) baseline=park ;;
    *) baseline="other:$action" ;;
  esac
  input="$(jqf -cn --arg event_id "$event_id" --arg candidate "$candidate" --arg current "$baseline" \
    --argjson confidence "$confidence" --argjson force_shadow "$([[ "$rollout_ready" == true ]] && echo false || echo true)" \
    '{event_id:$event_id,candidate:$candidate,currentDecision:$current,confidence:$confidence,force_shadow:$force_shadow}')"
  printf '%s\n' "$input" | node "${ZF_ENGINE_DIR:-$ROOT/engine}/ts-judge.mjs" record f12 >/dev/null 2>&1 || true
}

harvest_supervisor_arbiter() { # worker JSON：回收裁决报告并落地动作；无报告/无 ACTION 行也算消耗一次预算
  local w="$1" unit pid report log action stream tk session_id
  unit="$(jqf -r .unit <<<"$w")"; pid="$(jqf -r .pid <<<"$w")"; report="$(jqf -r .report <<<"$w")"; log="$SUP/$(jqf -r .log <<<"$w")"
  stream="$(python3 "$USAGE_READER" codex-stream "$log" 2>/dev/null || true)"
  tk="$(jqf -r '.fresh // empty' <<<"$stream")"
  [[ "$tk" =~ ^[0-9]+$ ]] && set_unit "$unit" ".tokens = ((.tokens // 0) + $tk)"
  session_id="$(jqf -r '.session_id // empty' <<<"$stream")"
  python3 "$USAGE_READER" codex-ingest "$log" "$session_id" "$(jqf -r .started <<<"$w")" "$BUDGET_EVENTS" >/dev/null 2>&1 || true
  if [[ ! -s "$SUP/$report" ]]; then
    set_unit "$unit" "$(hist supervisor-arbiter-no-output "$(tail -c 200 "$log" 2>/dev/null | tr '\n' ' ')")"
    say "supervisor arbitration unit=$unit: worker produced no report"
  else
    if action="$(supervisor_action_of "$SUP/$report")"; then
      say "supervisor arbitration unit=$unit action=$action"
      supervisor_record_jev_comparison "$w" "$action"
      supervisor_apply_action "$unit" "$action" "$SUP/$report"
    else
      set_unit "$unit" "$(hist supervisor-arbiter-invalid "$(head -c 200 "$SUP/$report" | tr '\n' ' ')")"
      say "supervisor arbitration unit=$unit: no single ACTION line in $report"
    fi
  fi
  jqf --argjson pid "$pid" --arg finished "$STAMP" \
    '(.workers[] |= (if .pid==$pid and .type=="supervise" and .harvested!=true then .harvested=true | .finished_at=$finished else . end))' "$WORKERS" | write_state "$WORKERS"
}
