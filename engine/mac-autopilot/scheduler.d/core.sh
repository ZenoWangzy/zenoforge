sched_pack_file() { ( source "$HERE/../config.sh" && pack_file "$1" ); } # relative path -> the pack's copy; fails without a pack or file
sched_config_file() { ( source "$HERE/../config.sh" && zf_config_file "$1" ); } # target config, then pack, then engine default
say() { echo "[$STAMP] $*" >> "$LOG"; }
# jq 的静默包装。坏输入曾在这里变成静默 "{}" 持续约 2 小时（10-29 census 事故），现在把 jq 的
# 解析/运行错误按「调用方 + stderr 首行」记进 scheduler.log；返回码不变。去重靠本 tick 固定的
# STAMP 前缀查日志同款行，命令替换子 shell 也能共享一份去重。
jqf() {
  local _err _rc _first _who
  _err="$(mktemp)" || { jq "$@" 2>/dev/null; return $?; }
  jq "$@" 2>"$_err"
  _rc=$?
  if (( _rc != 0 )) && [[ -s "$_err" && -n "${LOG:-}" ]]; then
    _first="$(head -n1 "$_err")"
    _who="${FUNCNAME[1]:-top}"
    if ! grep -Fq "[$STAMP] jqf error (rc=$_rc) in $_who: $_first" "$LOG" 2>/dev/null; then
      say "jqf error (rc=$_rc) in $_who: $_first"
    fi
  fi
  rm -f "$_err"
  return "$_rc"
}
js() { jq -cn --arg v "$1" '$v'; }  # 任意文本 → jq 字符串字面量，供拼入 set_unit 表达式
gh() {
  [[ -n "${GH_TICK_CALLS_FILE:-}" ]] && printf 'x\n' >>"$GH_TICK_CALLS_FILE" 2>/dev/null || :
  local started=$SECONDS rc=0 elapsed op="${1:-unknown}" unit="${id:-}"
  command gh "$@" || rc=$?
  if [[ "${TICK_DISPATCH_PENDING_ACTIVE:-false}" == true ]]; then
    elapsed=$((SECONDS - started))
    (( elapsed < 2 )) || say "dispatch detail gh_${op}${unit:+ unit=$unit} secs=${elapsed}s"
  fi
  return "$rc"
}
tick_gh_calls_begin() {
  GH_TICK_CALLS_FILE="$A/gh-calls.$BASHPID"
  : >"$GH_TICK_CALLS_FILE" 2>/dev/null || GH_TICK_CALLS_FILE=""
  # 被杀的 tick 留下的计数文件与过期的 ETag 缓存条目，下一拍顺手收掉。
  find "$A" -maxdepth 1 -name 'gh-calls.*' -mmin +120 -delete 2>/dev/null || :
  find "$GH_ETAG_DIR" -type f -mmin +360 -delete 2>/dev/null || :
}
tick_gh_calls_count() { awk 'END {print NR}' "$GH_TICK_CALLS_FILE" 2>/dev/null || printf '0\n'; }
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
    have="$(command gh --version 2>/dev/null | awk 'NR==1 {print $3}')"
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
