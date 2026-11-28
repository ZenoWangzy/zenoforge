#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fail() { echo "gh-cache.test.sh: $*" >&2; exit 1; }
t="$(mktemp -d)"; trap 'rm -rf -- "$t" "$test_env_root"' EXIT
cat > "$t/real-gh" <<'FAKE'
#!/usr/bin/env bash
echo x >> "$FAKE_CALLS"
for a in "$@"; do [[ "$a" != fail ]] || { echo 'boom' >&2; exit 1; }; done
echo "out-$(wc -l < "$FAKE_CALLS" | tr -d ' ')"
FAKE
chmod +x "$t/real-gh"
export ZF_GH_REAL="$t/real-gh" ZF_GH_MEASURE_FILE="$t/calls.tsv" FAKE_CALLS="$t/count"
unset ZF_GH_NO_CACHE ZF_GH_CACHE_TTL ZF_GH_CACHE_DIR GH_REPO
: > "$t/count"
cd "$t"
g() { "$dir/bin/gh" "$@" < /dev/null; }
calls() { wc -l < "$t/count" | tr -d ' '; }
state() { tail -1 "$t/calls.tsv" | cut -f9; }
expect_calls() { [ "$(calls)" = "$1" ] || fail "$2: expected $1 network calls, got $(calls)"; }

[ "$(g pr view 7 -R o/r)" = out-1 ] || fail 'first read output'
[ "$(state)" = miss ] || fail 'first read not logged as miss'
[ "$(g pr view 7 -R o/r)" = out-1 ] || fail 'second read not served from the cache'
[ "$(state)" = hit ] || fail 'second read not logged as hit'
[ "$(tail -1 "$t/calls.tsv" | cut -f9,10)" = $'hit\t6' ] || fail "hit row did not record cached body bytes: $(tail -1 "$t/calls.tsv")"
expect_calls 1 'repeat inside the TTL'
[ "$(tail -1 "$t/calls.tsv" | cut -f4,6)" = $'pr view\t0' ] || fail 'hit row lost its subcommand or exit code'
echo 'ok - repeat read inside the TTL makes no network call and logs hit'

g pr view 7 -R c/d > /dev/null
expect_calls 2 'other repository'
g pr view 8 -R o/r > /dev/null
expect_calls 3 'other argument'
echo 'ok - key covers repository and arguments'

g pr comment 7 -R o/r --body hi > /dev/null
g pr view 7 -R o/r > /dev/null
expect_calls 5 'read after a write'
echo 'ok - a write clears the cache'

for write in "api -X POST repos/o/r/issues" "api -XPOST repos/o/r/issues" "api --method=POST repos/o/r/issues" "api repos/o/r/issues -f title=x" "api repos/o/r/issues --field=title=x" "api repos/o/r/issues --input -" "api graphql" "issue edit 7" "pr merge 7" "run rerun 3"; do
  g issue view 7 -R o/r > /dev/null
  before="$(calls)"
  g $write > /dev/null
  g issue view 7 -R o/r > /dev/null
  [ "$(calls)" = $((before + 2)) ] || fail "write not clearing the cache: $write"
done
echo 'ok - every write form clears the cache'

before="$(calls)"
g api repos/o/r/issues > /dev/null
g api repos/o/r/issues > /dev/null
g api -X GET repos/o/r/issues/1 > /dev/null
g api --method get repos/o/r/issues/1 > /dev/null
expect_calls $((before + 3)) 'api GET'
before="$(calls)"
g api rate_limit > /dev/null; g api rate_limit > /dev/null
g api -H 'If-None-Match: W/"e"' repos/o/r/x > /dev/null; g api -H 'If-None-Match: W/"e"' repos/o/r/x > /dev/null
g pr checks 7 --watch > /dev/null; g pr checks 7 --watch > /dev/null
expect_calls $((before + 6)) 'uncacheable reads'
echo 'ok - api GET is cached; rate_limit, conditional and watch reads are not'

g pr view fail > /dev/null 2>&1 && fail 'failing call returned 0'
g pr view fail > /dev/null 2>&1 || true
before="$(calls)"
g pr view fail > /dev/null 2>&1 || true
expect_calls $((before + 1)) 'failed call'
[ "$(state)" = miss ] || fail 'failed call not logged as miss'
echo 'ok - a failed call is not cached'

g issue list -R o/r > /dev/null
before="$(calls)"
ZF_GH_NO_CACHE=1 g issue list -R o/r > /dev/null
ZF_GH_NO_CACHE=1 g issue list -R o/r > /dev/null
expect_calls $((before + 2)) 'bypass'
[ "$(state)" = miss ] || fail 'bypassed call not logged as miss'
ZF_GH_NO_CACHE=1 g issue close 7 -R o/r > /dev/null
g issue list -R o/r > /dev/null
expect_calls $((before + 4)) 'write under bypass'
echo 'ok - ZF_GH_NO_CACHE bypasses reads and a bypassed write still clears'

before="$(calls)"
ZF_GH_CACHE_TTL=0 g repo view o/r > /dev/null
ZF_GH_CACHE_TTL=0 g repo view o/r > /dev/null
expect_calls $((before + 2)) 'expired entry'
rm -f "$t"/gh-cache/*
ZF_GH_CACHE_TTL=9999 g run list -L 3 > /dev/null
[ "$(ls "$t/gh-cache" | wc -l | tr -d ' ')" = 1 ] || fail 'no cache entry written'
read -r exp < "$t"/gh-cache/*
[ "$exp" -le $(( $(date +%s) + 60 )) ] || fail "TTL not capped at 60 seconds: $exp"
echo 'ok - an expired entry refetches and the TTL is capped at 60 seconds'
echo 'gh-cache.test.sh: PASS'
