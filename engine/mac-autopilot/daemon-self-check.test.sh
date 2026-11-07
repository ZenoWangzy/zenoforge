#!/usr/bin/env bash
set -euo pipefail
# daemon-self-check.sh: a supervised loop is stale once the live link resolves elsewhere; an unsupervised or unresolvable one never is.
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/daemon-self-check-test.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
fail() { echo "daemon-self-check.test.sh: $*" >&2; exit 1; }
source "$here/daemon-self-check.sh"
mkdir -p "$tmp/v1/mac-autopilot" "$tmp/v2/mac-autopilot"
v1=$(cd "$tmp/v1/mac-autopilot" && pwd -P); ln -s "$tmp/v1/mac-autopilot" "$tmp/live"

unset INVOCATION_ID
ln -sfn "$tmp/v2/mac-autopilot" "$tmp/live"
zf_daemon_stale "$v1" "$tmp/live" && fail 'an unsupervised loop asked to exit'
export INVOCATION_ID=test
ln -sfn "$tmp/v1/mac-autopilot" "$tmp/live"
zf_daemon_stale "$v1" "$tmp/live" && fail 'a loop on the live directory asked to exit'
ln -sfn "$tmp/v2/mac-autopilot" "$tmp/live"
zf_daemon_stale "$v1" "$tmp/live" || fail 'a loop behind the live directory kept running'
zf_daemon_stale "$v1" "$tmp/missing" && fail 'an unresolvable live link asked to exit'
grep -q 'zf_daemon_stale "\$HERE" "\$LIVE"' "$here/bell-loop.sh" || fail 'bell-loop.sh does not use the check'
echo "daemon-self-check.test.sh: ok"
