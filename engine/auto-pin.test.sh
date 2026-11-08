#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
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

# a pin refused for a dirty checkout is retried once the tree clears, with no new main commit
g -C "$tmp/agent/checkout" init -q
: > "$PIN_CALLS"; c5=$(commit five); echo 1 > "$PIN_RC"
sed -i '2i echo "pin-vecta: source checkout has changes; commit or clear them"' "$tmp/clone/tools/pin-vecta.sh" 2>/dev/null || :
touch "$tmp/agent/checkout/dirty"
auto_pin_pass > "$tmp/out" & pass=$!
sleep 1
kill -0 "$pass" 2>/dev/null || fail 'a dirty checkout ended the wait'
[[ $(last) == "$c4" ]] || fail 'state moved on a dirty checkout'
g -C "$tmp/agent/checkout" add -A; g -C "$tmp/agent/checkout" commit -qm clean
wait "$pass" || fail 'retry pass returned non-zero'
[[ $(last) == "$c4" ]] || fail 'state moved before the retry pinned'
echo 0 > "$PIN_RC"
auto_pin_pass > /dev/null; [[ $(last) == "$c5" ]] || fail "retry did not pin the same commit: $(last)"
[[ $(grep -c "$c5" "$PIN_CALLS") == 2 ]] || fail "calls: $(tr '\n' ' ' < "$PIN_CALLS")"

# a pin refused for a missing intended-changes row is retried once the row lands, with no new main commit, and only once
: > "$PIN_CALLS"; c6=$(commit six); echo 1 > "$PIN_RC"
sed -i '2s/.*/echo "pin-vecta: add this row to intended-changes.tsv and rerun:"/' "$tmp/clone/tools/pin-vecta.sh"
auto_pin_pass > "$tmp/out" & pass=$!
sleep 1
kill -0 "$pass" 2>/dev/null || fail 'a refused pin ended the wait before the row landed'
printf 'state/rulings.json\tdeclared\t%s\n' "$c6" > "$tmp/agent/checkout/.zenoforge/build/intended-changes.tsv"
wait "$pass" || fail 'row retry pass returned non-zero'
[[ $(last) == "$c5" ]] || fail 'state moved before the row retry pinned'
auto_pin_pass > "$tmp/out" & pass=$!
sleep 1
kill -0 "$pass" 2>/dev/null || fail 'a second refusal retried again instead of waiting'
[[ $(grep -c "$c6" "$PIN_CALLS") == 2 ]] || fail "row retry calls: $(tr '\n' ' ' < "$PIN_CALLS")"
kill "$pass" 2>/dev/null || :
wait "$pass" 2>/dev/null

# A clone script that differs from the running copy ends the daemon after its pass, so systemd reinstalls it.
echo 0 > "$PIN_RC"
{ cat "$repo/tools/auto-pin.sh"; echo '# newer'; } > "$tmp/clone/tools/auto-pin.sh"
( auto_pin_main ) > "$tmp/out" 2>&1 & daemon=$!
for _ in {1..40}; do kill -0 "$daemon" 2>/dev/null || break; sleep 0.25; done
kill -0 "$daemon" 2>/dev/null && { kill "$daemon"; fail 'a daemon behind its clone kept running'; }
wait "$daemon" || fail 'the self-restart exit was not clean'
grep -q 'newer script' "$tmp/out" || fail "no self-restart line: $(cat "$tmp/out")"
# merge_override_pin: a base-only override move (clean three-way, pack copy byte-identical) has no pack file in the PR and must still merge
gh() { # stub: the PR's file list comes from GH_FILES; checks are green and the merge completes at once
  case "$*" in
    *"--json files"*) printf '%s\n' "$GH_FILES" ;;
    *statusCheckRollup*) echo 0 ;;
    *"pr merge"*) echo merged ;;
    *"--json state"*) echo MERGED ;;
  esac
}
ovlog=$tmp/override.log
printf '%s\n' 'result=pr-open route=PR landed=no pr=https://github.com/ZenoWangzy/vecta/pull/5876' \
  'pin-vecta: merged override mac-autopilot/scheduler.d/dispatch-queue.sh base=416ca459497a -> engine=cb9fd885a3b6 (clean three-way merge)' > "$ovlog"
GH_FILES=$(printf '%s\n' .zenoforge/build.json .zenoforge/build/overrides.tsv)
merge_override_pin "$ovlog" > "$tmp/ov.out" || fail "base-only override PR refused: $(cat "$tmp/ov.out")"
GH_FILES=$(printf '%s\n' .zenoforge/build.json .zenoforge/build/overrides.tsv engine/unrelated.sh)
if merge_override_pin "$ovlog" > "$tmp/ov.out"; then fail 'an unrelated file in the override PR was merged'; fi
GH_FILES=.zenoforge/build.json
if merge_override_pin "$ovlog" > "$tmp/ov.out"; then fail 'an override PR without overrides.tsv was merged'; fi
echo "auto-pin.test.sh: ok"
