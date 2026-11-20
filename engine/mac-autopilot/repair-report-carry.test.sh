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

echo 'repair-report-carry.test.sh: ok'
