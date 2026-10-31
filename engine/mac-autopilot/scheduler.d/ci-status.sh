ci_failed_steps() { # head -> failed step names of the head's failed runs
  local r
  for r in $(gh run list --commit "$1" --json databaseId,conclusion --jq '.[] | select(.conclusion=="failure") | .databaseId' 2>/dev/null); do
    gh api "repos/{owner}/{repo}/actions/runs/$r/jobs" --jq '.jobs[] | select(.conclusion=="failure") | .steps[] | select(.conclusion=="failure") | .name' 2>/dev/null
  done
}
ci_infra_red() { # head -> 0 when every failed step is a runner-environment step
  local steps; steps="$(ci_failed_steps "$1")"
  [[ -n "$steps" ]] && ! grep -qvE "$CI_INFRA_STEP_RE" <<<"$steps"
}

ci_unit_facts() { # id head → 早期测试红路径已为同一 head 解析过的事实；换了 head 就不沿用
  [[ "$(unit_field "$1" .ci_facts_head)" == "$2" ]] && unit_field "$1" .ci_facts
  return 0
}

# 所有 update-branch 都走这一个封装：expected_head_sha 钉住观察到的 head，GitHub 在 head 已变时返回 422，不会更新陌生提交。
ci_update_branch() { # pr head
  tick_prs_changed
  gh api -X PUT "repos/{owner}/{repo}/pulls/$1/update-branch" -f "expected_head_sha=$2" >/dev/null 2>&1
}

ci_red() { # id pr head names：同一 head 首次红只重跑失败的 run（多为 runner 抖动），重跑后仍红才派 repair
  local r n=0
  if [[ "$(unit_field "$1" .ci_rerun_sha)" != "$3" ]] && pr_behind_main "$2" "$3" && [[ "$(tick_pr_mergeable "$2")" == MERGEABLE ]]; then
    # 落后 main 的红多半是旧 base 的红（2026-10-19：main 自身 suites 红，5 个就绪 PR 跟着红）：服务端合入 main 再跑，
    # 不在旧 base 上重跑、不派 LLM 修复；干净合并的新 head 沿用原批准（approval_carries）。
    if ci_update_branch "$2" "$3"; then
      set_unit "$1" "$(hist ci-red-update-branch "$4") | .ci_rerun_sha=$(js "$3")"
      say "merge skipped PR#$2 (checks red on a stale base: $4) -> update-branch"
      return 0
    fi
  fi
  if [[ "$(unit_field "$1" .ci_deferred_sha)" == "$3" ]]; then
    for r in $(gh run list --commit "$3" --json databaseId,conclusion --jq '.[] | select(.conclusion=="failure" or .conclusion=="cancelled") | .databaseId' 2>/dev/null); do
      gh run rerun "$r" --failed >/dev/null 2>&1 && n=$((n+1))
    done
    set_unit "$1" "$(hist ci-deferred-start "$4") | del(.ci_deferred_sha)"
    say "merge skipped PR#$2 (approved head; CI deferred during review) -> started $n run(s)"
    return 0
  fi
  if [[ "$(unit_field "$1" .ci_rerun_sha)" != "$3" ]]; then
    for r in $(gh run list --commit "$3" --json databaseId,conclusion --jq '.[] | select(.conclusion=="failure") | .databaseId' 2>/dev/null); do
      gh run rerun "$r" --failed >/dev/null 2>&1 && n=$((n+1))
    done
    set_unit "$1" "$(hist ci-red-rerun "$4") | .ci_rerun_sha=$(js "$3")"
    say "merge skipped PR#$2 (checks red: $4) -> reran $n failed run(s) once"
    return 0
  fi
  if ci_infra_red "$3"; then
    # runner 环境步骤红（磁盘/容量门、Set up job、checkout 前准备）不是代码结论：不作废批准、不派 LLM 修复，
    # 再重跑；同一 head 连红 CI_INFRA_RERUNS 次交给 supervisor 修 runner（2026-10-20 cihost /data 90% 满，
    # 磁盘门把 PR CI 全拦红，已批准单元被送去 repair 又丢批准）。
    local k decision; k="$(unit_field "$1" '.ci_infra_reruns // 0')"; [[ "$k" =~ ^[0-9]+$ ]] || k=0
    echo "[$STAMP] RUNNER-INFRA-RED PR#$2 head=$3 steps: $(ci_failed_steps "$3" | sort -u | paste -sd ';') (rerun $((k+1))/$CI_INFRA_RERUNS)" >> "$A/alerts/gate.md"
    if (( k < CI_INFRA_RERUNS )); then
      for r in $(gh run list --commit "$3" --json databaseId,conclusion --jq '.[] | select(.conclusion=="failure" or .conclusion=="cancelled") | .databaseId' 2>/dev/null); do
        gh run rerun "$r" --failed >/dev/null 2>&1 && n=$((n+1))
      done
      set_unit "$1" "$(hist ci-infra-red "$4") | .ci_infra_reruns=$((k+1))"
      say "merge skipped PR#$2 (runner environment failure, not the code: $4) -> reran $n run(s), approval kept"
    else
      decision="$(decision_entry 'Stop CI retries and escalate runner failure to supervisor' 'runner environment failure persisted after the retry budget' "head $3 after $k reruns: $4" '["Dispatch a code repair for the runner failure"]' scheduler)"
      set_unit "$1" "$(hist supervisor-review "runner environment failure on head $3 after $k reruns: $4" "$decision") | .stage=\"supervisor-review\""
      say "merge skipped PR#$2 (runner environment failure persists: $4) -> supervisor-review"
    fi
    return 0
  fi
  set_unit "$1" "$(hist ci-red "$4") | .approved_sha=null | .repair_hint=$(js "PR head $3 的必需检查重跑后仍失败：$4。用 gh pr checks $2 与 gh run view <run-id> --log-failed 定位；失败的是集成测试就先在本机测试库复现（RUN_INTEGRATION=1 npx vitest run <文件>，PGTEST_URL 已配好），修到本地绿再 push；本 PR 引起的就修并补回归测试；确属与本 PR 无关的环境故障就不改代码，在报告里写明证据。$(ci_fact_hint "$3" "$(ci_unit_facts "$1" "$3")")") | .stage=\"repair-pending\""
  say "merge skipped PR#$2 (checks still red after rerun: $4) -> repair-pending"
}
ci_cancelled_upstream() { # checks_json
  jqf -e '([.[] | select(.bucket == "fail") | .name] == ["Pipeline suites"])
    and any(.[]; (.name == "Select pipeline-suite scope" or (.name | startswith("Pipeline suites "))) and .bucket == "cancel")' <<<"$1" >/dev/null
}

ci_cancelled() { # id pr head names [upstream]：只重启被取消的 job，不动批准与重跑额度；同一 head 第 CI_CANCEL_RERUNS 次后交 supervisor；upstream=1 时 run 结论是聚合 job 的 failure
  local r n=0 k up="${5:-}" decision
  k=0; [[ "$(unit_field "$1" .ci_cancel_head)" == "$3" ]] && k="$(unit_field "$1" .ci_cancel_reruns)"
  [[ "$k" =~ ^[0-9]+$ ]] || k=0
  if (( k >= CI_CANCEL_RERUNS )); then
    decision="$(decision_entry 'Stop CI retries and escalate repeated cancellation to supervisor' 'CI checks remained cancelled after the retry budget' "head $3 after $k restarts: $4" '["Treat cancellation as a code failure and dispatch repair"]' scheduler)"
    set_unit "$1" "$(hist supervisor-review "checks keep getting cancelled on head $3 after $k restarts: $4" "$decision") | .stage=\"supervisor-review\""
    say "merge skipped PR#$2 (checks cancelled again after $k restarts: $4) -> supervisor-review"
    return 0
  fi
  local sel='.conclusion=="cancelled"'; [[ -n "$up" ]] && sel='.conclusion=="cancelled" or .conclusion=="failure"'
  for r in $(gh run list --commit "$3" --json databaseId,conclusion --jq ".[] | select($sel) | .databaseId" 2>/dev/null); do
    gh run rerun "$r" --failed >/dev/null 2>&1 && n=$((n+1))
  done
  set_unit "$1" "$(hist ci-cancelled-restart "$4") | .ci_cancel_head=$(js "$3") | .ci_cancel_reruns=$((k+1))"
  say "merge skipped PR#$2 (checks cancelled, not failed: $4) -> restarted $n run(s), approval and rerun credit kept"
}

# 停线（Jidoka）：失败 job 的日志里已有测试断言失败（vitest FAIL / AssertionError / TAP not ok），就是确定性的代码结论。
# 以前要等其余检查全部跑完、再整体重跑一次才派修复：热修 #3860 04:15 测试已红，按旧路径约 2 小时后才会开始修（L62）。
ci_test_red_checks() { # checks_json → 第一行：失败日志含测试失败的检查名（逗号分隔，没有则空）；其后每行是该检查日志里 vitest 标记行的结构化事实
  local name link job hits="" logfile facts="" i pid
  local -a names=() logfiles=() pids=()
  # 失败 job 日志有界并行抓（GH_PARALLEL）。
  while IFS=$'\t' read -r name link; do
    job="${link##*/job/}"; [[ "$job" =~ ^[0-9]+$ ]] || continue
    # Dagger 里的 vitest 输出带 ANSI 颜色（ESC[41m FAIL ESC[49m），不去色就匹配不到：热修 #3860 的确定性测试红
    # 三次被当成"旧 base 的红"走 update-branch，每次多耗一整轮 CI（L75）。
    # 一次日志抓取同时给出红判定和 scripts/ci/vitest-fail-facts.mjs 打印的标记行；没有标记行的检查不解析、保持通用提示。
    logfile="$(mktemp)" || continue
    names+=("$name"); logfiles+=("$logfile")
    { gh api --allow-escape-sequences "repos/{owner}/{repo}/actions/jobs/$job/logs" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' > "$logfile"; } &
    pids+=("$!"); gh_par_throttle pids
  done < <(jqf -r '.[] | select(.bucket == "fail") | [.name, (.link // "")] | @tsv' <<<"$1")
  for pid in "${pids[@]}"; do wait "$pid" || :; done
  for i in "${!names[@]}"; do
    logfile="${logfiles[$i]}"
    if grep -qaE ' FAIL  .* > |AssertionError|not ok [0-9]+ -' "$logfile"; then
      name="${names[$i]}"
      hits="${hits:+$hits, }$name"
      facts="${facts}$(grep -a -m1 -oE 'ZENOFORGE-FAIL-FACTS \{.*' "$logfile" | sed 's/^ZENOFORGE-FAIL-FACTS //')"$'\n'
      # run-ci-suites.sh 已为每个失败的 engine 套件打印 "[pipeline suites] FAILED suite=<path>"；同一次抓取里取出，供分诊用
      facts="${facts}$(grep -a -oE '^\[pipeline suites\] FAILED suite=[^ ]+' "$logfile" | sed 's/.*suite=//' | jq -Rsc 'split("\n") | map(select(. != "")) | select(length > 0) | {pipelineSuites: .}' 2>/dev/null)"$'\n'
    fi
    rm -f "$logfile"
  done
  printf '%s\n' "$hits"
  printf '%s' "$facts" | grep -a '^{' || true
}

# 分诊（只出结论，不路由、不写台账）：stale-base / attributable / unknown。失败套件取自 ci_test_red_checks 的事实，
# 改动面取自 GitHub compare 的不可变 SHA 对（PR 自己相对合并基点的改动 + main 自合并基点以来的改动），映射只用
# engine/failure-triage.mjs 里复用的 pipeline-suites-scope.mjs；结果按 SHA 对落盘，同一对不再请求。
ci_compare_cached() { # base head file：SHA 对不可变，已落盘就不再请求
  [[ -s "$3" ]] && return 0
  if gh api "repos/{owner}/{repo}/compare/$1...$2" > "$3.tmp" 2>/dev/null; then mv "$3.tmp" "$3"; else rm -f "$3.tmp"; return 1; fi
}
ci_triage() { # head facts → verdict
  local suites cmp mb prf mainf behind complete=false cache="$A/triage-cache" k
  suites="$(jq -sc '[.[] | ((.pipelineSuites // [])[], ((.suites // [])[] | .file))] | unique' <<<"$2" 2>/dev/null)" || { echo unknown; return 0; }
  [[ -n "$suites" && "$suites" != "[]" && -n "$MAIN_HEAD" ]] || { echo unknown; return 0; }
  mkdir -p "$cache"
  k="$cache/$MAIN_HEAD...$1.json"
  ci_compare_cached "$MAIN_HEAD" "$1" "$k" || { echo unknown; return 0; }
  mb="$(jqf -r '.merge_base_commit.sha // empty' "$k")"; behind="$(jqf -r '.behind_by // 0' "$k")"
  [[ "$mb" =~ $SHA_RE ]] || { echo unknown; return 0; }
  prf="$(jqf -c '[.files[]?.filename]' "$k")"
  k="$cache/$mb...$MAIN_HEAD.json"
  ci_compare_cached "$mb" "$MAIN_HEAD" "$k" || { echo unknown; return 0; }
  mainf="$(jqf -c '[.files[]?.filename]' "$k")"
  # compare 最多返回 300 个文件；达到上限就不完整，按 unknown 处理
  jq -e -n --argjson a "$prf" --argjson b "$mainf" '($a | length) < 300 and ($b | length) < 300' >/dev/null 2>&1 && complete=true
  jq -nc --argjson s "$suites" --argjson a "$prf" --argjson b "$mainf" --argjson n "${behind:-0}" --argjson c "$complete" \
    '{suites: $s, prFiles: $a, mainFiles: $b, behind: $n, complete: $c}' \
    | node "${ZF_ENGINE_DIR:-$ROOT/engine}/failure-triage.mjs" 2>/dev/null || echo unknown
}

# 早期 stale-base 路由：开关开、判定 stale-base、非热修/非关键单元、同一 unit 同一套件还没走过这一跳时，
# 用一次服务端 update-branch 代替 LLM 修复；批准沿用仍只走 approval_carries。第二次同套件 stale-base 落到修复。
# hop 记在台账行 .stale_hops（套件路径列表）。返回 0 = 已更新分支，调用方不再派修复。
ci_stale_base_hop() { # id pr head facts
  [[ "$STALE_BASE_ROUTING" == true ]] || return 1
  [[ "$(unit_field "$1" '.hotpatch // false')" != true && "$(unit_field "$1" '.critical // false')" != true ]] || return 1
  [[ "$(ci_triage "$3" "$4")" == stale-base ]] || return 1
  local suites; suites="$(jq -sc '[.[] | ((.pipelineSuites // [])[])] | unique' <<<"$4" 2>/dev/null)"
  [[ -n "$suites" && "$suites" != "[]" ]] || return 1
  jq -e --argjson s "$suites" --arg id "$1" '[.units[] | select(.id == $id) | (.stale_hops // [])[]] as $h | all($s[]; . as $x | $h | index($x) | not)' "$UNITS" >/dev/null 2>&1 || return 1
  [[ "$(tick_pr_mergeable "$2")" == MERGEABLE ]] || return 1
  ci_update_branch "$2" "$3" || return 1
  set_unit "$1" "$(hist ci-stale-base-update "suites $suites") | .stale_hops = ((.stale_hops // []) + $suites | unique) | .ci_rerun_sha=$(js "$3")"
  say "merge skipped PR#$2 (stale-base failure in $suites) -> update-branch at $3, no repair"
}

# 失败套件与断言事实 → 修复提示片段。facts 是标记行 JSON（每行一个）；PR 改动面只用本地 git（head 对象不在就不说），
# 不推导 import 闭包：只比对 diff 是否触及失败文件或其所在包目录。
ci_fact_hint() { # head facts
  [[ -n "$2" ]] || return 0
  local changed="" txt
  git -C "$ROOT" cat-file -e "$1^{commit}" 2>/dev/null && changed="$(git -C "$ROOT" diff --name-only "origin/main...$1" 2>/dev/null)"
  txt="$(jq -r --arg changed "$changed" --argjson known "$([[ -n "$changed" ]] && echo true || echo false)" '
    (.suites // [])[] | . as $s
    | ($s.file | split("/") | if (.[0] == "packages" or .[0] == "apps") and length > 2 then .[0:2] | join("/") else (.[0:-1] | join("/")) end) as $pkg
    | (if $known then (if ($changed | split("\n") | any(. == $s.file or startswith($pkg + "/"))) then "本 PR diff 触及该套件或其所在目录" else "本 PR diff 未触及该套件所在目录" end) else "" end) as $rel
    | "\($s.file)" + (if $rel != "" then "（\($rel)）" else "" end) + ": "
      + ([$s.tests[] | "\(.name)" + (if .line then " @\(.line)" else "" end) + (if .msg != "" then " — \(.msg)" else "" end)] | join("; "))
      + (if $s.more > 0 then "; 另 \($s.more) 项" else "" end)' <<<"$2" 2>/dev/null | head -c 1500)"
  [[ -n "$txt" ]] && printf ' 失败套件与断言（来自 Vitest 结构化报告）：%s。' "$(paste -sd'|' <<<"$txt")"
  return 0
}

# 12 个 runner 被 PR CI 占满时 main 验证 run 要排队 50 分钟（2026-10-20）。马上会被新 head 取代的 PR run
# （修复已派出）和快车道根本不用的 PR run 先取消，把 runner 让给 main 验证和就绪 PR。
cancel_branch_runs() { # branch reason：reason 里第一个 ';' 之前的部分是写进审计日志的稳定原因
  local r n=0
  [[ -n "$1" ]] || return 0
  for r in $(gh run list --branch "$1" --limit 20 --json databaseId,status,event --jq '.[] | select(.status != "completed" and .event == "pull_request") | .databaseId' 2>/dev/null); do
    ZF_CANCEL_REASON="${2%%;*}" bash "${ZF_ENGINE_DIR:-$ROOT/engine}/night/main-ci-recovery.sh" cancel-run "$r" >/dev/null 2>&1 && n=$((n+1))
  done
  (( n > 0 )) && say "cancelled $n PR run(s) on $1 ($2)"
  return 0
}
ensure_pipeline_ci_label() { # 首次使用前建一次标签；已存在时 GitHub 回 422，忽略
  (( PIPELINE_CI_LABEL_READY )) && return 0
  gh api "repos/{owner}/{repo}/labels" -f name="$PIPELINE_CI_LABEL" -f color=0e8a16 \
    -f description="Pipeline-owned PR: the heavy PR gates run for this branch" >/dev/null 2>&1 || true
  PIPELINE_CI_LABEL_READY=1
}
ensure_gated_label() { # 首次使用前建一次标签；已存在时 GitHub 回 422，忽略
  (( GATED_LABEL_READY )) && return 0
  gh api "repos/{owner}/{repo}/labels" -f name="$GATED_LABEL" -f color=5319e7 \
    -f description="CI starts only when the scheduler marks the PR ready" >/dev/null 2>&1 || true
  GATED_LABEL_READY=1
}
gated_status() { # sha state context description：按 head 绑定的共享状态
  tick_prs_changed # Status writes alter the cached check rollup.
  gh api "repos/{owner}/{repo}/statuses/$1" -f state="$2" -f context="$3" -f description="$4" >/dev/null 2>&1
}
approved_status_on() { # head → 该 head 上有 agent/ci-approved success
  gh api "repos/{owner}/{repo}/commits/$1/status" \
    --jq '[.statuses[]? | select(.context == "agent/ci-approved" and .state == "success")] | length' 2>/dev/null | grep -qx '[1-9][0-9]*'
}
post_approved_status() { # unit sha：PR 车道的批准写成共享状态，其他主机和合并车道的消息读它
  [[ "$2" =~ $SHA_RE ]] || return 0
  [[ -n "$(unit_field "$1" '.pr // empty')" && "$(unit_field "$1" '.lane // empty')" != direct-main ]] || return 0
  gated_status "$2" success agent/ci-approved "approved by the reviewer" || say "unit=$1 could not write agent/ci-approved on ${2:0:9}"
  return 0
}
merge_ref_converts() { # pr → PR 合并引用里的 workflow 已含 converted_to_draft（服务端并发组会取消在跑的 run）
  gh api -X GET "repos/{owner}/{repo}/contents/.github/workflows/pipeline-suites.yml" -f ref="refs/pull/$1/merge" --jq .content 2>/dev/null \
    | base64 -d 2>/dev/null | grep -q converted_to_draft
}
gated_demote_pr() { # pr branch reason：退回 draft；只有合并引用还没有 converted_to_draft 时才补一次带审计的取消
  gh pr ready "$1" --undo >/dev/null 2>&1 || { tick_prs_changed; return 1; }
  tick_prs_set_draft "$1" true
  if [[ -n "${GATED_OF[$2]:-}" ]]; then
    local gated_pr gated_draft gated_head
    read -r gated_pr gated_draft gated_head <<<"${GATED_OF[$2]}"
    GATED_OF["$2"]="$gated_pr true $gated_head"
  fi
  merge_ref_converts "$1" || cancel_branch_runs "$2" "$3"
  return 0
}
gated_flag_pr() { # pr → 给 PR 加门控标签
  ensure_gated_label
  gh pr edit "$1" --add-label "$GATED_LABEL" >/dev/null 2>&1 || { tick_prs_changed; return 1; }
  tick_prs_add_label "$1" "$GATED_LABEL"
}
repair_demote() { # unit pr branch：repair 派出成功后，门控 PR 和符合条件的旧 agent PR 退回 draft，其余保持原来的审计取消
  local reason="repair dispatched; head will change"
  if [[ "$3" =~ $GATED_BRANCH_RE && "$(unit_field "$1" '.hotpatch // false')" != true && "$(unit_field "$1" '.lane // empty')" != direct-main ]] \
    && gated_flag_pr "$2"; then
    set_unit "$1" '.gated=true'
    gated_demote_pr "$2" "$3" "$reason" && return 0
  fi
  cancel_branch_runs "$3" "$reason"
}
scheduler_pr_open() { # branch title body [base] → SCHED_PR_NUM / SCHED_PR_OUT；agent/issue-* 以 draft + 门控标签创建，已有 open 的非 draft PR 就退回 draft 并加标签
  local row pr draft gate=0 title body base="${4:-main}"
  SCHED_PR_NUM=""; SCHED_PR_OUT=""
  [[ "$1" =~ $GATED_BRANCH_RE ]] && gate=1
  row="$(gh pr list --head "$1" --state open --json number,isDraft --jq '.[0] | select(. != null) | "\(.number) \(.isDraft)"' 2>/dev/null)"
  read -r pr draft <<<"$row"
  if [[ "$pr" =~ ^[0-9]+$ ]]; then
    if [[ "$base" != main ]]; then
      tick_prs_changed
      if ! SCHED_PR_OUT="$(gh pr edit "$pr" --base "$base" 2>&1)"; then
        SCHED_PR_NUM=""; return 0
      fi
    fi
    if (( gate )) && [[ "$draft" == false ]] && gated_flag_pr "$pr"; then gated_demote_pr "$pr" "$1" "ci deferred; PR adopted as draft" || true; fi
    SCHED_PR_NUM="$pr"; return 0
  fi
  title="$(scrub_closing_keywords <<<"$2")"
  body="$(scrub_closing_keywords <<<"$3")"
  tick_prs_changed
  if (( gate )); then
    ensure_gated_label
    SCHED_PR_OUT="$(gh pr create --draft --label "$GATED_LABEL" --base "$base" --head "$1" --title "$title" --body "$body" 2>&1)"
  else
    SCHED_PR_OUT="$(gh pr create --base "$base" --head "$1" --title "$title" --body "$body" 2>&1)"
  fi
  SCHED_PR_NUM="$(grep -oE '/pull/[0-9]+' <<<"$SCHED_PR_OUT" | grep -oE '[0-9]+$' | tail -1)"
}
gated_load() { # 一次 open PR 列表读出带门控标签的 PR；读失败或格式错就保持为空，本拍不翻任何 PR
  local listing br pr draft head
  GATED_OF=(); GATED_CENSUS_LOADED=false
  listing="$(tick_prs)" || return 1
  jqf -e 'type == "array"' <<<"$listing" >/dev/null || return 1
  while IFS=$'\t' read -r br pr draft head; do
    [[ -n "$br" && "$pr" =~ ^[0-9]+$ && "$head" =~ $SHA_RE ]] && GATED_OF["$br"]="$pr $draft $head"
  done < <(jqf -r --arg l "$GATED_LABEL" '.[] | select(any(.labels[]?; .name == $l)) | [.headRefName, .number, .isDraft, .headRefOid] | @tsv' <<<"$listing")
  GATED_CENSUS_LOADED=true
  return 0
}
gated_ready() { # id branch approved_head：批准的 head 占到名额（或属于豁免类）才 ready；head 对不上不翻，已 ready 的退回 draft
  local pr draft ghead ready_sha ready_at
  read -r pr draft ghead <<<"${GATED_OF[$2]:-}"
  [[ -n "$pr" ]] || return 0
  GATED_SLOT["$2"]=1
  if [[ "$draft" == false ]] && jqf -e --arg branch "$2" 'index($branch) != null' <<<"${CI_HOTFIX_BRANCHES:-[]}" >/dev/null 2>&1; then
    return 0
  fi
  if [[ "$ghead" != "$3" ]]; then
    [[ "$draft" == false ]] && gated_demote_pr "$pr" "$2" "ci deferred; approval no longer on the live head" \
      && say "gated unit=$1 PR#$pr demoted: approved ${3:0:9} is not the live head ${ghead:0:9}"
    return 0
  fi
  if [[ "$draft" == false ]]; then
    ready_sha="$(unit_field "$1" '.ci_ready_sha // empty')"
    ready_at="$(unit_field "$1" '.ci_ready_at // empty')"
    [[ "$ready_sha" == "$3" && -n "$ready_at" ]] && return 0
    gated_demote_pr "$pr" "$2" "ci deferred; refreshing ready-event evidence" || return 0
    draft=true
  fi
  approved_status_on "$3" || gated_status "$3" success agent/ci-approved "approved by the reviewer" || return 0
  ready_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  gh pr ready "$pr" >/dev/null 2>&1 || { tick_prs_changed; return 0; }
  tick_prs_set_draft "$pr" false
  GATED_OF["$2"]="$pr false $ghead"
  READIED_PRS["$pr"]=1
  [[ "$(unit_field "$1" '.ci_wip_wait // empty')" == "$3" ]] && gated_status "$3" success agent/ci-waiting "CI slot granted"
  set_unit "$1" "$(hist ci-ready "PR#$pr readied on ${3:0:9}") | .ci_ready_sha=$(js "$3") | .ci_ready_at=$(js "$ready_at") | del(.ci_wip_wait) | del(.ci_cancel_reruns)"
  say "gated unit=$1 PR#$pr readied on ${3:0:9}"
}
gated_wait() { # id branch approved_head：没占到名额的门控 PR 留在 draft 并挂共享 waiting 状态；已 ready 的被挤出名额就退回 draft
  local pr draft ghead
  read -r pr draft ghead <<<"${GATED_OF[$2]:-}"
  [[ -n "$pr" && "$ghead" == "$3" ]] || return 0
  [[ "$(unit_field "$1" '.ci_wip_wait // empty')" == "$3" ]] || gated_status "$3" pending agent/ci-waiting "waiting for a CI slot"
  if [[ "$draft" == false ]] && gated_demote_pr "$pr" "$2" "ci wip; displaced from its CI slot"; then
    say "gated unit=$1 PR#$pr demoted: lost its CI slot"
  fi
  return 0
}
gated_ready_exempt() { # 热修（含关联 issue 分类）与非产品 PR 不占产品 CI 名额；其余批准 PR 进入统一排序
  local id br head
  while IFS=$'\t' read -r id br head; do
    [[ -n "$id" ]] || continue
    gated_ready "$id" "$br" "$head"
  done < <(jqf -r --argjson hotfix "${CI_HOTFIX_BRANCHES:-[]}" '.units[] | select(.stage == "ready-to-merge" and (.hold_handoff_waiting // false) == false and (.pr // null) != null and (.lane // "") != "direct-main"
      and ((.hotpatch // false) == true or .product_paths == false or ((.branch // "") as $br | $hotfix | index($br) != null))
      and (.branch // "") != "" and (.approved_sha // "") != "") | [.id, .branch, .approved_sha] | @tsv' "$UNITS")
}
ci_ready_hotfix_gated() { # 先触发门控热修的 ready 事件，让它先进入 runner 队列
  local id br head
  GATED_OF=(); GATED_SLOT=()
  gated_load || return 0
  while IFS=$'\t' read -r id br head; do
    [[ -n "$id" ]] || continue
    gated_ready "$id" "$br" "$head"
  done < <(jqf -r --argjson hotfix "${CI_HOTFIX_BRANCHES:-[]}" '.units[] | select(.stage == "ready-to-merge" and (.hold_handoff_waiting // false) == false and (.pr // null) != null
      and (.lane // "") != "direct-main" and ((.branch // "") as $br | $hotfix | index($br) != null)
      and (.branch // "") != "" and (.approved_sha // "") != "") | [.id, .branch, .approved_sha] | @tsv' "$UNITS")
}
gated_demote_unapproved() { # 门控 PR 已 ready 但单元不在 ready-to-merge/合并中（评审、返工、阻塞）：批准已失效，退回 draft
  local id br stage pr draft ghead
  while IFS=$'\t' read -r id br stage; do
    [[ -n "$id" && -n "${GATED_OF[$br]:-}" && -z "${GATED_SLOT[$br]:-}" ]] || continue
    read -r pr draft ghead <<<"${GATED_OF[$br]}"
    [[ "$draft" == false ]] || continue
    if gated_demote_pr "$pr" "$br" "ci deferred; head is in $stage without an approval"; then
      say "gated unit=$id PR#$pr demoted: approval gone ($stage)"
    fi
  done < <(jqf -r --argjson hotfix "${CI_HOTFIX_BRANCHES:-[]}" '.units[] | select((.hold_handoff_waiting // false) == false and (.pr // null) != null and (.hotpatch // false) != true
      and ((.branch // "") as $br | $hotfix | index($br) == null) and (.branch // "") != ""
      and (.stage | IN("review-pending", "review", "rereview-pending", "rereview", "repair-pending", "repair", "blocked-external"))) | [.id, .branch, .stage] | @tsv' "$UNITS")
}
tick_prs() {
  [[ -n "$TICK_PRS" ]] || TICK_PRS="$(gh pr list --state open --limit 300 --json number,headRefOid,headRefName,baseRefName,isDraft,title,labels,body,statusCheckRollup,mergeable,createdAt 2>/dev/null)" || { TICK_PRS=""; return 1; }
  jqf -e 'type == "array"' <<<"$TICK_PRS" >/dev/null || { TICK_PRS=""; return 1; }
  printf '%s' "$TICK_PRS"
}
tick_prs_prime() { [[ -n "$TICK_PRS" ]] || tick_prs >/dev/null 2>&1 || true; }
tick_prs_changed() { TICK_PRS=""; TICK_PR_CHECK_CENSUS=""; TICK_PR_STATE=(); }
tick_prs_set_draft() { # PR ready/draft writes do not change its census identity or checks
  [[ -n "$TICK_PRS" ]] || return 0
  local updated
  updated="$(jqf --argjson pr "$1" --argjson draft "$2" 'map(if .number==$pr then .isDraft=$draft else . end)' <<<"$TICK_PRS")" || { tick_prs_changed; return 0; }
  TICK_PRS="$updated"
  TICK_PR_CHECK_CENSUS=""
}
tick_prs_add_label() { # mirror a successful label write in the current tick's PR census
  [[ -n "$TICK_PRS" ]] || return 0
  local updated
  updated="$(jqf --argjson pr "$1" --arg label "$2" 'map(if .number==$pr then .labels=((.labels // []) + [{name:$label}] | unique_by(.name)) else . end)' <<<"$TICK_PRS")" || { tick_prs_changed; return 0; }
  TICK_PRS="$updated"
}
ci_hotfix_branches() { # → 当前 open PR 中由 #4615 分类器识别的热修分支
  local prs label prefixes hot
  prs="$(tick_prs)" || return 1
  label="$(hotfix_lane_label)"
  prefixes="$(hotfix_lane_branch_prefixes | jqf -Rsc 'split("\n") | map(select(length > 0))')"
  hot='[]'
  hotfix_issue_numbers >/dev/null && hot="$TICK_HOTFIX_ISSUES"
  jqf -c --arg label "$label" --argjson prefixes "$prefixes" --argjson hot "$hot" '
    [.[] as $pr
      | ([($pr.headRefName // "") | match("^agent/issue-(hf-)?([0-9]+)(-|$)").captures[1].string | tonumber]
          + [($pr.body // "") | match("(?im)^[[:space:]]*[-*]?[[:space:]]*refs[[:space:]:]+#([0-9]+)"; "g").captures[0].string | tonumber]
          | unique) as $linked
      | select(($pr.headRefName // "") != "" and (any($pr.labels[]?; .name == $label)
          or any($prefixes[]; . as $prefix | ($pr.headRefName // "") | startswith($prefix))
          or any($linked[]; . as $n | $hot | index($n) != null)))
      | $pr.headRefName] | unique
  ' <<<"$prs"
}
hotfix_lane_label() { jqf -r '.hotfix_lane.label // "hotfix"' <<<"$CFG"; }
hotfix_lane_branch_prefixes() { jqf -r '.hotfix_lane.branch_prefixes[]? // empty' <<<"$CFG"; }
hotfix_issue_numbers() {
  local label rows
  if [[ "$TICK_HOTFIX_ISSUES_LOADED" != true ]]; then
    TICK_HOTFIX_ISSUES_LOADED=true
    label="$(hotfix_lane_label)"
    rows="$(gh issue list --state open --label "$label" --limit 200 --json number,labels 2>/dev/null)" || return 1
    if ! TICK_HOTFIX_ISSUES="$(jqf -c --arg label "$label" '
      if type != "array" then error("invalid issue census")
      else [.[] | select(any(.labels[]?; .name == $label)) | .number] end
    ' <<<"$rows")"; then TICK_HOTFIX_ISSUES='[]'; return 1; fi
  fi
  jqf -e 'type == "array"' <<<"${TICK_HOTFIX_ISSUES:-[]}" >/dev/null || return 1
  printf '%s' "$TICK_HOTFIX_ISSUES"
}

# PR 已在 GitHub 合并/关闭（如 10-27 手工批量落地），台账却还在工作环节：派活前先收掉。
# 10-28 #4039/#4040 已合并，仍各被派了两轮 repair 与两次裁决。只查不在本拍 open 列表里的单元，每拍有上限。
retire_landed_pr_units() {
  local prs open id pr state n=0
  prs="$(tick_prs)" || return 0
  open="$(jqf -c '[.[].number]' <<<"$prs")"
  while IFS=$'\t' read -r id pr; do
    [[ -n "$id" ]] || continue
    (( n < ${RETIRE_PR_CHECK_MAX:-10} )) || break
    n=$((n + 1))
    state="$(pr_view "$pr" state)"
    [[ -n "$state" ]] && TICK_PR_STATE["$pr"]="$state"
    [[ "$state" == MERGED || "$state" == CLOSED ]] || continue
    [[ "$state" == MERGED ]] && state=merged || state=closed
    set_unit "$id" "$(hist pr-"$state" "PR $state outside the pipeline") | .stage=\"$state\""
    say "unit=$id PR#$pr already $state on GitHub; retired before dispatch"
  done < <(jqf -r --argjson open "$open" '.units[]
    | select((.pr | type) == "number" and (.stage | test("^(closed|landed|merged|done|needs-human)$") | not)
      and (.hold_handoff_waiting // false) == false
      and (.pr as $p | $open | index($p)) == null)
    | [.id, (.pr | tostring)] | @tsv' "$UNITS")
}

# CI 只花在会合并的 head 上（约束理论：瓶颈不做无用功）。CI 是交付瓶颈（10-21 一天批准 110、合并 17），而评审
# 打回率约 43%：repair 一推就跑整套 PR CI，同时评审在审——10-20 07:00 起 39% 的 PR CI 时长花在从未获批的 head 上。
# 评审中的非热修单元，PR run 里没有 job 在跑的就取消（零浪费），记 .ci_deferred_sha；获批进合并车道后由 ci_red 起跑，
# 这次起跑不占"首红重跑一次"的额度。热修照常并行跑，交付时延优先。
ci_cancel_run_once() { # run-id reason：一个 tick 中同一个 run 只接受准入控制器选中的一次取消
  local run="$1"
  [[ -z "${CI_ADMISSION_CANCELLED[$run]:-}" ]] || return 1
  ZF_CANCEL_REASON="$2" bash "${ZF_ENGINE_DIR:-$ROOT/engine}/night/main-ci-recovery.sh" cancel-run "$run" >/dev/null 2>&1 || return 1
  CI_ADMISSION_CANCELLED["$run"]=1
}

ci_defer_unapproved() {
  # 一次批量取未结束的 PR run 再按分支对上单元：逐分支 gh run list 让这一步占了一拍 44–97 秒（10-21 09:10）。
  local id br sha r st jobs n=0
  local -a jobs_to_load=()
  local -A unit_of=()
  while IFS=$'\t' read -r id br; do [[ -n "$br" ]] && unit_of["$br"]="$id"; done \
    < <(jqf -r --argjson hot "${CI_HOTFIX_BRANCHES:-[]}" '.units[] | select((.hold_handoff_waiting // false) == false and (.hotpatch // false) != true
      and ((.branch // "") as $br | $hot | index($br) == null)
      and (.stage | IN("review","review-pending","rereview","rereview-pending")) and (.branch // "") != "") | [.id, .branch] | @tsv' "$UNITS")
  (( ${#unit_of[@]} > 0 )) || return 0
  while IFS=$'\t' read -r r sha st br; do
    [[ "$st" != queued && -n "${unit_of[$br]:-}" ]] && jobs_to_load+=("$r")
  done < <(unfinished_runs | jqf -r '.[] | select(.event == "pull_request") | [.databaseId, .headSha, .status, .headBranch] | @tsv' 2>/dev/null)
  ci_jobs_prefetch "${jobs_to_load[@]}" || :
  while IFS=$'\t' read -r r sha st br; do
    [[ -n "$r" && -n "${unit_of[$br]:-}" ]] || continue
    if [[ "$st" != queued ]]; then
      jobs="$(ci_jobs_status "$r")" || continue
      jqf -e 'all(.[]; . != "in_progress")' <<<"$jobs" >/dev/null 2>&1 || continue
    fi
    ci_cancel_run_once "$r" "ci deferred" || continue
    n=$((n+1)); set_unit "${unit_of[$br]}" ".ci_deferred_sha=$(js "$sha")"
  done < <(unfinished_runs | jqf -r '.[] | select(.event == "pull_request") | [.databaseId, .headSha, .status, .headBranch] | @tsv' 2>/dev/null)
  (( n > 0 )) && say "ci deferred: cancelled $n PR run(s) on heads still in review (CI starts on approval)"
  return 0
}
unfinished_runs() { # → 状态为 queued/in_progress/pending/waiting 的 run（与 gh run list 同字段）；一拍只取一次
  local st tmpdir pid
  local -a pids=()
  [[ "$TICK_UNFINISHED_LOADED" == true ]] && { printf '%s' "$TICK_UNFINISHED"; return 0; }
  tmpdir="$(mktemp -d)" || return 1
  # 四个状态列表有界并行取（GH_PARALLEL），条件请求命中 304 时免主限流配额。
  for st in queued in_progress pending waiting; do
    { if gh_api_cached -p "runs-$st" "repos/{owner}/{repo}/actions/runs?status=$st&per_page=100" \
        --jq '.workflow_runs[] | {databaseId: .id, status: .status, event: .event, headBranch: .head_branch, headSha: .head_sha, workflowName: .name, createdAt: .created_at}' \
        >"$tmpdir/$st"; then
      touch "$tmpdir/$st.ok"
    fi; } &
    pids+=("$!"); gh_par_throttle pids
  done
  for pid in "${pids[@]}"; do wait "$pid" || :; done
  TICK_UNFINISHED="$(cat "$tmpdir"/* | jqf -s 'unique_by(.databaseId)')"
  [[ -e "$tmpdir/in_progress.ok" ]] && TICK_UNFINISHED_IN_PROGRESS_OK=true
  if [[ -e "$tmpdir/queued.ok" && -e "$tmpdir/pending.ok" && -e "$tmpdir/waiting.ok" && -e "$tmpdir/in_progress.ok" ]]; then
    TICK_UNFINISHED_ALL_OK=true
  fi
  rm -rf -- "$tmpdir"
  TICK_UNFINISHED_LOADED=true
  printf '%s' "$TICK_UNFINISHED"
}
ci_jobs_prefetch() { # share full per-run job snapshots within this tick (bounded parallel, GH_PARALLEL)
  local id job_dir pid
  local -a ids=() pids=()
  (( $# > 0 )) || return 0
  job_dir="$(mktemp -d)" || return 1
  for id in "$@"; do
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    # 同一 id 只发一次：两个并发的 gh_api_cached 会写同一个 ETag 缓存文件
    [[ -n "${CI_RUN_JOBS_CACHE[$id]+cached}" || -e "$job_dir/$id" ]] && continue
    : >"$job_dir/$id"
    { gh_api_cached "runjobs-$id" "repos/{owner}/{repo}/actions/runs/$id/jobs?per_page=100" --jq '[.jobs[] | {status, runner_id}]' >"$job_dir/$id" || :; } &
    ids+=("$id"); pids+=("$!"); gh_par_throttle pids
  done
  for pid in "${pids[@]}"; do wait "$pid" || :; done
  for id in "${ids[@]}"; do
    [[ -s "$job_dir/$id" ]] && CI_RUN_JOBS_CACHE["$id"]="$(cat "$job_dir/$id")"
  done
  rm -rf -- "$job_dir"
}
ci_jobs_data() { # run id → one tick's full job snapshot, or a fresh read if it was not prefetched
  local jobs
  if [[ -n "${CI_RUN_JOBS_CACHE[$1]+cached}" ]]; then
    printf '%s' "${CI_RUN_JOBS_CACHE[$1]}"
    return 0
  fi
  jobs="$(gh_api_cached "runjobs-$1" "repos/{owner}/{repo}/actions/runs/$1/jobs?per_page=100" --jq '[.jobs[] | {status, runner_id}]')" || return 1
  CI_RUN_JOBS_CACHE["$1"]="$jobs"
  printf '%s' "$jobs"
}
ci_jobs_status() { ci_jobs_data "$1" | jqf '[.[] | .status]'; }
ci_jobs_active_runner_ids() { ci_jobs_data "$1" | jqf -r '.[] | select(.status == "in_progress") | .runner_id // empty'; }
ci_pr_free_slots() { # → online PR-capable runners minus runners with a job already assigned
  local runner_busy runner_busy_json runner_count active
  local ci_label="${ZF_CI_RUNNER_PREFIX-cihost-ci}" # default mirrors config.sh, which the scheduler does not source
  runner_busy="$(gh_api_cached -p runners "repos/{owner}/{repo}/actions/runners?per_page=100" \
    --jq ".runners[] | select(.status == \"online\" and any(.labels[]; .name | IN(\"$ci_label\",\"$ci_label-light\",\"$ci_label-priority\",\"vecta-suites\"))) | .busy")" || return 1
  runner_busy_json="$(jqf -s '.' <<<"$runner_busy")" || return 1
  runner_count="$(jqf -r 'length' <<<"$runner_busy_json")"
  active="$(jqf '[.[] | select(. == true)] | length' <<<"$runner_busy_json")"
  if (( runner_count > active )); then
    printf '%s\n' "$((runner_count - active))"
  else
    printf '0\n'
  fi
}
