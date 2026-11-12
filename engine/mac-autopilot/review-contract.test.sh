#!/usr/bin/env bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/review-contract.sh"
source "$script_dir/scheduler.d/reports.sh"
source "$script_dir/../night/owner-report-render.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() { echo "review-contract.test.sh: $*" >&2; exit 1; }

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
review_decision_log_flags_append "$tmp/review.md" issue-876 || fail 'decision-log flags did not append'
[[ "$(jq -r '[.entry,.reason,.unit,.at] | join("|")' "$SUP/decision-log-flags.jsonl")" == \
  'Tried cache-first; verification covered only the mock.|The report has no live-path verification.|issue-876|2026-11-10T23:30:00Z' ]] \
  || fail 'the marked entry did not reach the supervisor JSONL file'
daily_html="$(maintainer_health_mail_build_html '{}' 'plain report' "$AGENT_HOME")"
daily_html="$(jq -r '.html' <<<"$daily_html")"
[[ "$daily_html" == *'决策日志复核（1 条）'* && "$daily_html" == *'Tried cache-first; verification covered only the mock.'* ]] \
  || fail 'the marked entry did not reach the daily report that reads the supervisor JSONL file'

recur_finding='{"id":"F4","severity":"P1","file":"src/d.ts","line":3,"rule":"Defect","status":"open","summary":"[contract: out] Null guard missing on the write path."}'
[[ "$(review_finding_class_key "$recur_finding")" == defect-null-guard-missing-on-the-write ]] || fail 'class key was not derived from the rule and summary words'
zh_a='{"id":"Z1","severity":"P1","rule":"Defect","status":"open","summary":"空指针：写入路径缺少判空"}'
zh_b='{"id":"Z2","severity":"P1","rule":"Defect","status":"open","summary":"并发写入没有加锁"}'
[[ "$(review_finding_class_key "$zh_a")" == finding-* ]] || fail 'a Chinese-only summary did not get a hashed class key'
[[ "$(review_finding_class_key "$zh_a")" != "$(review_finding_class_key "$zh_b")" ]] || fail 'two Chinese-only findings share one class key'
[[ "$(review_finding_class_key "$zh_a")" == "$(review_finding_class_key "$zh_a")" ]] || fail 'the hashed class key is not stable'
recur_findings="[$recur_finding,{\"id\":\"F5\",\"severity\":\"P2\",\"rule\":\"Defect\",\"status\":\"open\",\"summary\":\"Minor naming nit.\"}]"
recur_state="$tmp/recur/state.json"
recur_upsert="$tmp/recur/upsert.sh"
recur_log="$tmp/recur/upsert.log"
mkdir -p "$tmp/recur"
cat >"$recur_upsert" <<EOF
#!/usr/bin/env bash
[[ ! -f "$tmp/recur/fail" ]] || exit 1
printf '%s\n' "\$*" >>"$recur_log"
EOF
chmod +x "$recur_upsert"
review_findings_record_classes "$recur_findings" "$recur_state" "$recur_upsert" unit-a || fail 'first sighting failed'
[[ ! -s "$recur_log" ]] || fail 'a first sighting opened a rule ticket'
[[ "$(jq -r '.["defect-null-guard-missing-on-the-write"]' "$recur_state")" == 1 ]] || fail 'first sighting was not counted'
review_findings_record_classes "$recur_findings" "$recur_state" "$recur_upsert" unit-b || fail 'second sighting failed'
[[ "$(wc -l <"$recur_log")" == 1 ]] || fail 'second sighting did not open exactly one rule ticket'
grep -q -- '--class review-defect-null-guard-missing-on-the-write' "$recur_log" || fail 'rule ticket class was not the repeated class'
review_findings_record_classes "$recur_findings" "$recur_state" "$recur_upsert" unit-c || fail 'third sighting failed'
[[ "$(wc -l <"$recur_log")" == 1 ]] || fail 'a third sighting opened another rule ticket'
[[ "$(jq -r '.["defect-null-guard-missing-on-the-write"]' "$recur_state")" == 3 ]] || fail 'third sighting was not counted'
[[ "$(jq -r 'keys|length' "$recur_state")" == 1 ]] || fail 'a non-blocking finding was counted'
touch "$tmp/recur/fail"
review_findings_record_classes "$recur_findings" "$tmp/recur/fresh.json" "$recur_upsert" unit-d || fail 'first sighting of the fresh state failed'
if review_findings_record_classes "$recur_findings" "$tmp/recur/fresh.json" "$recur_upsert" unit-e; then fail 'a failed rule ticket write reported success'; fi
[[ "$(jq -r '.["defect-null-guard-missing-on-the-write"]' "$tmp/recur/fresh.json")" == 1 ]] || fail 'a failed rule ticket write was counted'
rm -f "$tmp/recur/fail"
review_findings_record_classes "$recur_findings" "$tmp/recur/fresh.json" "$recur_upsert" unit-f || fail 'retry after a failed write did not open the ticket'
[[ "$(wc -l <"$recur_log")" == 2 ]] || fail 'retry after a failed write did not open exactly one ticket'

review_findings_record_classes "[$zh_a,$zh_b]" "$tmp/recur/zh.json" "$recur_upsert" unit-g || fail 'Chinese-only findings did not record'
[[ "$(jq -r 'keys|length' "$tmp/recur/zh.json")" == 2 ]] || fail 'distinct Chinese-only findings were counted as one class'

# Review prompt ownership and scheduler wiring are exercised by scheduler-gates.test.sh.

echo 'review-contract.test.sh: PASS'
