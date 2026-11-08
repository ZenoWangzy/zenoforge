#!/usr/bin/env bash
# Focused guard: a review dispatch copies the unit's implementation report and latest self-check log into the review clone,
# names only those copies in the prompt, and leaves git status clean. Read-only Claude reviewers cannot read under $SUP,
# so their inputs came back INPUT_INCOMPLETE (2026-11-08).
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

repo_root="$MAC_AUTOPILOT_ENV_ROOT"
source "$repo_root/engine/mac-autopilot/scheduler.d/review-rules.sh"
jqf() { command jq "$@"; }
review_contract_rule() { :; } # defined in evals-arbiter.sh; not under test here
risk_class_safety_rule() { :; } # needs the scheduler's HERE; not under test here

fail() { printf 'review-inputs-copy.test.sh: %s\n' "$*" >&2; exit 1; }

SUP="$test_env_root/sup"
mkdir -p "$SUP"
printf '## root-cause\nfixture report body\n' > "$SUP/impl-42-fixture.md"
printf 'self-check fixture output\n' > "$SUP/self-check-fixture.log"
wt="$test_env_root/review-clone"
git init -q "$wt"
printf 'tracked\n' > "$wt/tracked.txt"
git -C "$wt" add tracked.txt
git -C "$wt" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm fixture

# The unit fields as the scheduler stores them: a SUP-relative report path and an absolute self-check log path.
u="$(jq -cn --arg rep impl-42-fixture.md --arg log "$SUP/self-check-fixture.log" '{id:"pr-42",implementation_report:$rep,self_check_output:$log}')"
sha=1111111111111111111111111111111111111111

# Same shape as the dispatch call sites: review_prompt, then review_inputs_rule.
dispatch_prompt() {
  printf '%s' "$(review_prompt 42 fixture "$sha" review-42.md direct-main "$wt")$(review_inputs_rule "$u" "$wt")"
}
first="$(dispatch_prompt)"
second="$(dispatch_prompt)"

copied_report="$wt/.zf-review-inputs/implementation-report.md"
copied_log="$wt/.zf-review-inputs/self-check.log"
cmp -s "$copied_report" "$SUP/impl-42-fixture.md" || fail "implementation report not copied to $copied_report"
cmp -s "$copied_log" "$SUP/self-check-fixture.log" || fail "self-check log not copied to $copied_log"
[[ "$second" == *"$copied_report"* && "$second" == *"$copied_log"* ]] || fail "prompt does not name the copied input paths"
[[ "$first" == *"$copied_report"* ]] || fail "first dispatch prompt does not name the copied report"
[[ "$second" != *"$SUP/impl-42-fixture.md"* && "$second" != *"$SUP/self-check-fixture.log"* ]] \
  || fail "prompt still names a \$SUP path for an input"
[[ "$second" != *"impl-42-fixture.md"* ]] || fail "prompt still names the SUP-relative report path"

[[ -z "$(git -C "$wt" status --porcelain)" ]] || fail "git status is not empty: $(git -C "$wt" status --porcelain)"

ex="$wt/$(git -C "$wt" rev-parse --git-path info/exclude)"
count="$(grep -cxF '/.zf-review-inputs/' "$ex" || true)"
[[ "$count" == 1 ]] || fail "info/exclude holds $count /.zf-review-inputs/ lines after two dispatches, expected 1"

printf 'ok - review inputs copied, named, and git-ignored\n'
