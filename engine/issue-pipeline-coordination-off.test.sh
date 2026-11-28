#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PIPELINE_SRC="$SCRIPT_DIR/issue-pipeline.sh"
REAL_GIT="$(command -v git)"
REAL_GH="$(command -v gh || true)"
GUARD_BIN="$test_env_root/coord-off-bin"
GUARD_LOG="$test_env_root/coord-off-guard.log"
REMOTE="$test_env_root/coord-off-origin.git"
REPO_DIR="$test_env_root/coord-off-worktree"
mkdir -p "$GUARD_BIN" "$REPO_DIR"
"$REAL_GIT" init --bare --quiet "$REMOTE"
"$REAL_GIT" -C "$REPO_DIR" init --quiet
"$REAL_GIT" -C "$REPO_DIR" remote add origin "$REMOTE"

cat > "$GUARD_BIN/git" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "$arg" == */coord/repo.git ]]; then
    printf 'coordination clone access\n' >> "$ZF_COORD_TEST_GUARD_LOG"
    exit 99
  fi
done
exec "$ZF_COORD_TEST_REAL_GIT" "$@"
SH
cat > "$GUARD_BIN/gh" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == api && "${2:-}" == rate_limit ]]; then
  printf 'coordination rate-limit probe\n' >> "$ZF_COORD_TEST_GUARD_LOG"
  exit 99
fi
if [[ -n "${ZF_COORD_TEST_REAL_GH:-}" ]]; then
  exec "$ZF_COORD_TEST_REAL_GH" "$@"
fi
exit 127
SH
chmod +x "$GUARD_BIN/git" "$GUARD_BIN/gh"
export ZF_COORD_TEST_REAL_GIT="$REAL_GIT" ZF_COORD_TEST_REAL_GH="$REAL_GH"
export ZF_COORD_TEST_GUARD_LOG="$GUARD_LOG"
export PATH="$GUARD_BIN:$PATH"
export ZF_ENGINE_DIR="$SCRIPT_DIR" ZF_REPO_DIR="$REPO_DIR" REPO_DIR
unset ZF_COORD
source "$SCRIPT_DIR/lib.sh"

eval "$(sed -n '/^pipeline_claim_clear() {/,/^}/p; /^pipeline_claim_begin() {/,/^}/p; /^pipeline_claim_drop() {/,/^}/p; /^pipeline_claim_keep() {/,/^}/p; /^pipeline_batch_claim_acquire() {/,/^}/p; /^pipeline_batch_claim_drop() {/,/^}/p; /^pipeline_batch_claim_keep() {/,/^}/p; /^pipeline_batch_launch() {/,/^}/p; /^dispatch() {/,/^}/p; /^dispatch_advisor_batch() {/,/^}/p; /^dispatch_triage_batch() {/,/^}/p' "$PIPELINE_SRC")"

UNIT_PREFIX_TRANSIENT=zf
TRIAGE_RUNTIME_MAX_SEC=60
RECUT_RUNTIME_MAX_SEC=60
ADVISOR_RUNTIME_MAX_SEC=60
IMPLEMENT_RUNTIME_MAX_SEC=60
RELEASE_RUNTIME_MAX_SEC=60
ZF_BATCH_SLICE=zf-batch.slice
DRY_RUN=0
PIPELINE_CLAIM_KEY=''
PIPELINE_CLAIM_OWNER=''
PIPELINE_CLAIM_UNIT=''
PIPELINE_CLAIM_STAGE=''
DISPATCH_COUNT=0

pipeline_live_worker_check() { return 1; }
pipeline_scheduler_unit_inflight() { return 1; }
pipeline_advisor_issue_skip_inflight() { return 1; }
hand_agent_issue_is_live_owned() { return 1; }
ensure_issue_roadmap_parent_for_dispatch() { return 0; }
issue_spend_budget_status() { printf 'clear\t0\t0\n'; }
model_config_fault_blocked() { return 1; }
model_policy() { [[ "${1:-}" == identity ]] && printf 'codex:fixture\n'; }
codex_week_stopped() { return 1; }
agent_memory_floor_allows() { return 0; }
zf_advisor_batch_runner() { printf '%s\n' "$SCRIPT_DIR/run-advisor-batch.sh"; }
consume_unit_memory_oom() { return 1; }
state_read() { printf '%s\n' '{"unit_memory_ooms":{}}'; }
systemctl() {
  case "${2:-}" in
    is-active) return 1 ;;
    list-units) return 0 ;;
  esac
  return 1
}
quarantine_canary_scope_list_for_stage() { :; }
quarantine_mark_stage_dispatch_canaries() { :; }
record_env_fault() { return 1; }
guarded_write() {
  [[ "${1:-}" == systemd-run ]] || return 98
  for arg in "$@"; do
    [[ "$arg" != ZF_COORD_RUN* && "$arg" != ZF_COORD_KEY* && "$arg" != ZF_COORD_OWNER* ]] || return 97
  done
  DISPATCH_COUNT=$((DISPATCH_COUNT + 1))
}

for entry in 'triage 991201' 'recut 991202' 'advisor 991203'; do
  read -r stage issue <<< "$entry"
  dispatch "$stage" "$issue"
done
TRIAGE_RUNTIME_MAX_SEC=60
TRIAGE_CAP=8
ADVISOR_RUNTIME_MAX_SEC=60
NEEDS_ADVISOR_IDS=991206
dispatch_triage_batch 991205
dispatch_advisor_batch
stage_unit_active triage 991204 && { printf 'unexpected active issue\n' >&2; exit 1; }

[[ "$ZF_COORD" == off ]]
[[ "$DISPATCH_COUNT" == 5 ]]
[[ ! -e "$AGENT_HOME/coord" ]]
[[ ! -s "$GUARD_LOG" ]]
rm -f "$AGENT_HOME"/triage-batch-active*.json
[[ -z "$("$REAL_GIT" --git-dir="$REMOTE" for-each-ref refs/claims)" ]]
printf 'issue-pipeline-coordination-off.test.sh: PASS\n'
