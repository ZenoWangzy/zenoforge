#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
unset LUNA_PRIORITY
# tools/auto-pin.sh: a pass pins main's newest commit (a batch is pinned once); a failed pin neither exits nor loops on the same commit.
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/auto-pin-test.XXXXXX"); trap 'kill $(jobs -p) 2>/dev/null || :; rm -rf -- "$tmp" "$test_env_root"' EXIT
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
git init -q --bare "$tmp/product-origin.git"
g -C "$tmp/product-origin.git" symbolic-ref HEAD refs/heads/main
git init -q "$tmp/agent/checkout"; g -C "$tmp/agent/checkout" checkout -q -b main
g -C "$tmp/agent/checkout" remote add origin "$tmp/product-origin.git"
mkdir -p "$tmp/agent/checkout/.zenoforge/build"
: > "$tmp/agent/checkout/.zenoforge/build/intended-changes.tsv"
printf '#!/usr/bin/env bash\necho converge >> "$PIN_CALLS"\n' > "$tmp/agent/checkout/.zenoforge/build/engine-sync.sh"; chmod +x "$tmp/agent/checkout/.zenoforge/build/engine-sync.sh"
mkdir -p "$tmp/agent/engine-live"; printf '#!/usr/bin/env bash\necho wrapper >> "$PIN_CALLS"\n' > "$tmp/agent/engine-live/engine-sync.sh"; chmod +x "$tmp/agent/engine-live/engine-sync.sh"
g -C "$tmp/agent/checkout" add -A; g -C "$tmp/agent/checkout" commit -qm baseline
g -C "$tmp/agent/checkout" push -q -u origin main; g -C "$tmp/agent/checkout" fetch -q origin main
g clone -q "$tmp/product-origin.git" "$tmp/product-writer"
product_commit() { echo "$1" > "$tmp/product-writer/product-state"; g -C "$tmp/product-writer" add -A; g -C "$tmp/product-writer" commit -qm "$1"; g -C "$tmp/product-writer" push -q origin main; g -C "$tmp/product-writer" rev-parse HEAD; }

export ZF_AUTO_PIN_HOME=$tmp/home AGENT_HOME=$tmp/agent ZF_AUTO_PIN_CLONE=$tmp/clone ZF_AUTO_PIN_IDLE_SECS=0 ZF_AUTO_PIN_RETRY_SECS=0.2 ZF_AUTO_PIN_RATE_SECS=0.1
export ZF_AUTO_PIN_PSI_FILE=$tmp/cpu-pressure ZF_AUTO_PIN_LOAD_WAIT_SECS=900
printf 'some avg10=0 avg60=0 avg300=0 total=1\n' > "$ZF_AUTO_PIN_PSI_FILE"
export PIN_CALLS=$tmp/calls PIN_RC=$tmp/rc
unset ZF_AUTO_PIN_PRODUCT_FETCH_SECS
REAL_GIT=$(command -v git); export REAL_GIT PRODUCT_FETCH_CALLS=$tmp/product-fetches AUTO_PIN_MAIN_FETCH_CALLS=$tmp/main-fetches
mkdir -p "$tmp/bin"; : > "$PRODUCT_FETCH_CALLS" "$AUTO_PIN_MAIN_FETCH_CALLS"
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/systemctl"; chmod +x "$tmp/bin/systemctl"
cat > "$tmp/bin/git" <<'STUB'
#!/usr/bin/env bash
if [[ "${1-}" == -C && "${2-}" == "$AGENT_HOME/checkout" && "${3-}" == fetch ]]; then
  echo fetch >> "$PRODUCT_FETCH_CALLS"
fi
if [[ "${1-}" == -C && "${2-}" == "$ZF_AUTO_PIN_CLONE" && "${3-}" == fetch ]]; then
  echo fetch >> "$AUTO_PIN_MAIN_FETCH_CALLS"
fi
exec "$REAL_GIT" "$@"
STUB
chmod +x "$tmp/bin/git"; PATH="$tmp/bin:$PATH"; export PATH
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
product_fetch_count() { wc -l < "$PRODUCT_FETCH_CALLS"; }
auto_pin_main_fetch_count() { wc -l < "$AUTO_PIN_MAIN_FETCH_CALLS"; }
wait_for_product_fetches() {
  local expected=$1
  for _ in {1..200}; do
    [[ $(product_fetch_count) -ge $expected ]] && return 0
    sleep 0.05
  done
  return 1
}
wait_for_main_fetches() {
  local expected=$1
  for _ in {1..200}; do
    [[ $(auto_pin_main_fetch_count) -ge $expected ]] && return 0
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
! grep -qx converge "$PIN_CALLS" || fail 'a successful pin called the VectA hook directly'
[[ $(tr '\n' ' ' < "$PIN_CALLS") == "$c2 $c4 wrapper " ]] || fail "calls: $(tr '\n' ' ' < "$PIN_CALLS")"
# a batch of three merges since the last pin is pinned once, at the newest (ruling zenoforge-batch-land-2026-11-08)
: > "$PIN_CALLS"; b1=$(commit batch1); b2=$(commit batch2); b3=$(commit batch3)
auto_pin_pass > /dev/null; [[ $(last) == "$b3" ]] || fail "batch pass did not pin the newest: $(last)"
[[ $(tr '\n' ' ' < "$PIN_CALLS") == "$b3 wrapper " ]] || fail "batch calls: $(tr '\n' ' ' < "$PIN_CALLS")"
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

# a pin refused for a missing intended-changes row is retried once the row it names lands (same path and hash), with no new main commit, and only once
row_path=state/rulings.json row_hash=sha256:6d6f5c0a1b2c
tsv=$tmp/agent/checkout/.zenoforge/build/intended-changes.tsv
cat > "$tmp/clone/tools/pin-vecta.sh" <<STUB
#!/usr/bin/env bash
echo "\$1" >> "\$PIN_CALLS"
echo "pin-vecta: add this row to intended-changes.tsv and rerun:"
printf '%s\t%s\t%s\n' '$row_path' 'engine pin changes resolved config' '$row_hash'
exit 1
STUB
: > "$PIN_CALLS"; c6=$(commit six)
printf 'other/file.json\tdeclared\tsha256:aaaaaaaaaaaa\n' > "$tsv"
auto_pin_pass > "$tmp/out" & pass=$!
sleep 1
kill -0 "$pass" 2>/dev/null || fail 'unrelated sha256 rows triggered a row retry'
[[ $(grep -c "$c6" "$PIN_CALLS") == 1 ]] || fail "unrelated row retried: $(tr '\n' ' ' < "$PIN_CALLS")"
printf 'other/file.json\tdeclared\tsha256:aaaaaaaaaaaa\n%s\tdeclared\t%s\n' "$row_path" "$row_hash" > "$tsv"
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

# A product origin/main move retries this main commit once, even when the checked-out product HEAD stays put.
: > "$PIN_CALLS"; c_product=$(commit product-main-wakeup); echo 1 > "$PIN_RC"
export ZF_AUTO_PIN_PRODUCT_FETCH_SECS=600; retry=2; rm -f "$product_fetch_time"
product_head_before=$(g -C "$tmp/agent/checkout" rev-parse origin/main)
vecta_head_before=$(g -C "$tmp/agent/checkout" rev-parse HEAD)
auto_pin_pass > "$tmp/out" & pass=$!
wait_for_pin_calls "$c_product" 1 || fail 'product-main case did not start its failed pin'
product_head_after=$(product_commit product-only-fix)
[[ $(g -C "$tmp/agent/checkout" rev-parse HEAD) == "$vecta_head_before" ]] || fail 'product publisher moved the checked-out VectA HEAD'
wait_for_pass_exit "$pass" || fail 'product origin/main move did not return to retry the same commit'
wait "$pass" || fail 'product-main retry signal returned non-zero'
grep -Fq "RETRY-PRODUCT-MAIN from=$product_head_before to=$product_head_after commit=$c_product" "$tmp/out" || fail 'product retry log did not name both heads'
[[ $(last) == "$c7" ]] || fail 'state moved before the product-main retry pinned'
# A restarted daemon fetches the same product head but the persisted marker prevents another retry.
export ZF_AUTO_PIN_PRODUCT_FETCH_SECS=0; retry=0.2
fetches_before=$(product_fetch_count)
(
  source "$repo/tools/auto-pin.sh"
  auto_pin_pass
) > "$tmp/restart-out" & pass=$!
wait_for_pin_calls "$c_product" 2 || fail 'restarted product-main pass did not run its pin'
wait_for_product_fetches "$((fetches_before + 1))" || fail 'restarted product-main pass did not fetch the same head'
sleep 0.5
kill -0 "$pass" 2>/dev/null || fail 'restarted pass retried the unchanged product head'
! grep -q RETRY-PRODUCT-MAIN "$tmp/restart-out" || fail 'restart retried the same product head again'
[[ $(grep -Fc "$c_product" "$PIN_CALLS") == 2 ]] || fail 'unchanged product head caused another pin'
c_product_next=$(commit after-product-wakeup)
wait "$pass" || fail 'same-product-head wait did not end after engine main advanced'
[[ $(last) == "$c_product" ]] || fail 'product-wakeup failure was not skipped when engine main advanced'
echo 0 > "$PIN_RC"; auto_pin_pass > /dev/null
[[ $(last) == "$c_product_next" ]] || fail 'engine main advance after product refusal did not pin'

# A refusal can retry for three changed product heads; a fourth head change waits for engine main.
: > "$PIN_CALLS"; c_product_cap=$(commit product-main-retry-cap); echo 1 > "$PIN_RC"
retry=1; export ZF_AUTO_PIN_PRODUCT_FETCH_SECS=0
for attempt in 1 2 3; do
  auto_pin_pass > "$tmp/product-cap-$attempt.out" & pass=$!
  wait_for_pin_calls "$c_product_cap" "$attempt" || fail "product retry cap attempt $attempt did not pin"
  cap_head=$(product_commit "product-cap-$attempt")
  wait_for_pass_exit "$pass" || fail "product retry cap attempt $attempt did not return on a changed head"
  wait "$pass" || fail "product retry cap attempt $attempt returned non-zero"
  grep -Fq "RETRY-PRODUCT-MAIN" "$tmp/product-cap-$attempt.out" || fail "product retry cap attempt $attempt did not log a wake"
done
auto_pin_pass > "$tmp/product-cap-fourth.out" & pass=$!
wait_for_pin_calls "$c_product_cap" 4 || fail 'fourth product-cap pin did not run'
fetches_before=$(product_fetch_count)
product_commit product-cap-four
wait_for_product_fetches "$((fetches_before + 1))" || fail 'fourth product head was not fetched'
sleep 0.2
kill -0 "$pass" 2>/dev/null || fail 'fourth product head change returned from the refusal wait'
! grep -q RETRY-PRODUCT-MAIN "$tmp/product-cap-fourth.out" || fail 'fourth product head change retried the pin'
[[ $(grep -Fc "$c_product_cap" "$PIN_CALLS") == 4 ]] || fail 'fourth product head change ran an extra pin'
[[ $(ls "$ZF_AUTO_PIN_HOME/auto-pin-logs/${c_product_cap:0:12}.log".product-main-*-retried 2>/dev/null | wc -l) == 3 ]] || fail 'product-main retry markers did not stop at three'
c_product_cap_next=$(commit after-product-retry-cap)
wait "$pass" || fail 'product retry cap wait did not end after engine main advanced'
[[ $(last) == "$c_product_cap" ]] || fail 'product retry cap failure was not skipped on engine main advance'
echo 0 > "$PIN_RC"; auto_pin_pass > /dev/null
[[ $(last) == "$c_product_cap_next" ]] || fail 'engine main advance after product retry cap did not pin'
retry=0.2; export ZF_AUTO_PIN_PRODUCT_FETCH_SECS=600

# The default 10-minute interval allows only one product fetch across repeated wait-loop passes.
unset ZF_AUTO_PIN_PRODUCT_FETCH_SECS; retry=0.2; rm -f "$product_fetch_time"
: > "$PIN_CALLS"; c_product_throttle=$(commit product-fetch-throttle); echo 1 > "$PIN_RC"
fetches_before=$(product_fetch_count)
main_fetches_before=$(auto_pin_main_fetch_count)
auto_pin_pass > "$tmp/product-throttle.out" & pass=$!
wait_for_pin_calls "$c_product_throttle" 1 || fail 'product throttle case did not start its failed pin'
wait_for_product_fetches "$((fetches_before + 1))" || fail 'product throttle case did not perform its first fetch'
wait_for_main_fetches "$((main_fetches_before + 3))" || fail 'product throttle case did not run two wait-loop passes'
[[ $(product_fetch_count) == $((fetches_before + 1)) ]] || fail 'product fetch ran more than once inside the throttle interval'
kill -0 "$pass" 2>/dev/null || fail 'product throttle case ended before engine main advanced'
! grep -q RETRY-PRODUCT-MAIN "$tmp/product-throttle.out" || fail 'unchanged product head woke the throttle case'
c_product_throttle_next=$(commit after-product-fetch-throttle)
wait "$pass" || fail 'product throttle wait did not end after engine main advanced'
[[ $(last) == "$c_product_throttle" ]] || fail 'throttle refusal was not skipped when engine main advanced'
echo 0 > "$PIN_RC"; auto_pin_pass > /dev/null
[[ $(last) == "$c_product_throttle_next" ]] || fail 'engine main advance after product throttle did not pin'

# A failed bounded fetch is logged once and cannot use a changed stale tracking ref to wake a retry.
export ZF_AUTO_PIN_PRODUCT_FETCH_SECS=600; retry=1; rm -f "$product_fetch_time"
product_origin_url=$(g -C "$tmp/agent/checkout" remote get-url origin)
product_bad_old=$(g -C "$tmp/agent/checkout" rev-parse origin/main)
product_bad_head=$(product_commit product-head-after-fetch-failure)
g -C "$tmp/agent/checkout" fetch -q origin main
g -C "$tmp/agent/checkout" update-ref refs/remotes/origin/main "$product_bad_old" || fail 'could not restore the old product tracking ref'
g -C "$tmp/agent/checkout" remote set-url origin "$tmp/missing-product-origin.git"
: > "$PIN_CALLS"; c_product_fetch_failed=$(commit product-fetch-failed); echo 1 > "$PIN_RC"
fetches_before=$(product_fetch_count)
auto_pin_pass > "$tmp/product-fetch-failed.out" & pass=$!
wait_for_pin_calls "$c_product_fetch_failed" 1 || fail 'bad-origin case did not start its failed pin'
for _ in {1..200}; do grep -q PIN-FAILED "$tmp/product-fetch-failed.out" && break; sleep 0.05; done
grep -q PIN-FAILED "$tmp/product-fetch-failed.out" || fail 'bad-origin pin failure was not recorded'
g -C "$tmp/agent/checkout" update-ref refs/remotes/origin/main "$product_bad_head" || fail 'could not stage a changed stale tracking ref'
wait_for_product_fetches "$((fetches_before + 1))" || fail 'bad-origin case did not attempt the product fetch'
sleep 0.2
[[ $(grep -c PRODUCT-FETCH-FAILED "$tmp/product-fetch-failed.out") == 1 ]] || fail 'failed product fetch did not log exactly one failure line'
! grep -q RETRY-PRODUCT-MAIN "$tmp/product-fetch-failed.out" || fail 'failed product fetch treated the stale ref change as a product wake'
kill -0 "$pass" 2>/dev/null || fail 'bad-origin failure did not remain waiting'
kill "$pass" 2>/dev/null || :; wait "$pass" 2>/dev/null || :
g -C "$tmp/agent/checkout" remote set-url origin "$product_origin_url"
g -C "$tmp/agent/checkout" fetch -q origin main
c_product_fetch_failed_next=$(commit after-product-fetch-failure)
echo 0 > "$PIN_RC"; auto_pin_pass > /dev/null
[[ $(last) == "$c_product_fetch_failed_next" ]] || fail 'engine main advance after failed product fetch did not pin'
retry=0.2

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

# With no VectA checkout or product origin/main movement, a refusal waits and is not retried.
: > "$PIN_CALLS"; c8=$(commit vecta-stays-put); echo 1 > "$PIN_RC"
product_unchanged=$(g -C "$tmp/agent/checkout" rev-parse origin/main)
auto_pin_pass > "$tmp/out" & pass=$!
wait_for_pin_calls "$c8" 1 || fail 'unchanged-head case did not start its failed pin'
sleep 0.5
kill -0 "$pass" 2>/dev/null || fail 'a refusal with no VectA head move ended the wait'
[[ $(grep -Fc "$c8" "$PIN_CALLS") == 1 ]] || fail 'a refusal with no VectA head move retried'
[[ $(g -C "$tmp/agent/checkout" rev-parse origin/main) == "$product_unchanged" ]] || fail 'product origin/main moved in the unchanged-head case'
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
export GH_HEAD_FILE=$tmp/gh-head GH_CALLS=$tmp/gh-calls
gh() { # stub of the REST reads and row PR landing
  echo "$*" >> "$GH_CALLS"
  case "$*" in
    *"pr create"*)
      local branch=''
      while (($#)); do
        if [[ $1 == --head ]]; then branch=${2-}; shift 2; else shift; fi
      done
      git -C "$AGENT_HOME/checkout" rev-parse "$branch" > "$GH_HEAD_FILE" || return 1
      echo 'https://github.com/ZenoWangzy/vecta/pull/42'
      ;;
    *"/files"*) printf '%s\n' "$GH_FILES" ;;
    *"--jq .head.sha"*) [[ ! -s $GH_HEAD_FILE ]] || cat "$GH_HEAD_FILE"; [[ -s $GH_HEAD_FILE ]] || echo deadbeef ;;
    *"/check-runs"*) printf '%s\n' "${GH_CHECKS:-$green_checks}" ;;
    *"/status"*) echo 0 ;;
    *"pr merge"*)
      if [[ -n ${GH_MERGE_TARGET_GIT:-} && -s $GH_HEAD_FILE ]]; then
        git --git-dir "$GH_MERGE_TARGET_GIT" update-ref refs/heads/main "$(cat "$GH_HEAD_FILE")" || return 1
      fi
      echo merged
      ;;
    *"--jq .merged"*) echo true ;;
    *) echo "gh stub: unexpected $*" >&2; return 1 ;;
  esac
}
# A reviewed refusal lands just its intended row as a VectA PR, then the next pass retries the same engine SHA.
git -C "$AGENT_HOME/checkout" checkout -q main
git -C "$AGENT_HOME/checkout" reset --hard -q origin/main
echo 0 > "$PIN_RC"
: > "$PIN_CALLS"
: > "$GH_CALLS"
: > "$GH_HEAD_FILE"
GH_MERGE_TARGET_GIT=$tmp/product-origin.git; export GH_MERGE_TARGET_GIT
GH_FILES=.zenoforge/build/intended-changes.tsv
ROW_PATH=state/rulings.json; export ROW_PATH
cat > "$tmp/clone/tools/pin-vecta.sh" <<'STUB'
#!/usr/bin/env bash
echo "$1" >> "$PIN_CALLS"
row_file="$AGENT_HOME/checkout/.zenoforge/build/intended-changes.tsv"
reason="auto: reviewed merge ${1:0:12}"
if awk -F'\t' -v p="$ROW_PATH" -v r="$reason" -v h="$1" '$1 == p && $2 == r && $3 == h { found = 1 } END { exit !found }' "$row_file"; then exit 0; fi
echo 'pin-vecta: add this row to intended-changes.tsv and rerun:' >&2
printf '%s\tengine pin %s changes resolved config\t%s\n' "$ROW_PATH" "${1:0:12}" "$1" >&2
exit 1
STUB
: > "$PIN_CALLS"
c_reviewed=$(commit reviewed-merge)
mkdir -p "$tmp/clone/.git/zenoforge-merge-pr"
jq -n --arg sha "$c_reviewed" '{sha:$sha,green:true,cli_exit_code:0,engine_shards:[range(0;8)|{shard:.,exit_code:0}]}' \
  > "$tmp/clone/.git/zenoforge-merge-pr/$c_reviewed.json"
mkdir -p "$ZF_AUTO_PIN_HOME/state/work"
date +%s > "$ZF_AUTO_PIN_HOME/auto-pin-product-fetch.last"
auto_pin_pass > "$tmp/reviewed.out" & pass=$!
for _ in {1..200}; do
  grep -q 'PIN-ROW-AUTO' "$tmp/reviewed.out" 2>/dev/null && break
  kill -0 "$pass" 2>/dev/null || break
  sleep 0.05
done
if kill -0 "$pass" 2>/dev/null; then kill "$pass" 2>/dev/null || :; wait "$pass" 2>/dev/null || :; fail 'reviewed row did not land and return for retry'; fi
wait "$pass" || fail 'reviewed row landing pass failed'
grep -Fq "PIN-ROW-AUTO ${c_reviewed:0:12} $ROW_PATH" "$tmp/reviewed.out" || fail 'reviewed merge did not log its auto-landed row'
expected_auto_row=$(printf '%s\tauto: reviewed merge %s\t%s' "$ROW_PATH" "${c_reviewed:0:12}" "$c_reviewed")
grep -Fqx "$expected_auto_row" "$AGENT_HOME/checkout/.zenoforge/build/intended-changes.tsv" || fail 'reviewed merge row was not landed with the required reason and SHA'
[[ $(grep -Fc "$c_reviewed" "$PIN_CALLS") == 1 ]] || fail 'row landing did not leave exactly one initial refused pin'
[[ $(last) != "$c_reviewed" ]] || fail 'row landing advanced auto-pin state before retry'
auto_pin_pass > "$tmp/reviewed-retry.out" || fail 'reviewed row retry failed'
[[ $(grep -Fc "$c_reviewed" "$PIN_CALLS") == 2 ]] || fail 'reviewed merge did not retry the same engine SHA'
[[ $(last) == "$c_reviewed" ]] || fail 'reviewed retry did not pin the refused SHA'
rm "$tmp/clone/.git/zenoforge-merge-pr/$c_reviewed.json"
printf 'pin 245 %s\n' "$c_reviewed" > "$ZF_AUTO_PIN_HOME/state/work/merge-lane-hold.txt"
reviewed_merge "$c_reviewed" || fail 'a lane hold pin line did not mark its engine SHA reviewed'

# Without either review marker, a refused row stays a hand step and creates no VectA PR.
: > "$PIN_CALLS"
: > "$GH_CALLS"
c_unreviewed=$(commit unreviewed-merge)
printf 'pin 245 %s\n' "$c_reviewed" > "$ZF_AUTO_PIN_HOME/state/work/merge-lane-hold.txt"
row_count_before=$(wc -l < "$AGENT_HOME/checkout/.zenoforge/build/intended-changes.tsv")
date +%s > "$ZF_AUTO_PIN_HOME/auto-pin-product-fetch.last"
auto_pin_pass > "$tmp/unreviewed.out" & pass=$!
wait_for_pin_calls "$c_unreviewed" 1 || fail 'unreviewed refusal did not start'
sleep 0.5
kill -0 "$pass" 2>/dev/null || fail 'unreviewed row refusal did not keep the hand step'
[[ ! -s $GH_CALLS ]] || fail "unreviewed refusal created a VectA PR: $(cat "$GH_CALLS")"
[[ $(wc -l < "$AGENT_HOME/checkout/.zenoforge/build/intended-changes.tsv") == "$row_count_before" ]] || fail 'unreviewed refusal wrote an intended row'
kill "$pass" 2>/dev/null || :; wait "$pass" 2>/dev/null || :
echo 0 > "$PIN_RC"
cat > "$tmp/clone/tools/pin-vecta.sh" <<'STUB'
#!/usr/bin/env bash
echo "$1" >> "$PIN_CALLS"; exit "$(cat "$PIN_RC" 2>/dev/null || echo 0)"
STUB
auto_pin_pass > /dev/null
[[ $(last) == "$c_unreviewed" ]] || fail 'unreviewed test cleanup did not restore normal pinning'
unset GH_MERGE_TARGET_GIT

# An existing engine-SHA row from anywhere in last..next is accepted, but one before last is not.
range_last=$(last)
c_range_old=$(commit row-range-old)
c_range_next=$(commit row-range-next)
g -C "$ZF_AUTO_PIN_CLONE" fetch -q origin main
row_log=$tmp/row-range.log; row_tsv=$tmp/row-range.tsv
printf 'pin-vecta: add this row to intended-changes.tsv and rerun:\n%s\tengine pin\t%s\n' "$ROW_PATH" "$c_range_next" > "$row_log"
printf '%s\thand row\t%s\n' "$ROW_PATH" "$c_range_old" > "$row_tsv"
row_named_declared "$row_log" "$row_tsv" "$range_last" "$c_range_next" || fail 'an older engine SHA in last..next was not accepted'
printf '%s\thand row\t%s\n' "$ROW_PATH" "$range_last" > "$row_tsv"
if row_named_declared "$row_log" "$row_tsv" "$range_last" "$c_range_next"; then fail 'an engine SHA before last was accepted'; fi
echo 0 > "$PIN_RC"; auto_pin_pass > /dev/null
[[ $(last) == "$c_range_next" ]] || fail 'engine-SHA range test cleanup did not finish pinning'

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

# High CPU pressure holds the pin until PSI avg60 falls below the bound.
export ZF_AUTO_PIN_PSI_FILE=$tmp/cpu-pressure ZF_AUTO_PIN_LOAD_WAIT_SECS=900
printf 'some avg10=58.21 avg60=75 avg300=55.02 total=1\n' > "$ZF_AUTO_PIN_PSI_FILE"
sleep() {
  if [[ ${1-} == 30 ]]; then command sleep 1; else command sleep "$@"; fi
}
: > "$PIN_CALLS"; c_psi_wait=$(commit psi-wait); auto_pin_pass > "$tmp/psi-wait.out" & pass=$!
for _ in {1..100}; do grep -q '^auto-pin: waiting, cpu psi avg60 75 > 60$' "$tmp/psi-wait.out" && break; sleep 0.05; done
grep -q '^auto-pin: waiting, cpu psi avg60 75 > 60$' "$tmp/psi-wait.out" || fail 'high CPU PSI did not log its wait'
[[ ! -s $PIN_CALLS ]] || fail 'pin ran before CPU PSI fell below the bound'
printf 'some avg10=38 avg60=38 avg300=38 total=1\n' > "$ZF_AUTO_PIN_PSI_FILE"
wait "$pass" || fail 'CPU PSI wait pass returned non-zero'
[[ $(grep -Fc "$c_psi_wait" "$PIN_CALLS") == 1 ]] || fail 'pin did not run once CPU PSI fell below the bound'
[[ $(grep -Fc 'auto-pin: waiting,' "$tmp/psi-wait.out") == 1 ]] || fail 'CPU PSI wait was logged more than once'
! grep -q 'auto-pin: load wait expired' "$tmp/psi-wait.out" || fail 'CPU PSI wait expired after pressure fell below the bound'

# Hotfix pins bypass the CPU PSI wait.
printf 'some avg10=75 avg60=75 avg300=75 total=1\n' > "$ZF_AUTO_PIN_PSI_FILE"
: > "$PIN_CALLS"; c_psi_hotfix=$(commit psi-hotfix); LUNA_PRIORITY=hotfix auto_pin_pass > "$tmp/psi-hotfix.out"
[[ $(grep -Fc "$c_psi_hotfix" "$PIN_CALLS") == 1 ]] || fail 'hotfix did not run at high CPU PSI'
! grep -q '^auto-pin: waiting,' "$tmp/psi-hotfix.out" || fail 'hotfix waited on CPU PSI'
unset -f sleep

# A zero wait bound logs expiry and still runs the pin at high CPU PSI.
export ZF_AUTO_PIN_LOAD_WAIT_SECS=0
printf 'some avg10=75 avg60=75 avg300=75 total=1\n' > "$ZF_AUTO_PIN_PSI_FILE"
: > "$PIN_CALLS"; c_psi_expired=$(commit psi-wait-expired); auto_pin_pass > "$tmp/psi-expired.out"
[[ $(grep -Fc "$c_psi_expired" "$PIN_CALLS") == 1 ]] || fail 'expired CPU PSI wait did not run the pin'
grep -q '^auto-pin: waiting, cpu psi avg60 75 > 60$' "$tmp/psi-expired.out" || fail 'expired CPU PSI wait did not log its wait'
grep -q '^auto-pin: load wait expired$' "$tmp/psi-expired.out" || fail 'expired CPU PSI wait did not log expiry'
echo "auto-pin.test.sh: ok"
