
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

# Review method follows the configured contract path: target config, pack data, then engine default.
REVIEW_SKILL="${ZF_REVIEW_SKILL:-code-review}"
REVIEW_CONTRACT_MD="$(sched_config_file prompts/review-contract.md)"
review_contract_rule() { # 评审、复审 prompt 的契约句；方法文件只取引擎自带的，不跟被评审代码里的同名文件走
  printf '评审方法按 %s 技能（%s）：Standards 与 Spec 两轴分别审、分别报告，不合并不重排，两轴都由你在本会话内自己跑完，不派 sub-agent。verdict 行、review-findings schema 与 author-disposition schema 以 %s 为准（与技能不一致处以它为准）。' \
    "$REVIEW_SKILL" "$(matt_engine_skill_md "$REVIEW_SKILL")" "$REVIEW_CONTRACT_MD"
}
# 实现、修复、自修复 worker 共用的方法句：Matt 的 implement + tdd；缺陷、红 CI、评审发现走 diagnosing-bugs。
matt_method_rule() { # checkout → METHOD 段
  printf 'METHOD（Matt skills）：按 implement 技能（%s）做事，用 tdd 技能（%s）一次一个垂直切片红-绿推进；修缺陷、红 CI 或评审发现时，先按 diagnosing-bugs 技能（%s）造出一条能复现它的红色反馈回路，再改代码。无人可问：技能里要你询问用户、等确认或派 sub-agent 的步骤一律跳过，自己按证据决定；不要自己跑 code-review，流水线会另派独立评审。' \
    "$(matt_skill_md implement "${1:-.}")" "$(matt_skill_md tdd "${1:-.}")" "$(matt_skill_md diagnosing-bugs "${1:-.}")"
}

decision_eval_stages_for_paths() { # newline-delimited paths → affected eval stages
  # The mapping lives in eval/decision-stages.sh, shared with the engine-pin eval gate
  # (engine-sync.sh), so prompt-eval dispatch and pin gating read one decision surface.
  local engine_root="${ZF_ENGINE_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
  ZF_REVIEW_SKILL="$REVIEW_SKILL" bash "$engine_root/eval/decision-stages.sh" <<<"$1"
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

# #424 (ruling eval-regression-auto-revert-2026-11-05): evals still never gate, but a regression on a delivered change reverts it
# through the existing revert path (open_deploy_revert_pr, kind eval; sweep-merges.sh merges the PR). One revert per change.
eval_regression_open_revert() ( # issue culprit gate-sha → revert PR URL
  local preserved_gh=""
  declare -F gh >/dev/null 2>&1 && preserved_gh="$(declare -f gh)"
  source "$SCHEDULER_AGENT_LIB" >/dev/null || return 1
  REPO_DIR="$ROOT" # lib.sh derives it from the engine location; the revert must act on the scheduler's target repo
  [[ -z "$preserved_gh" ]] || eval "$preserved_gh"
  source "${SCHEDULER_AGENT_LIB%/lib.sh}/deploy-culprit.sh" || return 1
  open_deploy_revert_pr "$1" "$2" "$3" eval
)
# A regression is blamed on the unit only when it lies in stages the unit's own diff affects and no earlier delivered
# change with an unproven eval touches them: the eval tree carries every earlier change on main (cf. git bisect).
eval_regression_attributable() { # unit culprit regressed-stages-json
  local unit="$1" culprit="$2" stages="$3" other
  jqf -e --arg id "$unit" --argjson s "$stages" '.units[] | select(.id==$id) | (.eval_gate.stages // []) as $own
    | ($s|length) > 0 and all($s[]; . as $x | $own | index($x) != null)' "$UNITS" >/dev/null || return 1
  while IFS= read -r other; do
    [[ "$other" != "$culprit" ]] && git -C "$ROOT" merge-base --is-ancestor "$other" "$culprit" 2>/dev/null && return 1
  done < <(jqf -r --arg id "$unit" --argjson s "$stages" '.units[] | select(.id != $id and (.eval_gate.status // "") != "" and ((.eval_gate.status | IN("passed","skipped")) | not)
    and ([.eval_gate.stages[]?] | any(IN($s[])))) | (.merge_sha // .land_sha // empty)' <(units_history_doc))
  return 0
}
eval_regression_revert() { # unit gate-sha regressed-stages-json → 0 and the PR URL on stdout when a revert PR was opened; 3 when the change was already reverted; 4 when the regression is not attributable to it
  local unit="$1" gate_sha="$2" stages="$3" culprit issue out url
  culprit="$(unit_field "$unit" '.merge_sha // .land_sha')"; issue="$(unit_field "$unit" '.issue')"
  [[ "$culprit" =~ $SHA_RE && "$issue" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ -z "$(unit_field "$unit" '.eval_gate.revert_pr')" ]] || return 3
  git -C "$ROOT" merge-base --is-ancestor "$culprit" origin/main 2>/dev/null || return 1
  [[ -z "$(git -C "$ROOT" log origin/main -n 1 --format=%H --fixed-strings --grep="This reverts commit $culprit." 2>/dev/null)" ]] || return 3
  [[ "$(git -C "$ROOT" log -n 1 --format=%s "$culprit" 2>/dev/null)" != Revert\ * ]] || return 3
  eval_regression_attributable "$unit" "$culprit" "$stages" || return 4
  out="$(eval_regression_open_revert "$issue" "$culprit" "$gate_sha")" || return 1
  url="$(grep -oE 'https://[^[:space:]]+/pull/[0-9]+' <<<"$out" | tail -n 1)" # the helper's stdout also carries git output
  [[ -n "$url" ]] || return 1
  printf '%s\n' "$url"
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
    elif [[ "$status" == failed && -z "$(unit_field "$unit" '.eval_gate.confirm')" ]]; then
      # One fresh run under its own label (the same label would resume the stored results) before a failure counts:
      # a provider timeout or LLM variance fails a case without the change being at fault (cf. red-main rerun).
      detail="eval label=$label regressed against $baseline on sha $sha; rerunning once before blaming the change; report=$report"
      set_unit "$unit" "$(hist eval-regression-unconfirmed "$detail") | .eval_gate.status=\"pending\" | .eval_gate.confirm=true"
      say "eval regression unconfirmed unit=$unit label=$label; rerun next tick"
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
      local revert_url="" revert_status=0 revert_note=""
      revert_url="$(eval_regression_revert "$unit" "$sha" "$(jqf -c '[(.regressions[] | split("/")[0]), (if (.criticalFailures | length) > 0 then "review" else empty end),
        (if ((.supervisor.failures // []) | length) > 0 then "supervisor" else empty end)] | unique' <<<"$gate")")" || revert_status=$?
      if (( revert_status == 0 )); then
        set_unit "$unit" "$(hist eval-regression-revert "$revert_url") | .eval_gate.revert_pr=$(js "$revert_url")"
        revert_note=" Revert PR opened: $revert_url"
      elif (( revert_status == 4 )); then
        revert_note=" No revert: the regression is outside this change's stages or an earlier delivered change has an unproven eval on them."
      fi
      say "eval failed unit=$unit label=$label baseline=$baseline; delivery unaffected, revert_status=$revert_status ${revert_url}"
      (( revert_status == 3 )) || to_supervisor "$unit" "已交付架构改动的 eval 报告出现回归：$detail$revert_note" \
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
  local u id workdir sha tree label baseline stages report log pid worker active safe_id detail confirm pid_file
  local -a launcher=() worker_command=()
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
    baseline="$(accepted_eval_label)"
    # With no accepted results the gate stops before any case runs, and a retry repeats that on every tick and keeps the unit from retiring.
    if [[ ! -f "$AGENT_HOME/eval/$baseline/results.json" ]]; then
      detail="accepted evaluation label is missing: $baseline"
      set_unit "$id" "$(hist eval-error "$detail") | .eval_gate.status=\"error\" | .eval_gate.error=$(js "$detail")"
      echo "[$STAMP] eval unit=$id error=baseline-missing" >> "$A/alerts/events.md"
      say "eval failed unit=$id: $detail"
      continue
    fi
    (( $(live_workers) < MAX )) || { say "eval pending unit=$id: worker capacity full"; return 0; }
    confirm=""; [[ -z "$(jqf -r '.eval_gate.confirm // empty' <<<"$u")" ]] || confirm=-confirm
    label="gate-$tree$confirm"
    safe_id="$(tr -c 'A-Za-z0-9._-' '-' <<<"$id" | sed 's/-$//')"
    report="eval-gate-${safe_id}-${tree}$confirm.json"
    log="eval-gate-${safe_id}-${tree}$confirm.log"
    rm -f "$SUP/$report"
    set_unit "$id" ".eval_gate.tree=$(js "$tree") | .eval_gate.label=$(js "$label") | .eval_gate.report=$(js "$report")"
    launcher=(); command -v setsid >/dev/null 2>&1 && launcher=(setsid)
    worker_command=(timeout -k 30 14400 node "${ZF_ENGINE_DIR:-$ROOT/engine}/eval/decision-gate.mjs" \
      --repo "$workdir" --sha "$sha" --tree "$tree" --stages "$stages" \
      --baseline "$baseline" --label "$label" --concurrency 3 --output "$SUP/$report")
    pid_file="$(mktemp "$A/.worker-start.XXXXXX")" || return 1
    rm -f -- "$pid_file"
    worker_scope_launch "$pid_file" "$workdir" "$SUP/$log" "${launcher[@]}" -- "${worker_command[@]}" || {
      rm -f -- "$pid_file"; return 1;
    }
    pid="$WORKER_SCOPE_PID"
    rm -f -- "$pid_file"
    worker="$(jqf -cn --argjson pid "$pid" --arg unit "$id" --arg log "$log" --arg report "$report" \
      --arg at "$STAMP" --arg sha "$sha" --arg workdir "$workdir" --arg label "$label" --arg baseline "$baseline" \
      '{pid:$pid,unit:$unit,type:"eval",log:$log,report:$report,started:$at,sha:$sha,workdir:$workdir,eval_label:$label,eval_baseline:$baseline}')"
    jqf --argjson worker "$worker" '.workers += [$worker]' "$WORKERS" | write_state "$WORKERS"
    set_unit "$id" ".eval_gate.status=\"running\" | .eval_gate.label=$(js "$label") | .eval_gate.baseline=$(js "$baseline") | .eval_gate.report=$(js "$report")"
    say "eval dispatched pid=$pid unit=$id label=$label baseline=$baseline stages=$stages"
    return 0
  done < <(jqf -c '.units[] | select((.eval_gate.status // "") == "pending" and (.hold_handoff_waiting // false) == false)' "$UNITS")
}
