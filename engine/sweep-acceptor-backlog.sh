#!/usr/bin/env bash
# sweep-acceptor-backlog.sh: a repeatable, committed sweep for issues whose
# fix already merged BEFORE the `acceptor` field and the unconditional-
# close-on-completion rule (2026-09-15, "the acceptance loop" --
# docs/agents/issue-pipeline.md) existed. Those tickets merged under the
# OLD rule (never closes on merge) and have sat open ever since, looking
# exactly like unstarted work -- the maintainer's own complaint. This sweep is
# the one-time catch-up, written as a script (not a hand-run one-off)
# because it needs to be repeatable, reviewable, and safe to run again if
# the manifest below ever grows.
#
# The manifest below (issue number -> acceptor) is NOT computed by this
# script. Per the maintainer's own instruction ("Classify by reading each
# issue, not by pattern-matching its title"), each entry was read in full
# (title, body, acceptance criteria) by a human/agent and hand-classified;
# this script only ever performs the mechanical part (record, comment,
# close) and is safe to re-run -- it never re-derives a classification on
# its own. Extend the manifest by reading a new issue and adding a line,
# the same way sweep-parked-backlog.sh's own criterion is a fixed rule, not
# something this script infers.
#
# Classification notes (2026-09-15 read-through):
#   - #1226, #1227: pure regression-suite/test-file hardening -- the fix
#     changes nothing about what a running service actually does, only
#     what watches/tests it (CI's own coverage gap, and hardening on the
#     test file added for it). acceptor=none: a passing test already IS
#     the proof, nobody is watching for a behavior change that doesn't
#     exist.
#   - #1235, #1214, #1180, #1178, #1175, #1172, #1179: real, observable
#     production/runtime behavior changes (a new read query, a security
#     default, a broken confirmation flow now fixed, an audit gap closed,
#     ...) with no named external reporter -- all filed from the maintainer's
#     own GitHub account (this repo's only account; see CLAUDE.md), several
#     explicitly split from his own parent tickets via /to-tickets.
#     acceptor=maintainer: no closing email (his own ruling -- he already
#     knows), but still recorded, not left as `none`, since a future
#     reader should be able to tell "nobody is watching" apart from
#     "the maintainer is, he just doesn't need an email about it."
#   - #1221 is DELIBERATELY NOT in this manifest: verified 2026-09-15 that,
#     unlike the other nine, it has NOT actually merged -- four implement
#     attempts failed on an unrelated flaky assertion (tracked separately
#     as #1259) and it is genuinely still in flight (concluded/not-
#     completed, not merged). Sweeping it would be a false close. If a real
#     fix for #1221 lands later, it goes through the normal conclude_run()
#     path, not this sweep.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

declare -A BACKLOG_ACCEPTOR=(
  [1226]="none"
  [1227]="none"
  [1235]="maintainer"
  [1214]="maintainer"
  [1180]="maintainer"
  [1178]="maintainer"
  [1175]="maintainer"
  [1172]="maintainer"
  [1179]="maintainer"
)

ensure_state_labels

closed=0
skipped_not_merged=0
skipped_already_closed=0
skipped_on_hold=0

for n in $(printf '%s\n' "${!BACKLOG_ACCEPTOR[@]}" | sort -n); do
  acceptor="${BACKLOG_ACCEPTOR[$n]}"

  if is_on_hold "$n"; then
    echo "sweep-acceptor-backlog: #$n -- on-hold, leaving untouched" >&2
    skipped_on_hold=$((skipped_on_hold + 1))
    continue
  fi

  issue_state="$(gh issue view "$n" --repo "$REPO" --json state -q '.state' 2>/dev/null || echo "")"
  if [ "$issue_state" = "CLOSED" ]; then
    echo "sweep-acceptor-backlog: #$n -- already closed, idempotent no-op" >&2
    skipped_already_closed=$((skipped_already_closed + 1))
    continue
  fi

  # Belt and braces against the manifest itself being wrong (the #1221
  # lesson above): never close on the manifest's say-so alone -- confirm a
  # real merged agent/issue-$n PR exists first, the same search
  # issue-pipeline.sh's own release candidate-selection already trusts.
  merged_pr="$(gh pr list --repo "$REPO" --state merged --search "head:agent/issue-$n" --json number -q '.[0].number // empty' 2>/dev/null || echo "")"
  if [ -z "$merged_pr" ]; then
    echo "sweep-acceptor-backlog: #$n -- no merged agent/issue-$n PR found; NOT closing (do not guess a merge that may not exist -- see #1221 in this script's own header)" >&2
    skipped_not_merged=$((skipped_not_merged + 1))
    continue
  fi

  state_merge "$n" ". + $(jq -n --arg a "$acceptor" '{acceptor: $a}')"

  web_advisor_provider_clear_job_state "$n" || exit 1
  guarded_write gh issue comment "$n" --repo "$REPO" --body "$BOT_DISCLAIMER
这张票的修复已经合并（#${merged_pr}），是在「完成即关闭，不等确认」这条规则生效之前处理完的，属于历史积压。按现在的规则补齐分类（acceptor=${acceptor}）并关闭。如果验证下来还是不对，重新打开这张 issue 就行，机器人会当成新的一轮重新处理。"
  guarded_write gh issue close "$n" --repo "$REPO"
  state_merge "$n" '.closed_by_pipeline = true | del(.web_advisor_provider_job_id, .web_advisor_provider_job_started_at, .web_advisor_provider_job_episode_seq)'
  closed=$((closed + 1))

done

echo "sweep-acceptor-backlog: done -- closed=$closed skipped(not merged)=$skipped_not_merged skipped(already closed)=$skipped_already_closed skipped(on-hold)=$skipped_on_hold" >&2
