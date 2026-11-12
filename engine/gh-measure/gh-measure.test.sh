#!/usr/bin/env bash
# gh measurement shim: passes stdin and the exit code through, logs no argument values,
# and a TERM from an outer timeout reaches the real gh instead of orphaning it.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fail() { echo "gh-measure.test.sh: $*" >&2; exit 1; }
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
cat > "$t/real-gh" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  hang) echo $$ > "$FAKE_PID_FIFO"; read -r _ < "$FAKE_HOLD_FIFO" ;;
  api)
    shift; path=""
    while (($#)); do
      case "$1" in
        -H|--header|-f|--raw-field|-F|--field) shift 2 ;;
        -i) shift ;;
        -*) shift ;;
        *) path="$1"; break ;;
      esac
    done
    case "$path" in
      */not-modified) printf 'HTTP/2 304 Not Modified\n'; exit 1 ;;
      */secondary) echo 'You have exceeded a secondary rate limit.' >&2; exit 1 ;;
      */rate) echo 'API rate limit exceeded' >&2; exit 1 ;;
      *) cat; exit 3 ;;
    esac ;;
  *) cat; exit 3 ;;
esac
FAKE
chmod +x "$t/real-gh"
mkfifo "$t/pid.fifo" "$t/hold.fifo"
export ZF_GH_REAL="$t/real-gh" ZF_GH_MEASURE_FILE="$t/calls.tsv" FAKE_PID_FIFO="$t/pid.fifo" FAKE_HOLD_FIFO="$t/hold.fifo"

out="$(printf 'body-from-stdin' | "$dir/bin/gh" api repos/o/r/issues/4061/comments --field body=secret-value)" && rc=0 || rc=$?
[ "$out" = body-from-stdin ] || fail "stdin not passed through: $out"
[ "$rc" = 3 ] || fail "exit code not passed through: $rc"
row="$(tail -1 "$t/calls.tsv")"
[ "$(cut -f4,5,6,8 <<< "$row")" = $'api\trepos/o/r/issues/N/comments\t3\tother' ] || fail "unexpected row: $row"
! grep -q secret-value "$t/calls.tsv" || fail 'an argument value reached the log'

"$dir/bin/gh" pr view 12 --json state < /dev/null > /dev/null || true
[ "$(tail -1 "$t/calls.tsv" | cut -f4,5,8)" = $'pr view\t\tother' ] || fail "subcommand not recorded: $(tail -1 "$t/calls.tsv")"

# Header and field values are not endpoints; error classes distinguish 304, secondary and primary limits.
for kind in not-modified secondary rate; do
  args=(-H 'If-None-Match: W/"etag/path"' -f 'field=/secret' -F 'raw=/private')
  [[ "$kind" != not-modified ]] || args+=(-i)
  "$dir/bin/gh" api "${args[@]}" "repos/o/r/issues/4061/$kind" >/dev/null 2>/dev/null || true
  expected="$kind"; [[ "$kind" != not-modified ]] || expected=304
  row="$(tail -1 "$t/calls.tsv")"
  [ "$(cut -f5,8 <<< "$row")" = "repos/o/r/issues/N/$kind$(printf '\t')$expected" ] || fail "classification/endpoint for $kind: $row"
done
"$dir/bin/gh" api -H '-i' repos/o/r/issues/4061/not-modified >/dev/null 2>/dev/null || true
[ "$(tail -1 "$t/calls.tsv" | cut -f8)" = other ] || fail 'a body beginning with an HTTP 304 line was classified without -i'
"$dir/bin/gh" api --header 'X-Test: value' --raw-field 'raw=value' --field 'field=value' repos/o/r/issues/4061/long-options >/dev/null 2>/dev/null || true
[ "$(tail -1 "$t/calls.tsv" | cut -f5)" = 'repos/o/r/issues/N/long-options' ] || fail 'a long option value was recorded as the endpoint'

# An outer timeout sends TERM to the shim; the shim must pass it on and reap the real gh before exiting.
"$dir/bin/gh" hang < /dev/null & shim=$!
read -r child < "$t/pid.fifo"
kill -TERM "$shim"; wait "$shim" || true
! kill -0 "$child" 2>/dev/null || fail 'the real gh outlived a TERM to the shim'
[ "$(tail -1 "$t/calls.tsv" | cut -f4,8)" = $'hang \tother' ] || fail 'a killed call was not logged'

summary="$(python3 "$dir/summary.py" "$t/calls.tsv")"
grep -q '^8 gh calls .*failed 7 (87.5%)' <<< "$summary" || fail "summary did not count rows and ignore the 304: $summary"
# Spike pass: a site failing >=50% this hour after a clean day alerts; a noisy-before site and a healthy busy site do not.
now=1800000000; ts() { date -u -d "@$1" +%FT%TZ; }
: > "$t/spike.tsv"
row() { printf '%s\tu\tc.sh\t%s\t\t%s\t5\n' "$(ts "$1")" "$2" "$3" >> "$t/spike.tsv"; }
for i in 1 2 3 4 5; do row $((now - 600 * i)) "pr view" 1; row $((now - 7200 * i)) "pr view" 0; done
row $((now - 300)) "pr view" 0
printf '%s\tu\tscheduler.sh\tapi\tGET\t1\t5\n' "$(ts "$((now - 300))")" >> "$t/spike.tsv"
printf '%s\tu\tscheduler.sh\tapi\trepos/o/r/issues/N/dependencies/blocked_by\t1\t5\t304\n' "$(ts "$((now - 300))")" >> "$t/spike.tsv"
for i in 1 2 3 4; do row $((now - 600 * i)) "issue list" 1; row $((now - 7200 * i)) "issue list" 1; done
for i in 1 2 3 4; do row $((now - 600 * i)) "run list" 0; done
for i in 1 2 3; do
  printf '%s\tu\tscheduler.sh\tapi\tIf-None-Match: W/"etag-%s"\t1\t5\n' "$(ts "$((now - 100 * i))")" "$i" >> "$t/spike.tsv"
done
spikes="$(python3 "$dir/summary.py" spikes "$t/spike.tsv" "$now")"
[ "$spikes" = $'c.sh pr view\t83%' ] || fail "spike detection wrong: $spikes"
python3 "$dir/summary.py" "$t/spike.tsv" > "$t/summary.out"
call_sites="$(sed -n '/^by call site:/,$p' "$t/summary.out")"
[ "$(grep -c 'scheduler.sh api If-None-Match$' <<< "$call_sites")" = 1 ] || fail 'call-site table did not normalize ETag headers'
echo 'gh-measure.test.sh: PASS'
