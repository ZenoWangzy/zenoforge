#!/usr/bin/env bash
# Routing of triage between Codex and Claude haiku, keyed on codex_week_stopped (codex-budget.sh). The stop snapshot is read from
# $AGENT_HOME/codex-quota.json, so this also pins that the wrappers resolve AGENT_HOME the same way the scheduler does.
# Over the stop: the batch runner and run-triage.sh call only claude-haiku-5-5, reserve no Codex budget, and apply the result
# through the same path. Under the stop: Codex runs and Claude does not.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(mktemp -d)"
ZF_CONFIG_ROOT="$TEST_ROOT/repo/.zenoforge"
mkdir -p "$ZF_CONFIG_ROOT/prompts"
cp "$SCRIPT_DIR"/prompts/{triage.md,triage.schema.json,agent-settings.json} "$ZF_CONFIG_ROOT/prompts/"
export ZF_CONFIG_ROOT
export AGENT_HOME="$TEST_ROOT/agent"
export ZF_REPO_DIR="$TEST_ROOT/repo"
export REPO="test/repo" ZF_REPO="test/repo"
unset CODEX_QUOTA_SNAPSHOT_FILE
mkdir -p "$HOME/wt" "$AGENT_HOME/state" "$AGENT_HOME/night"
jq -n '{founder_login:"maintainer"}' > "$AGENT_HOME/recipients.json"
for n in 920101 920102 920103 920104; do
  [ ! -e "$HOME/wt/triage-$n" ] || { echo "refusing to overwrite $HOME/wt/triage-$n" >&2; exit 2; }
done

FAILED=0
cleanup() {
  if [ -e "$ZF_REPO_DIR/.git" ]; then
    while IFS= read -r worktree; do
      case "$worktree" in "$HOME/wt/triage-batch-run-"*|"$HOME/wt/triage-9201"*) git -C "$ZF_REPO_DIR" worktree remove --force "$worktree" >/dev/null 2>&1 || true ;; esac
    done < <(git -C "$ZF_REPO_DIR" worktree list --porcelain | sed -n 's/^worktree //p')
  fi
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT
assert_eq() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1 (expected [$2], got [$3])"; FAILED=1; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then echo "ok - $1"; else echo "not ok - $1 (expected to find [$3])"; FAILED=1; fi; }

FIXTURE_ORIGIN="$TEST_ROOT/origin.git"
mkdir -p "$ZF_REPO_DIR"
git init -q --bare "$FIXTURE_ORIGIN"
git --git-dir="$FIXTURE_ORIGIN" symbolic-ref HEAD refs/heads/main
git -C "$ZF_REPO_DIR" init -q -b main
git -C "$ZF_REPO_DIR" config user.email test@example.com
git -C "$ZF_REPO_DIR" config user.name Test
printf 'seed\n' > "$ZF_REPO_DIR/seed.txt"
git -C "$ZF_REPO_DIR" add seed.txt
git -C "$ZF_REPO_DIR" commit -q -m seed
git -C "$ZF_REPO_DIR" remote add origin "$FIXTURE_ORIGIN"
git -C "$ZF_REPO_DIR" push -q -u origin main
mkdir -p "$ZF_REPO_DIR/.gitnexus" "$ZF_REPO_DIR/engine/state"
jq -n --arg sha "$(git -C "$ZF_REPO_DIR" rev-parse HEAD)" '{lastCommit:$sha}' > "$ZF_REPO_DIR/.gitnexus/meta.json"
cp "$SCRIPT_DIR/state/rulings.json" "$ZF_REPO_DIR/engine/state/rulings.json"
mkdir -p "$ZF_REPO_DIR/.agents/skills/triage" && : > "$ZF_REPO_DIR/.agents/skills/triage/SKILL.md"
# Roadmap admission is covered by roadmap-order.test.sh.
jq '.switches["roadmap-order"] = false' "$SCRIPT_DIR/model-policy.default.json" > "$AGENT_HOME/model-policy.json"

FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"
export FAKE_GH_LOG="$TEST_ROOT/gh.log" FAKE_CODEX_ARGS="$TEST_ROOT/codex-args.log" FAKE_CLAUDE_ARGS="$TEST_ROOT/claude-args.log"
export FAKE_CODEX_OUTPUT="$TEST_ROOT/codex-output.ndjson" FAKE_CLAUDE_RESULT="$TEST_ROOT/claude-result.ndjson" FAKE_CLAUDE_STRUCTURED="$TEST_ROOT/claude-structured.json"
cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "issue view") jq -n --argjson n "$3" '{number:$n,title:"fixture",body:"fixture body",author:{login:"testuser"},comments:[],createdAt:"2026-01-01T00:00:00Z",updatedAt:"2026-01-01T00:00:00Z",state:"OPEN",labels:[{name:"needs-triage"},{name:"enhancement"}]}' ;;
  "issue list") echo '[]' ;;
  "label list") printf '%s\n' needs-triage needs-info ready-for-agent ready-for-human needs-owner duplicate finish-first wontfix needs-advisor needs-recut awaiting-release awaiting-pipeline-sync awaiting-pipeline-health released concluded bug enhancement founder-test ;;
  "variable get") echo 3 ;;
  "pr list") echo '[]' ;;
  "api "*) if [[ "${2:-}" == repos/test/repo/issues/*/sub_issues?per_page=100 ]]; then echo '[]'; else exit 1; fi ;;
  "issue edit"|"issue comment"|"issue close"|"label create") printf '%s\n' "$*" >> "$FAKE_GH_LOG" ;;
esac
exit 0
EOF
cat > "$FAKE_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
[[ " $* " == *" list-units "* ]] && exit 0
exit 1
EOF
cat > "$FAKE_BIN/gitnexus" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = analyze ] && exit 1
echo up-to-date
EOF
cat > "$FAKE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_CODEX_ARGS"
out=""
while [ "$#" -gt 0 ]; do case "$1" in --output-last-message) out="$2"; shift 2 ;; *) shift ;; esac; done
cat > /dev/null
cp "$FAKE_CODEX_OUTPUT" "$out"
exit 0
EOF
cat > "$FAKE_BIN/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_CLAUDE_ARGS"
cat > /dev/null
if [[ " $* " == *" --json-schema "* ]]; then
  jq -nc --slurpfile so "$FAKE_CLAUDE_STRUCTURED" '{type:"result",is_error:false,result:"",structured_output:$so[0],total_cost_usd:0.01}'
else
  jq -nc --rawfile r "$FAKE_CLAUDE_RESULT" '{type:"result",is_error:false,result:$r,total_cost_usd:0.01}'
fi
EOF
chmod +x "$FAKE_BIN"/*
export PATH="$FAKE_BIN:$PATH" ZF_GCLOUD_BIN=/nonexistent/gcloud

VALID="$(jq -nc '{category:"enhancement",state:"ready-for-agent",risk_class:"P1",level:"L1",entry_surface:"Web /chat/",acceptor:"maintainer",advisor_reason:"none",brief_md:"Summary: fixture.",notes_md:"No questions.",expected_packages:["packages/react-example"],expected_paths:[],estimated_changed_lines:10,external_deliverable:{required:false,location:"",reason:""}}')"
printf '%s\n' "$VALID" > "$FAKE_CLAUDE_STRUCTURED"
for n in 920101 920102 920103 920104; do jq -nc --argjson issue "$n" --argjson result "$VALID" '{issue:$issue,result:$result}'; done > "$FAKE_CODEX_OUTPUT"
for n in 920101 920103; do jq -nc --argjson issue "$n" --argjson result "$VALID" '{issue:$issue,result:$result}'; done > "$FAKE_CLAUDE_RESULT"
export CODEX_WEEK_STOP_PCT=100
week() { jq -n --argjson p "$1" --argjson r "$(( $(date +%s) + 3600 ))" '{week_pct:$p,week_reset:$r}' > "$AGENT_HOME/codex-quota.json"; }

# Over the stop: batch runner. Codex is never called; the haiku result applies through run-triage.sh --batch-result.
week 100
: > "$FAKE_CODEX_ARGS"; : > "$FAKE_CLAUDE_ARGS"; : > "$FAKE_GH_LOG"
OUT="$(bash "$SCRIPT_DIR/run-triage-batch.sh" --scheduled 920101 2>&1)" || { echo "not ok - batch over the stop exits 0"; FAILED=1; }
assert_eq "batch over the stop makes no Codex call" 0 "$(wc -l < "$FAKE_CODEX_ARGS" | tr -d ' ')"
assert_eq "batch over the stop makes one Claude call" 1 "$(wc -l < "$FAKE_CLAUDE_ARGS" | tr -d ' ')"
assert_contains "batch Claude call uses haiku" "$(cat "$FAKE_CLAUDE_ARGS")" '--model claude-haiku-5-5'
assert_eq "batch haiku result is applied" ready-for-agent "$(jq -r '.state' "$AGENT_HOME/state/920101.json")"

# Over the stop: single-issue run-triage.sh parses the haiku structured output like Codex output.
: > "$FAKE_CODEX_ARGS"; : > "$FAKE_CLAUDE_ARGS"; : > "$FAKE_GH_LOG"
OUT="$(bash "$SCRIPT_DIR/run-triage.sh" 920102 2>&1)" || { echo "not ok - run-triage over the stop exits 0"; FAILED=1; }
assert_eq "run-triage over the stop makes no Codex call" 0 "$(wc -l < "$FAKE_CODEX_ARGS" | tr -d ' ')"
assert_contains "run-triage Claude call uses haiku and the triage schema" "$(cat "$FAKE_CLAUDE_ARGS")" '--model claude-haiku-5-5'
assert_contains "run-triage Claude call is schema-constrained" "$(cat "$FAKE_CLAUDE_ARGS")" '--json-schema'
assert_eq "run-triage haiku verdict is applied" ready-for-agent "$(jq -r '.state' "$AGENT_HOME/state/920102.json")"

# Under the stop: Codex runs, Claude does not.
week 50
: > "$FAKE_CODEX_ARGS"; : > "$FAKE_CLAUDE_ARGS"
OUT="$(bash "$SCRIPT_DIR/run-triage-batch.sh" --scheduled 920103 2>&1)" || { echo "not ok - batch under the stop exits 0"; FAILED=1; }
assert_eq "batch under the stop calls Codex once" 1 "$(wc -l < "$FAKE_CODEX_ARGS" | tr -d ' ')"
assert_eq "batch under the stop makes no Claude call" 0 "$(wc -l < "$FAKE_CLAUDE_ARGS" | tr -d ' ')"

[ "$FAILED" -eq 0 ] || exit 1
echo "ALL PASS"
