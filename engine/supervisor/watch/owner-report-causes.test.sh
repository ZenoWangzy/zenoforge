#!/usr/bin/env bash
# owner-report-causes.py on a temp dir with a stub material command, a stub worker and a stub systemctl.
# Never calls a real worker, never reads real logs, never writes outside the temp dir.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)/test-env.sh"
job="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/owner-report-causes.py"
fx="$test_env_root/oc"
mkdir -p "$fx/bin" "$fx/home" "$fx/snaps"
fail() { printf 'owner-report-causes.test.sh: %s\n' "$*" >&2; exit 1; }

# Stub material command: prints $OC_TEST_MATERIAL, or fails when it is "fail".
cat > "$fx/bin/mail.sh" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == material ]] || exit 2
[[ "$OC_TEST_MATERIAL" != fail ]] || exit 1
printf '%s\n' "$OC_TEST_MATERIAL"
EOF
# Stub worker: records its call, its environment and what it was given, then writes $OC_TEST_ROWS or fails or hangs.
cat > "$fx/bin/worker" <<'EOF'
#!/usr/bin/env bash
key="$1" work="$2" prompt="$3"
echo x >> "$OC_TEST_CALLS"
printf '%s\n' "${WORKER_BACKEND:-}" > "$OC_TEST_CALLS.backend"
ls "$work/snapshots" > "$OC_TEST_CALLS.snaps"
cp "$prompt" "$OC_TEST_CALLS.prompt"
cp "$work/material.json" "$OC_TEST_CALLS.material"
case "$OC_TEST_MODE" in
  fail) exit 1 ;;
  hang) sleep 120 ;;
  nofile) printf 'stub-tail-%s\n' $(seq 1 60); exit 0 ;;  # rc 0, nothing written (the 2026-11-08 run)
  retry) [[ "$(wc -l < "$OC_TEST_CALLS")" -ge 2 ]] || exit 0 ;;  # first run writes nothing, the second answers
esac
printf '%s' "$OC_TEST_ROWS" > "$work/causes.jsonl"
echo done
EOF
cat > "$fx/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OC_TEST_SYSTEMCTL_LOG"
EOF
chmod +x "$fx/bin/mail.sh" "$fx/bin/worker" "$fx/bin/systemctl"
for d in 2026-10-30 2026-10-31 2026-11-01 2026-11-02 2026-11-03 2026-11-04 2026-11-05 2026-11-06 2026-11-07 2026-11-08; do
  printf '{"schema":1,"day":"%s","at":1,"figures":{}}\n' "$d" > "$fx/snaps/$d.json"
done
printf 'not a snapshot\n' > "$fx/snaps/notes.txt"

run() { # <mode> <rows> <material> -> rc; fresh state and out dirs per case
  rm -rf "$fx/state" "$fx/out" "$fx"/calls*
  OC_TEST_MODE="$1" OC_TEST_ROWS="$2" OC_TEST_MATERIAL="$3" OC_TEST_CALLS="$fx/calls" OC_TEST_SYSTEMCTL_LOG="$fx/systemctl.log" \
    OC_STATE="$fx/state" OC_OUT_DIR="$fx/out" OC_WORKER="$fx/bin/worker" OC_MAIL="$fx/bin/mail.sh" OC_SYSTEMCTL="$fx/bin/systemctl" \
    AGENT_HOME="$fx/home" ZF_OWNER_REPORT_SNAPSHOT_DIR="$fx/snaps" OC_TIMEOUT="${OC_TIMEOUT_TEST:-60}" \
    python3 -I "$job" > "$fx/run.out" 2>&1
}
outfile() { ls "$fx"/out/owner-report-causes-*.json 2>/dev/null | head -n1; }

material='[{"line":"finished","label":"做完","now":"14 个","yesterday":"10 个","change":"多 4 个","scorecard_rows":[]},{"line":"stock","label":"做完等上线的需求","now":"3 个","yesterday":"2 个","change":"多 1 个","scorecard_rows":[]}]'
rows='{"line":"finished","cause":"合并队列停了九个小时","evidence":"~/scheduler.log: 41 merged lines the day before, 12 today","basis":"read"}
{"line":"stock","cause":"发版卡住了"}
{"line":"bogus","cause":"没有这一行","evidence":"~/x.log: 3 lines","basis":"read"}
not json'

# --- a normal run: the worker is Codex luna, gets the snapshots, only checked rows reach the file
run ok "$rows" "$material" || fail "normal run failed: $(cat "$fx/run.out")"
f="$(outfile)"
[[ -n "$f" ]] || fail 'no causes file written'
[[ "$f" =~ owner-report-causes-[0-9]{4}-[0-9]{2}-[0-9]{2}\.json$ ]] || fail "file name pattern: $f"
[[ "$(jq -r '.rows | length' "$f")" == 1 && "$(jq -r '.rows[0].line' "$f")" == finished ]] || fail 'only the row with evidence is kept'
[[ "$(jq -r '.rows[0].evidence' "$f")" == *scheduler.log* ]] || fail 'the kept row carries its evidence'
[[ "$(jq -r '.dropped | length' "$f")" == 3 ]] || fail 'the row without evidence, the unknown line and the broken line are dropped and listed'
[[ "$(jq -r '.dropped[].reason' "$f")" != *"@"* ]] || fail 'dropped reasons carry no row text'
[[ "$(cat "$fx/calls.backend")" == luna ]] || fail 'the worker is launched with WORKER_BACKEND=luna, never GLM'
grep -q 'causes.jsonl`) as your first\|Create it as your first command' "$fx/calls.prompt" || fail 'the prompt tells the worker to create the output file first'
[[ "$(wc -l < "$fx/calls")" == 1 ]] || fail 'one worker run'
[[ "$(wc -l < "$fx/calls.snaps")" == 8 ]] || fail 'the worker gets the last 8 snapshots only'
grep -q 'notes.txt' "$fx/calls.snaps" && fail 'a file that is not a snapshot is not copied'
[[ "$(jq -r 'length' "$fx/calls.material")" == 2 ]] || fail 'the worker gets the material changes'
grep -q 'Never open `notify.log`' "$fx/calls.prompt" || fail 'the prompt forbids the mail log and secrets'
[[ -n "$(ls "$fx"/state/*.md)" ]] || fail 'the run is logged'
echo 'ok - normal run'

# --- same day again: no second worker run, the file is left as it is
before="$(cat "$f")"
OC_TEST_MODE=ok OC_TEST_ROWS='' OC_TEST_MATERIAL="$material" OC_TEST_CALLS="$fx/calls" OC_TEST_SYSTEMCTL_LOG="$fx/systemctl.log" \
  OC_STATE="$fx/state" OC_OUT_DIR="$fx/out" OC_WORKER="$fx/bin/worker" OC_MAIL="$fx/bin/mail.sh" OC_SYSTEMCTL="$fx/bin/systemctl" \
  AGENT_HOME="$fx/home" ZF_OWNER_REPORT_SNAPSHOT_DIR="$fx/snaps" python3 -I "$job" > /dev/null
[[ "$(wc -l < "$fx/calls")" == 1 && "$(cat "$f")" == "$before" ]] || fail 'a second run the same day must not call the worker or rewrite the file'
echo 'ok - one file a day'

# --- nothing material: a file with no rows, and no worker run
run ok '' '[]' || fail "empty material failed: $(cat "$fx/run.out")"
[[ "$(jq -r '.rows | length' "$(outfile)")" == 0 && ! -e "$fx/calls" ]] || fail 'no material change means no worker run'
echo 'ok - no material change'

# --- a failed worker writes no file; so does unreadable material
run fail '' "$material" && fail 'a failed worker must fail the run'
[[ -z "$(outfile)" ]] || fail 'a failed worker writes no file'
run ok '' fail && fail 'unreadable material must fail the run'
[[ -z "$(outfile)" && ! -e "$fx/calls" ]] || fail 'unreadable material writes no file and starts no worker'
echo 'ok - failures write nothing'

# --- rc 0 with no causes.jsonl is a failure: one more run, the output tail in the run log, no file, rc 1
OC_TIMEOUT_TEST=300 run nofile '' "$material" && fail 'a worker that exits 0 without the file must fail the run'
[[ -z "$(outfile)" ]] || fail 'no file written when the worker left no causes.jsonl'
[[ "$(wc -l < "$fx/calls")" == 2 ]] || fail "the worker is retried once, not more"
log="$(cat "$fx"/state/*.md)"
[[ "$log" == *'no causes.jsonl written'* && "$log" == *stub-tail-60* && "$log" != *stub-tail-20* ]] || fail "the run log keeps the last 40 lines of the worker output: $log"
echo 'ok - missing causes file fails and keeps the tail'

# --- the retry can recover; an empty causes.jsonl is a real answer (nothing traced), not a failure
OC_TIMEOUT_TEST=300 run retry "$rows" "$material" || fail "retry run failed: $(cat "$fx/run.out")"
[[ "$(wc -l < "$fx/calls")" == 2 && "$(jq -r '.rows | length' "$(outfile)")" == 1 ]] || fail 'the second worker run is used'
run ok '' "$material" || fail 'an empty causes.jsonl must not fail the run'
[[ "$(jq -r '.rows | length' "$(outfile)")" == 0 && "$(wc -l < "$fx/calls")" == 1 ]] || fail 'an empty file means nothing traced, one worker run'
echo 'ok - retry and empty file'

# --- a worker that hangs is killed at the total timeout and its scopes are stopped (as memory-check does)
rm -f "$fx/systemctl.log"
OC_TIMEOUT_TEST=3 run hang '' "$material" && fail 'a hung worker must fail the run'
[[ -z "$(outfile)" ]] || fail 'a timed-out worker writes no file'
grep -q -- '--user stop luna-zc-owncause-.*\.scope' "$fx/systemctl.log" || fail "the worker scopes are stopped on timeout: $(cat "$fx/systemctl.log" 2>/dev/null)"
echo 'ok - timeout stops the worker and its scopes'
echo 'PASS owner-report-causes'
