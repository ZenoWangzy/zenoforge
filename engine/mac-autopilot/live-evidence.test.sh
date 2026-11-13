#!/usr/bin/env bash
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$here/../test-env.sh"
source "$MODEL_POLICY_TEST_REPO/tools/merge-pr.sh"

fail() { printf 'live-evidence.test.sh: %s\n' "$*" >&2; exit 1; }

merge_pr_view() {
  jq -cn --arg body "$PR_BODY" --argjson files "$PR_FILES" \
    '{body:$body,files:($files|map({path:.})),commits:[]}'
}

PR_BODY=$'## prior-art\nno external prior art: fixture\n'
PR_FILES='["engine/runtime.sh"]'
warning="$(merge_pr_prior_art_ok 17 2>&1)" || fail "missing Live evidence was refused: $warning"
[[ "$warning" == *"warning: PR #17 changes engine runtime code but has no Live evidence line"* ]] \
  || fail "runtime PR warning missing: ${warning:-<empty>}"

PR_BODY+=$'\nLive evidence: intake-priority: applied\n'
warning="$(merge_pr_prior_art_ok 17 2>&1)" || fail "Live evidence line was refused: $warning"
[[ -z "$warning" ]] || fail "accepted Live evidence line still warned: $warning"

# #926 has no contract line in its historical PR body, so the checker keeps
# its expected applied line explicitly and detects the supplied skipped-only shape.
retro="$test_env_root/live-evidence-retro"
mkdir -p "$retro"
cat > "$retro/prs.json" <<'JSON'
[{"number":926,"mergedAt":"2026-11-12T11:33:59Z","body":"intake priority hook"}]
JSON
cat > "$retro/pins.json" <<'JSON'
[{"timestamp":"2026-11-12T12:00:00Z","message":"12:00:00 PINNED aaaaaaaaaaaa committed=x"}]
JSON
cat > "$retro/journal.json" <<'JSON'
[{"timestamp":"2026-11-12T12:10:00Z","message":"intake-priority: skipped (missing-typesafe-key)"}]
JSON
export ZF_LIVE_EVIDENCE_PR_FIXTURE="$retro/prs.json"
export ZF_LIVE_EVIDENCE_PIN_FIXTURE="$retro/pins.json"
export ZF_LIVE_EVIDENCE_JOURNAL_FIXTURE="$retro/journal.json"
export ZF_LIVE_EVIDENCE_ENGINE_LOGS="$retro/no-engine-log"
retro_now="$(python3 -c 'from datetime import datetime,timezone; print(int(datetime(2026,11,13,12,1,tzinfo=timezone.utc).timestamp()))')"
retro_result="$(python3 "$here/live-evidence.py" scan --state "$retro/state.json" --repo fixture/engine \
  --runtime-dir "$retro/runtime" --agent-home "$retro/agent" --now "$retro_now")" \
  || fail 'retroactive #926 scan failed'
jq -e '.missing | length == 1 and .[0].number == 926 and .[0].pattern == "intake-priority: applied"' \
  <<<"$retro_result" >/dev/null || fail "retroactive #926 was not flagged: $retro_result"

echo 'live-evidence.test.sh: PASS'
