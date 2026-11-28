#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/test-scheduler-gates-fixture.sh"
source "$SCHEDULER_AGENT_LIB"

fail() { echo "supervisor-needs-info.test.sh: $*" >&2; exit 1; }
NEEDS_INFO_COMMENT_BODY=""
gh() {
  if [[ "$1 $2" == 'issue comment' ]]; then NEEDS_INFO_COMMENT_BODY="${5:-}"; fi
  return 0
}
scheduler_issue_transition_allowed() { return 0; }
scheduler_issue_transition() { return 0; }
printf '%s\n' '{"units":[{"id":"issue-1727","issue":1727,"stage":"supervisor-review","history":[]}]}' > "$UNITS"
supervisor_needs_info issue-1727 'What contract version is required?' 'arbiter found a missing requirement'
comment_is_bot "$NEEDS_INFO_COMMENT_BODY" || fail 'supervisor question was not posted with the bot disclaimer'
[[ "${NEEDS_INFO_COMMENT_BODY#"$BOT_DISCLAIMER"$'\n'}" == '工厂 supervisor 需要澄清：What contract version is required?' ]] \
  || fail 'supervisor question text changed beyond the bot disclaimer prefix'
echo 'ok - supervisor needs-info question is posted as a bot comment'
