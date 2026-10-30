#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
eval "$(sed -n '/^hand_agent_process_tree() {/,/^}/p; /^hand_agent_codex_session_file() {/,/^}/p; /^hand_agent_process_started_at() {/,/^}/p'  "$script_dir/hand-agent-watchdog.sh")"

agent_epoch() { date -u -d "$1" +%s; }

tmp="$(mktemp -d)"
owner_pid=""
cleanup() {
  if [ -n "$owner_pid" ]; then
    kill "$owner_pid" 2>/dev/null || true
    wait "$owner_pid" 2>/dev/null || true
  fi
  rm -rf -- "$tmp"
}
trap cleanup EXIT
export CODEX_HOME="$tmp/codex" DISCOVERY_CALLS="$tmp/calls"
mkdir -p "$tmp/bin" "$CODEX_HOME/sessions" "$tmp/unrelated"
cat > "$tmp/bin/readlink" <<'EOF'
#!/usr/bin/env bash
echo readlink >> "$DISCOVERY_CALLS"
exec /usr/bin/readlink "$@"
EOF
cat > "$tmp/bin/ps" <<'EOF'
#!/usr/bin/env bash
echo ps >> "$DISCOVERY_CALLS"
exec /usr/bin/ps "$@"
EOF
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
mkfifo "$tmp/ready"
python3 - "$tmp" <<'PY' &
import os
import json
from datetime import datetime, timezone
from pathlib import Path
import sys
import time

root = Path(sys.argv[1])
os.chdir(root)
old = root / 'codex/sessions/rollout-old.jsonl'
latest = root / 'codex/sessions/rollout-latest.jsonl'
unrelated = root / 'codex/sessions/rollout-unrelated.jsonl'
stale = root / 'codex/sessions/rollout-stale.jsonl'
for path in (old, latest, unrelated, stale):
    started = datetime.now(timezone.utc).isoformat()
    if path == stale:
        started = '2020-01-01T00:00:00Z'
    cwd = str(root / 'another-owner') if path == unrelated else str(root)
    path.write_text(json.dumps({'type': 'session_meta', 'timestamp': started, 'payload': {'cwd': cwd}}) + '\n')
now = time.time()
os.utime(old, (now - 60, now - 60))
os.utime(unrelated, (now + 60, now + 60))
os.utime(stale, (now + 90, now + 90))
# Noise FDs reproduce discovery cost without changing selected session.
handles = [open('/dev/null') for _ in range(128)]
handles.extend(open(path) for path in (old, latest, unrelated, stale))
(root / 'ready').write_text('ready\n')
time.sleep(300)
PY
owner_pid=$!
IFS= read -r -t 5 ready < "$tmp/ready"
[[ "$ready" == ready ]]

selected="$(hand_agent_codex_session_file "$owner_pid")"
[[ "$selected" == "$CODEX_HOME/sessions/rollout-latest.jsonl"$'\t'"$owner_pid" ]] || { echo "FAIL: selected foreign or pre-launch session: $selected" >&2; exit 1; }
[[ "$(grep -c '^ps$' "$DISCOVERY_CALLS")" == 1 ]]
[[ "$(grep -c '^readlink$' "$DISCOVERY_CALLS")" == 2 ]] || {
  echo "not ok - session discovery launches readlink per FD: $(grep -c '^readlink$' "$DISCOVERY_CALLS") calls" >&2
  exit 1
}
echo 'ok - owner session selected; newer other-owner and stale-session FDs excluded'

CODEX_HOME="$tmp/no-session" hand_agent_codex_session_file "$owner_pid" > "$tmp/missing" && {
  echo 'not ok - missing session reported live' >&2
  exit 1
}
[ ! -s "$tmp/missing" ]
echo 'ok - unrelated sessions and missing sessions excluded'
