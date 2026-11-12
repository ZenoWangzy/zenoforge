#!/usr/bin/env bash
# Keeps the PR CI gate in step: the gate regex in tools/merge-pr.sh (merge_pr_gate_ci_ok) and the
# pull_request paths of engine-tests.yml and cli-tests.yml must agree, and both must keep push-to-main.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
fail() { echo "pr-ci-gate-paths.test.sh: $*" >&2; exit 1; }

# Gate regex straight from merge-pr.sh; jq's "\\." is ERE "\.". The override exists only for the mutation case below.
merge_pr="${PR_CI_GATE_MERGE_PR:-$root/tools/merge-pr.sh}"
raw="$(grep -oE 'test\("\^\([^"]*\)\$"\)' "$merge_pr" | head -1)"
[[ -n "$raw" ]] || fail "no gate regex found in tools/merge-pr.sh"
raw="${raw#*\"}"; raw="${raw%\"*}"
regex="$(sed 's/\\\\/\\/g' <<<"$raw")"

# Every item the regex can match, expanded from the regex itself (a sample for .*). Checked against the workflows below.
mapfile -t derived < <(node -e '
  const s = process.argv[1]; let i = 0;
  const prod = (a, b) => a.flatMap((x) => b.map((y) => x + y));
  function parseAlt() {
    let branches = [], seq = [""];
    while (i < s.length && s[i] !== ")") {
      const c = s[i];
      if (c === "|") { branches.push(...seq); seq = [""]; i++; }
      else if (c === "(") { i++; let sub = parseAlt(); i++; if (s[i] === "?") { sub = [...sub, ""]; i++; } seq = prod(seq, sub); }
      else if (c === "\\") { seq = seq.map((x) => x + s[i + 1]); i += 2; }
      else if (c === "." && s[i + 1] === "*") { seq = seq.map((x) => x + "x"); i += 2; }
      else if (c === "^" || c === "$") { i++; }
      else { seq = seq.map((x) => x + c); i++; }
    }
    branches.push(...seq);
    return branches;
  }
  console.log(parseAlt().join("\n"));
' "$regex")
[[ ${#derived[@]} -gt 0 ]] || fail "could not expand the gate regex"

# Hand-written list of gate files; the derived check below catches a regex item missing from it or from the workflows.
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
  engine/systemd/zenoforge-retro.service engine/systemd/zenoforge-supervisor.service
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
  for f in "${derived[@]}"; do
    covered=0
    for g in "${globs[@]}"; do
      # shellcheck disable=SC2254
      case "$f" in $g) covered=1; break ;; esac
    done
    [[ $covered == 1 ]] || fail "$wf.yml pull_request paths do not cover $f, which the merge-pr.sh gate regex matches"
  done
done

# Mutation: add one regex alternative that no workflow lists. The guard must go red.
if [[ -z "${PR_CI_GATE_MUTANT_RUN:-}" ]]; then
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp" "$test_env_root"' EXIT
  sed 's/(merge-pr|pin-vecta|auto-pin)/(merge-pr|pin-vecta|auto-pin|zz-mutant)/' "$merge_pr" > "$tmp/merge-pr.sh"
  [[ "$(grep -c 'zz-mutant' "$tmp/merge-pr.sh")" == 1 ]] || fail "mutation did not apply to the regex"
  set +e
  out="$(PR_CI_GATE_MERGE_PR="$tmp/merge-pr.sh" PR_CI_GATE_MUTANT_RUN=1 bash "${BASH_SOURCE[0]}" 2>&1)"
  rc=$?
  set -e
  [[ $rc -ne 0 && "$out" == *'tools/zz-mutant.sh'* ]] || fail "a regex item missing from the workflows did not fail the guard (rc=$rc): $out"
fi

echo "pr-ci-gate-paths.test.sh: ok (${#gate_files[@]} gate files, ${#derived[@]} regex items)"
