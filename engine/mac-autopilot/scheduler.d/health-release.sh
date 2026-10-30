
# 每拍按 NODE-HEALTH.md 的标准给各环节打分：快照写 node-health.txt，UNHEALTHY 写 alerts/node-health.md（每指标每小时一次）；
# 持续 3 小时 UNHEALTHY 的指标自动开/续 pipeline-system issue，由流水线自己修（maintainer 2026-10-20：系统要自己发现并报告异常）。
# flow.* 流动指标越过缺陷阈值时另发一条 supervisor inbox 事件（每越限一次只发一条，#4366）；常规采样只进 dashboard。
run_node_health() {
  [[ -f "$HERE/node_health.py" ]] || return 0
  python3 "$HERE/node_health.py" --runtime "$A" --hours 5 --alert --file-issues --inbox --json "$A/node-health.json" > "$A/node-health.txt" 2>>"$A/autopilot.err" || say "node health scoring failed"
  # CI 花费采样要逐个取 job（首次几百次 API 调用）：每 30 分钟在后台跑一次，不占调度拍。
  # 没有 pid 文件时不能退成 kill -0 0：0 是本进程组，永远成功，采样就永远不启动（L71 体检时 CI 浪费一直 NO-DATA）。
  local cs_pid; cs_pid="$(cat "$A/.ci-spend.pid" 2>/dev/null || true)"
  if [[ -f "$HERE/ci_spend.py" ]] && ! { [[ "$cs_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$cs_pid" 2>/dev/null; } \
    && [[ -z "$(find "$A" -maxdepth 1 -name ci-spend.json -mmin -30 2>/dev/null)" ]]; then
    (cd "$ROOT" && exec setsid python3 "$HERE/ci_spend.py" --runtime "$A" --hours 5) >> "$A/ci-spend.log" 2>&1 < /dev/null &
    echo $! > "$A/.ci-spend.pid"
  fi
}
phase() { local t0=$SECONDS rc=0; "$@" || rc=$?; (( SECONDS - t0 >= 5 )) && TICK_PHASES+=" $1=$((SECONDS - t0))s"; return $rc; }

stage_slo_watch() {
  local budgets row id stage since key
  budgets="$(jqf -c '.stage_slo_minutes // {"pending":30,"ready-to-merge":120,"landing":60,"supervisor-review":60,"blocked-external":240}' <<<"$CFG")"
  while IFS=$'\t' read -r id stage since key; do
    [[ -n "$id" ]] || continue
    set_unit "$id" ".slo_alerted=$(js "$key")"
    echo "[$STAMP] SLO-BREACH unit=$id stage=$stage waiting ${since}min" >> "$A/alerts/slo.md"
  done < <(jqf -r --argjson b "$budgets" --argjson now "$NOW_EPOCH" '
      .units[] | select(.stage | test("^(closed|landed|merged|done)$") | not)
      | ((.history // []) | map(select(.at != null)) | last | .at // empty) as $at | select($at != null)
      | ($at | sub("\\.[0-9]+"; "") | fromdateiso8601) as $t
      | (if (.stage | endswith("-pending")) then "pending" else .stage end) as $class
      | select($b[$class] != null and ($now - $t) > ($b[$class] * 60))
      | (.stage + "@" + $at) as $key | select((.slo_alerted // "") != $key)
      | "\(.id)\t\(.stage)\t\((($now - $t) / 60) | floor)\t\($key)"' "$UNITS" 2>/dev/null)
}

# ---------- 4c. 发布列车：每 15 分钟触发 issue-pipeline 的 release 选择器（单实例） ----------
run_release_train() {
  local train_script="${ZF_RELEASE_TRAIN_SCRIPT:-$HERE/release_train.sh}"
  [[ "$(jqf -r 'if .release_train.enabled == false then "false" else "true" end' <<<"$CFG")" == true ]] || return 0
  [[ -f "$train_script" ]] || return 0
  [[ ! -f "$A/.release-train" || -n "$(find "$A/.release-train" -mmin +15 2>/dev/null)" ]] || return 0
  systemctl --user is-active --quiet ${UNIT_PREFIX_TRANSIENT}-release-train 2>/dev/null && return 0
  touch "$A/.release-train"
  # 本服务只有大写代理变量；-E 一个未设置的小写名会让 systemd 设成空串，libcurl 优先读小写，
  # 空 https_proxy = 直连被墙的 GitHub（10-22 17:37Z 起委托切片的 git fetch 每次卡 60s 超时）
  local -x http_proxy="${http_proxy:-${HTTP_PROXY:-}}" https_proxy="${https_proxy:-${HTTPS_PROXY:-}}" no_proxy="${no_proxy:-${NO_PROXY:-}}"
  if systemd-run --user --unit ${UNIT_PREFIX_TRANSIENT}-release-train --collect -p RuntimeMaxSec=10800 \
      -E PATH -E HOME -E HTTP_PROXY -E HTTPS_PROXY -E ALL_PROXY -E NO_PROXY \
      -E http_proxy -E https_proxy -E no_proxy -E NODE_USE_ENV_PROXY \
      -E MAC_AUTOPILOT_RUNTIME_DIR="$A" -E MAC_AUTOPILOT_ROOT="$ROOT" \
      /bin/bash -c "exec /bin/bash '$train_script' >> '$A/release-train.log' 2>&1" >/dev/null 2>&1; then
    say "release train started"
  else
    say "release train launch failed"
  fi
}

# 修 main 单元的共用车道守卫：同 id 幂等；已转人工的旧单元给新的红让位；同一时间只保留一个在途修 main 单元。
main_red_lane_ready() { # unit-id new-red-sha；rc 0 = 可以开新单元
  local id="$1" sha="$2" stale
  jqf -e --arg id "$id" 'any(.units[]; .id == $id)' "$UNITS" >/dev/null && return 1
  # 旧 SHA 的修 main 单元已转人工（如只能改 workflow）：新的红不能被它挡住，旧单元作废。
  for stale in $(jqf -r '.units[] | select(.main_red == true and .stage == "supervisor-review") | .id' "$UNITS"); do
    set_unit "$stale" "$(hist superseded "main red again at $sha") | .stage=\"closed\""
    say "main-red unit $stale superseded by a new failure at $sha"
  done
  jqf -e 'any(.units[]; .main_red == true and (.stage | test("^(closed|landed|merged|done)$") | not))' "$UNITS" >/dev/null && return 1
  return 0
}

# main 的 Pipeline suites 红：立即开一个修 main 的直落单元（不等 supervisor 5 小时一查；2026-10-19 门禁因此关了 6 小时）。
open_main_red_unit() { # sha run-id attempt (a repeated, classified code failure)
  local id="main-red-${1:0:9}" failed task attempt="${3:-}"
  local recovery_session="${AGENT_HOME:-${HOME:-}/.zenoforge}/main-red/$1.json"
  [[ "$attempt" =~ ^[1-9][0-9]*$ ]] || return 0
  if jqf -e --arg sha "$1" '
    .red_sha == $sha and .red_workflow == "pipeline-suites.yml"
      and (.status == "rerun-requested" or .status == "bisecting"
        or .status == "culprit-found" or .status == "revert-open" or .status == "unattributed")
  ' "$recovery_session" >/dev/null 2>&1; then
    say "main-red unit $id deferred to the Pipeline suites bisect session"
    return 0
  fi
  main_red_lane_ready "$id" "$1" || return 0
  failed="$(gh run view "$2" --attempt "$attempt" --log-failed 2>/dev/null | grep -oE 'FAILED suite=[^ ]+ exit_code=[^ ]+ first_error=.{0,160}' | sort -u | head -10)"
  task="你是 the product 流水线的实现 subagent。main 的 Pipeline suites 在 $1 上失败（run $2 attempt ${attempt}），产品合并门禁因此关闭，这是最高优先级。
失败 suite：
${failed:-（日志里没解析出 FAILED suite= 行，用 gh run view $2 --attempt $attempt --log-failed 自查）}
用 gh run view $2 --attempt $attempt --log-failed 看完整失败；本地跑失败的 suite 复现。判断是测试/fixture 跟不上新改动、真实回归，还是 CI 负载下的超时（超时看 engine/run-ci-suites.sh 的 suite_weight_seconds：超时 = 3×权重，按实测刷新）。修根因，不弱化断言、不删测试。"
  units_update --arg id "$id" --arg sha "$1" --arg task "$task" --arg run "$2" --argjson attempt "$attempt" \
    '.units += [{id:$id, main_red:true, critical:true, ci_sha:$sha, ci_run_id:$run, ci_run_attempt:$attempt, title:("fix red main Pipeline suites at "+$sha[0:9]), stage:"implement-pending", lane:"direct-main", branch:("agent/"+$id), task:$task, history:[]}]'
  say "main suites red at $1 (run $2) -> opened $id"
  echo "[$STAMP] MAIN-RED unit=$id main=$1 run=$2" >> "$A/alerts/gate.md"
}

# 落地自红的 fast path（2026-10-29 zf-ab 请求）：post-land Pipeline suites 首红，失败 suite 属于
# 最近绿..红 head 窗口内某次落地 changed paths 按 focused-test-paths.mjs 映射出的 suite（含落地直接改的
# 测试文件）时，立即开 fix-forward 单元，不等重跑确认/二分/复现。反例：aec22b350（#4659）改
# ask.cjs，advisor-answer-stall 在 post-land run 40962277656 红，live advisor 坏了约 1 小时才被人工发现。
# post-land run 由 land-direct-main 每次落地 dispatch、去重后只有最新一个跑到完成，红的 head 不一定是
# 罪魁落地本身，所以归属按窗口内逐落地映射。不映射到窗口内任何落地的 suite 不过这里，仍走原有
# 重跑/二分路径。同一落地 SHA + 同一 suite 只开一次（单元 id 幂等）；一拍最多开一个，多个归属单元
# 随后续拍次逐个开出。
open_landed_red_unit() { # red-head-sha run-id attempt
  local head="$1" run="$2" attempt="$3"
  local run_json green_sha candidates c mapped row s owner="" suite="" first_error id repo url task owner_subject failed
  [[ "$head" =~ $SHA_RE && "$run" =~ ^[0-9]+$ && "$attempt" =~ ^[1-9][0-9]*$ ]] || return 0
  main_suites_load
  [[ -n "$MAIN_SUITES_RUNS" ]] || return 0
  run_json="$(jqf -c --argjson id "$run" 'map(select(.databaseId==$id)) | first // empty' <<<"$MAIN_SUITES_RUNS")"
  jqf -e --arg sha "$head" '.headSha==$sha and .status=="completed" and .conclusion=="failure"' <<<"$run_json" >/dev/null || return 0
  green_sha="$(jqf -r --arg at "$(jqf -r '.createdAt // empty' <<<"$run_json")" '
    map(select(.status=="completed" and .conclusion=="success" and (.createdAt // "") < $at))
    | sort_by(.createdAt) | last | .headSha // empty' <<<"$MAIN_SUITES_RUNS")"
  [[ "$green_sha" =~ $SHA_RE ]] || return 0
  git -C "$ROOT" merge-base --is-ancestor "$green_sha" "$head" 2>/dev/null || return 0
  failed="$(gh run view "$run" --attempt "$attempt" --log-failed 2>/dev/null \
    | grep -oE 'FAILED suite=[^ ]+ exit_code=[^ ]+ first_error=.{0,160}' | sort -u || true)"
  [[ -n "$failed" ]] || return 0
  candidates="$(git -C "$ROOT" rev-list "$green_sha..$head" 2>/dev/null | head -50 | tac)"
  while IFS= read -r c; do
    [[ "$c" =~ $SHA_RE ]] || continue
    mapped="$(cd "$ROOT" && node "${ZF_ENGINE_DIR:-$ROOT/engine}/focused-test-paths.mjs" --range "${c}^" "$c" 2>/dev/null || true)"
    [[ -n "$mapped" ]] || continue
    while IFS= read -r row; do
      s="${row#FAILED suite=}"; s="${s%% *}"
      [[ -n "$s" ]] || continue
      printf '%s\n' "$mapped" | grep -qxF "$s" || continue
      owner="$c"; suite="$s"; first_error="${row#*first_error=}"
      break
    done <<< "$failed"
    [[ -n "$owner" ]] && break
  done <<< "$candidates"
  [[ -n "$owner" ]] || return 0
  id="landed-red-${owner:0:9}-$(printf '%s' "$suite" | sha256sum | cut -c1-6)"
  main_red_lane_ready "$id" "$head" || return 0
  owner_subject="$(git -C "$ROOT" log -1 --format=%s "$owner" 2>/dev/null || true)"
  repo="$(git -C "$ROOT" remote get-url origin 2>/dev/null)"
  repo="${repo#*github.com[:/]}"; repo="${repo%.git}"
  if [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then url="https://github.com/${repo}/actions/runs/${run}"; else url="run ${run}"; fi
  task="你是 the product 流水线的实现 subagent。post-land Pipeline suites 红（${url}，attempt ${attempt}），失败的 suite 按 focused-test-paths.mjs 归属到你落地的提交 ${owner}（${owner_subject}），是本次落地的回归，最高优先级直接修根因。
失败 suite：${suite}
first_error：${first_error}
用 gh run view ${run} --attempt ${attempt} --log-failed 看完整失败，本地跑 ${suite} 复现；修根因，不弱化断言、不删测试。若该 suite 覆盖线上运行面（advisor、调度器等），在报告写明 live 组件是否受影响。"
  units_update --arg id "$id" --arg owner "$owner" --arg suite "$suite" --arg sha "$head" --arg run "$run" \
    --argjson attempt "$attempt" --arg url "$url" --arg task "$task" \
    '.units += [{id:$id, main_red:true, landed_red:true, critical:true, landed_sha:$owner, landed_suite:$suite, ci_sha:$sha, ci_run_id:$run, ci_run_attempt:$attempt, ci_run_url:$url, title:("fix post-land red "+($suite|split("/")|last)+" at "+$owner[0:9]), stage:"implement-pending", lane:"direct-main", branch:("agent/"+$id), task:$task, history:[]}]'
  say "landed red at $head (run $run): suite $suite owned by landing $owner -> opened $id"
  echo "[$STAMP] LANDED-RED unit=$id landing=$owner suite=$suite run=$run" >> "$A/alerts/gate.md"
}

supersede_resolved_main_red_units() {
  [[ "$MAIN_HEAD" =~ $SHA_RE ]] || return 0
  local pending green_shas id ci_sha candidate reason history_update
  pending="$(jqf -r --slurpfile workers "$WORKERS" '
    .units[] as $unit
    | select($unit.main_red == true and $unit.stage == "implement-pending")
    | select(any($workers[0].workers[]; .unit == $unit.id and .harvested != true) | not)
    | [$unit.id, ($unit.ci_sha // "")] | @tsv
  ' "$UNITS")"
  [[ -n "$pending" ]] || return 0
  main_suites_load
  [[ -n "$MAIN_SUITES_RUNS" ]] || return 0
  green_shas="$(jqf -r '
    [ .[] | select((.headSha // "") | test("^[0-9a-f]{40}$"))
      | {sha:.headSha, at:(.createdAt // ""), status:(.status // ""), conclusion:(.conclusion // "")}
    ]
    | group_by(.sha)
    | map(sort_by(.at) | last)
    | map(select(.status == "completed" and .conclusion == "success"))
    | sort_by(.at) | reverse | .[].sha
  ' <<<"$MAIN_SUITES_RUNS")"
  [[ -n "$green_shas" ]] || return 0
  while IFS=$'\t' read -r id ci_sha; do
    [[ -n "$id" && "$ci_sha" =~ $SHA_RE ]] || continue
    while read -r candidate; do
      [[ "$candidate" =~ $SHA_RE && "$candidate" != "$ci_sha" ]] || continue
      git -C "$ROOT" merge-base --is-ancestor "$ci_sha" "$candidate" 2>/dev/null || continue
      git -C "$ROOT" merge-base --is-ancestor "$candidate" "$MAIN_HEAD" 2>/dev/null || continue
      reason="newer main SHA $candidate passed Pipeline suites"
      history_update="$(hist superseded "$reason")"
      set_unit "$id" "$history_update | .stage=\"closed\""
      say "main-red unit $id superseded by green Pipeline suites at $candidate"
      break
    done <<<"$green_shas"
  done <<<"$pending"
}

# ---------- 4. 新 PR 自动评审（限量：只挑最新 max_pending_reviews 个） ----------
# PR 关联 issue 带 hotfix 时也不登记（#4615）：10-29 #4612/#4613 开出来时漏了 PR 标签，被登记成 unit 后
# ci_wip 掐掉了它们的 CI。关联认分支 agent/issue-<n>-*（含 agent/issue-hf-<n>）和正文 Refs #n。
hotfix_linked_issue_numbers() { # PR JSON → 关联 issue 号数组
  jqf -cn --argjson p "$1" '
    ([($p.headRefName // "") | match("^agent/issue-(hf-)?([0-9]+)(-|$)") | .captures[1].string | tonumber]
      + [($p.body // "") | match("(?im)^[[:space:]]*[-*]?[[:space:]]*refs[[:space:]:]+#([0-9]+)"; "g") | .captures[0].string | tonumber]
    | unique)
  '
}
is_hotfix_pr() { # PR JSON → success when config, PR label, or linked issue marks it hotfix
  local pr="$1" label branch prefix linked hot
  label="$(hotfix_lane_label)"
  jqf -e --arg label "$label" 'any(.labels[]?; .name == $label)' <<<"$pr" >/dev/null && return 0
  branch="$(jqf -r '.headRefName // ""' <<<"$pr")"
  while IFS= read -r prefix; do
    [[ -n "$prefix" && "$branch" == "$prefix"* ]] && return 0
  done < <(hotfix_lane_branch_prefixes)
  linked="$(hotfix_linked_issue_numbers "$pr")" || return 1
  [[ "$linked" != "[]" ]] || return 1
  if hotfix_issue_numbers >/dev/null; then hot="$TICK_HOTFIX_ISSUES"; else hot='[]'; fi
  jqf -e --argjson linked "$linked" --argjson hot "$hot" \
    'any($linked[]; . as $n | $hot | index($n) != null)' <<<"{}" >/dev/null
}
label_hotfix_pr() { # PR number, currently known label names
  local pr="$1" labels="$2" label
  label="$(hotfix_lane_label)"
  jqf -e --arg label "$label" 'index($label) != null' <<<"$labels" >/dev/null && return 0
  gh pr edit "$pr" --add-label "$label" >/dev/null 2>&1 || { say "hotfix PR#$pr: could not add configured label $label"; return 1; }
  tick_prs_changed
  say "hotfix PR#$pr: added configured label $label"
}
register_new_prs() {
  [[ "$(jqf -r .auto_dispatch_new_prs <<<"$CFG")" == "true" ]] || return 0
  local CAP="${MAX_PENDING_REVIEWS:-12}" n_registered=0 pr sha pr_head target branch draft title labels pr_num critical u wt rep lane body64 body body_file pr_json
  while IFS=$'\t' read -r pr sha branch draft title labels body64; do
    [[ -z "$sha" ]] && continue
    [[ "$pr" =~ ^[0-9]{1,9}$ ]] || { say "skip malformed PR number from gh pr list"; continue; }
    pr_num="$((10#$pr))"
    (( pr_num > 0 )) || { say "skip non-positive PR number from gh pr list"; continue; }
    (( n_registered >= CAP )) && break
    [[ "$draft" == "true" ]] && continue
    body="$(jqf -nr --arg body64 "$body64" '$body64 | @base64d')" || body=""
    body_file="$(scheduler_jq_arg_file "$body")" || continue
    pr_json="$(jqf -cn --argjson number "$pr_num" --arg branch "$branch" --rawfile body "$body_file" --argjson labels "$labels" \
      '{number:$number,headRefName:$branch,body:$body,labels:[$labels[] | {name:.}]}')"
    rm -f -- "$body_file"
    # CI 准入与新 PR 收单共用 is_hotfix_pr；热修 PR 由 supervisor 负责，scheduler 不登记。
    if is_hotfix_pr "$pr_json"; then
      label_hotfix_pr "$pr_num" "$labels" || true
      say "skip pr-$pr_num: configured hotfix lane"
      continue
    fi
    jqf -e --argjson pr_num "$pr_num" '([.units[].pr] | map(select(. != null)) | index($pr_num)) != null' "$UNITS" >/dev/null 2>&1 && continue
    critical=false
    has_critical_label "$labels" && critical=true
    if [[ "$FOCUS_MODE" == "release" && "$critical" != "true" && "$(critical_pending_count)" -gt 0 ]]; then
      FOCUS_SKIPPED+=("pr-$pr_num")
      say "skip new PR unit=pr-$pr_num focus=release critical=false"
      continue
    fi
    u="$(jqf -cn --argjson pr_num "$pr_num" --arg title "$title" --arg branch "$branch" --argjson critical "$critical" '{id:("pr-"+($pr_num|tostring)),title:$title,stage:"review-pending",pr:$pr_num,branch:$branch,critical:$critical,history:[]}')"
    jqf --argjson u "$u" '.units += [$u]' "$UNITS" | write_state "$UNITS"
    n_registered=$((n_registered+1))
    if [[ -n "${HANDOFF_PR_CENSUS:-}" ]]; then
      if [[ "${HANDOFF_CENSUS_PARTIAL:-0}" == 1 ]]; then handoff_include_pr "$pr_num" || continue; fi
      register_new_issues 1 reuse
      jqf -e --arg id "pr-$pr_num" 'any(.units[]; .id == $id and .hold_handoff_waiting == true)' "$UNITS" >/dev/null && continue
      [[ "$(unit_field "pr-$pr_num" '.stage')" == review-pending ]] || continue
    fi
    lane="$(ensure_lane "pr-$pr_num" "$pr_num")" || { say "new PR unit=pr-$pr_num: lane unavailable"; continue; }
    [[ "$lane" == direct-main ]] && cancel_branch_runs "$branch" "direct-main lane; does not use PR CI"
    room_for "pr-$pr_num" review || continue
    pick review || continue
    wt="$(ensure_clone "pr-$pr_num")" || { say "new PR unit=pr-$pr_num: clone unavailable; stays review-pending"; continue; }
    target="$(unit_review_target "pr-$pr_num" "$pr_num" "$lane" "$branch")" || { say "new PR unit=pr-$pr_num: PR head unavailable; stays review-pending"; continue; }
    read -r pr_head sha <<<"$target"
    checkout_pr_head "$wt" "$pr_num" "$sha" "$pr_head" || { say "new PR unit=pr-$pr_num: PR head unavailable; stays review-pending"; continue; }
    rep="review-${pr_num}-${TAG}.md"
    dispatch_if_room "pr-$pr_num" "review" "review" "${rep%.md}.worker.log" "$rep" \
      "$PICK_MODEL" "$PICK_EFFORT" "$(review_prompt "$pr_num" "$title" "$sha" "$rep" "$lane" "$wt")" "$sha" "$wt" "$pr_head" || true
  done < <(tick_prs | jqf -r 'sort_by(-.number) | .[0:15] | .[] | "\(.number)\t\(.headRefOid)\t\(.headRefName)\t\(.isDraft)\t\(.title | gsub("\t"; " "))\t\([.labels[].name] | @json)\t\((.body // "") | @base64)"' 2>/dev/null)
}

# 把本拍已经读到的 PR 与 run 事实发布成一份快照（pr-run-snapshot.json，见 runtime-env.sh）：bell、zombie-watch、dashboard 读它，
# 不再各自列 run。每个分区读失败就写 null，读的人把它当"不可用"。快照是这台主机本拍的读缓存，不是权威，别的主机自己重建。
publish_pr_run_snapshot() {
  local prs unfinished ci suites infra query_started query_elapsed ci_file ci_pid
  prs="$(tick_prs 2>/dev/null | jqf -c 'map({number, headRefOid, headRefName, isDraft, title, labels: [.labels[]?.name]})')" || prs=""
  unfinished="$(unfinished_runs)"
  main_suites_load; suites="$MAIN_SUITES_RUNS"
  # main CI 与 infra run 列表并行取。
  query_started=$SECONDS
  ci_file="$(mktemp)" || ci_file=/dev/null
  { gh run list --workflow CI --branch main --limit 100 --json databaseId,headSha,status,conclusion,createdAt,attempt >"$ci_file" 2>/dev/null || :; } &
  ci_pid=$!
  infra="$(gh run list -R "${ZF_INFRA_REPO-example-org/example-infra}" --limit 30 --json databaseId,status,conclusion,createdAt,headSha,workflowName,displayTitle 2>/dev/null)" || infra=""
  wait "$ci_pid" || :
  ci="$(cat "$ci_file" 2>/dev/null)"
  [[ "$ci_file" == /dev/null ]] || rm -f -- "$ci_file"
  query_elapsed=$((SECONDS - query_started))
  (( query_elapsed < 2 )) || say "snapshot run_queries=${query_elapsed}s"
  pr_run_snapshot_publish "$A" "$prs" "$unfinished" "$ci" "$suites" "$infra" "$MAIN_HEAD" \
    || say "pr-run snapshot not written; readers treat it as unavailable"
}
