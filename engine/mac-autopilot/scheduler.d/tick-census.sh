# 一拍一次的 open PR census（轻量列表 + 跨进程共享 + 按需读取）。原列表一次要 body 与 statusCheckRollup，
# GraphQL 常在 GitHub 的 10s 超时上失败（2026-11-21 60 分钟实测：448 次、221 次失败、每次 10–15s），每个 station
# 进程还各自重读。现在列表只取轻字段；检查行按 head SHA 走 REST check-runs（tick_pr_check_runs），正文按 PR 单取
# （tick_pr_body），成功的一次列表写进 $A 下的缓存文件，别的 station 进程 60s 内直接复用，不再各问 GitHub。
# 读不到、格式错一律"不可用"（返回 1），调用方本拍不据此决策；自己改了 PR 后 tick_prs_changed 清掉重来。
declare -gA TICK_PR_BODY=() TICK_PR_BODY_LOADED=() TICK_PR_CHECK_RUNS=()
declare -gi TICK_PR_BODY_FETCHES=0 # 本进程真正走 GitHub 的正文读取次数（缓存命中不计），受 pr_body_fetch_cap 限制
TICK_PR_BODY_CAP_SAID='' TICK_CENSUS_ERR_SAID=''
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
  out="$(gh pr list --state open --limit 300 --json number,headRefOid,headRefName,baseRefName,isDraft,title,labels,mergeable,createdAt,reviewDecision,updatedAt 2>"${err:-/dev/null}")" || {
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
  TICK_PRS=""; TICK_PR_STATE=(); TICK_PR_CHECK_RUNS=(); TICK_PR_BODY=(); TICK_PR_BODY_LOADED=()
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
  cap="$(jqf -r '.pr_body_fetch_cap // 20' <<<"${CFG:-"{}"}" 2>/dev/null)"; [[ "$cap" =~ ^[0-9]+$ ]] || cap=20
  if (( TICK_PR_BODY_FETCHES >= cap )); then
    [[ -n "${TICK_PR_BODY_CAP_SAID:-}" ]] || { say "pr body fetch cap reached cap=$cap"; TICK_PR_BODY_CAP_SAID=1; }
    return 1
  fi
  TICK_PR_BODY_FETCHES=$((TICK_PR_BODY_FETCHES + 1))
  body="$(gh pr view "$n" --json body --jq '.body // ""' 2>/dev/null)" || return 1
  TICK_PR_BODY_LOADED[$n]=1; TICK_PR_BODY[$n]="$body"
  if file="$(tick_pr_body_file "$n" "$updated")"; then # 写文件失败只是没有缓存，不影响本次读取
    mkdir -p -- "${file%/*}" 2>/dev/null && tmp="$(mktemp "${file%/*}/.XXXXXX" 2>/dev/null)" \
      && { printf '%s' "$body" > "$tmp" && mv -f "$tmp" "$file" 2>/dev/null || rm -f -- "$tmp"; }
  fi
  printf '%s' "$body"
}
prs_attach_body() { # stdin: census rows, $1 PR 号, $2 正文 → 该 PR 的 .body 补上（正文走 --rawfile，绕开 jqf 的 64KiB argv 上限）
  jqf --argjson n "$1" --rawfile b <(printf '%s' "$2") 'map(if .number == $n then .body = $b else . end)'
}
tick_pr_check_runs() { # head SHA → 归一化检查行 [{name,link,started_at,bucket}]；一个进程一个 SHA 只取一次
  local sha="$1" raw
  [[ "$sha" =~ $SHA_RE ]] || return 1
  if [[ -n "${TICK_PR_CHECK_RUNS[$sha]:-}" ]]; then printf '%s' "${TICK_PR_CHECK_RUNS[$sha]}"; return 0; fi
  raw="$(gh api "repos/{owner}/{repo}/commits/$sha/check-runs?per_page=100" --jq '.check_runs // []' 2>/dev/null)" || return 1
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
