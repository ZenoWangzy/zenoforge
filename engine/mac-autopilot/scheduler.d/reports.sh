final_message_of() { awk '/^tokens used$/{getline; buf=""; f=1; next} f{buf=buf $0 "\n"} END{printf "%s", buf}' "$1" 2>/dev/null; }
tokens_of() { awk '/tokens used/{getline; if (match($0, /[0-9][0-9,]*/)) { n=substr($0, RSTART, RLENGTH); gsub(/,/, "", n); print n }; exit}' "$1" 2>/dev/null; }

write_state() { # 用法: jqf ... "$1" | write_state "$1"   stdin=新内容 $1=目标文件
  local dst="$1" _t valid=false; _t="$(mktemp "${dst}.tmp.XXXXXX")" || return 1
  cat > "$_t"
  if [[ "$dst" == "$UNITS" ]]; then
    # No units are deleted by this scheduler. Clone cleanup and worker-ledger
    # trimming below remain legitimate; neither may erase registered unit IDs.
    # -s: a state file must be exactly one document. A top-level comma in a hand edit (10-29 06:32Z) wrote three
    # concatenated copies; per-document -e accepted every later write and each copy drifted apart.
    jq -e -s --slurpfile old "$dst" 'length==1 and (.[0] |
      type=="object" and (.units|type)=="array"
      and all(.units[]; type=="object" and (.id|type)=="string" and (.id|length)>0 and (.stage|type)=="string")
      and ([.units[].id]|length)==([.units[].id]|unique|length)
      and (($old[0].units|map(.id)) - [.units[].id] | length)==0)
    ' "$_t" >/dev/null 2>&1 && valid=true
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

# 评审结论只认整行 `VERDICT: X`；旧报告别名规范化为 review-contract.md 的 verdict。
verdict_of() {
  local found findings
  found="$(grep -E '^[[:space:]>#*-]*(\*\*)?VERDICT:[[:space:]]*(READY|NOT_READY|INPUT_INCOMPLETE|APPROVE|REQUEST-CHANGES|BLOCK)(\*\*)?[[:space:]]*$' "$1" 2>/dev/null \
    | grep -oE 'READY|NOT_READY|INPUT_INCOMPLETE|APPROVE|REQUEST-CHANGES|BLOCK' \
    | sed -e 's/^APPROVE$/READY/' -e 's/^REQUEST-CHANGES$/NOT_READY/' -e 's/^BLOCK$/INPUT_INCOMPLETE/' | sort -u)"
  if [[ -n "$found" ]]; then
    [[ "$(wc -l <<<"$found")" -eq 1 ]] && { printf '%s' "$found"; return 0; }
    return 1
  fi
  # 10-28：约 1/5 的评审写「## Verdict」标题、下一行裸写 NOT_READY，缺 `VERDICT:` 前缀，被当成无结论重跑。
  found="$(awk 'h && NF { gsub(/[*`]/, ""); if ($0 ~ /^[[:space:]]*(READY|NOT_READY|INPUT_INCOMPLETE)[[:space:]]*$/) print $1; exit }
    /^#+[[:space:]]*Verdict[[:space:]]*$/ { h = 1 }' "$1" 2>/dev/null)"
  if [[ -n "$found" ]]; then
    [[ "$(wc -l <<<"$found")" -eq 1 ]] && { printf '%s' "$found"; return 0; }
    return 1
  fi
  findings="$(findings_block_of "$1")" || return 1
  jqf -e 'any(.findings[]; .status=="open" and (.severity=="P0" or .severity=="P1"))' <<<"$findings" >/dev/null 2>&1 \
    && printf 'NOT_READY'
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
  raw="$(awk '/^```review-findings[[:space:]]*$/{on=1;buf="";last="";next} on&&/^```[[:space:]]*$/{last=buf;on=0;next} on{buf=buf $0 "\n"} END{printf "%s", last}' "$1" 2>/dev/null)"
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
    def disposition: type=="object" and (.id|type)=="string" and (.id|length)>0
      and (.disposition|IN("fixed","disproved","intentional","out-of-scope"))
      and (.reason|type)=="string" and (.reason|test("\\S")) and (.reason|test("^[^\\r\\n]+$"))
      and keys==["disposition","id","reason"];
    if type=="array" and all(.[]; finding(true)) then
      {findings:map(normalized_finding),dispositions:[],legacy:true,dropped:0,dropped_findings:[]}
    elif type=="object" and keys==["dispositions","findings"] and (.findings|type)=="array" and (.dispositions|type)=="array"
      and all(.findings[]; finding(false)) and all(.dispositions[]; disposition)
      and (([.findings[].id] | length)==([.findings[].id] | unique | length))
      and (([.dispositions[].id] | length)==([.dispositions[].id] | unique | length)) then
      {findings:(.findings|map(select(evidence_gap==[])|normalized_finding)),dispositions:.dispositions,legacy:false,
       dropped:([.findings[]|select(evidence_gap!=[])]|length),
       dropped_findings:[.findings[]|select(evidence_gap!=[])|{id,reason:("no rerunnable evidence: missing "+(evidence_gap|join(", ")))}]}
    else empty end' <<<"$raw" 2>/dev/null
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
# 一次打回在 .review_findings 里追加一条：round 是它在 history 里的第几次打回，findings 只含阻断级（P0/P1，
# 含 resolved 状态，由复发规则排除）；块缺失或畸形记 block=missing（node_health 的 review.findings_missing_pct 数它）。
# 不写 history：顾问触发读 history 的最后一条是否为 review-request-changes。
review_findings_update() { # report-path report-name → set_unit 表达式片段（以 " | " 开头）
  local rec block
  if block="$(findings_block_of "$1")"; then
    rec="$(jq -c '{block:"ok", findings:[.findings[] | select(.severity=="P0" or .severity=="P1")], all_findings:.findings, dispositions:[], dropped, dropped_findings}' <<<"$block")"
  else
    rec='{"block":"missing","findings":[],"dispositions":[]}'
  fi
  printf ' | .review_findings = ((.review_findings // []) + [{round:((.history // []) | map(select(.stage=="review-request-changes")) | length), at:%s, report:%s} + %s])' \
    "$(js "$STAMP")" "$(js "$2")" "$rec"
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
