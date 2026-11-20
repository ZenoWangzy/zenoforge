#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-scheduler-gates-fixture.sh"

fail() { printf 'repair-report-carry.test.sh: %s\n' "$*" >&2; exit 1; }

cat > "$sup/impl-375-original.md" <<'REPORT'
## decision-log
The original incident report is retained for the repair.

## root-cause
Prior root cause: the dispatch path omitted report context.

## recurrence-guard
kind: test
Prior recurrence guard: assert the repair prompt keeps report sections.

## prior-art
Source: https://example.invalid/repair-report-carry
REPORT
printf 'VERDICT: REQUEST-CHANGES\nRepair this finding.\n' > "$sup/review-375.md"

unit='{"labels":["bug"],"implementation_report":"impl-375-original.md","history":[{"stage":"review-request-changes"}]}'
repair_prompt="$(repair_failure_prompt "$unit" review-375.md)" \
  || fail 'repair prompt rejected an incident unit with a readable prior report'

for section in root-cause recurrence-guard prior-art; do
  [[ "$repair_prompt" == *"## $section"* ]] || fail "repair prompt dropped ## $section"
done
for detail in \
  'Prior root cause: the dispatch path omitted report context.' \
  'Prior recurrence guard: assert the repair prompt keeps report sections.' \
  'https://example.invalid/repair-report-carry'; do
  [[ "$repair_prompt" == *"$detail"* ]] || fail "repair prompt dropped prior report content: $detail"
done

cat > "$sup/review-ordinary.md" <<'REPORT'
VERDICT: REQUEST-CHANGES
Repair this finding.

```review-findings
{"findings":[{"id":"F1","severity":"P1","file":"src/a.ts","line":1,"rule":"Defect","status":"open","summary":"The first value is not checked.","introduced_by":"candidate","base_evidence":"The base has no check.","rerun_command":"npm test","rerun_output":"FAIL"},{"id":"F2","severity":"P1","file":"src/b.ts","line":2,"rule":"Spec","status":"open","summary":"The second result is omitted.","introduced_by":"candidate","base_evidence":"The base returns the result.","rerun_command":"npm test","rerun_output":"FAIL"}],"dispositions":[]}
```
REPORT
ordinary_unit='{"labels":["feature"],"history":[{"stage":"review-request-changes"}],"review_findings":[{"block":"ok","disposition_block":"ok","dispositions":[{"id":"F1","disposition":"fixed","reason":"The first value is now checked."},{"id":"F2","disposition":"intentional","reason":"The issue requires the second result."}]}]}'
ordinary_prompt="$(repair_failure_prompt "$ordinary_unit" review-ordinary.md)" \
  || fail 'repair prompt rejected a non-incident unit with a readable prior review report'
for detail in \
  'F1: The first value is not checked.' \
  'F2: The second result is omitted.' \
  'Author dispositions from unit history' \
  'F1: fixed — The first value is now checked.' \
  'F2: intentional — The issue requires the second result.' \
  'Repair this finding.'; do
  [[ "$ordinary_prompt" == *"$detail"* ]] || fail "ordinary repair prompt dropped prior review context or failure evidence: $detail"
done

no_report_unit='{"labels":["feature"],"repair_hint":"repair context hint","history":[{"stage":"supervisor-requeue"}]}'
no_report_prompt="$(repair_failure_prompt "$no_report_unit" '')" \
  || fail 'repair without a prior report was rejected despite its repair hint'
[[ "$no_report_prompt" == 'repair context hint' ]] || fail "repair without a prior report changed: $no_report_prompt"

echo 'repair-report-carry.test.sh: ok'
