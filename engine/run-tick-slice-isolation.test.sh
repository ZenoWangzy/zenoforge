#!/usr/bin/env bash
# The slice-failure regression at the run-tick boundary. A real local bare
# origin keeps the launcher's checkout guard and timer post-step in the path.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
FIXTURE="$test_env_root/run-tick-slice-isolation"
ORIGIN="$FIXTURE/origin.git"
REPO="$FIXTURE/repo"
FAKE_BIN="$FIXTURE/bin"
STAGE_LOG="$FIXTURE/stages.log"
SYSTEMCTL_LOG="$FIXTURE/systemctl.log"
RUN_OUTPUT="$FIXTURE/run-tick.out"
RUN_STATUS=0
mkdir -p "$FIXTURE" "$FAKE_BIN"

cat > "$FAKE_BIN/gh" <<'GH'
#!/usr/bin/env bash
if [[ "${1:-}" == variable && "${2:-}" == get ]]; then
  echo observe
  exit 0
fi
exit 0
GH
cat > "$FAKE_BIN/systemctl" <<'SYSTEMCTL'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
exit 0
SYSTEMCTL
chmod +x "$FAKE_BIN/gh" "$FAKE_BIN/systemctl"

git init -q --bare "$ORIGIN"
git --git-dir="$ORIGIN" symbolic-ref HEAD refs/heads/main
git init -q -b main "$REPO"
git -C "$REPO" config user.name test
git -C "$REPO" config user.email test@example.invalid
mkdir -p "$REPO/engine/systemd" "$REPO/.zenoforge/systemd"
copy_agent_library "$REPO/engine" run-tick.sh issue-pipeline-slices.sh
cp "$SCRIPT_DIR/run-tick.sh" "$REPO/engine/run-tick.sh"
cp "$SCRIPT_DIR/issue-pipeline-slices.sh" "$REPO/engine/issue-pipeline-slices.sh"
cp "$SCRIPT_DIR/systemd/pipeline-timers.list" "$REPO/.zenoforge/systemd/pipeline-timers.list"
cat > "$REPO/engine/fake-stage-scheduler" <<'SCHEDULER'
#!/usr/bin/env bash
printf '%s\n' "$2" >> "$STAGE_LOG"
[[ "$2" != recut ]] || exit 1
exit 0
SCHEDULER
chmod +x "$REPO/engine/fake-stage-scheduler"
cat > "$REPO/engine/issue-pipeline.sh" <<'PIPELINE'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/config.sh"
source "$ZF_ENGINE_DIR/issue-pipeline-slices.sh"
REPO="${ZF_REPO:-example-maintainer/example-repo}"
gh() { printf 'triage\n'; }
check_gmail_credential() { :; }
manual_pause_is_valid() { return 1; }
roadmap_switch_value() { printf 'false\n'; }
roadmap_cache_path() { printf '%s.tree.json\n' "$1"; }
LOCK_FILE="$AGENT_HOME/slice.lock"
run_pipeline_slices "$ZF_ENGINE_DIR/fake-stage-scheduler"
PIPELINE
cat > "$REPO/engine/check-host-daemons.py" <<'PY'
#!/usr/bin/env python3
raise SystemExit(0)
PY
chmod +x "$REPO/engine/issue-pipeline.sh" "$REPO/engine/check-host-daemons.py"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m fixture
git -C "$REPO" remote add origin "$ORIGIN"
git -C "$REPO" push -q -u origin main

run_launcher() {
  set +e
  AGENT_HOME="$FIXTURE/agent-home" ZF_REPO_DIR="$REPO" \
    ZF_PACK_DIR="$REPO/engine" ZF_PACK_REL=engine ZF_REPO=example-maintainer/example-repo \
    ZF_AGENT_RECIPIENTS_FILE="$FIXTURE/recipients.json" \
    ZF_HOST_OPS_DIR="$FIXTURE/hostops" ZF_ENGINE_SYNC="$FIXTURE/no-engine-sync" \
    SYSTEMD_USER_UNIT_DIR="$FIXTURE/user-units" SYSTEMCTL_LOG="$SYSTEMCTL_LOG" STAGE_LOG="$STAGE_LOG" \
    AGENT_DRY_RUN=1 GIT_FETCH_TIMEOUT_SEC=5 PATH="$FAKE_BIN:$PATH" \
    bash "$REPO/engine/run-tick.sh" > "$RUN_OUTPUT" 2>&1
  RUN_STATUS=$?
  set -e
}

printf '%s\n' '{"founder_login":"testmaintainer","recipients":{"testmaintainer":"maintainer@example.invalid"}}' \
  > "$FIXTURE/recipients.json"
: > "$STAGE_LOG"
: > "$SYSTEMCTL_LOG"
run_launcher
[[ "$RUN_STATUS" == 0 ]] || { tail -n 40 "$RUN_OUTPUT" >&2; echo "not ok - isolated slice failure returned $RUN_STATUS" >&2; exit 1; }
grep -q 'issue-pipeline: slice failed stage=recut status=1; isolating this slice and continuing other stages' "$RUN_OUTPUT" \
  || { tail -n 40 "$RUN_OUTPUT" >&2; echo 'not ok - isolated slice failure was not reported as continuing' >&2; exit 1; }
grep -qx maintenance "$STAGE_LOG" \
  || { cat "$STAGE_LOG" >&2; echo 'not ok - maintenance slice did not run after recut failed' >&2; exit 1; }
grep -Fq -- '--user is-active --quiet zenoforge-agent.timer' "$SYSTEMCTL_LOG" \
  || { cat "$SYSTEMCTL_LOG" >&2; echo 'not ok - run-tick post-handoff timer checks did not run' >&2; exit 1; }
echo 'ok - one failed slice is isolated and run-tick post-steps complete'

before="$(wc -l < "$STAGE_LOG")"
git -C "$REPO" switch -q -c wrong-branch
run_launcher
[[ "$RUN_STATUS" == 1 ]] \
  || { tail -n 40 "$RUN_OUTPUT" >&2; echo "not ok - checkout integrity failure returned $RUN_STATUS" >&2; exit 1; }
grep -Fq 'not main' "$RUN_OUTPUT" \
  || { tail -n 40 "$RUN_OUTPUT" >&2; echo 'not ok - checkout integrity refusal did not name wrong branch' >&2; exit 1; }
[[ "$(wc -l < "$STAGE_LOG")" == "$before" ]] \
  || { echo 'not ok - issue pipeline ran after checkout integrity refusal' >&2; exit 1; }
echo 'ok - wrong-branch checkout still refuses before the scheduler handoff'
