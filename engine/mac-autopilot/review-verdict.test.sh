#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/test-scheduler-gates-fixture.sh"

fail() { echo "review-verdict.test.sh: $*" >&2; exit 1; }
units() { printf '%s\n' "$1" > "$UNITS"; echo '{"workers":[]}' > "$WORKERS"; }
field() { jq -r --arg id "$1" ".units[] | select(.id==\$id) | $2" "$UNITS"; }
r="$fixture/review-verdict.md"

# Redacted from the 2026-11-03/04 reports: bold verdicts with same-line explanations.
printf '# Review report\n\n**VERDICT: READY** (no candidate P0/P1 blockers)\n' > "$r"
[[ "$(verdict_of "$r")" == READY ]] || fail 'bold verdict with a trailing remark was not parsed'
printf '**VERDICT: NOT_READY** — 3 candidate P1 blockers\n' > "$r"
[[ "$(verdict_of "$r")" == NOT_READY ]] || fail 'bold not-ready verdict with a trailing remark was not parsed'

# Normalization covers case, punctuation and code fences around an otherwise clear verdict.
printf 'verdict: ready.\n' > "$r"
[[ "$(verdict_of "$r")" == READY ]] || fail 'lowercase verdict with trailing punctuation was not normalized'
printf '```text\nVERDICT: BLOCK.\n```\n' > "$r"
[[ "$(verdict_of "$r")" == INPUT_INCOMPLETE ]] || fail 'fenced verdict with trailing punctuation was not parsed'

# Redacted translated labels and recovered final-message shapes.
printf '## 结论：VERDICT: READY\n' > "$r"
[[ "$(verdict_of "$r")" == READY ]] || fail 'verdict after a translated label heading was not parsed'
printf '**结论：VERDICT: READY** (no candidate blockers)\n' > "$r"
[[ "$(verdict_of "$r")" == READY ]] || fail 'verdict after a translated bold label was not parsed'
printf '# 结论\n\n**结论：`VERDICT: READY`** — note\n' > "$r"
[[ "$(verdict_of "$r")" == READY ]] || fail 'inline-code verdict behind a translated label was not parsed'
printf 'Review complete; report saved, verdict **VERDICT: READY**.\n' > "$r"
[[ "$(verdict_of "$r")" == READY ]] || fail 'mid-line verdict in a recovered final message was not parsed'
printf '## verdict\nnot_ready\n' > "$r"
[[ "$(verdict_of "$r")" == NOT_READY ]] || fail 'lowercase verdict heading and value were not normalized'

# A second distinct value remains ambiguous, even when the findings block would imply NOT_READY.
ambiguity_block='{"findings":[{"id":"F1","severity":"P1","file":"src/a.ts","line":42,"rule":"Defect","status":"open","summary":"x","introduced_by":"candidate","base_evidence":"absent in base","rerun_command":"pnpm test","rerun_output":"FAIL"}],"dispositions":[]}'
{ printf '**结论：VERDICT: READY** (if blocked, change to NOT_READY)\n\n```review-findings\n%s\n```\n' "$ambiguity_block"; } > "$r"
[[ -z "$(verdict_of "$r" || true)" ]] || fail 'two different values on the verdict line were not treated as ambiguous'

# A missing verdict receives one format-only retry that names the prior report; a repeat escalates.
alive() { [[ " ${ALIVE_PIDS:-} " == *" $1 "* ]]; }
tick_prs_changed() { :; }
tick_prs_prime() { :; }
H1=1111111111111111111111111111111111111111
units '{"units":[{"id":"pr-abstain","pr":7,"stage":"review","history":[]}]}'
cat > "$sup/review-abstain-T1.md" <<'REPORT'
# Incremental review incomplete

No verdict was produced because the required read-only review input was unavailable.
REPORT
jq -n --arg sha "$H1" '{workers:[{pid:4244,unit:"pr-abstain",type:"review",log:"x.log",report:"review-abstain-T1.md",sha:$sha}]}' > "$WORKERS"
harvest_workers || :
[[ "$(field pr-abstain .stage)" == review-pending \
  && "$(field pr-abstain '.history[-1].stage')" == verdict-missing \
  && "$(field pr-abstain .review_report)" == review-abstain-T1.md ]] \
  || fail 'a missing verdict did not receive exactly one retry'
verdict_reask="$(verdict_reask_rule "$(jq -c --arg id pr-abstain '.units[] | select(.id==$id)' "$UNITS")")"
[[ "$verdict_reask" == *review-abstain-T1.md* && "$verdict_reask" == *"$REVIEW_CONTRACT_MD"* \
  && "$verdict_reask" == *'不重新评审'* && "$verdict_reask" == *VERDICT* ]] \
  || fail 'format-only retry omitted the previous report or contract instruction'

units '{"units":[{"id":"pr-abstain","pr":7,"stage":"review","history":[{"stage":"verdict-missing"}]}]}'
jq -n --arg sha "$H1" '{workers:[{pid:4244,unit:"pr-abstain",type:"review",log:"x.log",report:"review-abstain-T1.md",sha:$sha}]}' > "$WORKERS"
harvest_workers || :
[[ "$(field pr-abstain .stage)" == supervisor-review ]] || fail 'a second missing verdict did not escalate'
echo 'review-verdict.test.sh: PASS (parse, ambiguity, format-only retry, second-failure escalation)'
