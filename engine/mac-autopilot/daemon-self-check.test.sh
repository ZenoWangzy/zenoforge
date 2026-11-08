#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
# daemon-self-check.sh: a supervised loop is stale only when its own script or a file it sources differs from the live copy.
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/daemon-self-check-test.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
fail() { echo "daemon-self-check.test.sh: $*" >&2; exit 1; }
source "$here/daemon-self-check.sh"
files=(loop.sh env.sh ../conf.sh)
mkdir -p "$tmp/v1/mac-autopilot"; for f in "${files[@]}"; do echo "$f one" > "$tmp/v1/mac-autopilot/$f"; done
started=$tmp/v1/mac-autopilot
newdir() { rm -rf "$tmp/$1"; cp -r "$tmp/v1" "$tmp/$1"; ln -sfn "$tmp/$1/mac-autopilot" "$tmp/live"; }
stale() { zf_daemon_stale "$started" "$tmp/live" "${files[@]}"; }

export INVOCATION_ID=test
newdir v2   # the pin moved, every byte is the same
stale && fail 'a pin with identical bytes asked for a restart'
echo 'two' >> "$tmp/v2/conf.sh"
stale || fail 'a changed sourced file did not ask for a restart'
newdir v3; echo 'two' >> "$tmp/v3/mac-autopilot/loop.sh"
stale || fail "a changed own script did not ask for a restart"
newdir v4; rm "$tmp/v4/mac-autopilot/env.sh"
stale || fail 'a sourced file missing on the live side did not ask for a restart'
newdir v5; rm "$tmp/v5/mac-autopilot/loop.sh"; echo 'two' >> "$tmp/v5/conf.sh"
stale && fail 'a restart was asked for with no own script on the live side'
zf_daemon_stale "$started" "$tmp/missing" "${files[@]}" && fail 'an unresolvable live dir asked for a restart'
newdir v6; echo 'two' >> "$tmp/v6/mac-autopilot/loop.sh"
( unset INVOCATION_ID; stale ) && fail 'an unsupervised loop asked for a restart'
grep -q 'zf_daemon_stale "\$HERE" "\$LIVE" bell-loop.sh runtime-env.sh' "$here/bell-loop.sh" || fail 'bell-loop.sh does not use the check'
echo "daemon-self-check.test.sh: ok"
