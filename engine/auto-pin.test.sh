#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
# tools/auto-pin.sh: a pass pins main's newest commit (a batch is pinned once); a failed pin neither exits nor loops on the same commit.
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/auto-pin-test.XXXXXX"); trap 'kill $(jobs -p) 2>/dev/null || :; rm -rf "$tmp"' EXIT
fail() { echo "auto-pin.test.sh: $*" >&2; exit 1; }
g() { git -c user.name=t -c user.email=t@example.invalid "$@"; }

git init -q --bare "$tmp/origin.git"; g clone -q "$tmp/origin.git" "$tmp/work" 2>/dev/null; g -C "$tmp/work" checkout -q -b main
mkdir -p "$tmp/work/tools"
cat > "$tmp/work/tools/pin-vecta.sh" <<'STUB'
#!/usr/bin/env bash
echo "$1" >> "$PIN_CALLS"; [[ ! -e "$PIN_RC.rate" ]] || echo 'pin-vecta: GraphQL: API rate limit already exceeded' >&2; exit "$(cat "$PIN_RC" 2>/dev/null || echo 0)"
STUB
commit() { echo "$1" > "$tmp/work/f"; g -C "$tmp/work" add -A; g -C "$tmp/work" commit -qm "$1"; g -C "$tmp/work" push -q origin main; g -C "$tmp/work" rev-parse HEAD; }
c1=$(commit one)
g clone -q "$tmp/origin.git" "$tmp/clone"
mkdir -p "$tmp/agent/checkout/.zenoforge/build"
printf '#!/usr/bin/env bash\necho converge >> "$PIN_CALLS"\n' > "$tmp/agent/checkout/.zenoforge/build/engine-sync.sh"; chmod +x "$tmp/agent/checkout/.zenoforge/build/engine-sync.sh"

export ZF_AUTO_PIN_HOME=$tmp/home AGENT_HOME=$tmp/agent ZF_AUTO_PIN_CLONE=$tmp/clone ZF_AUTO_PIN_IDLE_SECS=0 ZF_AUTO_PIN_RETRY_SECS=0.2 ZF_AUTO_PIN_RATE_SECS=0.1
export PIN_CALLS=$tmp/calls PIN_RC=$tmp/rc
mkdir -p "$ZF_AUTO_PIN_HOME/auto-pin-logs"; echo "$c1" > "$ZF_AUTO_PIN_HOME/auto-pin.last"; : > "$PIN_CALLS"
source "$repo/tools/auto-pin.sh"; set +e  # the daemon runs without -e
last() { cat "$ZF_AUTO_PIN_HOME/auto-pin.last"; }
wait_for_pin_calls() {
  local commit=$1 expected=$2
  for _ in {1..200}; do
    [[ $(grep -Fc "$commit" "$PIN_CALLS" 2>/dev/null || :) -ge $expected ]] && return 0
    sleep 0.05
  done
  return 1
}
wait_for_pass_exit() {
  local pass=$1
  for _ in {1..200}; do
    kill -0 "$pass" 2>/dev/null || return 0
    sleep 0.05
  done
  return 1
}

# a failed pin waits in place while main stays put: the pass does not return, state does not move
c2=$(commit two); echo 1 > "$PIN_RC"
auto_pin_pass > "$tmp/out" & pass=$!
sleep 2
kill -0 "$pass" 2>/dev/null || fail 'daemon exited after a failed pin'
[[ $(last) == "$c1" ]] || fail 'state moved before main advanced'
# main advances twice: the waiting pass moves on, then one pass pins main's head; the commit between is not pinned on its own
c3=$(commit three); c4=$(commit four); echo 0 > "$PIN_RC"
wait "$pass" || fail 'pass returned non-zero'
grep -q PIN-FAILED "$tmp/out" || fail 'no PIN-FAILED line'
[[ $(last) == "$c2" ]] || fail "failed commit not skipped: $(last)"
auto_pin_pass > /dev/null; [[ $(last) == "$c4" ]] || fail "second pass did not pin main's head: $(last)"
auto_pin_pass > /dev/null; [[ $(last) == "$c4" ]] || fail 'idle pass moved state'
[[ $(tr '\n' ' ' < "$PIN_CALLS") == "$c2 $c4 converge " ]] || fail "calls: $(tr '\n' ' ' < "$PIN_CALLS")"
# a batch of three merges since the last pin is pinned once, at the newest (ruling zenoforge-batch-land-2026-11-08)
: > "$PIN_CALLS"; b1=$(commit batch1); b2=$(commit batch2); b3=$(commit batch3)
auto_pin_pass > /dev/null; [[ $(last) == "$b3" ]] || fail "batch pass did not pin the newest: $(last)"
[[ $(tr '\n' ' ' < "$PIN_CALLS") == "$b3 converge " ]] || fail "batch calls: $(tr '\n' ' ' < "$PIN_CALLS")"
c4=$b3  # later cases continue from the batch head

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

# A VectA checkout move after a refusal retries this same main commit once.
# The next failure at that moved head waits until another head or main change.
cat > "$tmp/clone/tools/pin-vecta.sh" <<'STUB'
#!/usr/bin/env bash
echo "$1" >> "$PIN_CALLS"; [[ ! -e "$PIN_RC.rate" ]] || echo 'pin-vecta: GraphQL: API rate limit already exceeded' >&2; exit "$(cat "$PIN_RC" 2>/dev/null || echo 0)"
STUB
: > "$PIN_CALLS"; c7=$(commit vecta-move-retry); echo 1 > "$PIN_RC"
vecta_before=$(g -C "$tmp/agent/checkout" rev-parse HEAD)
auto_pin_pass > "$tmp/out" & pass=$!
wait_for_pin_calls "$c7" 1 || fail 'VectA move case did not start its failed pin'
vecta_after=$(echo moved > "$tmp/agent/checkout/vecta-state"; g -C "$tmp/agent/checkout" add -A; g -C "$tmp/agent/checkout" commit -qm moved; g -C "$tmp/agent/checkout" rev-parse HEAD)
wait_for_pass_exit "$pass" || fail 'VectA checkout head move did not return to retry the same commit'
wait "$pass" || fail 'VectA move retry signal returned non-zero'
[[ $(last) == "$c5" ]] || fail 'state moved before the VectA move retry pinned'
grep -Fq "RETRY-VECTA-HEAD from=$vecta_before to=$vecta_after commit=$c7" "$tmp/out" || fail 'VectA retry log did not name both heads'
echo 0 > "$PIN_RC"
auto_pin_pass > /dev/null
[[ $(last) == "$c7" ]] || fail 'VectA move retry did not pin the same commit'
[[ $(grep -Fc "$c7" "$PIN_CALLS") == 2 ]] || fail "VectA move calls: $(tr '\n' ' ' < "$PIN_CALLS")"

# A rate-limited pin retries the same commit after a backoff, at most 3 times, then waits; a non-rate-limit failure waits at once.
: > "$PIN_CALLS"; c12=$(commit rate-limited); echo 1 > "$PIN_RC"; : > "$PIN_RC.rate"; before=$(last)
for _ in 1 2 3; do auto_pin_pass > "$tmp/out"; grep -q RATE-LIMIT-RETRY "$tmp/out" || fail 'rate-limited pin did not log a retry'; done
[[ $(last) == "$before" ]] || fail 'state moved during rate-limit retries'
auto_pin_pass > "$tmp/out" & pass=$!
sleep 1
kill -0 "$pass" 2>/dev/null || fail 'a fourth rate-limited pin did not wait'
[[ $(grep -Fc "$c12" "$PIN_CALLS") == 4 ]] || fail "rate-limit calls: $(tr '\n' ' ' < "$PIN_CALLS")"
! grep -q RATE-LIMIT-RETRY "$tmp/out" || fail 'a fourth rate-limited pin retried again'
c13=$(commit after-rate-limit)
wait "$pass" || fail 'rate-limit wait did not end after main advanced'
[[ $(last) == "$c12" ]] || fail "rate-limited commit was not skipped when main advanced: $(last)"
rm -f "$PIN_RC.rate"; : > "$PIN_CALLS"; echo 1 > "$PIN_RC"; c14=$(commit plain-failure)
auto_pin_pass > "$tmp/out" & pass=$!
wait_for_pin_calls "$c14" 1 || fail 'plain failure did not start its pin'
sleep 0.5
kill -0 "$pass" 2>/dev/null || fail 'a plain failure ended the wait'
! grep -q RATE-LIMIT-RETRY "$tmp/out" || fail 'a non-rate-limit failure was retried as a rate limit'
[[ $(grep -Fc "$c14" "$PIN_CALLS") == 1 ]] || fail 'a non-rate-limit failure retried'
c15=$(commit advance-after-plain-failure)
wait "$pass" || fail 'plain-failure wait did not end after main advanced'
echo 0 > "$PIN_RC"; auto_pin_pass > /dev/null
[[ $(last) == "$c15" ]] || fail "main advance after plain failure did not pin: $(last)"

# With no VectA head movement, a refusal waits and is not retried.
: > "$PIN_CALLS"; c8=$(commit vecta-stays-put); echo 1 > "$PIN_RC"
auto_pin_pass > "$tmp/out" & pass=$!
wait_for_pin_calls "$c8" 1 || fail 'unchanged-head case did not start its failed pin'
sleep 0.5
kill -0 "$pass" 2>/dev/null || fail 'a refusal with no VectA head move ended the wait'
[[ $(grep -Fc "$c8" "$PIN_CALLS") == 1 ]] || fail 'a refusal with no VectA head move retried'
c9=$(commit advance-main-after-vecta-wait)
wait "$pass" || fail 'unchanged-head wait did not end after main advanced'
[[ $(last) == "$c8" ]] || fail 'unchanged-head failure was not skipped when main advanced'
echo 0 > "$PIN_RC"
auto_pin_pass > /dev/null
[[ $(last) == "$c9" ]] || fail 'main advance after unchanged-head failure did not pin'

# A second failure at the same moved VectA head does not retry until that head changes again.
: > "$PIN_CALLS"; c10=$(commit vecta-second-failure); echo 1 > "$PIN_RC"
vecta_before=$(g -C "$tmp/agent/checkout" rev-parse HEAD)
auto_pin_pass > "$tmp/out" & pass=$!
wait_for_pin_calls "$c10" 1 || fail 'second-failure case did not start its first pin'
vecta_after=$(echo moved-again > "$tmp/agent/checkout/vecta-state"; g -C "$tmp/agent/checkout" add -A; g -C "$tmp/agent/checkout" commit -qm moved-again; g -C "$tmp/agent/checkout" rev-parse HEAD)
wait_for_pass_exit "$pass" || fail 'first VectA head move did not request a retry'
wait "$pass" || fail 'first VectA head retry signal returned non-zero'
grep -Fq "RETRY-VECTA-HEAD from=$vecta_before to=$vecta_after commit=$c10" "$tmp/out" || fail 'first VectA retry log did not name both heads'
auto_pin_pass > "$tmp/out" & pass=$!
wait_for_pin_calls "$c10" 2 || fail 'second failure at the moved head did not run'
sleep 0.5
kill -0 "$pass" 2>/dev/null || fail 'second failure at the same moved head retried again'
[[ $(grep -Fc "$c10" "$PIN_CALLS") == 2 ]] || fail 'same moved VectA head caused more than one retry'
c11=$(commit advance-main-after-second-failure)
wait "$pass" || fail 'second-failure wait did not end after main advanced'
[[ $(last) == "$c10" ]] || fail 'second failure was not skipped when main advanced'
echo 0 > "$PIN_RC"
auto_pin_pass > /dev/null
[[ $(last) == "$c11" ]] || fail 'main advance after second failure did not pin'

# A clone script that differs from the running copy ends the daemon after its pass, so systemd reinstalls it.
echo 0 > "$PIN_RC"
{ cat "$repo/tools/auto-pin.sh"; echo '# newer'; } > "$tmp/clone/tools/auto-pin.sh"
( auto_pin_main ) > "$tmp/out" 2>&1 & daemon=$!
for _ in {1..40}; do kill -0 "$daemon" 2>/dev/null || break; sleep 0.25; done
kill -0 "$daemon" 2>/dev/null && { kill "$daemon"; fail 'a daemon behind its clone kept running'; }
wait "$daemon" || fail 'the self-restart exit was not clean'
grep -q 'newer script' "$tmp/out" || fail "no self-restart line: $(cat "$tmp/out")"
# merge_override_pin: a base-only override move (clean three-way, pack copy byte-identical) has no pack file in the PR and must still merge
green_checks='[{"check_runs":[{"status":"completed","conclusion":"success"}]}]'
gh() { # stub of the REST reads: files from GH_FILES, check runs from GH_CHECKS (default green), the merge completes at once
  case "$*" in
    *"/files"*) printf '%s\n' "$GH_FILES" ;;
    *"--jq .head.sha"*) echo deadbeef ;;
    *"/check-runs"*) printf '%s\n' "${GH_CHECKS:-$green_checks}" ;;
    *"/status"*) echo 0 ;;
    *"pr merge"*) echo merged ;;
    *"--jq .merged"*) echo true ;;
    *) echo "gh stub: unexpected $*" >&2; return 1 ;;
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
# checks: a completed failing check refuses the merge; a pending check is not a failure
GH_FILES=$(printf '%s\n' .zenoforge/build.json .zenoforge/build/overrides.tsv)
GH_CHECKS='[{"check_runs":[{"status":"completed","conclusion":"failure"}]}]'
if merge_override_pin "$ovlog" > "$tmp/ov.out"; then fail 'an override PR with a failed check was merged'; fi
grep -q 'failed check' "$tmp/ov.out" || fail 'failed check was not named'
GH_CHECKS='[{"check_runs":[{"status":"in_progress","conclusion":null}]}]'
merge_override_pin "$ovlog" > "$tmp/ov.out" || fail "override PR with a pending check was refused: $(cat "$tmp/ov.out")"
unset GH_CHECKS
echo "auto-pin.test.sh: ok"
