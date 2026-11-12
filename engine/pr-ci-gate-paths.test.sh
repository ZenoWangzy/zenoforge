#!/usr/bin/env bash
# Keeps the PR CI gate in step: the gate regex in tools/merge-pr.sh (merge_pr_gate_ci_ok) and the
# pull_request paths of engine-tests.yml and cli-tests.yml must agree, and both must keep push-to-main.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
fail() { echo "pr-ci-gate-paths.test.sh: $*" >&2; exit 1; }

# Gate regex straight from merge-pr.sh; jq's "\\." is ERE "\.".
raw="$(grep -oE 'test\("\^\([^"]*\)\$"\)' "$root/tools/merge-pr.sh" | head -1)"
[[ -n "$raw" ]] || fail "no gate regex found in tools/merge-pr.sh"
raw="${raw#*\"}"; raw="${raw%\"*}"
regex="$(sed 's/\\\\/\\/g' <<<"$raw")"

# Every gate file, written out. A new alternative in the regex needs a line here too.
gate_files=(
  tools/merge-pr.sh tools/pin-vecta.sh tools/auto-pin.sh
  engine/eval/some-eval.sh
  engine/mac-autopilot/bell.sh engine/mac-autopilot/bell-loop.sh engine/mac-autopilot/pin-lag.sh
  engine/lib.d/main-red.sh engine/lib.d/main-red-bisect.sh
  engine/deploy-culprit.sh engine/worktree-lifecycle.sh engine/mac-autopilot/rescued_gc.sh
  engine/mac-autopilot/scheduler.d/cleanup.sh engine/mac-autopilot/scheduler.d/units.sh
  engine/mac-autopilot/scheduler.d/review-rules.sh
  engine/prompts/review-contract.md engine/notify.sh engine/ts-judge.sh engine/redact-secrets.sh
  engine/night/authorization-readonly.sh engine/night/production-tenant-marker-readonly.sh
  engine/night/node-health-rules.sh engine/night/maintainer-health-mail.sh
  engine/night/acceptance-login-probe.mjs
  engine/systemd/zenoforge-agent.service engine/systemd/zenoforge-daily-perf-report.service
  engine/systemd/zenoforge-health-mail.service engine/systemd/zenoforge-health-maintenance.service
  engine/systemd/zenoforge-label-churn.service engine/systemd/zenoforge-memory-check.service
  engine/systemd/zenoforge-owner-report-causes.service engine/systemd/zenoforge-roi-collector.service
  engine/systemd/zenoforge-supervisor.service
)

for f in "${gate_files[@]}"; do
  [[ "$f" =~ $regex ]] || fail "gate regex does not match listed gate file $f"
done

for wf in engine-tests cli-tests; do
  file="$root/.github/workflows/$wf.yml"
  [[ -f "$file" ]] || fail "missing $file"
  grep -qx '  push:' "$file" && grep -qx '    branches: \[main\]' "$file" \
    || fail "$wf.yml lost its push-to-main trigger"
  grep -qx '  workflow_dispatch:' "$file" || fail "$wf.yml lost workflow_dispatch"
  grep -qx '  pull_request:' "$file" || fail "$wf.yml has no pull_request trigger"

  # Globs listed under on.pull_request.paths.
  mapfile -t globs < <(awk '/^  pull_request:/{f=1;next} /^  [a-z_]+:/{f=0} f && /^      - /{sub(/^      - /,""); print}' "$file")
  [[ ${#globs[@]} -gt 0 ]] || fail "$wf.yml pull_request has no paths"

  for g in "${globs[@]}"; do
    sample="${g//\*\*/sample.sh}"
    [[ "$sample" =~ $regex ]] || fail "$wf.yml path $g is not a gate file in merge-pr.sh"
  done
  for f in "${gate_files[@]}"; do
    covered=0
    for g in "${globs[@]}"; do
      # shellcheck disable=SC2254
      case "$f" in $g) covered=1; break ;; esac
    done
    [[ $covered == 1 ]] || fail "$wf.yml pull_request paths do not cover gate file $f"
  done
done

echo "pr-ci-gate-paths.test.sh: ok (${#gate_files[@]} gate files)"
