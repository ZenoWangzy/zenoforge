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
[ "$(cut -f4,5,6 <<< "$row")" = $'api\trepos/o/r/issues/N/comments\t3' ] || fail "unexpected row: $row"
! grep -q secret-value "$t/calls.tsv" || fail 'an argument value reached the log'

"$dir/bin/gh" pr view 12 --json state < /dev/null > /dev/null || true
[ "$(tail -1 "$t/calls.tsv" | cut -f4,5)" = $'pr view\t' ] || fail "subcommand not recorded: $(tail -1 "$t/calls.tsv")"

# An outer timeout sends TERM to the shim; the shim must pass it on and reap the real gh before exiting.
"$dir/bin/gh" hang < /dev/null & shim=$!
read -r child < "$t/pid.fifo"
kill -TERM "$shim"; wait "$shim" || true
! kill -0 "$child" 2>/dev/null || fail 'the real gh outlived a TERM to the shim'
[ "$(tail -1 "$t/calls.tsv" | cut -f4)" = 'hang ' ] || fail 'a killed call was not logged'

python3 "$dir/summary.py" "$t/calls.tsv" | grep -q '^3 gh calls' || fail 'summary did not count the rows'
# Spike pass: a site failing >=50% this hour after a clean day alerts; a noisy-before site and a healthy busy site do not.
now=1800000000; ts() { date -u -d "@$1" +%FT%TZ; }
: > "$t/spike.tsv"
row() { printf '%s\tu\tc.sh\t%s\t\t%s\t5\n' "$(ts "$1")" "$2" "$3" >> "$t/spike.tsv"; }
for i in 1 2 3 4; do row $((now - 600 * i)) "pr view" 1; row $((now - 7200 * i)) "pr view" 0; done
for i in 1 2 3 4; do row $((now - 600 * i)) "issue list" 1; row $((now - 7200 * i)) "issue list" 1; done
for i in 1 2 3 4; do row $((now - 600 * i)) "run list" 0; done
[ "$(python3 "$dir/summary.py" spikes "$t/spike.tsv" "$now" | cut -f1)" = "c.sh pr view" ] || fail 'spike detection wrong'
echo 'gh-measure.test.sh: PASS'
