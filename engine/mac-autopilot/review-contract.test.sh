#!/usr/bin/env bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/review-contract.sh"
source "$script_dir/scheduler.d/reports.sh"
source "$script_dir/../night/owner-report-render.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp" "$test_env_root"' EXIT

fail() { echo "review-contract.test.sh: $*" >&2; exit 1; }
jqf() { command jq "$@"; }
js() { command jq -Rn --arg v "$1" '$v'; }

cat >"$tmp/implement-report.md" <<'EOF'
```contract
{
  "acceptance_criteria": ["The issue requirement is met."],
  "intended_files": ["src/example.ts"],
  "behavior_changes": ["The new behavior is visible."],
  "tests_added": ["src/example.test.ts: accepts the valid input"]
}
```
Implementation summary follows.
EOF
contract="$(contract_block_of "$tmp/implement-report.md")" || fail 'valid contract block was rejected'
[[ "$(jq -r '.acceptance_criteria[0]' <<<"$contract")" == 'The issue requirement is met.' ]] || fail 'acceptance criteria were not extracted'
[[ "$(jq -r '.intended_files[0]' <<<"$contract")" == 'src/example.ts' ]] || fail 'intended files were not extracted'
[[ "$(jq -r '.behavior_changes[0]' <<<"$contract")" == 'The new behavior is visible.' ]] || fail 'behavior changes were not extracted'
[[ "$(jq -r '.tests_added[0]' <<<"$contract")" == 'src/example.test.ts: accepts the valid input' ]] || fail 'tests added were not extracted'

printf 'No contract block\n' >"$tmp/missing.md"
if contract_block_of "$tmp/missing.md" >/dev/null; then fail 'missing contract block was accepted'; fi
cat >"$tmp/malformed.md" <<'EOF'
```contract
{"acceptance_criteria": [2], "intended_files": [], "behavior_changes": [], "tests_added": []}
```
EOF
if contract_block_of "$tmp/malformed.md" >/dev/null; then fail 'contract with non-string entries was accepted'; fi

check_review_contract_example() {
  local path="$1" parsed
  parsed="$(findings_block_of "$path")" || fail "review contract findings example was rejected: $path"
  [[ "$(jq -r '.findings|length' <<<"$parsed")" == 1 ]] || fail "review contract example did not keep one finding: $path"
  [[ "$(jq -r '.findings[0].class // empty' <<<"$parsed")" == null-guard ]] || fail "review contract example did not preserve its class: $path"
  [[ "$(jq -r '.dropped' <<<"$parsed")" == 0 ]] || fail "review contract example dropped a finding: $path"
}
review_contract="$script_dir/../prompts/review-contract.md"
check_review_contract_example "$review_contract"
grep -Fq -- '- `rerun_command`:' "$review_contract" || fail 'review contract field list omits rerun_command'
grep -Fq -- '- `rerun_output`:' "$review_contract" || fail 'review contract field list omits rerun_output'
override_review_contract="$script_dir/../../.zenoforge/prompts/review-contract.md"
if [[ -f "$override_review_contract" ]]; then check_review_contract_example "$override_review_contract"; fi

cat >"$tmp/unverified-review.md" <<'EOF'
Review report without a verdict line.

```review-findings
{"findings":[{"id":"F1","severity":"P1","file":"src/a.ts","line":4,"rule":"Defect","status":"unverified","summary":"Only a test can prove this finding.","introduced_by":"candidate","base_evidence":"The base lacks the check.","rerun_command":"pnpm vitest run src/a.test.ts","rerun_output":"Not run by the read-only reviewer; pass to repair or the engine's test run."}],"dispositions":[]}
```
EOF
unverified="$(findings_block_of "$tmp/unverified-review.md")" || fail 'an unverified test-only finding was rejected'
[[ "$(jq -r '.findings|length' <<<"$unverified")" == 1 && "$(jq -r '.findings[0].status' <<<"$unverified")" == unverified ]] \
  || fail 'an unverified test-only finding was not kept'
[[ "$(jq -r '.dropped' <<<"$unverified")" == 0 ]] || fail 'an unverified test-only finding was dropped'
[[ "$(verdict_of "$tmp/unverified-review.md")" == NOT_READY ]] || fail 'an unverified P1 finding did not default to NOT_READY'
unverified_hint="$(review_findings_hint_update "$tmp/unverified-review.md")"
[[ "$unverified_hint" == *'Only a test can prove this finding.'* ]] || fail 'an unverified finding was not passed to repair'
sed '1i VERDICT: READY' "$tmp/unverified-review.md" > "$tmp/unverified-ready.md"
[[ "$(verdict_of "$tmp/unverified-ready.md")" == NOT_READY ]] || fail 'an explicit READY verdict overrode an unverified P1 finding'
{ printf '## Verdict\nREADY\n'; cat "$tmp/unverified-review.md"; } > "$tmp/unverified-heading-ready.md"
[[ "$(verdict_of "$tmp/unverified-heading-ready.md")" == NOT_READY ]] || fail 'a heading READY verdict overrode an unverified P1 finding'
{
  printf 'VERDICT: READY\n\n```review-findings\n'
  jq -cn '{findings:[{id:"F1",severity:"P1",file:"src/a.ts",line:4,rule:"Defect",status:"unverified",summary:"Only a test can prove this finding.",introduced_by:"candidate",base_evidence:"The base lacks the check."}],dispositions:[]}'
  printf '```\n'
} > "$tmp/unverified-dropped.md"
dropped_unverified="$(findings_block_of "$tmp/unverified-dropped.md")" || fail 'a dropped unverified finding block was rejected entirely'
[[ "$(jq -r '.dropped' <<<"$dropped_unverified")" == 1 ]] || fail 'the missing rerun fields did not mark the unverified finding dropped'
[[ "$(jq -r '.dropped_findings[0] | [.severity,.status] | join(":")' <<<"$dropped_unverified")" == P1:unverified ]] \
  || fail 'the dropped finding lost its blocker severity or unverified status'
[[ "$(verdict_of "$tmp/unverified-dropped.md")" == NOT_READY ]] || fail 'an explicit READY verdict overrode a dropped unverified P1 finding'
printf 'VERDICT: READY\n\n```review-findings\nnot-json\n```\n' > "$tmp/unverified-malformed.md"
if findings_block_of "$tmp/unverified-malformed.md" >/dev/null 2>&1; then fail 'the malformed findings fixture was accepted'; fi
[[ "$(verdict_of "$tmp/unverified-malformed.md")" == NOT_READY ]] || fail 'an explicit READY verdict overrode an unparseable findings block'

findings='[
  {"id":"F1","severity":"P1","file":"src/a.ts","line":4,"rule":"Spec","status":"open","summary":"[contract: in] Required behavior is missing."},
  {"id":"F2","severity":"P1","file":"src/b.ts","line":9,"rule":"Defect","status":"open","summary":"[contract: out] A real data defect remains."},
  {"id":"F3","severity":"P1","file":"src/c.ts","line":12,"rule":"Defect","status":"inherited","summary":"Legacy finding without a relation marker."}
]'
enriched="$(review_findings_with_contract_relation "$findings")" || fail 'findings relation extraction failed'
[[ "$(jq -r '.[0].contract_relation' <<<"$enriched")" == in-contract ]] || fail 'in-contract blocker was not classified'
[[ "$(jq -r '.[1].contract_relation' <<<"$enriched")" == out-of-contract ]] || fail 'out-of-contract blocker was not classified'
[[ "$(jq -r '.[2].contract_relation' <<<"$enriched")" == unclassified ]] || fail 'legacy finding did not remain readable'
[[ "$(jq -r '.[0].summary' <<<"$enriched")" == '[contract: in] Required behavior is missing.' ]] || fail 'the source summary marker was not retained'

AGENT_HOME="$tmp/agent"
SUP="$AGENT_HOME/checkout/.scratch-supervisor"
STAMP=2026-11-10T23:30:00Z
mkdir -p "$SUP"
cat >"$tmp/review.md" <<'EOF'
```review-findings
{"findings":[],"dispositions":[],"decision_log_flags":[{"entry":"Tried cache-first; verification covered only the mock.","reason":"The report has no live-path verification."}]}
```
EOF
parsed="$(findings_block_of "$tmp/review.md")" || fail 'review findings with optional decision-log flags were rejected'
[[ "$(jq -r '.decision_log_flags[0].entry' <<<"$parsed")" == 'Tried cache-first; verification covered only the mock.' ]] \
  || fail 'the optional decision-log flag was not kept by the review parser'

cat >"$tmp/nested-flags.json" <<'EOF'
{
  "findings": [
    {
      "id": "F1",
      "severity": "P1",
      "file": "src/review-target.ts",
      "line": 280,
      "rule": "Defect",
      "status": "open",
      "summary": "The default view omits rows that need review.",
      "introduced_by": "candidate",
      "base_evidence": "The base version includes all rows; the candidate filters them.",
      "rerun_command": "grep -n 'changedRows' src/review-target.ts",
      "rerun_output": "280: filter changedRows",
      "decision_log_flags": []
    }
  ],
  "dispositions": []
}
EOF
write_findings_report() {
  {
    printf '```review-findings\n'
    cat "$1"
    printf '\n```\n'
  } >"$2"
}
write_findings_report "$tmp/nested-flags.json" "$tmp/review-nested-empty.md"
nested_empty="$(findings_block_of "$tmp/review-nested-empty.md")" || fail 'the nested-flags review fixture was rejected'
[[ "$(jq -r 'has("decision_log_flags")' <<<"$nested_empty")" == true ]] \
  || fail 'the parser did not expose decision-log flags at the top level'
[[ "$(jq -r '.findings[0] | has("decision_log_flags")' <<<"$nested_empty")" == false ]] \
  || fail 'the parser kept decision-log flags on the finding'

jq --arg top_entry 'Tried cache-first.' --arg top_reason 'The check only covered a mock.' \
  --arg nested_entry 'Could not verify the live path.' --arg nested_reason 'The report lacks live-path evidence.' \
  '.decision_log_flags=[{entry:$top_entry,reason:$top_reason}]
   | .findings[0].decision_log_flags=[{entry:$top_entry,reason:$top_reason},{entry:$nested_entry,reason:$nested_reason}]' \
  "$tmp/nested-flags.json" >"$tmp/nested-flags-valid.json"
write_findings_report "$tmp/nested-flags-valid.json" "$tmp/review-nested-valid.md"
nested_valid="$(findings_block_of "$tmp/review-nested-valid.md")" || fail 'valid nested decision-log flags were rejected'
[[ "$(jq -r '[.decision_log_flags[].entry] | join("|")' <<<"$nested_valid")" == \
  'Tried cache-first.|Could not verify the live path.' ]] \
  || fail 'nested decision-log flags were not appended and de-duplicated at the top level'
[[ "$(jq -r '.findings[0] | has("decision_log_flags")' <<<"$nested_valid")" == false ]] \
  || fail 'the parser kept hoisted decision-log flags on the finding'

jq '.findings[0].foo="unknown"' "$tmp/nested-flags.json" >"$tmp/nested-flags-unknown.json"
write_findings_report "$tmp/nested-flags-unknown.json" "$tmp/review-nested-unknown.md"
if findings_block_of "$tmp/review-nested-unknown.md" >/dev/null 2>&1; then
  fail 'a finding with an unknown key was accepted'
fi

jq '.findings[0].decision_log_flags=[{"entry":"Missing reason"}]' "$tmp/nested-flags.json" \
  >"$tmp/nested-flags-missing-reason.json"
write_findings_report "$tmp/nested-flags-missing-reason.json" "$tmp/review-nested-missing-reason.md"
if findings_block_of "$tmp/review-nested-missing-reason.md" >/dev/null 2>&1; then
  fail 'a nested decision-log flag without a reason was accepted'
fi

jq --arg entry 'A legacy finding carried a decision-log flag.' --arg reason 'The flag must survive normalization.' \
  '[.findings[0] | .decision_log_flags=[{entry:$entry,reason:$reason}]]' \
  "$tmp/nested-flags.json" >"$tmp/nested-flags-legacy.json"
write_findings_report "$tmp/nested-flags-legacy.json" "$tmp/review-nested-legacy.md"
nested_legacy="$(findings_block_of "$tmp/review-nested-legacy.md")" || fail 'a legacy finding with nested flags was rejected'
[[ "$(jq -r '.decision_log_flags[0].entry' <<<"$nested_legacy")" == 'A legacy finding carried a decision-log flag.' ]] \
  || fail 'a legacy finding decision-log flag was not hoisted'
[[ "$(jq -r '.findings[0] | has("decision_log_flags")' <<<"$nested_legacy")" == false ]] \
  || fail 'a legacy finding kept its decision-log flags after normalization'

review_decision_log_flags_append "$tmp/review.md" issue-876 || fail 'decision-log flags did not append'
[[ "$(jq -r '[.entry,.reason,.unit,.at] | join("|")' "$SUP/decision-log-flags.jsonl")" == \
  'Tried cache-first; verification covered only the mock.|The report has no live-path verification.|issue-876|2026-11-10T23:30:00Z' ]] \
  || fail 'the marked entry did not reach the supervisor JSONL file'
daily_html="$(maintainer_health_mail_build_html '{}' 'plain report' "$AGENT_HOME")"
daily_html="$(jq -r '.html' <<<"$daily_html")"
[[ "$daily_html" == *'决策日志复核（1 条）'* && "$daily_html" == *'Tried cache-first; verification covered only the mock.'* ]] \
  || fail 'the marked entry did not reach the daily report that reads the supervisor JSONL file'

recur_finding='{"id":"F4","severity":"P1","file":"src/d.ts","line":3,"rule":"Defect","status":"open","summary":"[contract: out] Null guard missing on the write path."}'
rewritten_a='{"id":"R1","severity":"P1","file":"src/order.ts","line":42,"rule":"Defect","status":"open","summary":"Order totals skip the fee."}'
rewritten_b='{"id":"R2","severity":"P1","file":"src/order.ts","line":59,"rule":"Defect","status":"open","summary":"The fee is missing from the calculated total."}'
[[ "$(review_finding_class_key "$rewritten_a")" == "$(review_finding_class_key "$rewritten_b")" ]] || fail 'reworded findings in the same rule, file and 20-line range got different keys'
recur_key="$(review_finding_class_key "$recur_finding")"
[[ "$recur_key" == finding-* ]] || fail 'class key was not derived from the finding location'
rewritten_c='{"id":"R3","severity":"P1","file":"src/order.ts","line":61,"rule":"Defect","status":"open","summary":"The fee is missing from the calculated total."}'
[[ "$(review_finding_class_key "$rewritten_a")" != "$(review_finding_class_key "$rewritten_c")" ]] || fail 'different line ranges shared a class key'
zh_a='{"id":"Z1","severity":"P1","file":"src/a.ts","line":3,"rule":"Defect","status":"open","summary":"空指针：写入路径缺少判空"}'
zh_b='{"id":"Z2","severity":"P1","file":"src/b.ts","line":3,"rule":"Defect","status":"open","summary":"并发写入没有加锁"}'
[[ "$(review_finding_class_key "$zh_a")" == finding-* ]] || fail 'a finding without reviewer class did not get a derived key'
[[ "$(review_finding_class_key "$zh_a")" != "$(review_finding_class_key "$zh_b")" ]] || fail 'findings in different files share one class key'
[[ "$(review_finding_class_key "$zh_a")" == "$(review_finding_class_key "$zh_a")" ]] || fail 'the derived class key is not stable'
mixed_a='{"id":"M1","severity":"P1","file":"src/mixed-a.ts","line":7,"rule":"Defect","status":"open","summary":"写入 null 判空"}'
mixed_b='{"id":"M2","severity":"P1","file":"src/mixed-b.ts","line":7,"rule":"Defect","status":"open","summary":"读取 null 判空"}'
[[ "$(review_finding_class_key "$mixed_a")" == finding-* ]] || fail 'a mixed-language finding did not get a derived class key'
[[ "$(review_finding_class_key "$mixed_a")" != "$(review_finding_class_key "$mixed_b")" ]] || fail 'findings in different files share one class key'
empty_s='{"id":"E1","severity":"P1","file":"src/empty.ts","line":1,"rule":"Defect","status":"open","summary":""}'
[[ "$(review_finding_class_key "$empty_s")" == finding-* ]] || fail 'an empty summary prevented a location-based class key'
[[ "$(review_finding_class_key '{"id":"E2","severity":"P1","rule":"Defect","class":"null-guard","summary":""}')" == null-guard ]] || fail 'a reviewer class was dropped for an empty summary'
recur_findings="[$recur_finding,{\"id\":\"F5\",\"severity\":\"P2\",\"rule\":\"Defect\",\"status\":\"open\",\"summary\":\"Minor naming nit.\"}]"
recur_state="$tmp/recur/state.json"
recur_upsert="$tmp/recur/upsert.sh"
recur_log="$tmp/recur/upsert.log"
mkdir -p "$tmp/recur"
cat >"$recur_upsert" <<EOF
#!/usr/bin/env bash
[[ ! -f "$tmp/recur/fail" ]] || exit 1
printf '%s\n' "\$*" >>"$recur_log"
while (( \$# )); do [[ "\$1" == --body-file ]] && cat "\$2" >>"$recur_log.body"; shift; done
EOF
chmod +x "$recur_upsert"
parsed_class_log="$tmp/recur/parsed-class-upsert.log"
parsed_class_upsert="$tmp/recur/parsed-class-upsert.sh"
cat >"$parsed_class_upsert" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$parsed_class_log"
EOF
chmod +x "$parsed_class_upsert"
write_finding_report() {
  local path="$1" id="$2" file="$3" class_json="$4" finding
  finding="$(jq -cn --arg id "$id" --arg file "$file" --arg class_json "$class_json" '
    {id:$id,severity:"P1",file:$file,line:17,rule:"Defect",status:"open",summary:"Missing a null guard.",introduced_by:"candidate",base_evidence:"The base does not guard null.",rerun_command:("test -f " + $file),rerun_output:"The candidate reaches an unguarded call."}
    + (if $class_json=="-" then {} else {class:($class_json|fromjson)} end)')"
  {
    printf '%s\n' 'VERDICT: NOT_READY' '' '```review-findings'
    jq -cn --argjson finding "$finding" '{findings:[$finding],dispositions:[]}'
    printf '%s\n' '```'
  } >"$path"
}
write_finding_report "$tmp/recur/class-a.md" class-a src/a.ts '"null-guard"'
class_a_report="$(findings_block_of "$tmp/recur/class-a.md")" || fail 'a finding with class did not parse'
[[ "$(jq -r '.findings|length' <<<"$class_a_report")" == 1 && "$(jq -r '.dropped' <<<"$class_a_report")" == 0 ]] \
  || fail 'a class finding did not produce a usable canonical block'
[[ "$(jq -r '.findings[0].class' <<<"$class_a_report")" == null-guard ]] || fail 'the parser dropped the finding class'
review_findings_record_classes "$(jq -c '.findings' <<<"$class_a_report")" "$tmp/recur/class-state.json" "$parsed_class_upsert" class-unit-a \
  || fail 'the parsed class finding did not record'
write_finding_report "$tmp/recur/class-b.md" class-b src/b.ts '"null-guard"'
class_b_report="$(findings_block_of "$tmp/recur/class-b.md")" || fail 'a second finding with class did not parse'
review_findings_record_classes "$(jq -c '.findings' <<<"$class_b_report")" "$tmp/recur/class-state.json" "$parsed_class_upsert" class-unit-b \
  || fail 'the second parsed class finding did not record'
[[ "$(jq -r '."null-guard"' "$tmp/recur/class-state.json")" == 2 ]] || fail 'the parsed class was not counted across units'
[[ "$(grep -c -- '--class review-null-guard' "$parsed_class_log")" == 1 ]] || fail 'the parsed class did not open exactly one rule ticket across files'
write_finding_report "$tmp/recur/class-invalid.md" invalid-class src/invalid.ts '"Bad Class"'
invalid_class_report="$(findings_block_of "$tmp/recur/class-invalid.md")" || fail 'a malformed class made the block fail'
[[ "$(jq -r '.findings[0] | has("class")' <<<"$invalid_class_report")" == false ]] || fail 'a malformed class was not removed'
invalid_class_key="$(review_finding_class_key "$(jq -c '.findings[0]' <<<"$invalid_class_report")")"
[[ "$invalid_class_key" == finding-* ]] || fail 'a malformed class did not fall back to the derived key'
review_findings_record_classes "$(jq -c '.findings' <<<"$invalid_class_report")" "$tmp/recur/class-invalid-state.json" "$parsed_class_upsert" invalid-unit \
  || fail 'a malformed class fallback did not record'
[[ "$(jq -r --arg key "$invalid_class_key" '.[$key]' "$tmp/recur/class-invalid-state.json")" == 1 ]] || fail 'the malformed class fallback was not counted'
write_finding_report "$tmp/recur/class-null.md" null-class src/null.ts null
null_class_report="$(findings_block_of "$tmp/recur/class-null.md")" || fail 'a null class made the block fail'
[[ "$(jq -r '.findings[0] | has("class")' <<<"$null_class_report")" == false ]] || fail 'a null class was not removed'
null_class_key="$(review_finding_class_key "$(jq -c '.findings[0]' <<<"$null_class_report")")"
[[ "$null_class_key" == finding-* ]] || fail 'a null class did not fall back to the derived key'
review_findings_record_classes "$(jq -c '.findings' <<<"$null_class_report")" "$tmp/recur/class-null-state.json" "$parsed_class_upsert" null-unit \
  || fail 'a null class fallback did not record'
[[ "$(jq -r --arg key "$null_class_key" '.[$key]' "$tmp/recur/class-null-state.json")" == 1 ]] || fail 'the null class fallback was not counted'
write_finding_report "$tmp/recur/classless.md" classless src/classless.ts -
classless_report="$(findings_block_of "$tmp/recur/classless.md")" || fail 'a finding without class did not parse'
[[ "$(jq -r '.findings[0] | has("class")' <<<"$classless_report")" == false ]] || fail 'a finding without class gained one during normalization'
classless_key="$(review_finding_class_key "$(jq -c '.findings[0]' <<<"$classless_report")")"
[[ "$classless_key" == finding-* ]] || fail 'a finding without class did not get the derived key'
review_findings_record_classes "$(jq -c '.findings' <<<"$classless_report")" "$tmp/recur/classless-state.json" "$parsed_class_upsert" classless-unit \
  || fail 'a finding without class did not record'
[[ "$(jq -r --arg key "$classless_key" '.[$key]' "$tmp/recur/classless-state.json")" == 1 ]] || fail 'the finding without class was not counted'
review_findings_record_classes "$recur_findings" "$recur_state" "$recur_upsert" unit-a || fail 'first sighting failed'
[[ ! -s "$recur_log" ]] || fail 'a first sighting opened a rule ticket'
[[ "$(jq -r --arg key "$recur_key" '.[$key]' "$recur_state")" == 1 ]] || fail 'first sighting was not counted'
review_findings_record_classes "$recur_findings" "$recur_state" "$recur_upsert" unit-b || fail 'second sighting failed'
[[ "$(wc -l <"$recur_log")" == 1 ]] || fail 'second sighting did not open exactly one rule ticket'
grep -q -- "--class review-$recur_key" "$recur_log" || fail 'rule ticket class was not the repeated class'
review_findings_record_classes "$recur_findings" "$recur_state" "$recur_upsert" unit-c || fail 'third sighting failed'
[[ "$(grep -c -- "--class review-$recur_key" "$recur_log")" == 2 ]] || fail 'a third sighting did not add to the existing ticket'
[[ "$(jq -r --arg key "$recur_key" '.[$key]' "$recur_state")" == 3 ]] || fail 'third sighting was not counted'
[[ "$(jq -r 'keys|length' "$recur_state")" == 1 ]] || fail 'a non-blocking finding was counted'
touch "$tmp/recur/fail"
review_findings_record_classes "$recur_findings" "$tmp/recur/fresh.json" "$recur_upsert" unit-d || fail 'first sighting of the fresh state failed'
if review_findings_record_classes "$recur_findings" "$tmp/recur/fresh.json" "$recur_upsert" unit-e; then fail 'a failed rule ticket write reported success'; fi
[[ "$(jq -r --arg key "$recur_key" '.[$key]' "$tmp/recur/fresh.json")" == 1 ]] || fail 'a failed rule ticket write was counted'
rm -f "$tmp/recur/fail"
review_findings_record_classes "$recur_findings" "$tmp/recur/fresh.json" "$recur_upsert" unit-f || fail 'retry after a failed write did not open the ticket'
[[ "$(wc -l <"$recur_log")" == 3 ]] || fail 'retry after a failed write did not open exactly one ticket'
grep -q unit-a "$recur_log.body" && grep -q unit-b "$recur_log.body" && grep -qi deterministic "$recur_log.body" && grep -qi lint "$recur_log.body" \
  || fail 'ticket body lacks both findings or the deterministic-check ask'

review_findings_record_classes "[$zh_a,$zh_b]" "$tmp/recur/zh.json" "$recur_upsert" unit-g || fail 'Chinese-only findings did not record'
[[ "$(jq -r 'keys|length' "$tmp/recur/zh.json")" == 2 ]] || fail 'distinct Chinese-only findings were counted as one class'
empty_key="$(review_finding_class_key "$empty_s")"
review_findings_record_classes "[$empty_s,$empty_s]" "$tmp/recur/empty.json" "$recur_upsert" unit-h || fail 'empty-summary findings failed to record'
[[ "$(jq -r --arg key "$empty_key" '.[$key]' "$tmp/recur/empty.json")" == 1 ]] || fail 'an empty summary prevented a location-based class from being counted'
review_findings_record_classes "[$mixed_a,$mixed_b]" "$tmp/recur/mixed.json" "$recur_upsert" unit-i || fail 'mixed-language findings failed to record'
[[ "$(jq -r 'keys|length' "$tmp/recur/mixed.json")" == 2 ]] || fail 'distinct mixed-language findings were counted as one class'

dup_state="$tmp/recur/dup.json"
review_findings_record_classes "$recur_findings" "$dup_state" "$recur_upsert" unit-a || fail 'a unit recorded twice failed'
review_findings_record_classes "$recur_findings" "$dup_state" "$recur_upsert" unit-a || fail 'a rereview of one unit failed'
[[ "$(jq -r --arg key "$recur_key" '.[$key]' "$dup_state")" == 1 ]] || fail 'a rereview of one unit was counted twice'

scale_prompt="$script_dir/../prompts/review-contract.md"
scale_section="$(awk '/^## Scale checklist$/ { inside=1 } inside && /^## / && $0 != "## Scale checklist" { exit } inside { print }' "$scale_prompt")"
[[ -n "$scale_section" ]] || fail 'review prompt lacks the scale checklist'
[[ "$(awk 'END { print NR }' <<<"$scale_section")" -le 12 ]] || fail 'scale checklist exceeds 12 lines'
[[ "$(grep -cE '^- .*\? \(P[0-9]' <<<"$scale_section")" == 7 ]] || fail 'scale checklist must have seven questions naming design principles'
grep -Fq 'docs/design/AGENT-SCALE-PRINCIPLES.md' <<<"$scale_section" || fail 'scale checklist does not link the design principles'
for n in 1 2 4 5 6 7 8 9 13; do
  grep -qE "[(, ]P$n[),]" <<<"$scale_section" || fail "scale checklist lacks design principle P$n"
done
grep -Fq 'unbounded cost is a finding; name the principle' <<<"$scale_section" \
  || fail 'scale checklist does not require a finding to name the principle'

scale_prompt="$script_dir/../prompts/review-contract.md"
scale_section="$(awk '/^## Scale checklist$/ { inside=1 } inside && /^## / && $0 != "## Scale checklist" { exit } inside { print }' "$scale_prompt")"
[[ -n "$scale_section" ]] || fail 'review prompt lacks the scale checklist'
[[ "$(awk 'END { print NR }' <<<"$scale_section")" -le 12 ]] || fail 'scale checklist exceeds 12 lines'
[[ "$(grep -cE '^- .*\? \(P[0-9]' <<<"$scale_section")" == 7 ]] || fail 'scale checklist must have seven questions naming design principles'
grep -Fq 'docs/design/AGENT-SCALE-PRINCIPLES.md' <<<"$scale_section" || fail 'scale checklist does not link the design principles'
for n in 1 2 4 5 6 7 8 9 13; do
  grep -qE "[(, ]P$n[),]" <<<"$scale_section" || fail "scale checklist lacks design principle P$n"
done
grep -Fq 'unbounded cost is a finding; name the principle' <<<"$scale_section" \
  || fail 'scale checklist does not require a finding to name the principle'

prompt_version='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
cat >"$tmp/versioned-review.md" <<'EOF'
```review-findings
{"findings":[],"dispositions":[]}
```
EOF
worker="$(jq -cn --arg version "$prompt_version" '{type:"review",report:"review-report.md",prompt:"engine/prompts/review-contract.md",prompt_version:$version}')"
update="$(review_findings_update "$tmp/versioned-review.md" review-report.md "$worker")"
unit="$(jq -c ". $update" <<<'{"history":[{"stage":"review-request-changes"}],"review_findings":[]}')"
jq -e --arg version "$prompt_version" '.review_findings[-1].prompt == "engine/prompts/review-contract.md" and
  .review_findings[-1].prompt_version == $version' <<<"$unit" >/dev/null \
  || fail 'review prompt version was not persisted with its finding record'
override_update="$(review_findings_update "$tmp/versioned-review.md" engine-override-gate.md "$worker")"
override_unit="$(jq -c ". $override_update" <<<'{"history":[{"stage":"review-request-changes"}],"review_findings":[]}')"
jq -e '(.review_findings[-1] | has("prompt_version") | not) and
  (.review_findings[-1] | has("prompt") | not)' <<<"$override_unit" >/dev/null \
  || fail 'synthetic engine-override findings inherited the reviewer prompt version'
cat >"$tmp/versioned-disposition.md" <<'EOF'
```review-findings
{"findings":[],"dispositions":[]}
```
EOF
disposition_update="$(review_dispositions_update "$tmp/versioned-disposition.md" "$unit")"
unit="$(jq -c ". $disposition_update" <<<"$unit")"
jq -e --arg version "$prompt_version" '.review_findings[-1].disposition_block == "ok" and
  .review_findings[-1].prompt_version == $version' <<<"$unit" >/dev/null \
  || fail 'review prompt version was lost when dispositions were recorded'

implement_worker="$(jq -cn --arg version "$prompt_version" '{type:"implement",prompt:"engine/mac-autopilot/scheduler.d/dispatch-queue.sh",prompt_stage:"implement",prompt_version:$version}')"
failed_prompt_update="$(unit_prompt_update '{"stage":"implement-pending","prompt":"engine/prompts/triage.md"}' "$implement_worker")"
failed_prompt_unit="$(jq -c "$failed_prompt_update" <<<'{"stage":"implement-pending","prompt":"engine/prompts/triage.md"}')"
jq -e '(.prompt == "engine/prompts/triage.md") and (has("prompt_version") | not)' <<<"$failed_prompt_unit" >/dev/null \
  || fail 'failed implementation attempt claimed the unit prompt identity'
prompt_update="$(unit_prompt_update '{"stage":"review-pending","prompt":"engine/prompts/triage.md"}' "$implement_worker")"
prompt_unit="$(jq -c "$prompt_update" <<<'{"stage":"review-pending","prompt":"engine/prompts/triage.md"}')"
jq -e --arg version "$prompt_version" '.prompt == "engine/mac-autopilot/scheduler.d/dispatch-queue.sh" and .prompt_stage == "implement" and .prompt_version == $version' \
  <<<"$prompt_unit" >/dev/null || fail 'implementation prompt attribution did not replace the initial triage prompt'
review_worker="$(jq -cn --arg version "$prompt_version" '{type:"review",prompt:"engine/prompts/review-contract.md",prompt_version:$version}')"
preserve_update="$(unit_prompt_update "$prompt_unit" "$review_worker")"
preserved_unit="$(jq -c "$preserve_update" <<<"$prompt_unit")"
jq -e --arg version "$prompt_version" '.prompt == "engine/mac-autopilot/scheduler.d/dispatch-queue.sh" and .prompt_stage == "implement" and .prompt_version == $version' \
  <<<"$preserved_unit" >/dev/null || fail 'review attribution replaced the code prompt used for unit scoring'
repair_worker="$(jq -cn --arg version "$prompt_version" '{type:"repair",prompt:"engine/mac-autopilot/scheduler.d/dispatch-queue.sh",prompt_stage:"repair",prompt_version:$version}')"
repair_update="$(unit_prompt_update "$prompt_unit" "$repair_worker")"
repaired_unit="$(jq -c "$repair_update" <<<"$prompt_unit")"
jq -e --arg version "$prompt_version" '.prompt == "engine/mac-autopilot/scheduler.d/dispatch-queue.sh" and .prompt_stage == "implement" and .prompt_version == $version' \
  <<<"$repaired_unit" >/dev/null || fail 'repair prompt replaced the initial implementation prompt used for unit scoring'

# Review prompt ownership and scheduler wiring are exercised by scheduler-gates.test.sh.

echo 'review-contract.test.sh: PASS'
