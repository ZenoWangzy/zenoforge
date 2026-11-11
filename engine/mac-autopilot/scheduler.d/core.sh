sched_pack_file() { ( source "$HERE/../config.sh" && pack_file "$1" ); } # relative path -> the pack's copy; fails without a pack or file
sched_config_file() { ( source "$HERE/../config.sh" && zf_config_file "$1" ); } # target config, then pack, then engine default
sched_mechanism_registry() { # stdout: path of the engine registry with the target overlay merged over it
  local overlay out="$A/mechanism-registry.merged.json" tmp
  overlay="$(sched_config_file state/mechanism-registry.json)" || return 1
  tmp="$(mktemp "$out.XXXXXX")" || return 1 # refill and slow ticks overlap here, before the scheduler lock
  if python3 -B "$HERE/config_paths.py" "$overlay" >"$tmp"; then
    mv -f "$tmp" "$out" && printf '%s\n' "$out"
  else
    rm -f "$tmp"; return 1
  fi
}
say() { echo "[$STAMP] $*" >> "$LOG"; }
# Add $1 to the EXIT trap in front of the trap already set (the engine canary, scheduler.sh:11), never replacing it; skipped when already there.
# In a subshell `trap -p` still prints the parent's trap, which the subshell never runs: chaining it there made every
# ( ... ) that took a lock run the parent's cleanup on exit (#753 red: test roots removed mid-test). A subshell's first call sets only its own.
chain_exit_trap() {
  local cur prior
  if [[ "$BASHPID" != "$$" && "${chain_exit_trap_pid:-}" != "$BASHPID" ]]; then
    chain_exit_trap_pid=$BASHPID
    trap "$1" EXIT # lint-exempt: a subshell's own first EXIT trap, see above
    return 0
  fi
  cur="$(trap -p EXIT)"
  [[ "$cur" == *"$1"* ]] && return 0
  eval "prior=$(sed -n 's/^trap -- //; s/ EXIT$//p' <<<"$cur")"
  trap "$1${prior:+; $prior}" EXIT # lint-exempt: the one bare EXIT trap, every other one calls this
}
# Refuse a unit advisor launch before Node sees a bad provider path. The bell
# recognizes this stable line and files one incident through pipeline issue upsert.
ADVISOR_PROVIDER_MISSING_LOGGED=false
ADVISOR_PROVIDER_MISSING_LOGGED_PATH=""
advisor_provider_script_available() {
  local script="${1:-}"
  [[ -f "$script" && -r "$script" ]] && return 0
  if [[ "$ADVISOR_PROVIDER_MISSING_LOGGED" != true || "$ADVISOR_PROVIDER_MISSING_LOGGED_PATH" != "$script" ]]; then
    say "advisor provider missing: $script"
    ADVISOR_PROVIDER_MISSING_LOGGED=true
    ADVISOR_PROVIDER_MISSING_LOGGED_PATH="$script"
  fi
  return 1
}
advisor_dispatch_or_route() { # unit-json total-review-rejections
  local unit="$1" total="$2" id decision
  id="$(jqf -r .id <<<"$unit")" || return 1
  if advisor_provider_script_available "$ADVISOR_PROVIDER_SCRIPT"; then
    advisor_launch "$unit" "$total"
    return $?
  fi
  decision="$(decision_entry 'Route to one arbiter review' 'advisor provider unavailable' \
    "the configured provider script is not readable: $ADVISOR_PROVIDER_SCRIPT" \
    '["Retry the convergence review after restoring the provider script"]' scheduler)"
  set_unit "$id" "$(hist arbiter-review "advisor provider missing at round $total" "$decision") | .advisor_round=$total | .arbiter=true | .reviewed_sha=null | .reviewed_pr_head=null | .stage=\"review-pending\""
}
# jq 的静默包装。坏输入曾在这里变成静默 "{}" 持续约 2 小时（10-29 census 事故），现在把 jq 的
# 解析/运行错误按「调用方 + stderr 首行」记进 scheduler.log；返回码不变。去重靠本 tick 固定的
# STAMP 前缀查日志同款行，命令替换子 shell 也能共享一份去重。
jqf() {
  local LC_ALL=C
  local _err _rc _first _who _i _name _value _bytes
  local -a _jqf_args=("$@")
  for ((_i = 0; _i < ${#_jqf_args[@]}; _i++)); do
    case "${_jqf_args[_i]}" in
      --arg|--argjson)
        ((_i + 2 < ${#_jqf_args[@]})) || continue
        _name="${_jqf_args[_i + 1]}"
        _value="${_jqf_args[_i + 2]}"
        _bytes=${#_value}
        if ((_bytes > 65536)); then
          _first="jqf: argv value $_name is $_bytes bytes > 65536; pass it via stdin or --slurpfile"
          _who="${FUNCNAME[1]:-top}"
          [[ "$_who" != jqf_optional_file ]] || _who="${FUNCNAME[2]:-top}"
          [[ -z "${LOG:-}" ]] || say "jqf error (rc=126) in $_who: $_first"
          printf '%s\n' "$_first" >&2
          return 126
        fi
        _i=$((_i + 2))
        ;;
    esac
  done
  _err="$(mktemp)" || { jq "$@" 2>/dev/null; return $?; }
  jq "$@" 2>"$_err"
  _rc=$?
  if (( _rc != 0 )) && [[ -s "$_err" && -n "${LOG:-}" ]]; then
    _first="$(head -n1 "$_err")"
    # 11-03 Broken pipe 误报：调用方提前停止读流（收单收满 want 后 break、`jqf | head -n` 截断、
    # 循环内 return）时 jq 写 stdout 得 EPIPE；SIGPIPE 被忽略的上下文（systemd 服务、命令替换）里
    # jq 以 rc=2 + "writing output failed: Broken pipe" 报出来。EPIPE 只能是下游读者关闭，不是 jq
    # 的错，不记；只放行这一条消息——ENOSPC 等其它写失败与解析/运行错误首行不同，照记。返回码不变。
    if [[ "$_first" != *"writing output failed: Broken pipe" ]]; then
      _who="${FUNCNAME[1]:-top}"
      [[ "$_who" != jqf_optional_file ]] || _who="${FUNCNAME[2]:-top}"
      if ! grep -Fq "[$STAMP] jqf error (rc=$_rc) in $_who: $_first" "$LOG" 2>/dev/null; then
        say "jqf error (rc=$_rc) in $_who: $_first"
      fi
    fi
  fi
  rm -f "$_err"
  return "$_rc"
}
# Optional file reads return 64 without logging only when the path is truly
# absent. Existing unreadable, malformed, or non-file paths still pass through
# jqf so scheduler.log keeps the diagnostic even when callers redirect stderr.
jqf_optional_file() {
  local _file="$1" _parent
  shift
  if [[ ! -e "$_file" && ! -L "$_file" ]]; then
    if [[ "$_file" == */* ]]; then
      _parent="${_file%/*}"
      [[ -n "$_parent" ]] || _parent=/
    else
      _parent=.
    fi
    while [[ ! -e "$_parent" && ! -L "$_parent" ]]; do
      case "$_parent" in
        /|.) break ;;
        */*) _parent="${_parent%/*}"; [[ -n "$_parent" ]] || _parent=/ ;;
        *) _parent=. ;;
      esac
    done
    if [[ -d "$_parent" && -x "$_parent" ]]; then
      return 64
    fi
  fi
  jqf "$@" "$_file"
}
# Refresh dependency state without dropping native blocked_by entries written by concurrent hold checks.
sched_dep_cache_refresh_merge() {
  local cache_file="$1" epoch="$2" states_json="$3" lock_file="${1%/*}/dep-check.cache.lock" lock_fd="" blocked_by rc=0
  if ! exec {lock_fd}>>"$lock_file" || ! flock -x "$lock_fd"; then
    [[ -z "$lock_fd" ]] || exec {lock_fd}>&-
    return 1
  fi
  blocked_by="$(jqf_optional_file "$cache_file" -c 'if (.blocked_by|type)=="object" then .blocked_by else {} end' 2>/dev/null || echo '{}')"
  if ! jqf -cn --argjson epoch "$epoch" --slurpfile states <(printf '%s' "$states_json") --argjson blocked_by "$blocked_by" \
    '{epoch:$epoch,states:$states[0]} + (if ($blocked_by|length)>0 then {blocked_by:$blocked_by} else {} end)' > "$cache_file.tmp" \
    || ! mv "$cache_file.tmp" "$cache_file"; then
    rm -f -- "$cache_file.tmp"
    rc=1
  fi
  flock -u "$lock_fd" || true
  exec {lock_fd}>&-
  return "$rc"
}
js() { jq -cn --arg v "$1" '$v'; }  # 任意文本 → jq 字符串字面量，供拼入 set_unit 表达式
# 旧单元形状归一（11-03 pr-3575：字符串 .cto_rulings 撞上数组追加，jqf rc=5，整笔更新被丢）。字段改形
# （.cto_rulings 2026-10-21 起为累积数组；.ready_since 早期存过 ISO 字符串）后没有任何路径归一存量数据，
# 追加与读取处共用这里的一条表达式，不再各写一份。
cto_rulings_norm() { # → jq 表达式：.cto_rulings 归一为数组（旧字符串包一层；null/其它按空数组）
  printf '%s' '(.cto_rulings | if type=="string" then [.] elif type=="array" then . else [] end)'
}
ready_since_epoch() { # → jq 表达式：.ready_since 归一为 epoch 秒（ISO 字符串就地转换，解析不了按 0）
  # %s 实参不做反斜杠转义：jq 源里的 "\\." 必须原样到达 jq（printf 格式串会吞掉一层）
  printf '%s' '(.ready_since // 0 | if type=="string" then (try (sub("\\.[0-9]+"; "") | fromdateiso8601) catch 0) else . end)'
}
gh() {
  [[ -n "${GH_TICK_CALLS_FILE:-}" ]] && printf 'x\n' >>"$GH_TICK_CALLS_FILE" 2>/dev/null || :
  local started=$SECONDS rc=0 elapsed op="${1:-unknown}" unit="${id:-}"
  local timeout_op="${1:-unknown}" timeout_unit="${id:-unknown}"
  local timeout_seconds="${AUTOPI_GH_TIMEOUT_SECONDS:-120}"
  [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || timeout_seconds=120
  [[ -z "${2:-}" ]] || timeout_op+=" $2"
  gh_timeout -k 1 "${timeout_seconds}s" "$@" || rc=$?
  (( rc != 124 )) || say "gh timeout op=$timeout_op unit=$timeout_unit after=${timeout_seconds}s"
  if [[ "${TICK_DISPATCH_PENDING_ACTIVE:-false}" == true ]]; then
    elapsed=$((SECONDS - started))
    (( elapsed < 2 )) || say "dispatch detail gh_${op}${unit:+ unit=$unit} secs=${elapsed}s"
  fi
  return "$rc"
}
AUTOPILOT_AUTO_FILED_LABEL_READY="${AUTOPILOT_AUTO_FILED_LABEL_READY:-false}"
scheduler_auto_filed_issue_create() {
  local existing
  if [[ "$AUTOPILOT_AUTO_FILED_LABEL_READY" != true ]]; then
    existing="$(gh label list --limit 100 --json name -q '.[].name' 2>/dev/null || true)"
    if grep -qx -- auto-filed <<<"$existing" || gh label create auto-filed --color ededed \
        --description "Automatically filed by Zenoforge" >/dev/null 2>&1; then
      AUTOPILOT_AUTO_FILED_LABEL_READY=true
    fi
  fi
  # The marker must not block filing: a ticket that fails to file is worse than one the title predicate has to catch.
  if [[ "$AUTOPILOT_AUTO_FILED_LABEL_READY" == true ]]; then
    gh issue create "$@" --label auto-filed
  else
    gh issue create "$@"
  fi
}
tick_gh_calls_begin() {
  GH_TICK_CALLS_FILE="$A/gh-calls.$BASHPID"
  : >"$GH_TICK_CALLS_FILE" 2>/dev/null || GH_TICK_CALLS_FILE=""
  ZF_PRODUCTION_DEPLOYMENT_CACHE_DIR="$A/deployment-status.$BASHPID"
  rm -rf -- "$ZF_PRODUCTION_DEPLOYMENT_CACHE_DIR" 2>/dev/null || :
  mkdir -p -- "$ZF_PRODUCTION_DEPLOYMENT_CACHE_DIR" 2>/dev/null || ZF_PRODUCTION_DEPLOYMENT_CACHE_DIR=""
  export ZF_PRODUCTION_DEPLOYMENT_CACHE_DIR
  TICK_INTAKE_READS_FILE="$A/intake-reads.$BASHPID"
  printf '0\n' >"$TICK_INTAKE_READS_FILE" 2>/dev/null || TICK_INTAKE_READS_FILE=""
  TICK_PHASE_DETAILS=""
  TICK_PHASES=""
  TICK_LOCK_WAIT=0
  # 被杀的 tick 留下的计数文件与过期的 ETag 缓存条目，下一拍顺手收掉。
  find "$A" -maxdepth 1 -name 'gh-calls.*' -mmin +120 -delete 2>/dev/null || :
  find "$A" -maxdepth 1 -type d -name 'deployment-status.*' -mmin +120 -exec rm -rf -- {} + 2>/dev/null || :
  find "$A" -maxdepth 1 -name 'intake-reads.*' -mmin +120 -delete 2>/dev/null || :
  find "$GH_ETAG_DIR" -type f -mmin +360 -delete 2>/dev/null || :
}
# One roadmap tree per tick for issue_transition's parent check: a shell variable, not exported, so detached workers never see it.
# The first transition fetches into this file (roadmap_ensure_issue_parent); a killed tick's leftover is swept after 120 min.
tick_roadmap_cache_begin() {
  find "$A" -maxdepth 1 -name 'roadmap-tree.*' -mmin +120 -delete 2>/dev/null || :
  [[ -z "${ZF_ROADMAP_TREE_CACHE_FILE:-}" ]] || return 0
  ZF_ROADMAP_TREE_CACHE_FILE="$A/roadmap-tree.$BASHPID.json"
  TICK_ROADMAP_CACHE_OWNED=true
}
tick_roadmap_cache_end() {
  [[ "${TICK_ROADMAP_CACHE_OWNED:-}" == true ]] || return 0
  rm -f -- "$ZF_ROADMAP_TREE_CACHE_FILE" "$ZF_ROADMAP_TREE_CACHE_FILE".* 2>/dev/null || :
  unset ZF_ROADMAP_TREE_CACHE_FILE TICK_ROADMAP_CACHE_OWNED
}
tick_gh_calls_count() { [[ -n "${GH_TICK_CALLS_FILE:-}" ]] || { printf '0\n'; return 0; }; awk 'END {print NR}' "$GH_TICK_CALLS_FILE" 2>/dev/null || printf '0\n'; }
gh_par_throttle() { # pid 数组名：在途数达到 GH_PARALLEL 时等最早的一个结束
  local -n _gh_pids="$1"
  while (( ${#_gh_pids[@]} >= GH_PARALLEL )); do wait "${_gh_pids[0]}" || :; _gh_pids=("${_gh_pids[@]:1}"); done
}
gh_api_cached() { # [-p] key url [gh api 参数…]；--jq 的输出即缓存正文；-p 跨页串行（逐页 JSONL 输出）
  local paginate=false
  [[ "${1:-}" == "-p" ]] && { paginate=true; shift; }
  local key="$1" url="$2"; shift 2
  local etag="" first out body next pages=0
  mkdir -p "$GH_ETAG_DIR" 2>/dev/null || return 1
  local -a cond=()
  IFS= read -r etag <"$GH_ETAG_DIR/$key.etag" 2>/dev/null || etag=""
  [[ -n "$etag" ]] && cond=(-H "If-None-Match: $etag")
  out="$(gh api -i "${cond[@]}" "$url" "$@" 2>/dev/null)" || :  # 304 时 gh 退出码 1 但 stdout 有头部，内容要保留
  out="${out//$'\r'/}"  # 头部行以 CRLF 结尾：先去掉 \r，空行分隔与 ETag/Link 值才干净
  first="$(head -n1 <<<"$out")"
  if [[ "$first" == *" 304 "* ]]; then
    [[ -f "$GH_ETAG_DIR/$key.body" ]] || return 1
    cat "$GH_ETAG_DIR/$key.body"
    return 0
  fi
  [[ "$first" == *" 200 OK"* ]] || return 1
  etag="$(grep -i '^etag: ' <<<"$out" | head -1 | cut -d' ' -f2-)"
  body="$(sed -e '1,/^$/d' <<<"$out")"
  next="$(grep -io '<[^>]*>; *rel="next"' <<<"$out" | head -1 | grep -o '<[^>]*>' | tr -d '<>')"
  if [[ "$paginate" == true ]]; then
    while [[ -n "$next" ]]; do
      (( pages < 50 )) || { say "gh_api_cached $key: page cap hit; treating as unavailable"; return 1; }
      out="$(gh api -i "$next" "$@" 2>/dev/null)" || :
      out="${out//$'\r'/}"
      [[ "$(head -n1 <<<"$out")" == *" 200 OK"* ]] || return 1  # 任一页非 200 整次判失败，不缓存部分结果
      body+=$'\n'"$(sed -e '1,/^$/d' <<<"$out")"
      pages=$((pages + 1))
      next="$(grep -io '<[^>]*>; *rel="next"' <<<"$out" | head -1 | grep -o '<[^>]*>' | tr -d '<>')"
    done
  fi
  printf '%s' "$body" >"$GH_ETAG_DIR/$key.body.tmp" 2>/dev/null \
    && mv -f "$GH_ETAG_DIR/$key.body.tmp" "$GH_ETAG_DIR/$key.body" || return 1
  [[ -n "$etag" ]] && printf '%s\n' "$etag" >"$GH_ETAG_DIR/$key.etag" || :
  printf '%s' "$body"
}
required_checks_without_pass() {
  # `gh pr checks` bucket and same-name de-dup semantics differ on old gh; an older gh never merges.
  local min have ready_at="${2:-}"
  min="$(jq -r '.min_gh_version // empty' "$REQUIRED_PR_CHECKS_FILE" 2>/dev/null)"
  if [[ -n "$min" ]]; then
    have="$(gh_timeout 5s --version 2>/dev/null | awk 'NR==1 {print $3}' || true)"
    if [[ -z "$have" || "$(printf '%s\n%s\n' "$min" "$have" | sort -V | head -1)" != "$min" ]]; then
      echo "gh ${have:-unavailable} is older than required $min"; return 0
    fi
  fi
  jq -r --arg ready_at "$ready_at" --slurpfile policy "$REQUIRED_PR_CHECKS_FILE" '
    def time_key:
      try (capture("^(?<seconds>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?<fraction>\\.[0-9]+)?Z$") as $time
        | [$time.seconds, (($time.fraction // "") | sub("^\\."; "") | . + "000000000" | .[0:9])])
      catch null;
    def passed($name): any(.[]; .name == $name and .bucket == "pass"
      and ($ready_at == "" or (
        (.started_at | time_key) as $started
        | ($ready_at | time_key) as $ready
        | $started != null and $ready != null and $started >= $ready
      )));
    . as $checks | $policy[0] as $p |
    [$p.required[] | . as $name | select($checks | passed($name) | not)] | unique | join(", ")
  ' <<< "$1" 2>/dev/null || echo "required-pr-checks.json unreadable"
}
