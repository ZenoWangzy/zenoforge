#!/usr/bin/env bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# The live scheduler runs as a systemd user service, and systemd ignores SIGPIPE for
# services: a consumer that stops reading early turns jq's failed write into an EPIPE
# error return (rc=2, "writing output failed: Broken pipe") instead of a silent
# SIGPIPE death. Mirror that here so the false-error path is exercised deterministically.
trap '' PIPE

fixture="$test_env_root/jqf-epipe"
A="$fixture/autopi"
LOG="$A/scheduler.log"
STAMP=2026-11-03T00:00:00Z
mkdir -p "$A/alerts"
: > "$LOG"

source "$script_dir/scheduler.d/core.sh"

# Far more rows than a pipe buffer, so jq is still writing when each consumer stops.
big_stream='range(0; 200000)'

# 1. A consumer that stops reading early (the `jqf | head -n` bound) must not log a jqf error.
rows="$(jqf -c -n "$big_stream" | head -20 || true)"
[[ "$(grep -c . <<<"$rows")" -eq 20 ]] || { echo 'not ok - jqf-epipe: bounded consumer read fewer rows than expected' >&2; exit 1; }
if grep -Fq 'jqf error' "$LOG"; then
  cat "$LOG" >&2
  echo 'not ok - jqf-epipe: a consumer that stops reading early logged a false jqf error' >&2
  exit 1
fi

# 2. The intake shape: a read loop that breaks once it has enough (register_new_issues
#    breaks at `added < want`), streaming from a producer that is still writing.
fifo="$fixture/rows.fifo"
rm -f -- "$fifo"
mkfifo "$fifo"
( jqf -c -n "$big_stream | {n:.}" > "$fifo" ) & producer=$!
n=0
while IFS= read -r row; do
  n=$((n + 1))
  (( n >= 3 )) && break
done < "$fifo"
wait "$producer" || true
[[ "$n" -eq 3 ]] || { echo "not ok - jqf-epipe: consumer broke after $n rows, expected 3" >&2; exit 1; }
if grep -Fq 'jqf error' "$LOG"; then
  cat "$LOG" >&2
  echo 'not ok - jqf-epipe: a read loop that breaks early logged a false jqf error' >&2
  exit 1
fi

# 3. A real jq failure must still be logged.
if jqf -e . <<< '{bad' >/dev/null 2>&1; then
  echo 'not ok - jqf-epipe: malformed JSON passed jqf' >&2
  exit 1
fi
grep -Fq 'jqf error' "$LOG" && grep -Fq 'jq: parse error' "$LOG" \
  || { cat "$LOG" >&2; echo 'not ok - jqf-epipe: a real parse error was not logged' >&2; exit 1; }

# 4. A write failure that is not a closed consumer (ENOSPC via /dev/full) must still be
#    logged: the suppression is for the exact EPIPE message and nothing broader.
: > "$LOG"
if jqf -c -n "$big_stream" > /dev/full 2>/dev/null; then
  echo 'not ok - jqf-epipe: writing to /dev/full should fail' >&2
  exit 1
fi
grep -Fq 'jqf error' "$LOG" && grep -Fq 'writing output failed: No space left on device' "$LOG" \
  || { cat "$LOG" >&2; echo 'not ok - jqf-epipe: a non-EPIPE write failure was not logged' >&2; exit 1; }

echo 'ok - jqf-epipe: early-stopping consumers stay silent; real jq failures still log'
