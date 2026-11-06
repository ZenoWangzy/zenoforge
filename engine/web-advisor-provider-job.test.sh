#!/usr/bin/env bash
# A finished batch job wakes its harvest at once, and never in place of the tick's own gates.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d)"; trap 'rm -rf -- "$tmp"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
mkdir -p "$tmp/bin" "$tmp/home/live" "$tmp/jobs"
ln -s "$tmp/home/live" "$tmp/home/engine-live"
cat > "$tmp/bin/lease" <<'S'
#!/usr/bin/env bash
printf answer > "$JOB_DIR_UNDER_TEST/answer.txt"
printf '{"phase":"answered"}\n' > "$JOB_DIR_UNDER_TEST/state.json"
S
printf '#!/usr/bin/env bash\n[ "${TIMER_RC:-0}" = 0 ]\n' > "$tmp/bin/systemctl"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$RUN_LOG"\n[ "${RUN_RC:-0}" = 0 ]\n' > "$tmp/bin/systemd-run"
chmod +x "$tmp/bin/"*

run_job() { # job id, then env assignments
  local job="$1"; shift
  mkdir -p "$tmp/jobs/$job"; printf '%s\n' "$(( $(date +%s) + 600 ))" > "$tmp/jobs/$job/deadline"; printf q > "$tmp/jobs/$job/question.txt"
  : > "$tmp/run.log"
  env PATH="$tmp/bin:$PATH" AGENT_HOME="$tmp/home" WEB_ADVISOR_PROVIDER_JOB_DIR="$tmp/jobs" RUN_LOG="$tmp/run.log" \
    JOB_DIR_UNDER_TEST="$tmp/jobs/$job" ZF_CDP_BROWSER_LEASE_SCRIPT="$tmp/bin/lease" \
    ZF_WEB_ADVISOR_PROVIDER_UNIT_PREFIX=fx ZF_REPO_DIR=/repo ZF_CONFIG_ROOT=/repo/.zenoforge "$@" \
    bash "$here/web-advisor-provider-job.sh" "$job" ask.cjs topic 2> "$tmp/err"
}

run_job advisor-batch-1 || fail "a batch job must finish cleanly: $(cat "$tmp/err")"
[[ "$(cat "$tmp/jobs/advisor-batch-1/done")" == 0 ]] || fail 'done not written'
grep -q -- '--unit fx-advisor-batch ' "$tmp/run.log" || fail "wrong unit: $(cat "$tmp/run.log")"
grep -q -- "$tmp/home/live/run-advisor-batch.sh --poll-only --scheduled$" "$tmp/run.log" || fail "harvest must run the live engine, poll only: $(cat "$tmp/run.log")"
grep -q -- '-E ZF_ENGINE_DIR='"$tmp"'/home/live -E ZF_REPO_DIR=/repo -E ZF_CONFIG_ROOT=/repo/.zenoforge' "$tmp/run.log" || fail "unit env: $(cat "$tmp/run.log")"
grep -q 'harvest woken' "$tmp/err" || fail 'no wake line'

run_job advisor-batch-2 TIMER_RC=1 || fail 'a stopped timer must not fail the job'
[[ ! -s "$tmp/run.log" ]] || fail 'a stopped timer is a pause: no harvest may start'

run_job advisor-batch-3 RUN_RC=1 || fail 'a refused start must not fail the job'
grep -q 'the next tick harvests' "$tmp/err" || fail 'a refused start left no line'

run_job single-4 || fail 'a single job must finish cleanly'
[[ ! -s "$tmp/run.log" ]] || fail 'only a batch job wakes the batch wrapper'
echo "web-advisor-provider-job.test.sh: PASS"
