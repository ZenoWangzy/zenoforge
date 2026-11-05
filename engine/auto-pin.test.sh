#!/usr/bin/env bash
set -euo pipefail
# tools/auto-pin.sh: the pass pins oldest first, one commit per pass; a failed pin neither exits nor loops on the same commit.
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/auto-pin-test.XXXXXX"); trap 'kill $(jobs -p) 2>/dev/null || :; rm -rf "$tmp"' EXIT
fail() { echo "auto-pin.test.sh: $*" >&2; exit 1; }
g() { git -c user.name=t -c user.email=t@example.invalid "$@"; }

git init -q --bare "$tmp/origin.git"; g clone -q "$tmp/origin.git" "$tmp/work" 2>/dev/null; g -C "$tmp/work" checkout -q -b main
mkdir -p "$tmp/work/tools"
cat > "$tmp/work/tools/pin-vecta.sh" <<'STUB'
#!/usr/bin/env bash
echo "$1" >> "$PIN_CALLS"; exit "$(cat "$PIN_RC" 2>/dev/null || echo 0)"
STUB
commit() { echo "$1" > "$tmp/work/f"; g -C "$tmp/work" add -A; g -C "$tmp/work" commit -qm "$1"; g -C "$tmp/work" push -q origin main; g -C "$tmp/work" rev-parse HEAD; }
c1=$(commit one)
g clone -q "$tmp/origin.git" "$tmp/clone"
mkdir -p "$tmp/agent/checkout/.zenoforge/build"
printf '#!/usr/bin/env bash\necho converge >> "$PIN_CALLS"\n' > "$tmp/agent/checkout/.zenoforge/build/engine-sync.sh"; chmod +x "$tmp/agent/checkout/.zenoforge/build/engine-sync.sh"

export ZF_AUTO_PIN_HOME=$tmp/home AGENT_HOME=$tmp/agent ZF_AUTO_PIN_CLONE=$tmp/clone ZF_AUTO_PIN_IDLE_SECS=0 ZF_AUTO_PIN_RETRY_SECS=0.2
export PIN_CALLS=$tmp/calls PIN_RC=$tmp/rc
mkdir -p "$ZF_AUTO_PIN_HOME/auto-pin-logs"; echo "$c1" > "$ZF_AUTO_PIN_HOME/auto-pin.last"; : > "$PIN_CALLS"
source "$repo/tools/auto-pin.sh"; set +e  # the daemon runs without -e
last() { cat "$ZF_AUTO_PIN_HOME/auto-pin.last"; }

# a failed pin waits in place while main stays put: the pass does not return, state does not move
c2=$(commit two); echo 1 > "$PIN_RC"
auto_pin_pass > "$tmp/out" & pass=$!
sleep 2
kill -0 "$pass" 2>/dev/null || fail 'daemon exited after a failed pin'
[[ $(last) == "$c1" ]] || fail 'state moved before main advanced'
# main advances twice: the waiting pass moves on, then each later pass pins exactly one commit, oldest first
c3=$(commit three); c4=$(commit four); echo 0 > "$PIN_RC"
wait "$pass" || fail 'pass returned non-zero'
grep -q PIN-FAILED "$tmp/out" || fail 'no PIN-FAILED line'
[[ $(last) == "$c2" ]] || fail "failed commit not skipped: $(last)"
auto_pin_pass > /dev/null; [[ $(last) == "$c3" ]] || fail "second pass did not pin the oldest: $(last)"
auto_pin_pass > /dev/null; [[ $(last) == "$c4" ]] || fail "third pass did not pin the next: $(last)"
auto_pin_pass > /dev/null; [[ $(last) == "$c4" ]] || fail 'idle pass moved state'
[[ $(tr '\n' ' ' < "$PIN_CALLS") == "$c2 $c3 converge $c4 converge " ]] || fail "calls: $(tr '\n' ' ' < "$PIN_CALLS")"
echo "auto-pin.test.sh: ok"
