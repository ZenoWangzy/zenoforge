#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../test-env.sh"
p=$(cd "$(dirname "$0")" && pwd); t=$(mktemp -d)
export AGENT_HOME=$t CLAUDE_SESSIONS_DIR=$t/s; mkdir "$t/s"
printf '{"pid":"%s","sessionId":"sid-1","name":"session"}\n' "$$" > "$t/s/$$.json"
"$p/hf-role-claim.sh" | grep -q 'session'
[[ $(jq -r .sessionId "$t/hotfix-supervisor.json") == sid-1 ]]
mv "$t/s/$$.json" "$t/session.json"
! "$p/hf-role-claim.sh" >/dev/null 2>&1
