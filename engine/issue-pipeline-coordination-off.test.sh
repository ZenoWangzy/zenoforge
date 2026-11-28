#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REAL_GIT="$(command -v git)"
GUARD_BIN="$test_env_root/coord-off-bin"
GUARD_LOG="$test_env_root/coord-off-guard.log"
DISPATCH_LOG="$test_env_root/coord-off-dispatch.log"
REMOTE="$test_env_root/coord-off-origin.git"
REPO_DIR="$test_env_root/coord-off-worktree"
ISSUES="$test_env_root/coord-off-issues.json"
PROVIDER_SCRIPT="$test_env_root/coord-off-advisor-provider"
mkdir -p "$GUARD_BIN" "$REPO_DIR"
"$REAL_GIT" init --bare --quiet "$REMOTE"
"$REAL_GIT" -C "$REPO_DIR" init --quiet
"$REAL_GIT" -C "$REPO_DIR" remote add origin "$REMOTE"
cat > "$ISSUES" <<'JSON'
[{"number":991205,"title":"coordination off triage fixture","body":"fixture","state":"open","created_at":"2026-11-01T00:00:00Z","updated_at":"2026-11-02T00:00:00Z","labels":[{"name":"needs-triage"}],"user":{"login":"fixture"}},{"number":991206,"title":"coordination off recut fixture","body":"fixture","state":"open","created_at":"2026-11-01T00:00:00Z","updated_at":"2026-11-02T00:00:00Z","labels":[{"name":"needs-recut"}],"user":{"login":"fixture"}},{"number":991207,"title":"coordination off advisor fixture","body":"fixture","state":"open","created_at":"2026-11-01T00:00:00Z","updated_at":"2026-11-02T00:00:00Z","labels":[{"name":"needs-advisor"}],"user":{"login":"fixture"}}]
JSON
jq '.switches["roadmap-order"] = false | .roles.advisor.disabled = false' "$SCRIPT_DIR/model-policy.default.json" > "$AGENT_HOME/model-policy.json"
: > "$AGENT_HOME/codex-probe-passed"
printf '#!/usr/bin/env bash\nexit 0\n' > "$PROVIDER_SCRIPT"
chmod +x "$PROVIDER_SCRIPT"

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
set -euo pipefail
if [[ "${1:-}" == api && "${2:-}" == rate_limit ]]; then
  printf 'coordination rate-limit probe\n' >> "$ZF_COORD_TEST_GUARD_LOG"
  exit 99
fi
case "${1:-}:${2:-}" in
  variable:get)
    case "${3:-}" in
      AGENT_PIPELINE) printf 'triage\n' ;;
      AGENT_PHASE) printf '2\n' ;;
      *) exit 1 ;;
    esac
    ;;
  api:*)
    case "${2:-}" in
      *labels=needs-triage*) jq '[.[] | select(any(.labels[]?; .name == "needs-triage"))]' "$ZF_COORD_TEST_ISSUES_FILE" ;;
      *labels=needs-recut*) jq '[.[] | select(any(.labels[]?; .name == "needs-recut"))]' "$ZF_COORD_TEST_ISSUES_FILE" ;;
      *labels=needs-advisor*) jq '[.[] | select(any(.labels[]?; .name == "needs-advisor"))]' "$ZF_COORD_TEST_ISSUES_FILE" ;;
      *) printf '[]\n' ;;
    esac
    ;;
  issue:view)
    jq -r --argjson n "${3:-0}" '.[] | select(.number == $n) | .labels[]?.name' "$ZF_COORD_TEST_ISSUES_FILE"
    ;;
  issue:list) printf '[]\n' ;;
  *) exit 98 ;;
esac
SH
cat > "$GUARD_BIN/systemctl" <<'SH'
#!/usr/bin/env bash
case "${2:-}" in
  is-active) exit 1 ;;
  list-units) exit 0 ;;
  *) exit 1 ;;
esac
SH
cat > "$GUARD_BIN/systemd-run" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${*//$'\n'/ }" >> "$ZF_COORD_TEST_DISPATCH_LOG"
SH
cat > "$GUARD_BIN/codex" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$GUARD_BIN/curl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$GUARD_BIN/git" "$GUARD_BIN/gh" "$GUARD_BIN/systemctl" "$GUARD_BIN/systemd-run" "$GUARD_BIN/codex" "$GUARD_BIN/curl"

export ZF_COORD_TEST_REAL_GIT="$REAL_GIT" ZF_COORD_TEST_GUARD_LOG="$GUARD_LOG"
export ZF_COORD_TEST_DISPATCH_LOG="$DISPATCH_LOG" ZF_COORD_TEST_ISSUES_FILE="$ISSUES"
export PATH="$GUARD_BIN:$PATH"
export ZF_ENGINE_DIR="$SCRIPT_DIR" ZF_REPO_DIR="$REPO_DIR" ZF_CONFIG_ROOT="$SCRIPT_DIR" REPO_DIR
export ZF_REPO=fixture/repo ZF_PIPELINE_ROADMAP_SWITCH=false AGENT_DRY_RUN=0
export ZF_WEB_ADVISOR_PROVIDER_SCRIPT="$PROVIDER_SCRIPT"
unset ZF_COORD

run_stage() {
  local stage="$1"
  OUTPUT="$test_env_root/coord-off-$stage-pipeline.log"
  if ! bash "$SCRIPT_DIR/issue-pipeline.sh" --stage "$stage" > "$OUTPUT" 2>&1; then
    cat "$OUTPUT" >&2
    exit 1
  fi
}
run_stage triage
run_stage recut
run_stage advisor

worker_dispatch_count="$(grep -Ec 'run-(triage-batch|recut|advisor-batch)\.sh' "$DISPATCH_LOG" || true)"
if [[ "$worker_dispatch_count" != 3 ]]; then
  printf 'expected 3 issue worker dispatches, found %s\n' "$worker_dispatch_count" >&2
  cat "$DISPATCH_LOG" >&2
  for stage in triage recut advisor; do
    printf '%s stage output:\n' "$stage" >&2
    cat "$test_env_root/coord-off-$stage-pipeline.log" >&2
  done
  exit 1
fi
for expected in "$SCRIPT_DIR/run-triage-batch.sh --scheduled 991205" "$SCRIPT_DIR/run-recut.sh 991206" "$SCRIPT_DIR/run-advisor-batch.sh --scheduled 991207"; do
  if ! grep -Fq -- "$expected" "$DISPATCH_LOG"; then
    printf 'missing dispatch: %s\n' "$expected" >&2
    cat "$DISPATCH_LOG" >&2
    exit 1
  fi
done
if [[ -e "$AGENT_HOME/coord" ]]; then
  printf 'coordination state was created: %s\n' "$AGENT_HOME/coord" >&2
  exit 1
fi
if [[ -s "$GUARD_LOG" ]]; then
  printf 'remote coordination access was attempted:\n' >&2
  cat "$GUARD_LOG" >&2
  exit 1
fi
if [[ -n "$("$REAL_GIT" --git-dir="$REMOTE" for-each-ref refs/claims)" ]]; then
  printf 'remote claims were created\n' >&2
  exit 1
fi
printf 'issue-pipeline-coordination-off.test.sh: PASS\n'
