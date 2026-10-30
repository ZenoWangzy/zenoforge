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
cp -- "$SCRIPT_DIR/health-maintenance.sh" "$fixture_repo/engine/night/health-maintenance.sh"
cat > "$fixture_repo/engine/night/founder-health-mail.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$MAINTAINER_MAIL_ARGS"
printf 'maintainer health mail: sent\n'
EOF
chmod +x "$fixture_repo/engine/night/founder-health-mail.sh"
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
