product_boundary_rule() { # 整块取得才输出；CLAUDE.md 缺失或被改写到某组关键词消失，就什么都不输出并返回 1
  local kws lines block=""
  (( ${#PRODUCT_BOUNDARY_SELECTORS[@]} )) || return 1
  for kws in "${PRODUCT_BOUNDARY_SELECTORS[@]}"; do
    lines="$(awk -v kws="$kws" 'BEGIN { n = split(kws, k, "|") }
      { for (i = 1; i <= n; i++) if (index($0, k[i]) == 0) next; print }' "$ROOT/CLAUDE.md" 2>/dev/null)"
    [[ -n "$lines" ]] || return 1
    block+=$'\n'"$lines"
  done
  printf '\n【项目指令原文（硬性边界；路由表可以不读，这几条不能丢）】%s' "$block"
}
unit_lane_class() { # unit-json → product|pipeline-system|direct-main|main-red|hot-patch|unknown
  # pipeline-system 单元走 direct-main；NEEDS-PR 转到 PR 车道后仍是 pipeline-system。台账里没有的单元按 unknown 处理。
  jqf -r 'if (.id // null) == null then "unknown"
    elif .main_red == true then "main-red"
    elif .hotpatch == true then "hot-patch"
    elif .lane == "direct-main" then "direct-main"
    elif any((.history // [])[]?; .stage == "needs-pr") then "pipeline-system"
    elif .lane == "pr" then "product"
    else "unknown" end' <<<"$1"
}
worker_rules() { # unit-json type provider
  [[ "$3" == codex ]] || return 0
  printf '%s%s' "$WORKER_POLL_RULE" "$WORKER_LARGE_FILE_RULE"
  if [[ "$(unit_lane_class "$1")" == product && ( "$2" == implement || "$2" == repair ) ]]; then
    # 读取范围规则说"硬性边界已附在下面"：边界块取不到就不豁免路由表，worker 照旧读项目指令。
    local boundary
    if boundary="$(product_boundary_rule)"; then printf '%s%s' "$WORKER_READ_SCOPE_RULE" "$boundary"; fi
  fi
}

# models.<role> = [model, effort, service_tier?]；model 以 claude- 开头走 claude CLI，否则走 codex。
build_codex_command() { # type model effort unit cold-prompt [new-failure]
  local type="$1" model="$2" effort="$3" unit="$4" prompt="$5" failure="${6-$5}" session_id="" usage prompt_arg role tier self_fix prior
  local -a tier_args=()
  CODEX_MODE=fresh
  CODEX_SESSION_ID=""
  CODEX_PATH_REASON=initial
  WORKER_STDOUT_REPORT=0
  CODEX_USAGE_START='{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0}'
  prompt+="$(worker_rules "$(jqf -c --arg id "$unit" '[.units[] | select(.id==$id)][0] // {}' "$UNITS")" "$type" "$(provider_of "$model")")"
  prompt_arg="$prompt"
  self_fix="$(unit_field "$unit" '.self_fix_active // false')"
  if [[ "$model" == claude-* ]]; then
    # Claude 评审只读：报告作为最终回答输出，由 dispatch 成功后落盘（不给写文件权限）。
    # --strict-mcp-config：不加载用户级 MCP 服务器（4 个评审曾拉起 426 个进程、2.5 GB 内存，且 chrome-devtools 会碰用户浏览器）。
    WORKER_STDOUT_REPORT=1
    CODEX_USAGE_START=null  # Claude is not measured by Codex cumulative counters.
    # 用户级 PreToolUse hook（rtk）把 git log/diff 改写成 rtk git …，白名单不匹配，dontAsk 全拒：评审 worker 不加载 hook。
    CODEX_COMMAND=(claude -p "$prompt_arg
（本次运行无写文件权限：把完整报告正文作为最终回答输出，调度器会原样落盘到上述报告路径。
当前目录就是评审目录：git 命令直接写「git diff ...」，不要加「-C <dir>」「--no-pager」，也不要「cd ... &&」（这些形式不匹配白名单会被拒）。可用命令（白名单外一律被拒）：git diff/log/show/fetch/rev-parse/merge-base/ls-files、gh pr view/diff/checks、gh issue view、head/tail/wc/cat/ls/grep/rg/jq/sort；优先用 Read/Grep 工具读代码。当前目录已是评审目录，直接执行单条命令即可。一条命令被拒只说明其中某一段不在白名单，不代表 Bash 不可用：拆成单条白名单命令重试，不要据此判定 INPUT_INCOMPLETE。）" \
      --settings '{"disableAllHooks":true}' --add-dir "$ENGINE_ROOT/.agents/skills" --add-dir "$ENGINE_ROOT/engine/prompts" \
      --model "$model" --effort "$effort" --permission-mode dontAsk --strict-mcp-config \
      --tools "Read,Grep,Glob,Bash" --allowedTools "$CLAUDE_REVIEW_TOOLS")
    return 0
  fi
  tier="$(jqf -r --arg m "$model" '[.models[] | select(.[0]==$m) | .[2] // empty][0] // empty' <<<"$CFG")"
  [[ -n "$tier" ]] && tier_args=(--config "service_tier=\"$tier\"")
  # Persistent implementer sessions: never add --ephemeral here.
  CODEX_FRESH_COMMAND=(codex exec -m "$model" -c "model_reasoning_effort=$effort" ${tier_args[@]+"${tier_args[@]}"} "${CODEX_ENV_ARGS[@]}" \
    -s danger-full-access --json "$prompt_arg")
  if [[ "$type" == repair ]]; then
    prior="$(unit_field "$unit" '.sessions.repair // {}')"
    session_id="$(jqf -r '.id // empty' <<<"$prior")"
    CODEX_PATH_REASON=no-recorded-session
    if [[ "$session_id" =~ $SESSION_RE ]]; then
      if [[ "$(jqf -r '.provider // empty' <<<"$prior")" != codex ]]; then
        CODEX_PATH_REASON=provider-changed
      elif [[ "$(jqf -r '.model // empty' <<<"$prior")" != "$model" ]]; then
        CODEX_PATH_REASON=model-changed
      elif [[ -z "$(session_file_for_id "$session_id")" ]]; then
        CODEX_PATH_REASON=session-files-missing
      elif [[ -z "$failure" ]]; then
        CODEX_PATH_REASON=no-new-failure
      elif [[ "$self_fix" != true ]] && ! { usage="$(session_tokens_for_id "$session_id")"; [[ "$usage" =~ ^[0-9]+$ ]] && (( usage < 8000000 )); }; then
        # Same cumulative-raw cutoff as rereview (a repair chain keeps growing one session); a self-fix always continues.
        CODEX_PATH_REASON=session-too-large
      else
        CODEX_MODE=resume
        CODEX_PATH_REASON=same-provider-model
        CODEX_SESSION_ID="$session_id"
        CODEX_USAGE_START="$(session_usage_for_id "$session_id")"
        CODEX_COMMAND=(codex exec -s danger-full-access resume "$session_id" -m "$model" \
          -c "model_reasoning_effort=$effort" ${tier_args[@]+"${tier_args[@]}"} "${CODEX_ENV_ARGS[@]}" --json "$failure")
        return 0
      fi
    fi
  fi
  if [[ "$type" == "rereview" ]]; then
    role="$(session_role "$type")"
    session_id="$(jqf -r --arg id "$unit" --arg role "$role" '[.units[] | select(.id==$id) | .session_ids[$role] // empty][0] // empty' "$UNITS")"
    if [[ "$session_id" =~ $SESSION_RE ]]; then
      local snapshot; snapshot="$(session_usage_for_id "$session_id")"
      usage="$(jqf -r 'if .==null then empty else .raw end' <<<"$snapshot")"
      # 阈值比累计 raw（input+output），不比 fresh：9M raw 而 fresh 只有 0.3M 的会话仍要冷启动；按 fresh 比会让
      # 500 个可续的修复派发里 464 个改成续会话。
      if [[ "$self_fix" == true ]] || { [[ "$usage" =~ ^[0-9]+$ ]] && (( usage < 8000000 )); }; then
        CODEX_MODE=resume
        CODEX_SESSION_ID="$session_id"
        CODEX_USAGE_START="$snapshot"
        prompt_arg="继续沿用本会话已有上下文，仅处理本次增量任务，不重读未变化背景：$prompt"
        CODEX_COMMAND=(codex exec -s danger-full-access resume "$session_id" -m "$model" \
          -c "model_reasoning_effort=$effort" ${tier_args[@]+"${tier_args[@]}"} "${CODEX_ENV_ARGS[@]}" --json "$prompt_arg")
        return 0
      fi
    fi
  fi
  # A deterministic self-fix must never silently switch to a fresh worker.
  [[ "$self_fix" == true ]] && return 1
  # --json（两种模式一致）：stdout 变为 JSONL 事件流（thread.started / turn.completed 用量），worker 日志即事件源，
  # 回收时由 usage_reader 落进原生事件库；人类可读输出只在非 --json 模式存在，legacy 日志的页脚解析保留给旧 worker。
  CODEX_COMMAND=("${CODEX_FRESH_COMMAND[@]}")
}

# 每个单元独占一个隔离 clone（L8：worker 不进主 checkout）；clone 放磁盘而非 tmpfs /tmp。
# branch 为空 → detached 于最新 origin/main；require_remote=1 时分支必须已在 origin（repair）。
# 目标提交在调度器自己的对象库里就从 $ROOT 取，没有或对不上才走 GitHub；worker clone 的 origin 仍是 GitHub URL。
fetch_local_first() { # dir ref-in-ROOT dest-ref-in-dir want-sha
  local dir="$1" src="$2" dest="$3" want="$4"
  [[ "$want" =~ $SHA_RE ]] || return 1
  [[ "$(git -C "$ROOT" rev-parse -q --verify "$src^{commit}" 2>/dev/null)" == "$want" ]] || return 1
  git -C "$dir" fetch -q --no-tags "$ROOT" "+$src:$dest" 2>/dev/null \
    && [[ "$(git -C "$dir" rev-parse -q --verify "$dest^{commit}" 2>/dev/null)" == "$want" ]]
}
