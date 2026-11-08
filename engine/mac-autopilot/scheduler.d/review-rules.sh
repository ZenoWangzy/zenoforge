supervisor_rule() {
  local note r
  note="$(jqf -r '.note // ""' <<<"$1")"
  [[ "$note" == CTO* ]] && printf '\n【supervisor 裁决（必须遵守，不得据此 BLOCK 或打回）】%s' "$note"
  while IFS= read -r r; do
    [[ -n "$r" && "$r" != "$note" ]] && printf '\n【supervisor 裁决（必须遵守，不得据此 BLOCK 或打回）】%s' "$r"
  done < <(jqf -r "$(cto_rulings_norm)[]" <<<"$1")
  return 0
}
decision_scope() { # unit-json -> prior decisions in history, for the next implementation worker
  local decisions
  decisions="$(jqf -r '[(.history // [])[] | select(.decision != null) |
    "- \(.at // "") [\(.decision.owner // "")] \(.decision.decision // "")\n  Why: \(.decision.why // "")\n  Evidence: \(.decision.evidence // "")\n  Rejected: \((.decision.rejected // []) | if type == "array" then join(", ") else tostring end)"] | join("\n")' <<<"$1")"
  [[ -n "$decisions" ]] || return 0
  printf 'Decided earlier (do not reopen without new evidence):\n%s' "$decisions"
}
hotpatch_rule() { [[ "$(jqf -r '.hotpatch // false' <<<"$1")" == true ]] && printf '%s' "$HOTPATCH_REVIEW_RULE"; return 0; }
arbiter_rule() { [[ "$(jqf -r '.arbiter // false' <<<"$1")" == true ]] && printf '%s' "$ARBITER_RULE"; return 0; }
incident_rule_for_unit() {
  incident_labels_match_json "$1" "${INCIDENT_LABELS:-$INCIDENT_DEFAULT_LABELS_JSON}" || return 0
  printf '\n%s' "${INCIDENT_RULE:-$(incident_rule_text)}"
}
incident_worker_prompt() { # worker type unit JSON prompt → prompt with the shared incident rule when applicable
  local type="$1" unit_json="$2" prompt="$3"
  case "$type" in
    implement|repair|review|rereview) prompt+="$(incident_rule_for_unit "$unit_json")" ;;
  esac
  printf '%s' "$prompt"
}
incident_escalation_stated() { # prior-art section on stdin → success when it says an escalation happened; negated mentions ("no escalation was needed") do not count
  local apos="'" aux='(was|were|is|are|be|been|has|have|had|did|does)' before after
  # Negators may be followed only by a short closed filler list, so "was not sure and escalated" still counts as an escalation.
  before="(^|[^[:alpha:]])(no|not|never|without|nothing)([[:space:]]+(further|other|additional|formal|any|an|a|the|need|needed|to|be|have|required))*[[:space:]]+escalat[[:alpha:]]*"
  after="escalat[[:alpha:]]*[:,]?([[:space:]]+reference)?[:,]?([[:space:]]+$aux)*(([[:space:]]+(not|never|unnecessary|unneeded|moot|none|n/a))|[[:space:]]+[[:alpha:]]+n${apos}t)([^[:alpha:]/]|$)"
  tr '[:upper:]' '[:lower:]' | sed -E "s/$before//g; s#$after#  #g" | grep -Eq '(^|[^[:alpha:]])escalat(e|ed|es|ion|ions|ing)([^[:alpha:]]|$)'
}
incident_report_gate_reason() { # incident unit [implementation report path] → missing report requirement or empty
  local unit_json="$1" report="${2:-}" kind_line kind guard_section prior_art_section missing=()
  incident_labels_match_json "$unit_json" "${INCIDENT_LABELS:-$INCIDENT_DEFAULT_LABELS_JSON}" || return 0
  if [[ -z "$report" ]]; then
    report="$(jqf -r '.implementation_report // .report // empty' <<<"$unit_json")"
  fi
  if [[ -z "$report" ]]; then
    printf 'missing ## root-cause, ## recurrence-guard, and ## prior-art (incident implementation report is unavailable)'
    return 0
  fi
  [[ "$report" == /* ]] || report="$SUP/$report"
  if [[ ! -s "$report" ]]; then
    printf 'missing ## root-cause, ## recurrence-guard, and ## prior-art (incident implementation report is unavailable: %s)' "${report##*/}"
    return 0
  fi
  grep -qE '^## root-cause[[:space:]]*$' "$report" || missing+=("## root-cause")
  grep -qE '^## recurrence-guard[[:space:]]*$' "$report" || missing+=("## recurrence-guard")
  grep -qE '^## prior-art[[:space:]]*$' "$report" || missing+=("## prior-art")
  if (( ${#missing[@]} > 0 )); then
    printf 'missing %s' "$(IFS=' and '; echo "${missing[*]}")"
    return 0
  fi
  prior_art_section="$(awk '/^## prior-art[[:space:]]*$/{inside=1; next} /^##[[:space:]]/{inside=0} inside {print}' "$report")"
  if ! grep -Eiq 'https?://[^[:space:]<>)]+' <<<"$prior_art_section"; then
    printf 'missing an http(s) source URL in ## prior-art'
    return 0
  fi
  if incident_escalation_stated <<<"$prior_art_section" \
    && ! grep -Eiq '^[[:space:]]*([-*][[:space:]]+)?escalation reference:[[:space:]]*(https?://[^[:space:]]+|#[0-9]+|PR[[:space:]]*#[0-9]+|issue[[:space:]]*#[0-9]+)[[:space:]]*$' <<<"$prior_art_section"; then
    printf 'escalation note in ## prior-art lacks an escalation reference'
    return 0
  fi
  guard_section="$(awk '/^## recurrence-guard[[:space:]]*$/{inside=1; next} /^##[[:space:]]/{inside=0} inside {print}' "$report")"
  kind_line="$(grep -iE '^[[:space:]]*([-*][[:space:]]+|[0-9]+[.)][[:space:]]+)?(guard[[:space:]]+)?kind:[[:space:]]*' <<<"$guard_section" | head -n1 | tr '[:upper:]' '[:lower:]' || true)"
  kind="$(sed -nE 's/^[[:space:]]*([-*][[:space:]]+|[0-9]+[.)][[:space:]]+)?(guard[[:space:]]+)?kind:[[:space:]]*`?([[:alnum:]-]+)`?.*$/\3/p' <<<"$kind_line" | head -n1)"
  case "$kind" in
    architecture|state|script|lint|test) ;;
    prose) printf 'guard kind prose is not allowed'; return 0 ;;
    "") printf 'missing recurrence-guard kind (expected architecture, state, script, lint, or test)'; return 0 ;;
    *) printf 'guard kind %s is not allowed (expected architecture, state, script, lint, or test)' "$kind"; return 0 ;;
  esac
  return 0
}
# 4741: every repair replaced implementation_report, so a 5-line merge-repair report failed the gate above on the newest file,
# turned a READY review into NOT_READY and dispatched another repair, four times. A report becomes the unit's implementation_report only when it passes the gate.
implementation_report_adopt() { # unit report-name [dispatch] → 0 adopted, 1 failed the gate (resume may repair it), 2 kept the old report or escalated
  local id="$1" new="$2" mode="${3:-harvest}" u old reason prev_reason n
  u="$(jqf -c --arg id "$id" '[.units[] | select(.id==$id)][0] // {}' "$UNITS")"
  old="$(jqf -r '.implementation_report // empty' <<<"$u")"
  reason="$(incident_report_gate_reason "$u" "$new")"
  if [[ -z "$reason" ]]; then
    set_unit "$id" ".implementation_report=$(js "$new") | del(.report_gate_fail)"
    return 0
  fi
  # At dispatch the worker has not written the report yet, so an incident unit keeps its passing report until harvest judges the new one.
  if [[ -n "$old" && "$old" != "$new" && -z "$(incident_report_gate_reason "$u" "$old")" ]]; then
    [[ "$mode" == dispatch ]] || { say "report-keep unit=$id kept=$old rejected=$new reason=$reason"; set_unit "$id" 'del(.report_gate_fail)'; }
    return 2
  fi
  set_unit "$id" ".implementation_report=$(js "$new")"
  [[ "$mode" != dispatch ]] || return 1
  prev_reason="$(jqf -r '.report_gate_fail.reason // empty' <<<"$u")"
  n=1; [[ "$prev_reason" != "$reason" ]] || n=$(( $(jqf -r '.report_gate_fail.n // 0' <<<"$u") + 1 ))
  set_unit "$id" ".report_gate_fail={reason:$(js "$reason"),n:$n}"
  # No passing report to keep and the same reason twice in a row: another repair writes the same kind of report.
  if (( n >= 2 )); then
    to_supervisor "$id" "incident report gate failed ${n} times in a row with the same reason: $reason (report $new)"
    return 2
  fi
  return 1
}
incident_review_verdict() { # incident unit READY|other [implementation report] → READY or forced NOT_READY
  local unit_json="$1" verdict="$2" report="${3:-}" reason
  [[ "$verdict" == READY ]] || { printf '%s' "$verdict"; return 0; }
  reason="$(incident_report_gate_reason "$unit_json" "$report")"
  [[ -z "$reason" ]] && printf 'READY' || printf 'NOT_READY'
}
# 引擎覆盖守卫（2026-11-03：产品 PR 通过 .zenoforge/build/overrides.tsv fork 引擎文件，评审时无人拒绝，只有 converge
# 的 override guard 在合并后才拦截并卡死全部 pin）。评审时用与 converge override guard 相同的引擎文件分类——
# build.json pin 所指引擎树里存在的路径，不维护第二份清单——拒绝「新增/变更 overrides.tsv 行」或「新增 pack 文件遮蔽
# 引擎文件」的 diff；唯一逃生口是 supervisor 的 PR 标签（config engine_override.approved_label）。
engine_override_approved_label() { # config JSON → PR label that skips the engine override guard
  local label
  label="$(jq -r '.engine_override.approved_label // "engine-override-approved"' <<<"$1" 2>/dev/null || true)"
  [[ -n "$label" && "$label" != null ]] || label='engine-override-approved'
  printf '%s' "$label"
}
engine_override_engine_dir() { # → directory of the engine whose tree classifies engine-owned files
  if [[ -n "${ZF_ENGINE_DIR:-}" && -d "${ZF_ENGINE_DIR:-}" ]]; then
    printf '%s' "$ZF_ENGINE_DIR"
  elif [[ -n "${ENGINE_ROOT:-}" && -d "${ENGINE_ROOT:-}" ]]; then
    printf '%s' "$ENGINE_ROOT"
  else
    (cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
  fi
}
engine_override_engine_ships() { # pin rel-path → success when the pinned engine ships the file
  local pin="$1" rel="$2" dir sha_re='^[0-9a-f]{40}$'
  dir="$(engine_override_engine_dir)"
  # The converge override guard verifies each overrides row against the pinned engine's tree; resolve the same
  # pin in a git checkout first, then fall back to the running engine's files when it has no git directory.
  if [[ "$pin" =~ $sha_re ]] \
     && git -C "$dir" cat-file -e "$pin:${ZF_PACK_REL:-engine}/$rel" >/dev/null 2>&1; then
    return 0
  fi
  [[ -f "$dir/$rel" ]]
}
engine_override_pr_has_label() { # pr label → success when the PR carries the label
  local pr="$1" want="$2" prs labels
  [[ "$pr" =~ ^[0-9]+$ ]] || return 1
  if prs="$(tick_prs 2>/dev/null)" \
     && labels="$(jq -r --argjson p "$pr" 'if any(.[]; .number == $p) then ([.[] | select(.number == $p)][0].labels // []) | .[] | .name // empty else "absent" end' <<<"$prs" 2>/dev/null)"; then
    [[ "$labels" == absent ]] && return 1
    grep -Fxq -- "$want" <<<"$labels" && return 0
    return 1
  fi
  labels="$(pr_view "$pr" labels 2>/dev/null | jq -r '.[]? | .name // empty' 2>/dev/null || true)"
  grep -Fxq -- "$want" <<<"$labels"
}
engine_override_scan() { # checkout head → offending rows: kind, file, line, engine path, path, blob, base blob
  local checkout="$1" head="$2" base pin_json hook engine overrides_rel pack_rel line path blob base_blob rel f hook_dir sha_re='^[0-9a-f]{40}$'
  [[ -n "$checkout" && -d "$checkout" ]] || return 0
  base="$(git -C "$checkout" merge-base origin/main "$head" 2>/dev/null)" || return 0
  [[ "$base" =~ $sha_re ]] || return 0
  pin_json="$(git -C "$checkout" show "$head:.zenoforge/build.json" 2>/dev/null)" || return 0
  hook="$(jq -r '.hook // empty | select(type == "string" and length > 0)' <<<"$pin_json" 2>/dev/null || true)"
  engine="$(jq -r '.engine // empty | select(type == "string" and length > 0)' <<<"$pin_json" 2>/dev/null || true)"
  [[ -n "$hook" && -n "$engine" ]] || return 0
  case "$hook" in */*) hook_dir="${hook%/*}" ;; *) hook_dir="" ;; esac
  overrides_rel="${hook_dir:+$hook_dir/}overrides.tsv"
  pack_rel="${hook_dir:+$hook_dir/}pack"
  if git -C "$checkout" cat-file -e "$head:$overrides_rel" 2>/dev/null; then
    while IFS=$'\t' read -r line path blob; do
      [[ -n "${path:-}" ]] || continue
      base_blob="$( { git -C "$checkout" show "$base:$overrides_rel" 2>/dev/null || true; } \
        | awk -F'\t' -v p="$path" '$1 == p {print $2; exit}')"
      [[ "$base_blob" == "${blob:-}" ]] && continue
      engine_override_engine_ships "$engine" "$path" || continue
      printf 'override-row\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$overrides_rel" "$line" "${ZF_PACK_REL:-engine}/$path" "$path" "${blob:-}" "${base_blob:-absent}"
    done < <(git -C "$checkout" show "$head:$overrides_rel" 2>/dev/null \
      | awk -F'\t' 'NF >= 2 && $1 !~ /^[[:space:]]*#/ {print NR "\t" $1 "\t" $2}')
  fi
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    rel="${f#"$pack_rel"/}"
    [[ "$rel" != "$f" ]] || continue
    engine_override_engine_ships "$engine" "$rel" || continue
    printf 'pack-file\t%s\t1\t%s\t%s\t\t\n' "$f" "${ZF_PACK_REL:-engine}/$rel" "$rel"
  done < <(git -C "$checkout" diff --no-renames --diff-filter=A --name-only "$base" "$head" -- "$pack_rel" 2>/dev/null)
  return 0
}
engine_override_gate_reason() { # pr approved-label checkout head → blocking finding lines, or empty when admitted
  local pr="$1" label="$2" checkout="$3" head="$4" rows kind file line engine_path path blob base_blob
  rows="$(engine_override_scan "$checkout" "$head" 2>/dev/null || true)"
  [[ -n "$rows" ]] || return 0
  engine_override_pr_has_label "$pr" "$label" && return 0
  while IFS=$'\t' read -r kind file line engine_path path blob base_blob; do
    [[ -n "${file:-}" ]] || continue
    if [[ "$kind" == pack-file ]]; then
      printf '%s:%s shadows the engine-owned file %s with a pack copy; engine change: file it on ZenoWangzy/zenoforge\n' \
        "$file" "$line" "$engine_path"
    else
      printf '%s:%s overrides the engine-owned file %s (base row blob: %s); engine change: file it on ZenoWangzy/zenoforge\n' \
        "$file" "$line" "$engine_path" "${base_blob:-absent}"
    fi
  done <<<"$rows"
}
engine_override_findings_json() { # checkout head → review-findings object, one P1 Standards finding per offending row
  local checkout="$1" head="$2" rows kind file line engine_path path blob base_blob id=0 findings='[]' summary evidence
  rows="$(engine_override_scan "$checkout" "$head" 2>/dev/null || true)"
  while IFS=$'\t' read -r kind file line engine_path path blob base_blob; do
    [[ -n "${file:-}" ]] || continue
    [[ "$line" =~ ^[0-9]+$ ]] || line=1
    id=$((id + 1))
    if [[ "$kind" == pack-file ]]; then
      summary="A new pack file shadows the engine-owned $engine_path; engine change: file it on ZenoWangzy/zenoforge."
      evidence="The base has no pack file for $path; the candidate adds one over the engine-owned $engine_path."
    else
      summary="An overrides.tsv row overrides the engine-owned $engine_path; engine change: file it on ZenoWangzy/zenoforge."
      evidence="The base overrides row for $path pins ${base_blob:-nothing}; the candidate pins ${blob:-empty}, and the pinned engine ships $engine_path."
    fi
    findings="$(jq -cn --argjson findings "$findings" --arg id "F$id" --arg file "$file" --argjson line "$line" \
      --arg engine_path "$engine_path" --arg summary "$summary" --arg evidence "$evidence" \
      --arg checkout "$checkout" --arg head "$head" \
      --arg rerun_output "line $line: $(git -C "$checkout" show "$head:$file" 2>/dev/null | sed -n "${line}p" | head -c 200)" \
      '$findings + [{id:$id,severity:"P1",file:$file,line:$line,rule:"Standards",status:"open",summary:$summary,
        introduced_by:"candidate",base_evidence:$evidence,
        rerun_command:("git -C '"'"'" + $checkout + "'"'"' show '"'"'" + $head + ":" + $file + "'"'"'"),rerun_output:$rerun_output}]')"
  done <<<"$rows"
  printf '{"findings":%s,"dispositions":[]}' "$findings"
}
engine_override_review_verdict() { # pr approved-label checkout head READY|other → READY or forced NOT_READY
  local pr="$1" label="$2" checkout="$3" head="$4" verdict="$5" reason
  [[ "$verdict" == READY ]] || { printf '%s' "$verdict"; return 0; }
  reason="$(engine_override_gate_reason "$pr" "$label" "$checkout" "$head" 2>/dev/null || true)"
  if [[ -n "$reason" ]]; then printf 'NOT_READY'; else printf 'READY'; fi
  return 0
}
risk_class_safety_rule() { # checkout → safety prompt for risk classes found by the repository classifier
  local checkout="$1" hits classes paths
  [[ -n "$checkout" && -d "$checkout" ]] || return 0
  hits="$(cd "$checkout" && node "$HERE/../risk-class.mjs" --json origin/main...HEAD 2>/dev/null)" || return 0
  classes="$(jq -r '[.[].kind] | unique | join(", ")' <<<"$hits" 2>/dev/null)"
  [[ -n "$classes" ]] || return 0
  paths="$(jq -r '.[] | "- \(.kind): \(.path)"' <<<"$hits")"
  printf '\nRisk-class paths from the existing classifier (%s):\n%s\n' "$classes" "$paths"
}
lane_rule() { # lane sha
  [[ "$1" == direct-main ]] || return 0
  printf '%s' "
本单元走非产品快车道（direct-main）：评审对象是本 clone 当前检出的提交 $2，它可能只在本地、尚未推到 PR 或根本没有 PR（非产品改动不开 PR、不推 topic），GitHub 上的 PR head、PR diff 与 CI 状态因此不同步属正常——diff 以本地 git 为准，不用 gh pr diff。批准后流水线把它压成一个提交经 land-direct-main.sh 直落 main（落地时跑 focused 检查，suites 在落地后跑）。PR head 不同步、无 CI run、交付路径都不是阻断理由。"
}
subject_of() { # pr issue → 评审/修复对象的称呼（无 PR 的直落单元用 issue 或单元 id）
  if [[ -n "$1" ]]; then printf 'PR #%s' "$1"; elif [[ -n "$2" ]]; then printf 'issue #%s 的本地实现（无 PR）' "$2"; else printf '本地实现（无 PR）'; fi
}
review_prompt() { # pr-or-subject title sha report [lane] [checkout]
  local subject="$1"; [[ "$subject" =~ ^[0-9]+$ ]] && subject="PR #$subject"
  printf '%s' "你是 the product 流水线的独立代码评审 subagent，只读【增量评审】（diff-scoped，不做全库漫游）。当前目录是隔离 clone，已检出被评审提交（detached），origin/main 为最新 main；本地 diff：git diff origin/main...HEAD。评审 ${subject}（$2）fixed head $3：
评审面：① diff（merge-base..head）与关联 issue 验收条件逐条对照；② 变更文件的直接 import/依赖闭包；③ 只读边界下可核实的测试与行为证据。
请完整读取并遵守正式评审契约，按其要求评审与交付。$(review_contract_rule)
效率纪律：不重述代码内容；不展开未变更文件的细节；低风险样式性改动一行带过。目标 15-25 分钟内交付。
只读边界：不编辑/commit/push/merge/评论。报告写到 $SUP/$4。落盘后交付完即结束。$(risk_class_safety_rule "${6:-}")$(lane_rule "${5:-}" "$3")"
}

pr_view() { gh pr view "$1" --json "$2" --jq ".$2" 2>/dev/null; }
tick_pr_head() { # PR → head SHA from this tick's open-PR census, with a direct fallback for a census miss
  local pr="$1" prs="" head=""
  prs="$(tick_prs 2>/dev/null || true)"
  if [[ -n "$prs" ]]; then
    head="$(jqf -r --argjson p "$pr" '[.[] | select(.number == $p) | .headRefOid][0] // empty' <<<"$prs")"
  fi
  [[ "$head" =~ $SHA_RE ]] || head="$(pr_view "$pr" headRefOid)" || return 1
  [[ "$head" =~ $SHA_RE ]] || return 1
  printf '%s\n' "$head"
}
tick_pr_base() { # PR → base branch from this tick's open-PR census, with a direct fallback for a census miss
  local pr="$1" prs="" base=""
  prs="$(tick_prs 2>/dev/null || true)"
  if [[ -n "$prs" ]]; then
    base="$(jqf -r --argjson p "$pr" '[.[] | select(.number == $p) | .baseRefName][0] // empty' <<<"$prs")"
  fi
  [[ -n "$base" ]] || base="$(pr_view "$pr" baseRefName)" || return 1
  [[ -n "$base" ]] || return 1
  printf '%s\n' "$base"
}
tick_pr_branch() { # PR → head branch from this tick's open-PR census, with a direct fallback for a census miss
  local pr="$1" prs="" branch=""
  prs="$(tick_prs 2>/dev/null || true)"
  if [[ -n "$prs" ]]; then
    branch="$(jqf -r --argjson p "$pr" '[.[] | select(.number == $p) | .headRefName][0] // empty' <<<"$prs")"
  fi
  [[ -n "$branch" ]] || branch="$(pr_view "$pr" headRefName)" || return 1
  [[ -n "$branch" ]] || return 1
  printf '%s\n' "$branch"
}
tick_pr_state() { # An open-census hit is OPEN; closed or missing PRs still need a direct lookup.
  local prs state=""
  prs="$(tick_prs 2>/dev/null || true)"
  [[ -z "$prs" ]] || state="$(jqf -r --argjson p "$1" 'if any(.[]; .number == $p) then "OPEN" else empty end' <<<"$prs")"
  [[ -n "$state" ]] || state="$(pr_view "$1" state)" || return 1
  printf '%s\n' "$state"
}
tick_pr_mergeable() { # Missing mergeability and PRs outside the census use the direct lookup.
  local prs state=""
  prs="$(tick_prs 2>/dev/null || true)"
  [[ -z "$prs" ]] || state="$(jqf -r --argjson p "$1" '[.[] | select(.number == $p) | .mergeable][0] // empty' <<<"$prs")"
  [[ -n "$state" ]] || state="$(pr_view "$1" mergeable)" || return 1
  printf '%s\n' "$state"
}
classify_lane() { # pr → direct-main|pr（取不到文件列表返回 1）
  local files json verdict
  # The REST file list includes previous_filename for renames; both sides must be classified.
  # gh refuses --slurp together with --jq (exit 1 before any request): from 10-20 every call failed, 506 a hour on
  # 10-22, and no unit got a lane, so non-product PRs never took the direct-main lane. --jq runs per page instead.
  files="$(gh api --paginate "repos/{owner}/{repo}/pulls/$1/files" \
    --jq '.[] | .filename, (.previous_filename // empty)' 2>/dev/null)" || return 1
  json="$(jq -Rsc 'split("\n") | map(select(length > 0))' <<<"$files")" || return 1
  [[ "$json" != '[]' ]] || return 1
  verdict="$(node "$POLICY_SCRIPT" --classify-path-set - <<<"$json" 2>/dev/null)" || return 1
  [[ "$verdict" == eligible ]] && echo direct-main || echo pr
}
lane_policy_blob() { git -C "$ROOT" rev-parse "HEAD:${POLICY_SCRIPT#"$ROOT"/}" 2>/dev/null || echo unknown; }
fast_land_candidates() { # → 快车道要看的 ready-to-merge 单元（每行一个 JSON）
  # 记成 pr 车道但分类策略已变的单元也要进来，让 ensure_lane 重分；只取 lane != pr 时它们永远留在产品车道
  # （10-22：94 个待合并单元里 35 个策略过期，其中 4 个非产品 PR 一直排 CI 名额）。
  # supervisor-owned 热修单元不经快车道重分或直落：直落会推 main，归热修 supervisor 会话。
  jqf -c --arg p "$(lane_policy_blob)" '[.units[] | select(.stage=="ready-to-merge" and (.hold_handoff_waiting // false) == false
      and (.supervisor_owned // false) == false
      and ((.pr // null) != null or (.lane // "") == "direct-main")
      and ((.lane // "") != "pr" or (.lane_policy // "") != $p))] | sort_by('"$(ready_since_epoch)"') | .[]' "$UNITS"
}
ensure_lane() { # id pr → 打印并记录 lane
  # 分类随策略文件变：pr 车道的单元在 branch-delivery-policy.mjs 改动后重分一次（10-22 R1 把 workflow 划进直落 main，
  # 之前被记成 pr 的 #4044 若不重分会永远走产品 PR 车道）。direct-main 不回退：PR 新增产品路径会在派发前被拒。
  local lane policy; lane="$(unit_field "$1" .lane)"
  policy="$(lane_policy_blob)"
  if [[ -z "$lane" || ( "$lane" == pr && "$(unit_field "$1" '.lane_policy // empty')" != "$policy" ) ]]; then
    lane="$(classify_lane "$2")" || return 1
    set_unit "$1" ".lane=\"$lane\" | .lane_policy=\"$policy\""
  fi
  printf '%s' "$lane"
}
# 评审目标绑定一对 SHA：远端 PR head 是审核时观察到的基线，候选 SHA 可以是该 head 的本地修复后代。
unit_review_target() { # id pr lane branch → <pr-head> <candidate-sha>
  local pr_head local_head dir="$WT_ROOT/wt-$1"
  if [[ -z "$2" ]]; then
    # 无 PR 的直落单元：候选是本地分支 head，基线是它与 main 的分叉点（批准绑定这一对）。
    [[ "$3" == direct-main && -n "$4" && -d "$dir/.git" ]] || return 1
    local_head="$(git -C "$dir" rev-parse -q --verify "refs/heads/$4" 2>/dev/null)"
    pr_head="$(git -C "$dir" merge-base refs/remotes/origin/main "$local_head" 2>/dev/null)"
    [[ "$local_head" =~ $SHA_RE && "$pr_head" =~ $SHA_RE && "$local_head" != "$pr_head" ]] || return 1
    printf '%s %s' "$pr_head" "$local_head"; return 0
  fi
  pr_head="$(tick_pr_head "$2")" || return 1
  if [[ "$3" == direct-main && -n "$4" && -d "$dir/.git" ]]; then
    local_head="$(git -C "$dir" rev-parse -q --verify "refs/heads/$4" 2>/dev/null)"
    if [[ "$local_head" =~ $SHA_RE && "$local_head" != "$pr_head" ]] \
      && git -C "$dir" merge-base --is-ancestor "$pr_head" "$local_head" 2>/dev/null; then
      printf '%s %s' "$pr_head" "$local_head"; return 0
    fi
  fi
  printf '%s %s' "$pr_head" "$pr_head"
}
unit_head() { # id pr lane branch → candidate SHA (compatibility helper)
  local target
  target="$(unit_review_target "$1" "$2" "$3" "$4")" || return 1
  printf '%s' "${target#* }"
}
