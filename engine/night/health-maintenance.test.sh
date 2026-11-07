#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/zenoforge-health-maintenance-test.XXXXXX")"
trap 'rm -rf -- "$tmp" "$test_env_root"' EXIT

fixture_repo="$tmp/repo"
fixture_agent="$tmp/agent"
mkdir -p -- "$fixture_repo/engine/night" "$fixture_agent/night" "$tmp/bin"
cp -- "$REPO_DIR/engine/config.sh" "$fixture_repo/engine/config.sh"
cp -- "$SCRIPT_DIR/health-maintenance.sh" "$fixture_repo/engine/night/health-maintenance.sh"
cat > "$fixture_repo/engine/night/node-health.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$PRODUCTION_MONITOR_ARGS"
printf 'production monitor completed\n'
EOF
cat > "$fixture_repo/engine/worktree-lifecycle.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  reap) printf 'worktree sweep completed\n' ;;
  stats) printf 'worktrees=0 local_branches=0 remote_branches=0 stale_over_24h=0\n' ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$fixture_repo/engine/night/node-health.sh" "$fixture_repo/engine/worktree-lifecycle.sh"
cat > "$fixture_repo/engine/night/maintainer-health-mail.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$MAINTAINER_MAIL_ARGS"
printf 'maintainer health mail: sent\n'
EOF
chmod +x "$fixture_repo/engine/night/maintainer-health-mail.sh"
cat > "$tmp/bin/timeout" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == -k && "$2" == 5 ]] || exit 90
shift 3
exec "$@"
EOF
chmod +x "$tmp/bin/timeout"

AGENT_HOME="$fixture_agent" \
ZF_NIGHT_DIR="$fixture_agent/night" \
ZF_REPO_DIR="$fixture_repo" \
MAINTAINER_MAIL_ARGS="$tmp/founder-mail-args" \
PATH="$tmp/bin:$PATH" \
  bash "$fixture_repo/engine/night/health-maintenance.sh" founder-mail

[[ "$(cat "$tmp/founder-mail-args")" == tick ]]
jq -e '.verdict == "OK" and .detail == "maintainer health mail tick completed"' \
  "$fixture_agent/night/founder-health-mail-last-result.json" >/dev/null
echo 'ok - health maintenance invokes maintainer mail without a HEALTH path'

AGENT_HOME="$fixture_agent" \
ZF_NIGHT_DIR="$fixture_agent/night" \
ZF_REPO_DIR="$fixture_repo" \
PRODUCTION_MONITOR_ARGS="$tmp/production-monitor-args" \
PATH="$tmp/bin:$PATH" \
  bash "$fixture_repo/engine/night/health-maintenance.sh" maintenance
[[ "$(cat "$tmp/production-monitor-args")" == --prod-anomaly-only ]]
jq -e '.verdict == "OK" and .detail == "production monitor completed"' \
  "$fixture_agent/night/production-monitor-last-result.json" >/dev/null
echo 'ok - ten-minute health maintenance invokes the bounded production outage monitor'
