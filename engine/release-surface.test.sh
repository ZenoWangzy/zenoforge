#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
RUNTIME="$test_env_root/release-surface-agent"
mkdir -p "$RUNTIME/state" "$RUNTIME/alerts"
stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '[%s] release-closer: deployed=%s closed=[701001, 701002] awaiting-release=[]\n' \
  "$stamp" "$(printf 'a%.0s' {1..40})" > "$RUNTIME/alerts/events.md"

python3 - "$RUNTIME/state" <<'PY'
import json
import sys
from pathlib import Path

state_dir = Path(sys.argv[1])
head = "0123456789abcdef0123456789abcdef01234567"
for issue, evidence in (
    (701001, "Feature surface: admin notification settings panel"),
    (701002, "Feature surface: send a message to the team room"),
):
    real_user_path = "\n".join((evidence, "URL: https://example.invalid/admin",
                                "Visible DOM: Admin notification settings",
                                "Same-run network: GET /api/notifications -> 200"))
    state = {
        "title": "Admin notification settings",
        "brief_md": "Add admin notification settings panel",
        "deploy_state": "deployed",
        "deployed_sha": "a" * 40,
        "run": {
            "outcome": "merged",
            "evidence": {
                "pr_number": issue,
                "pr_head_sha": head,
                "mandatory_checks": {"status": "passed", "head_sha": head},
                "real_user_path": real_user_path,
            },
        },
    }
    (state_dir / f"{issue}.json").write_text(json.dumps(state))
PY

for issue in 701001 701002; do
  AGENT_HOME="$RUNTIME" AGENT_DRY_RUN=1 REPO="example/repo" \
    bash -c '
      source "$1/lib.sh"
      queue_maintainer_outcome() { :; }
      conclude_run "$2" deployed "Production evidence recorded."
    ' _ "$SCRIPT_DIR" "$issue" >"$RUNTIME/close-$issue.log" 2>&1
done

PYTHONPATH="$SCRIPT_DIR/mac-autopilot" python3 - "$RUNTIME" <<'PY'
import sys
from datetime import datetime, timezone
from pathlib import Path

import ledger_history
import node_health

runtime = sys.argv[1]
now = datetime.now(timezone.utc)
events = ledger_history.release_acceptances(runtime, now=now)
assert len(events) == 2, events
by_issue = {event["issue"]: event for event in events}
assert by_issue[701001]["surface_covered"] is True, by_issue
assert by_issue[701002]["surface_covered"] is False, by_issue
event_text = (Path(runtime) / "alerts" / "events.md").read_text()
assert "release-closer: deployed=" + "a" * 40 + " closed=[701001] surface_covered=true" in event_text
assert "release-closer: deployed=" + "a" * 40 + " closed=[701002] surface_covered=false" in event_text
delivery = node_health.delivery_metrics([], None, None, events, None, now)
assert delivery["details"]["uncovered_closes_7d"] == 1, delivery["details"]
assert ledger_history.uncovered_closes_line(delivery["details"]["uncovered_closes_7d"]) == "uncovered closes (7d): 1"
print("release surface close and delivery metric: PASS")
PY

mkdir -p "$RUNTIME/bin"
cat > "$RUNTIME/bin/gh" <<'GH'
#!/usr/bin/env bash
if [[ "${1:-}" == "api" ]]; then
  printf '{"data":{"search":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}\n'
  exit 0
fi
printf '[]\n'
exit 0
GH
chmod +x "$RUNTIME/bin/gh"
repo_root="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
delivery_now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
delivery_output="$(AGENT_HOME="$RUNTIME" ZF_REPO="" MAC_AUTOPILOT_ROOT="$repo_root" PATH="$RUNTIME/bin:$PATH" \
  PYTHONPATH="$SCRIPT_DIR/mac-autopilot" python3 "$SCRIPT_DIR/mac-autopilot/node_health.py" \
  --runtime "$RUNTIME" --audit /dev/null --now "$delivery_now" 2>/dev/null)"
grep -Fq 'delivery    uncovered closes (7d): 1' <<< "$delivery_output"
