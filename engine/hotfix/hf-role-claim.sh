#!/usr/bin/env bash
# Register the nearest ancestor session as the hotfix supervisor.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$here/../config.sh"
s=${CLAUDE_SESSIONS_DIR:-$HOME/.claude/sessions}
out=$AGENT_HOME/hotfix-supervisor.json
p=$$
while ((p > 1)); do
  if [[ -r $s/$p.json ]]; then
    jq -c '{sessionId, name, pid}' "$s/$p.json" > "$out"
    echo "hotfix role claimed: $(jq -r .name "$out") ($(jq -r .sessionId "$out"))"; exit 0
  fi
  p="$(LC_ALL=C ps -o ppid= -p "$p" 2>/dev/null || true)"
  p="${p//[[:space:]]/}"
done
echo 'hf-role-claim: no session found above this shell' >&2; exit 1
