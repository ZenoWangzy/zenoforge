final_message_of() { awk '/^tokens used$/{getline; buf=""; f=1; next} f{buf=buf $0 "\n"} END{printf "%s", buf}' "$1" 2>/dev/null; }
tokens_of() { awk '/tokens used/{getline; if (match($0, /[0-9][0-9,]*/)) { n=substr($0, RSTART, RLENGTH); gsub(/,/, "", n); print n }; exit}' "$1" 2>/dev/null; }

write_state() { # 用法: jqf ... "$1" | write_state "$1"   stdin=新内容 $1=目标文件
  local dst="$1" _t valid=false _units_shape
  _t="$(mktemp "${dst}.tmp.XXXXXX")" || return 1
  cat > "$_t"
  # Identical bytes are no write: validation reads two multi-MB files, the .bak copy and the mtime bump drop every cached ledger view.
  # About one ledger write in three in a 2026-11-07 full tick left the content unchanged (13 of 36 in harvest, 5 of 14 in dispatch).
  if [[ -s "$_t" ]] && cmp -s "$_t" "$dst"; then rm -f "$_t"; return 0; fi
  if [[ "$dst" == "$UNITS" ]]; then
    # No unit leaves the system through this scheduler: a write may only drop ids that
    # are already persisted in the retirement archive (retire_terminal_units writes the
    # archive before trimming the ledger, so a crash keeps the row in both places).
    # Clone cleanup and worker-ledger trimming below remain legitimate; neither may
    # erase registered unit IDs.
    # -s: a state file must be exactly one document. A top-level comma in a hand edit (10-29 06:32Z) wrote three
    # concatenated copies; per-document -e accepted every later write and each copy drifted apart.
    _units_shape='length==1 and (.[0] |
      type=="object" and (.units|type)=="array"
      and all(.units[]; type=="object" and (.id|type)=="string" and (.id|length)>0 and (.stage|type)=="string")
      and ([.units[].id]|length)==([.units[].id]|unique|length)'
    if jq -e -s --slurpfile old "$dst" "$_units_shape and ((\$old[0].units|map(.id)) - [.units[].id] | length)==0)" "$_t" >/dev/null 2>&1; then
      valid=true
    elif [[ -s "${UNITS_ARCHIVE:-}" ]] && jq -e -s --slurpfile old "$dst" --slurpfile arch "$UNITS_ARCHIVE" --argjson terminal "$UNIT_RETIRE_STAGES" "$_units_shape
      and ((.units|map(.id)) as \$kept | (\$arch[0].units|map(.id)) as \$archived
      | all(\$old[0].units[]; .id as \$i | (\$kept|index(\$i)) != null
          or ((\$archived|index(\$i)) != null and (.stage as \$s | \$terminal|index(\$s)) != null))))" "$_t" >/dev/null 2>&1; then
      valid=true
    fi
  elif [[ "$dst" == "$WORKERS" ]]; then
    jq -e -s 'length==1 and (.[0] | type=="object" and (.workers|type)=="array"
      and all(.workers[]; type=="object" and (.pid|type)=="number" and .pid>0 and (.unit|type)=="string"))' \
      "$_t" >/dev/null 2>&1 && valid=true
  else
    jq -e -s 'length==1 and (.[0]|type=="object")' "$_t" >/dev/null 2>&1 && valid=true
  fi
  if [[ -s "$_t" && "$valid" == true ]]; then
    cp "$dst" "$dst.bak" 2>/dev/null || true
    mv "$_t" "$dst"
    if [[ "$dst" == "$WORKERS" ]]; then LIVE_WORKER_CACHE_UNTIL=0; fi
    return 0
  else
    rm -f "$_t"; say "write_state guard: invalid shape or missing unit IDs for $dst, keep old"
    return 1
  fi
}

# 评审结论：整文件扫「VERDICT token + 取值」并规范化旧别名（review-contract.md 的 verdict）。
# 11-04 根因（一晚 9 个单元两次转 supervisor）：结论行写法带加粗/前缀/行内备注——`**VERDICT: READY**（备注）`、
# `## 结论：VERDICT: READY`、复原终答里的 `结论 **VERDICT: READY**。`——整行锚定正则一概不认。取值只在含
# VERDICT 的行内计数，且该行必须有一个紧跟 token 的锚定取值（散文里的裸取值不产生结论）；锚定行上
# 取值只从 VERDICT 后面开始计数；同行第二个状态词（如 `VERDICT: READY（…否则应改判 NOT_READY）`）仍是真歧义。
verdict_of() {
  local found findings
  found="$(awk '
    {
      line = toupper($0)
      if (!match(line, /VERDICT[[:space:]]*:[[:space:]]*/)) next
      line = substr(line, RSTART + RLENGTH)
      if (line !~ /^(READY|NOT_READY|INPUT_INCOMPLETE|APPROVE|REQUEST-CHANGES|BLOCK)([^A-Z0-9_-]|$)/) next
      while (match(line, /(READY|NOT_READY|INPUT_INCOMPLETE|APPROVE|REQUEST-CHANGES|BLOCK)([^A-Z0-9_-]|$)/)) {
        value = substr(line, RSTART, RLENGTH)
        sub(/[^A-Z0-9_-]$/, "", value)
        print value; line = substr(line, RSTART + RLENGTH)
      }
    }' "$1" 2>/dev/null \
    | sed -e 's/^APPROVE$/READY/' -e 's/^REQUEST-CHANGES$/NOT_READY/' -e 's/^BLOCK$/INPUT_INCOMPLETE/' | sort -u)"
  if [[ -n "$found" ]]; then
    [[ "$(wc -l <<<"$found")" -eq 1 ]] && { printf '%s' "$found"; return 0; }
    return 1
  fi
  # 10-28：约 1/5 的评审写「## Verdict」标题、下一行裸写 NOT_READY，缺 `VERDICT:` 前缀，被当成无结论重跑。
  found="$(awk 'h && NF { line=toupper($0); gsub(/[*`]/, "", line); if (line ~ /^[[:space:]]*(READY|NOT_READY|INPUT_INCOMPLETE)[[:space:]]*$/) { gsub(/[[:space:]]/, "", line); print line }; exit }
    toupper($0) ~ /^#+[[:space:]]*VERDICT[[:space:]]*$/ { h = 1 }' "$1" 2>/dev/null)"
  if [[ -n "$found" ]]; then
    [[ "$(wc -l <<<"$found")" -eq 1 ]] && { printf '%s' "$found"; return 0; }
    return 1
  fi
  findings="$(findings_block_of "$1")" || return 1
  jqf -e 'any(.findings[]; .status=="open" and (.severity=="P0" or .severity=="P1"))' <<<"$findings" >/dev/null 2>&1 \
    && printf 'NOT_READY'
}

# 10-28..11-08: a reviewer whose Bash the permission mode refused reports INPUT_INCOMPLETE without judging the code.
review_tools_denied() { # report-path → 0 when the report blames a denied tool (don't-ask mode / 权限模式)
  grep -qiE "don.t.ask|权限模式" "$1" 2>/dev/null
}
harvest_input_incomplete() { # unit report-path report-name head reviewed-filter: an INPUT_INCOMPLETE review never leads to a commit repair
  local unit="$1" rep="$2" report="$3" wsha="$4" reviewed="$5" bdep
  bdep="$(blocked_on_of "$rep" || :)"
  if [[ -z "$bdep" ]] && review_tools_denied "$rep"; then
    # The reviewer's own tools were refused: the code was never judged. One re-review per head, then the supervisor.
    set_unit "$unit" "$(hist review-block "$wsha") | $reviewed | .approved_sha=null"
    if [[ "$(unit_history_count "$unit" review-tools-denied "^$wsha")" == 0 ]]; then
      set_unit "$unit" "$(hist review-tools-denied "$wsha $report") | .reviewed_sha=null | .reviewed_pr_head=null | .stage=\"review-pending\""
      say "review-tools-denied unit=$unit report=$report: re-reviewing the same head once"
    else
      to_supervisor "$unit" "review tools were denied twice on head $wsha (report $report)"
    fi
    return 0
  fi
  set_unit "$unit" "$(hist_blocked review-block "$bdep" review-report "$wsha") | $reviewed | .approved_sha=null | .blocked_main_sha=$(js "$MAIN_HEAD") | .stage=\"blocked-external\""
  [[ -z "$bdep" ]] || park_blocked "$unit" "$bdep"
  cancel_unit_runs "$unit" "review blocked"
}

verification_plan_for_state() { # checkout state-json → advisory feature plan from declared paths
  local checkout="$1" state="$2" entry_surface expected_paths
  entry_surface="$(jqf -r '.entry_surface // empty' <<<"$state")"
  expected_paths="$(jqf -c '[.expected_paths[]?] | unique' <<<"$state")"
  build_verification_intent_plan_json "$checkout" "$HERE/.." "$entry_surface" "$expected_paths"
}

verification_plan_brief() { # plan-json → worker-facing structured feature evidence
  jq -c '
    {
      feature_ids:(.matched_features // []),
      unmapped_paths:(.unmapped_paths // []),
      plan_status:(.status // "unavailable"),
      verify_command:(if ((.matched_features // []) | length) > 0
        then "node scripts/e2e/yangfeng-regression/verify-feature.mjs --feature \((.matched_features // []) | join(",")) --target <base-url> --json"
        else null end)
    }
  ' <<<"$1"
}

# review-contract.md owns the review-findings object. Legacy arrays remain readable for reports already on disk.
# A canonical finding without a non-blank rerun_command and rerun_output is dropped, not rejected: it never reaches
# findings, and `dropped` / `dropped_findings` keep the count and reasons visible.
findings_block_of() { # report → stdout: {findings:[...],dispositions:[...]}
  local raw
  # 11-08：gpt-6-luna 评审员把块写成 ~~~review-findings（合法的 CommonMark 围栏），旧 awk 只认反引号，两份报告都记 block=missing。
  # 收栏必须与开栏同一围栏字符。
  raw="$(awk '/^(```|~~~)review-findings[[:space:]]*$/{on=1;buf="";last="";f=substr($0,1,3);next} on&&$0 ~ ("^" f "[[:space:]]*$"){last=buf;on=0;next} on{buf=buf $0 "\n"} END{printf "%s", last}' "$1" 2>/dev/null)"
  [[ -n "${raw//[[:space:]]/}" ]] || return 1
  jq -ce '
    def finding($legacy): type=="object"
      and (.id|type)=="string" and (.id|length)>0
      and (.severity|IN("P0","P1","P2","P3"))
      and (.file|type)=="string" and (.file|length)>0
      and (.line|type)=="number" and .line==(.line|floor) and .line>0
      and (.status|IN("open","resolved","inherited"))
      and ((has("introduced_by")|not and $legacy) or (.introduced_by|IN("candidate","pre_existing","unknown")))
      and ((has("base_evidence")|not and $legacy) or ((.base_evidence|type)=="string" and (.base_evidence|test("\\S"))))
      and (if $legacy then true else del(.rerun_command,.rerun_output)|keys==["base_evidence","file","id","introduced_by","line","rule","severity","status","summary"] end)
      and ((has("rule")|not) or (.rule|type)=="string")
      and ((has("summary")|not) or (.summary|type)=="string")
      and (if $legacy then true else (.rule|length)>0 and (.summary|length)>0 end);
    def evidence_gap: [("rerun_command","rerun_output") as $k | select((.[$k]|type)!="string" or (.[$k]|test("\\S")|not)) | $k];
    def normalized_finding: {id,severity,file,line,rule:(.rule // null),status,summary:(.summary // null),introduced_by:(.introduced_by // null),base_evidence:(.base_evidence // null)};
    def decision_log_flag: type=="object" and keys==["entry","reason"]
      and (.entry|type)=="string" and (.entry|test("\\S")) and (.entry|test("^[^\\r\\n]+$"))
      and (.reason|type)=="string" and (.reason|test("\\S")) and (.reason|test("^[^\\r\\n]+$"));
    def disposition: type=="object" and (.id|type)=="string" and (.id|length)>0
      and (.disposition|IN("fixed","disproved","intentional","out-of-scope"))
      and (.reason|type)=="string" and (.reason|test("\\S")) and (.reason|test("^[^\\r\\n]+$"))
      and keys==["disposition","id","reason"];
    if type=="array" and all(.[]; finding(true)) then
      {findings:map(normalized_finding),dispositions:[],decision_log_flags:[],legacy:true,dropped:0,dropped_findings:[]}
    elif type=="object" and (keys==["dispositions","findings"] or keys==["decision_log_flags","dispositions","findings"]) and (.findings|type)=="array" and (.dispositions|type)=="array"
      and all(.findings[]; finding(false)) and all(.dispositions[]; disposition)
      and ((has("decision_log_flags")|not) or ((.decision_log_flags|type)=="array" and all(.decision_log_flags[]; decision_log_flag)))
      and (([.findings[].id] | length)==([.findings[].id] | unique | length))
      and (([.dispositions[].id] | length)==([.dispositions[].id] | unique | length)) then
      {findings:(.findings|map(select(evidence_gap==[])|normalized_finding)),dispositions:.dispositions,decision_log_flags:(.decision_log_flags // []),legacy:false,
       dropped:([.findings[]|select(evidence_gap!=[])]|length),
       dropped_findings:[.findings[]|select(evidence_gap!=[])|{id,reason:("no rerunnable evidence: missing "+(evidence_gap|join(", ")))}]}
    else empty end' <<<"$raw" 2>/dev/null
}
review_decision_log_flags_append() { # review report unit → append marked entries as JSONL in the supervisor directory
  local report="$1" unit="$2" parsed flags
  parsed="$(findings_block_of "$report")" || return 0
  flags="$(jq -c '.decision_log_flags[]?' <<<"$parsed")"
  [[ -n "$flags" ]] || return 0
  mkdir -p "$SUP"
  while IFS= read -r flag; do
    jq -cn --arg at "${STAMP:-}" --arg unit "$unit" --arg report "${report##*/}" --argjson flag "$flag" \
      '{at:$at,unit:$unit,report:$report,entry:$flag.entry,reason:$flag.reason}' >> "$SUP/decision-log-flags.jsonl"
  done <<<"$flags"
}
# Actionable blocking findings provide a concrete target for the repair worker.
review_findings_hint_update() { # report → jq update fragment for open P0/P1 findings
  local findings hint
  findings="$(findings_block_of "$1")" || return 0
  hint="$(jqf -r '[.findings[] | select(.status=="open" and (.severity=="P0" or .severity=="P1"))
    | "\(.id) \(.file):\(.line) — \(.summary // .id)"] | join("\n")' <<<"$findings")"
  [[ -n "$hint" ]] || return 0
  printf ' | .repair_hint=%s' "$(js "$hint")"
}

# 打回但发现块不可解析时的同 head 重问段（harvest 的 review-findings-missing 路径派发时附带）。
# 11-03 根因：Claude 评审员把文件级发现写成 line:0，一个不合 schema 的 finding 废掉整块，
# REQUEST-CHANGES 带零发现进了修复。重问点名上一份报告与契约要点，评审员据此重交合规报告。
findings_reask_rule() { # unit-json → prompt 片段
  local prev
  prev="$(jqf -r '.review_report // empty' <<<"$1")"
  printf '\n【发现块重问】上一份评审报告 %s 的结论是打回，但其 review-findings 块缺失或不符合 schema，流水线无法把发现交给修复，请重做这次评审并重新交付完整报告。机器可读块是报告最后一个 fence、恰好一个，围栏用三个反引号写成 ```review-findings（不用 ~~~），正文与块所述一致；每个 finding 的字段与取值以 %s 为准：line 必须是正整数（文件级发现写 1，不是 0），file 用仓库相对路径，severity 取 P0-P3，introduced_by 与 base_evidence 必填非空；发现 ID 沿用上一份报告的编号。\n' \
    "${prev:-上一份报告}" "$REVIEW_CONTRACT_MD"
}
# 结论行不可解析时的同 head 格式重问段（harvest 的 verdict-missing 路径派发时附带）。
# 11-04 根因：结论行格式不合契约时旧路径整场重评，重评照样写歪，两次后转 supervisor——每个格式失败烧一个人工槽。
# 重问只谈格式：评审员读回自己的上一份报告，原样重交并补一行独立 VERDICT 行，不重新展开评审。
verdict_reask_rule() { # unit-json → prompt 片段
  local prev
  prev="$(jqf -r '.review_report // empty' <<<"$1")"
  printf '\n【结论行重问】上一份评审报告 %s 没有单一可解析的 VERDICT 行。请读取该报告并把它原样重交为一份完整报告（沿用其中的结论、发现与 review-findings 块，不重新评审），只把结论改为一行独立结论行：整行仅有 `VERDICT: READY`、`VERDICT: NOT_READY` 或 `VERDICT: INPUT_INCOMPLETE` 三者之一——不加粗、不写成标题、不带「结论：」之类前缀、同一行不写任何备注或第二个取值。取值沿用你上一份报告的结论。结论行格式以 %s 为准。\n' \
    "${prev:-上一份报告}" "$REVIEW_CONTRACT_MD"
}
# 一次打回在 .review_findings 里追加一条：round 是它在 history 里的第几次打回，findings 只含阻断级（P0/P1，
# 含 resolved 状态，由复发规则排除）；块缺失或畸形记 block=missing（node_health 的 review.findings_missing_pct 数它）。
# 不追加 history：分类附在已有的打回事件上，顾问仍按最后一条 stage 识别 REQUEST-CHANGES。
review_findings_update() { # report-path report-name → set_unit 表达式片段（以 " | " 开头）
  local rec block reason
  if block="$(findings_block_of "$1")"; then
    rec="$(jq -c '{block:"ok", findings:[.findings[] | select(.severity=="P0" or .severity=="P1")], all_findings:.findings, dispositions:[], dropped, dropped_findings}' <<<"$block")"
  else
    rec='{"block":"missing","findings":[],"dispositions":[]}'
  fi
  reason="$(jq -r '([.findings[0].rule?, .findings[0].severity?] | map(select(type=="string" and length>0)) | first // "")[:48]' <<<"$rec")"
  printf ' | .review_findings = ((.review_findings // []) + [{round:((.history // []) | map(select(.stage=="review-request-changes")) | length), at:%s, report:%s} + %s])' \
    "$(js "$STAMP")" "$(js "$2")" "$rec"
  if [[ -n "$reason" ]]; then printf ' | .history[-1].reason=%s' "$(js "$reason")"; fi
}

# 同一发现类别的复现计数（只记 NOT_READY 的阻断级发现；合成门禁报告不记）。失败只记日志，下一次评审重试。
review_class_recurrence_record() { # report-path unit: never blocks the harvest
  local block repo="${REPO:-${ZF_REPO:-}}"
  [[ "${1##*/}" =~ ^(incident|engine-override)-gate- ]] && return 0
  block="$(findings_block_of "$1")" || return 0
  ( export ZF_GH_REPO="$repo" ZF_REPO="$repo"
    review_findings_record_classes "$(jq -c '.findings' <<<"$block")" "${REVIEW_CLASS_STATE:-$SUP/review-class-state.json}" \
      "${REVIEW_CLASS_UPSERT:-$HERE/../pipeline-issue-upsert.sh}" "$2" ) \
    || say "review class recurrence: rule ticket write failed unit=$2; retried on the next review"
  return 0
}

review_dispositions_update() { # repair-report → attach author dispositions to the latest finding record
  local block record
  if block="$(findings_block_of "$1")" && [[ "$(jqf -r '.legacy // false' <<<"$block")" == false ]]; then
      record="$(jq -c --argjson expected "$(jqf -c '[.review_findings[-1] | (.all_findings // .findings // [])[]?.id] | sort' <<<"$2")" '
      .dispositions as $d | {disposition_block:(if ([$d[].id] | sort)==$expected then "ok" else "incomplete" end),dispositions:$d}' <<<"$block")"
  else
    record='{"disposition_block":"missing","dispositions":[]}'
  fi
  printf ' | .review_findings = ((.review_findings // []) as $r | if ($r|length)==0 then $r else $r[0:-1] + [($r[-1] + %s)] end)' "$record"
}

review_dispositions_context() { # unit-json → persisted author dispositions for targeted re-review
  jqf -r '(.review_findings // [] | last) as $latest
    | if $latest == null then empty
      elif $latest.disposition_block == "ok" then
        "\nAuthor dispositions from unit history (re-review these IDs; do not repeat the original debate):\n" +
        ([$latest.dispositions[] | "- \(.id): \(.disposition) — \(.reason)"] | join("\n"))
      elif $latest.disposition_block == "incomplete" then "\nAuthor dispositions from unit history are incomplete; re-review the listed findings and identify any missing ID."
      elif $latest.disposition_block == "missing" then "\nThe repair report did not record author dispositions; use the prior findings and current diff."
      else empty end' <<<"$1"
}

# 改动文件扫描：首次打回之后，每次返工与复审都按此前的阻断发现类别（rule + 一句话）检查本 PR 全部改动文件，不只被点名的文件。
# 顾问裁决/仲裁评审之后重新计类别；没有打回过的单元不带这一段。输出为提示片段，无类别时为空。
sweep_rule() { # unit-json [head-sha]
  local classes
  classes="$(jqf -r '(.history // []) as $h
    | ([$h | to_entries[] | select(.value.stage | IN("advisor-ruling","arbiter-review")) | .key] | max // -1) as $i
    | ([$h[:($i + 1)][] | select(.stage=="review-request-changes")] | length) as $k
    | [(.review_findings // [])[] | select(.block=="ok" and .round > $k) | .findings[] | select((.severity=="P0" or .severity=="P1") and .status!="resolved")
        | "- [\(.rule // "?")] \(.summary // .id)（\(.file):\(.line)）"] | unique | .[]' <<<"$1" 2>/dev/null)"
  [[ -n "$classes" ]] || return 0
  printf '\n改动文件扫描（此前打回过）：下列是此前的阻断发现类别。对本 PR 全部改动文件（git diff --name-only origin/main...HEAD；以 head %s 为准，不限于被点名的文件）逐类搜同类实例，一并处理或在报告里逐类写出：是否又发现更多同类实例、各几处（发现块里新实例用同一 rule 记 open）。\n%s\n' "${2:-当前 head}" "$classes"
}

# 人工 PR 评审反馈（#119）：上次派发（write-start）之后的人工评审与行内评论。机器人与引擎自己的评论（带 vecta-agent-comment）不算。
human_feedback_items() { # pr since-iso → JSON 数组（时间升序）；gh 失败返回 1
  local pr="$1" since="$2" reviews comments
  reviews="$(gh api --paginate "repos/{owner}/{repo}/pulls/$pr/reviews" 2>/dev/null)" || { say "human feedback pr=$pr: could not list reviews"; return 1; }
  comments="$(gh api --paginate "repos/{owner}/{repo}/pulls/$pr/comments" 2>/dev/null)" || { say "human feedback pr=$pr: could not list review comments"; return 1; }
  jq -n --arg since "$since" --argjson r "$(jq -s 'add // []' <<<"$reviews")" --argjson c "$(jq -s 'add // []' <<<"$comments")" '
    def human: .user.type != "Bot" and ((.user.login // "") | endswith("[bot]") | not) and ((.body // "") | contains("<!-- vecta-agent-comment -->") | not);
    def text: (.body // "") | gsub("\\s+"; " ") | .[0:500];
    ([$r[] | select(human and (.submitted_at // "") >= $since and (((.body // "") | test("\\S")) or .state == "CHANGES_REQUESTED"))
        | {at:.submitted_at, kind:("review " + .state), who:(.user.login // "?"), text:text, url:(.html_url // "")}]
     + [$c[] | select(human and (.created_at // "") >= $since and ((.body // "") | test("\\S")))
        | {at:.created_at, kind:("line comment " + (.path // "")), who:(.user.login // "?"), text:text, url:(.html_url // "")}])
    | sort_by(.at)'
}
human_feedback_block() { # pr since-iso → 提示片段：最新 8 条带链接；无反馈或 PR 号非法则为空；gh 读失败返回 1（调用方须失败关闭）
  local items
  [[ "$1" =~ ^[0-9]+$ ]] || return 0
  items="$(human_feedback_items "$1" "$2")" || return 1
  jqf -r 'if length == 0 then empty else
    "\n人工 PR 评审反馈（上次派发之后共 \(length) 条，列出最新 \(if length > 8 then 8 else length end) 条；逐条处理，完整内容见链接）：\n"
    + ([.[-8:][] | "- [\(.kind)] \(.who) \(.at)：\(.text) \(.url)"] | join("\n")) end' <<<"$items"
}
last_dispatch_at() { jqf -r '[(.history // [])[] | select(.stage == "write-start") | .at] | last // ""' <<<"$1"; }
# 就绪单元：census 的 reviewDecision 为 CHANGES_REQUESTED，且上次派发之后有人工的请求修改评审，则移回 repair-pending。
ready_changes_requested_sweep() {
  local id pr since items
  [[ -n "${TICK_PRS:-}" ]] || return 0
  while IFS=$'\t' read -r id pr since; do
    [[ "$pr" =~ ^[0-9]+$ ]] || continue
    jqf -e --argjson n "$pr" 'any(.[]; .number == $n and .reviewDecision == "CHANGES_REQUESTED")' <<<"$TICK_PRS" >/dev/null || continue
    items="$(human_feedback_items "$pr" "$since")" || { say "ready unit=$id pr=$pr: human feedback unreadable, retry next tick"; continue; }
    jqf -e 'any(.[]; .kind == "review CHANGES_REQUESTED")' <<<"$items" >/dev/null || continue
    set_unit "$id" "$(hist review-changes-requested "PR#$pr human changes requested") | .approved_sha=null | .repair_hint=$(js "PR#$pr 有人工请求修改的评审，见评审反馈。") | .stage=\"repair-pending\""
    say "ready unit=$id pr=$pr: human changes requested -> repair-pending"
  done < <(jqf -r '.units[] | select(.stage == "ready-to-merge" and (.pr // null) != null)
    | [.id, (.pr | tostring), ([(.history // [])[] | select(.stage == "write-start") | .at] | last // "")] | @tsv' "$UNITS")
  return 0
}
