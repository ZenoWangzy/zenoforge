# 一拍一次的 open PR census（轻量列表 + 跨进程共享 + 按需读取）。原列表一次要 body 与 statusCheckRollup，
# GraphQL 常在 GitHub 的 10s 超时上失败（2026-11-21 60 分钟实测：448 次、221 次失败、每次 10–15s），每个 station
# 进程还各自重读。现在列表只取轻字段；检查行按 head SHA 走 REST check-runs（tick_pr_check_runs），正文按 PR 单取
# （tick_pr_body），成功的一次列表写进 $A 下的缓存文件，别的 station 进程 60s 内直接复用，不再各问 GitHub。
# 读不到、格式错一律"不可用"（返回 1），调用方本拍不据此决策；自己改了 PR 后 tick_prs_changed 清掉重来。
declare -gA TICK_PR_BODY=() TICK_PR_BODY_LOADED=() TICK_PR_CHECK_RUNS=() TICK_PR_REVIEWS=() TICK_PR_REVIEWS_LOADED=()
declare -gi TICK_PR_BODY_FETCHES=0 # 本进程真正走 GitHub 的正文读取次数（缓存命中不计），受 pr_body_fetch_cap 限制
TICK_PR_BODY_CAP_SAID='' TICK_CENSUS_ERR_SAID=''
tick_prs_rest_snapshot() {
  local repo="${1:-}" cache_key=open-prs url='repos/{owner}/{repo}/pulls?state=open&per_page=100' pages
  if [[ -n "$repo" ]]; then
    cache_key="open-prs-${repo//\//-}"
    url="repos/$repo/pulls?state=open&per_page=100"
  fi
  pages="$(gh_tick_cache_get "$cache_key.json" gh_api_cached -p "$cache_key" "$url")" || return 1
  jqf -sc 'add | map({number, headRefOid:.head.sha, headRefName:.head.ref, baseRefName:.base.ref,
    isDraft:(.draft // false), title, body, labels:[.labels[]? | {name}],
    mergeable:(if has("mergeable") then (if .mergeable == true then "MERGEABLE" elif .mergeable == false then "CONFLICTING" else "UNKNOWN" end) else null end),
    createdAt:.created_at, updatedAt:.updated_at})' <<<"$pages"
}
tick_prs_fetch() { tick_prs_rest_snapshot; }
tick_pr_rest_json() {
  local repo="${2:-}" cache_key="pr-$1" url
  [[ "$1" =~ ^[1-9][0-9]*$ ]] || return 1
  if [[ -n "$repo" ]]; then
    cache_key="pr-${repo//\//-}-$1"
    url="repos/$repo/pulls/$1"
  else
    url="repos/{owner}/{repo}/pulls/$1"
  fi
  gh_tick_cache_get "$cache_key.json" gh_api_cached "$cache_key" "$url"
}
tick_pr_rest_field() {
  local field="$2" pr
  pr="$(tick_pr_rest_json "$1")" || return 1
  case "$field" in
    number) jqf -r '.number // empty' <<<"$pr" ;;
    state) jqf -r 'if .merged_at != null then "MERGED" else (.state // "" | ascii_upcase) end' <<<"$pr" ;;
    isDraft) jqf -r '.draft // false' <<<"$pr" ;;
    headRefOid) jqf -r '.head.sha // empty' <<<"$pr" ;;
    headRefName) jqf -r '.head.ref // empty' <<<"$pr" ;;
    baseRefName) jqf -r '.base.ref // empty' <<<"$pr" ;;
    title) jqf -r '.title // empty' <<<"$pr" ;;
    body) jqf -r '.body // empty' <<<"$pr" ;;
    labels) jqf -c '[.labels[]? | {name}]' <<<"$pr" ;;
    mergeable) jqf -r 'if .mergeable == true then "MERGEABLE" elif .mergeable == false then "CONFLICTING" else "UNKNOWN" end' <<<"$pr" ;;
    mergeCommit) jqf -c 'if .merge_commit_sha == null then null else {oid:.merge_commit_sha} end' <<<"$pr" ;;
    mergedAt) jqf -r '.merged_at // empty' <<<"$pr" ;;
    *) return 1 ;;
  esac
}
tick_pr_cli_view() {
  local -a args=("$@")
  local n='' repo='' fields='' filter='' i=2 key url raw json extra
  while (( i < ${#args[@]} )); do
    case "${args[$i]}" in
      -R|--repo) ((i+=1)); repo="${args[$i]:-}" ;;
      --repo=*) repo="${args[$i]#*=}" ;;
      --json) ((i+=1)); fields="${args[$i]:-}" ;;
      --json=*) fields="${args[$i]#*=}" ;;
      -q|--jq) ((i+=1)); filter="${args[$i]:-}" ;;
      -q=*|--jq=*) filter="${args[$i]#*=}" ;;
      --*) return 1 ;;
      *) [[ -n "$n" ]] || n="${args[$i]}" ;;
    esac
    ((i+=1))
  done
  [[ "$n" =~ ^[1-9][0-9]*$ && -n "$fields" ]] || return 1
  raw="$(tick_pr_rest_json "$n" "$repo")" || return 1
  json="$(jqf '{number, state:(if .merged_at != null then "MERGED" else (.state // "" | ascii_upcase) end), isDraft:(.draft // false), headRefName:.head.ref,
    headRefOid:.head.sha, baseRefName:.base.ref, baseRefOid:.base.sha, title, body,
    labels:[.labels[]? | {name}], mergeable:(if .mergeable == true then "MERGEABLE" elif .mergeable == false then "CONFLICTING" else "UNKNOWN" end),
    mergeCommit:(if .merge_commit_sha == null then null else {oid:.merge_commit_sha} end), mergedAt:.merged_at}' <<<"$raw")" || return 1
  key="${repo//\//-}-$n"; [[ -n "$repo" ]] || key="$n"
  url="repos/{owner}/{repo}/pulls/$n/files?per_page=100"
  [[ -z "$repo" ]] || url="repos/$repo/pulls/$n/files?per_page=100"
  if [[ ",$fields," == *,files,* ]]; then
    extra="$(gh_tick_cache_get "pr-files-$key.json" gh_api_cached -p "pr-files-$key" "$url")" || return 1
    extra="$(jqf -sc 'add | map({path:.filename, additions, deletions, changeType:(.status // "" | ascii_upcase), previous_filename})' <<<"$extra")" || return 1
    json="$(jqf --argjson files "$extra" '. + {files:$files}' <<<"$json")" || return 1
  fi
  url="repos/{owner}/{repo}/pulls/$n/commits?per_page=100"
  [[ -z "$repo" ]] || url="repos/$repo/pulls/$n/commits?per_page=100"
  if [[ ",$fields," == *,commits,* ]]; then
    extra="$(gh_tick_cache_get "pr-commits-$key.json" gh_api_cached -p "pr-commits-$key" "$url")" || return 1
    extra="$(jqf -sc 'add | map((.commit.message // "") as $message | {oid:.sha, message:$message,
      messageBody:(if ($message | contains("\n")) then ($message[($message | index("\n") + 1):] | ltrimstr("\n")) else "" end),
      authors:[{email:(.commit.author.email // ""), login:(.author.login // "")} ]})' <<<"$extra")" || return 1
    json="$(jqf --argjson commits "$extra" '. + {commits:$commits}' <<<"$json")" || return 1
  fi
  if [[ -n "$filter" ]]; then jqf -r "$filter" <<<"$json"; else jqf -c <<<"$json"; fi
}
tick_pr_cli_list() {
  local -a args=("$@")
  local state='' repo='' head='' base='' limit='' fields='' filter='' i=2 rows
  while (( i < ${#args[@]} )); do
    case "${args[$i]}" in
      -R|--repo) ((i+=1)); repo="${args[$i]:-}" ;;
      --repo=*) repo="${args[$i]#*=}" ;;
      --state) ((i+=1)); state="${args[$i]:-}" ;;
      --state=*) state="${args[$i]#*=}" ;;
      --head) ((i+=1)); head="${args[$i]:-}" ;;
      --head=*) head="${args[$i]#*=}" ;;
      --base) ((i+=1)); base="${args[$i]:-}" ;;
      --base=*) base="${args[$i]#*=}" ;;
      --limit) ((i+=1)); limit="${args[$i]:-}" ;;
      --limit=*) limit="${args[$i]#*=}" ;;
      --json) ((i+=1)); fields="${args[$i]:-}" ;;
      --json=*) fields="${args[$i]#*=}" ;;
      -q|--jq) ((i+=1)); filter="${args[$i]:-}" ;;
      -q=*|--jq=*) filter="${args[$i]#*=}" ;;
      --*) return 1 ;;
      *) return 1 ;;
    esac
    ((i+=1))
  done
  [[ "$state" == open && -n "$fields" ]] || return 1
  if [[ -z "$repo" || "$repo" == "${REPO:-}" ]]; then rows="$(tick_prs)" || return 1; else rows="$(tick_prs_rest_snapshot "$repo")" || return 1; fi
  rows="$(jqf --arg head "$head" --arg base "$base" --arg limit "$limit" --arg fields "$fields" '
    map(select(($head == "" or .headRefName == $head) and ($base == "" or .baseRefName == $base)))
    | if ($limit | test("^[0-9]+$")) then .[:($limit | tonumber)] else . end
    | map(with_entries(select(.key as $key | ($fields | split(",") | index($key)) != null)))' <<<"$rows")" || return 1
  if [[ -n "$filter" ]]; then jqf -r "$filter" <<<"$rows"; else jqf -c <<<"$rows"; fi
}
tick_prs_read() { # → open-PR census JSON；进程内未缓存时先看 60s 窗口文件，再问 GitHub
  local f out now err rc
  if [[ -n "${A:-}" ]]; then
    f="$A/.tick-prs-census.json"
    if out="$(cat "$f" 2>/dev/null)" && [[ "${out%%$'\n'*}" =~ ^[0-9]+$ ]] \
      && now="$(date +%s)" && (( now - ${out%%$'\n'*} < 60 )) \
      && out="${out#*$'\n'}" && jqf -e 'type == "array"' <<<"$out" >/dev/null 2>&1; then
      printf '%s' "$out"
      return 0
    fi
  fi
  err="$(mktemp 2>/dev/null)" || err=""
  out="$(tick_prs_fetch 2>"${err:-/dev/null}")" || {
    rc=$?
    printf 'tick census read failed rc=%s err=%s\n' "$rc" "$(head -n1 "$err" 2>/dev/null | cut -c1-200)" >&2
    [[ -z "$err" ]] || rm -f -- "$err"
    return 1
  }
  [[ -z "$err" ]] || rm -f -- "$err"
  jqf -e 'type == "array"' <<<"$out" >/dev/null 2>&1 || return 1
  if [[ -n "${A:-}" ]]; then # 只有成功的读取才落盘：失败的读不写文件，下一个进程自己再问
    tick_census_store "$A/.tick-prs-census.json" "$out"
    tick_pr_body_sweep "$out"
  fi
  printf '%s' "$out"
}
tick_census_store() { # $1 文件，$2 census JSON：写成 "epoch 行 + JSON"，tmp + mv 原子替换
  local tmp
  if tmp="$(mktemp "$1.XXXXXX" 2>/dev/null)"; then
    if { date +%s; printf '%s' "$2"; } > "$tmp" 2>/dev/null && mv -f "$tmp" "$1" 2>/dev/null; then :; else rm -f -- "$tmp"; fi
  fi
}
tick_prs() {
  local errf="" rc=0
  if [[ -z "$TICK_PRS" ]]; then
    errf="$(mktemp 2>/dev/null)" || errf=""
    TICK_PRS="$(tick_prs_read 2>"${errf:-/dev/null}")" || rc=$?
    # 失败的读只在本进程第一次记一行（tick_prs_read 的 stderr 第一行；它在子 shell 里跑，记行必须在这里）
    if (( rc )) && [[ -n "$errf" && -s "$errf" && -z "${TICK_CENSUS_ERR_SAID:-}" ]]; then
      say "$(head -n1 "$errf")"; TICK_CENSUS_ERR_SAID=1
    fi
    [[ -z "$errf" ]] || rm -f -- "$errf"
    (( rc == 0 )) || { TICK_PRS=""; return 1; }
  fi
  jqf -e 'type == "array"' <<<"$TICK_PRS" >/dev/null || { TICK_PRS=""; return 1; }
  printf '%s' "$TICK_PRS"
}
tick_prs_prime() { [[ -n "$TICK_PRS" ]] || tick_prs >/dev/null 2>&1 || true; }
tick_prs_changed() { # 本拍自己改了 PR（ready/draft/标签/创建/关闭/合并）：进程内缓存与共享文件一起作废
  TICK_PRS=""; TICK_PR_STATE=(); TICK_PR_CHECK_RUNS=(); TICK_PR_BODY=(); TICK_PR_BODY_LOADED=(); TICK_PR_REVIEWS=(); TICK_PR_REVIEWS_LOADED=()
  [[ -z "${GH_TICK_CACHE_DIR:-}" ]] || rm -f -- "$GH_TICK_CACHE_DIR"/open-prs*.json "$GH_TICK_CACHE_DIR"/pr-*.json 2>/dev/null || :
  [[ -z "${A:-}" ]] || rm -f -- "$A/.tick-prs-census.json" 2>/dev/null || :
}
tick_prs_set_draft() { # PR ready/draft writes do not change its census identity, body or checks
  [[ -n "$TICK_PRS" ]] || return 0
  local updated
  updated="$(jqf --argjson pr "$1" --argjson draft "$2" 'map(if .number==$pr then .isDraft=$draft else . end)' <<<"$TICK_PRS")" || { tick_prs_changed; return 0; }
  TICK_PRS="$updated"
}
tick_prs_add_label() { # mirror a successful label write in the current tick's PR census
  [[ -n "$TICK_PRS" ]] || return 0
  local updated
  updated="$(jqf --argjson pr "$1" --arg label "$2" 'map(if .number==$pr then .labels=((.labels // []) + [{name:$label}] | unique_by(.name)) else . end)' <<<"$TICK_PRS")" || { tick_prs_changed; return 0; }
  TICK_PRS="$updated"
}
tick_pr_body_file() { # PR 号 + updatedAt → 正文缓存文件名（$A/.pr-body/<n>-<updatedAt 去符号>）；没有 A 或 updatedAt 返回 1
  local key="${2//[^0-9A-Za-z]/}"
  [[ -n "${A:-}" && -n "$key" ]] || return 1
  printf '%s/.pr-body/%s-%s' "$A" "$1" "$key"
}
tick_pr_body_sweep() { # 成功的一次 census 之后：删掉 census 里已没有的 PR，或正文已换了 updatedAt 的旧缓存
  local keep f
  keep="$(jqf -r '.[] | "\(.number)-\(.updatedAt // "" | gsub("[^0-9A-Za-z]"; ""))"' <<<"$1" 2>/dev/null)" || return 0
  for f in "$A"/.pr-body/*; do
    [[ -e "$f" ]] || continue
    grep -qxF -- "${f##*/}" <<<"$keep" || rm -f -- "$f"
  done
}
tick_pr_body() { # PR number → body 正文：进程内缓存 → 按 updatedAt 的文件缓存 → GitHub（每进程有上限）；读不到返回 1
  local body n="$1" updated file cap tmp
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  if [[ -n "${TICK_PR_BODY_LOADED[$n]:-}" ]]; then printf '%s' "${TICK_PR_BODY[$n]}"; return 0; fi
  updated="$(jqf -r --argjson n "$n" 'first(.[] | select(.number == $n) | .updatedAt) // empty' <<<"${TICK_PRS:-[]}" 2>/dev/null)"
  if file="$(tick_pr_body_file "$n" "$updated")" && [[ -f "$file" ]]; then
    body="$(cat -- "$file")"; TICK_PR_BODY_LOADED[$n]=1; TICK_PR_BODY[$n]="$body"
    printf '%s' "$body"; return 0
  fi
  if jqf -e --argjson n "$n" 'any(.[]; .number == $n and has("body"))' <<<"${TICK_PRS:-[]}" >/dev/null 2>&1; then
    body="$(jqf -r --argjson n "$n" '[.[] | select(.number == $n) | .body][0] // ""' <<<"$TICK_PRS")" || return 1
    TICK_PR_BODY_LOADED[$n]=1; TICK_PR_BODY[$n]="$body"
    printf '%s' "$body"; return 0
  fi
  cap="$(jqf -r '.pr_body_fetch_cap // 20' <<<"${CFG:-"{}"}" 2>/dev/null)"; [[ "$cap" =~ ^[0-9]+$ ]] || cap=20
  if (( TICK_PR_BODY_FETCHES >= cap )); then
    [[ -n "${TICK_PR_BODY_CAP_SAID:-}" ]] || { say "pr body fetch cap reached cap=$cap"; TICK_PR_BODY_CAP_SAID=1; }
    return 1
  fi
  TICK_PR_BODY_FETCHES=$((TICK_PR_BODY_FETCHES + 1))
  body="$(tick_pr_rest_field "$n" body)" || return 1
  TICK_PR_BODY_LOADED[$n]=1; TICK_PR_BODY[$n]="$body"
  if file="$(tick_pr_body_file "$n" "$updated")"; then # 写文件失败只是没有缓存，不影响本次读取
    mkdir -p -- "${file%/*}" 2>/dev/null && tmp="$(mktemp "${file%/*}/.XXXXXX" 2>/dev/null)" \
      && { printf '%s' "$body" > "$tmp" && mv -f "$tmp" "$file" 2>/dev/null || rm -f -- "$tmp"; }
  fi
  printf '%s' "$body"
}
tick_pr_reviews() {
  local n="$1" reviews
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || return 1
  if [[ -n "${TICK_PR_REVIEWS_LOADED[$n]:-}" ]]; then printf '%s' "${TICK_PR_REVIEWS[$n]}"; return 0; fi
  reviews="$(gh_tick_cache_get "pr-reviews-$n.json" gh_api_cached -p "pr-reviews-$n" \
    "repos/{owner}/{repo}/pulls/$n/reviews?per_page=100")" || return 1
  reviews="$(jqf -sc 'add // []' <<<"$reviews")" || return 1
  jqf -e 'type == "array" and all(.[]; type == "object" and (.state | type == "string"))' <<<"$reviews" >/dev/null || return 1
  TICK_PR_REVIEWS[$n]="$reviews"; TICK_PR_REVIEWS_LOADED[$n]=1
  printf '%s' "$reviews"
}
tick_pr_has_changes_requested() {
  local reviews
  reviews="$(tick_pr_reviews "$1")" || return 1
  jqf -r '[.[] | select(.user.type != "Bot" and ((.user.login // "") | endswith("[bot]") | not))]
    | sort_by(.submitted_at // "") | group_by(.user.login // "") | map(last)
    | any(.[]; .state == "CHANGES_REQUESTED")' <<<"$reviews"
}
prs_attach_body() { # stdin: census rows, $1 PR 号, $2 正文 → 该 PR 的 .body 补上（正文走 --rawfile，绕开 jqf 的 64KiB argv 上限）
  jqf --argjson n "$1" --rawfile b <(printf '%s' "$2") 'map(if .number == $n then .body = $b else . end)'
}
tick_pr_check_runs() { # head SHA → 归一化检查行 [{name,link,started_at,bucket}]；一个进程一个 SHA 只取一次
  local sha="$1" raw
  [[ "$sha" =~ $SHA_RE ]] || return 1
  if [[ -n "${TICK_PR_CHECK_RUNS[$sha]:-}" ]]; then printf '%s' "${TICK_PR_CHECK_RUNS[$sha]}"; return 0; fi
  raw="$(gh_commit_check_runs_cached "$sha")" || return 1
  raw="$(jqf -c '.check_runs // []' <<<"$raw")" || return 1
  # REST 的 check-run：未完成时 conclusion 是 ""（或 null），不是绿；skipped 映射成 skipping，让同管线的
  # pr-required-aggregate.mjs --latest-checks 照旧在选行前丢弃 SKIPPED 副本（#4687，列表带 statusCheckRollup
  # 时的原语义：raw 结论先过 mjs 再分档）；同名多行由 node 留最新 run。
  raw="$(jqf -c 'map({name: (.name // ""), link: (.details_url // .html_url // ""), started_at: (.started_at // null),
    bucket: (if ((.status // "") | ascii_downcase) != "completed" then "pending"
      else ((.conclusion // "" | ascii_downcase) as $c | if $c == "success" then "pass" elif ($c | IN("neutral", "skipped")) then "skipping"
        elif $c == "cancelled" then "cancel" elif ($c | IN("failure", "timed_out", "action_required", "startup_failure")) then "fail" else "pending" end) end)})' <<<"$raw")" || return 1
  raw="$(node "$HERE/../ci/pr-required-aggregate.mjs" --latest-checks <<<"$raw" 2>/dev/null)" || return 1
  jqf -e 'type == "array"' <<<"$raw" >/dev/null 2>&1 || return 1
  TICK_PR_CHECK_RUNS["$sha"]="$raw"
  printf '%s' "$raw"
}
# 打开 PR census 的归一化（轻字段）：以 PR 号为键的对象 {head,draft,mergeable}。检查行不再随列表下发，
# 由 pr_census_checks_fill 按候选的 head SHA 单独补；start.sh 的 pin 切换自检共用这一条轻管线。
pr_census_by_number() { # stdin: gh pr list JSON → stdout: {"<pr>": {head,draft,mergeable}}
  jqf 'map({key: (.number | tostring), value: {head: .headRefOid, draft: .isDraft, mergeable: .mergeable}}) | from_entries'
}
pr_census_checks_fill() { # stdin: pr_census_by_number 的对象 → stdout: 每个 head 是 40 位 SHA 的条目补上 checks 与 ci
  local obj pr head rows ci
  obj="$(cat)"
  while IFS=$'\t' read -r pr head; do
    [[ "$pr" =~ ^[0-9]+$ ]] || continue
    # 在本 shell 调一次（写缓存）；$(...) 里的写入回不到这里，所以读缓存而不是再调一次
    if tick_pr_check_runs "$head" >/dev/null 2>&1 && rows="${TICK_PR_CHECK_RUNS[$head]}"; then
      ci="$(jqf -r 'if any(.[]; .bucket == "pending") then 2 elif any(.[]; .bucket == "fail" or .bucket == "cancel") then 1 else 0 end' <<<"$rows")"
      # 检查行是整份 census 量级的载荷，走文件而不是 argv（--argjson checks "$rows" 这一形态会被
      # jq-arg-safety 按无界变量拦下）；--slurpfile 后 $checks 是 [rows]，取 [0]。
      obj="$(jqf --arg pr "$pr" --slurpfile checks <(printf '%s' "$rows") --argjson ci "$ci" '.[$pr].checks=$checks[0] | .[$pr].ci=$ci' <<<"$obj")" || obj="$(jqf --arg pr "$pr" '.[$pr].checks=null | .[$pr].ci=null' <<<"$obj")"
    else # 取不到检查行不是绿：留 null，排序按 ci // 2 落到 pending 档，合并车道按 check census unavailable 跳过
      obj="$(jqf --arg pr "$pr" '.[$pr].checks=null | .[$pr].ci=null' <<<"$obj")"
    fi
  done < <(jqf -r 'to_entries[] | select((.value.head // "") | test("^[0-9a-f]{40}$")) | "\(.key)\t\(.value.head)"' <<<"$obj")
  printf '%s' "$obj"
}
repair_check_rows() { # PR number → latest normalized check rows for its head（census 命中走 per-SHA REST，未命中或读失败落 gh pr checks）
  local pr="$1" head rows checks
  tick_prs_prime
  if [[ -n "${TICK_PRS:-}" ]] && head="$(jqf -r --argjson pr "$pr" '[.[] | select(.number == $pr) | .headRefOid][0] // empty' <<<"$TICK_PRS")" && [[ "$head" =~ $SHA_RE ]] \
    && rows="$(tick_pr_check_runs "$head")"; then
    printf '%s' "$rows"
    return 0
  fi
  # gh exits nonzero when a check failed but still prints the rows; only empty output is a real gh failure.
  checks="$(unset GH_TOKEN; gh pr checks "$pr" --json name,bucket,link 2>/dev/null)"; [[ -n "$checks" ]] || return 1
  node "$HERE/../ci/pr-required-aggregate.mjs" --latest-checks <<<"$checks" 2>/dev/null
}
