#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
split_engine="$(cd -- "$test_env_root" && pwd -P)/engine-checkout/engine"
split_target="$(cd -- "$test_env_root" && pwd -P)/target-checkout"
split_origin="$(cd -- "$test_env_root" && pwd -P)/target-origin"
config_root="$split_target/.zenoforge"
agent_home="$(cd -- "$test_env_root" && pwd -P)/triage-agent-home"
fake_bin="$(cd -- "$test_env_root" && pwd -P)/fake-bin"
issue_number="$((90044000 + $$))"
fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }

copy_agent_library "$split_engine" run-triage.sh
mkdir -p "$split_engine/bin"
cp "$SCRIPT_DIR/bin/agent-sandbox-run" "$split_engine/bin/agent-sandbox-run"
mkdir -p "$config_root/prompts" "$agent_home/state" "$agent_home/night" "$fake_bin"
cp "$SCRIPT_DIR/prompts/triage.md" "$config_root/prompts/triage.md"
cp "$SCRIPT_DIR/prompts/triage.schema.json" "$config_root/prompts/triage.schema.json"
cp "$SCRIPT_DIR/prompts/agent-settings.json" "$config_root/prompts/agent-settings.json"
jq '.switches["roadmap-order"] = false | .roles.advisor.disabled = false' \
  "$SCRIPT_DIR/model-policy.default.json" > "$agent_home/model-policy.json"
printf '%s\n' '{"intake_priority":{"enabled":false}}' > "$config_root/night.json"

cat > "$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
case "${1:-} ${2:-}" in
  "issue view")
    jq -n --argjson n "$FAKE_ISSUE_NUMBER" --arg body "$FAKE_ISSUE_BODY" \
      '{number:$n,title:"triage split fixture",body:$body,author:{login:"fixture"},comments:[],createdAt:"2026-01-01T00:00:00Z",updatedAt:"2026-01-01T00:00:00Z",state:"OPEN",labels:[{name:"enhancement"}]}'
    ;;
  "variable get") printf '3\n' ;;
  *) printf '[]\n' ;;
esac
EOF
cat > "$fake_bin/codex" <<'EOF'
#!/usr/bin/env bash
last_message=""
while (($#)); do
  if [[ "$1" == --output-last-message && $# -ge 2 ]]; then
    last_message="$2"
    shift 2
  else
    shift
  fi
done
cat >/dev/null
printf '%s' "$FAKE_TRIAGE_STRUCTURED" > "$last_message"
printf 'tokens used\n1\n'
EOF
cat > "$fake_bin/gitnexus" <<'EOF'
#!/usr/bin/env bash
printf 'up-to-date\n'
EOF
cat > "$fake_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case " $* " in *' list-units '*) exit 0 ;; esac
exit 1
EOF
chmod +x "$fake_bin/gh" "$fake_bin/codex" "$fake_bin/gitnexus" "$fake_bin/systemctl"

git init -q --bare "$split_origin"
git -C "$split_origin" symbolic-ref HEAD refs/heads/main
git init -q -b main "$split_target"
git -C "$split_target" config user.email test@example.com
git -C "$split_target" config user.name Test
printf 'target seed\n' > "$split_target/seed.txt"
git -C "$split_target" add -A
git -C "$split_target" commit -q -m target-seed
git -C "$split_target" remote add origin "$split_origin"
git -C "$split_target" push -q -u origin main
target_head="$(git -C "$split_target" rev-parse HEAD)"
printf 'product_sha=%s\n' "$target_head" > "$(dirname -- "$split_engine")/BUILD-INFO"
mkdir -p "$split_target/.gitnexus"
jq -cn --arg sha "$target_head" --arg indexed "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{lastCommit:$sha,indexedAt:$indexed}' > "$split_target/.gitnexus/meta.json"

export PATH="$fake_bin:$PATH" AGENT_HOME="$agent_home" AGENT_MODEL="$MODEL_POLICY_TEST_WORK_IDENTITY"
export ZF_ENGINE_DIR="$split_engine" ZF_PACK_DIR="$split_engine" ZF_REPO_DIR="$split_target"
export ZF_CONFIG_ROOT="$config_root" ZF_PACK_REL=engine REPO=test/repo ZF_REPO=test/repo
export FAKE_GH_LOG="$agent_home/gh.log" FAKE_ISSUE_NUMBER="$issue_number"
export FAKE_ISSUE_BODY='A small fixture issue for the split-directory triage dry run.'
export FAKE_TRIAGE_STRUCTURED="$(jq -cn '{category:"enhancement",state:"ready-for-agent",risk_class:"P1",level:"L1",entry_surface:"Web",acceptor:"maintainer",brief_md:"Fixture verdict.",notes_md:"Fixture notes.",expected_packages:[],expected_paths:[],related:[],suspected_shared_cause:null,estimated_changed_lines:0,external_deliverable:{required:false,location:"",reason:""},advisor_reason:"none"}')"

run_status=0
if run_output="$(bash "$split_engine/run-triage.sh" --dry-run "$issue_number" 2>&1)"; then
  :
else
  run_status=$?
fi
[[ "$run_status" == 0 ]] || fail "split-directory triage --dry-run failed (rc=$run_status): $run_output"
[[ "$run_output" == *"issue: #$issue_number"* ]] || fail "split-directory dry run did not print the verdict: $run_output"
[[ "$run_output" == *"state: ready-for-agent"* ]] || fail "split-directory dry run did not apply the ready-for-agent gate: $run_output"
[[ ! -e "$split_target/engine" ]] || fail 'target checkout unexpectedly contains an engine directory'
[[ "$(git -C "$split_target" rev-parse HEAD)" == "$target_head" ]] || fail 'dry run changed the target checkout'
if grep -Eq '(^| )issue (edit|comment|close)( |$)|(^| )label create( |$)|--method POST|-X POST' "$FAKE_GH_LOG"; then
  fail "split-directory dry run performed GitHub writes: $(cat "$FAKE_GH_LOG")"
fi
[[ ! -e "$HOME/wt/triage-$issue_number" ]] || fail 'split-directory dry run left its triage worktree behind'
printf 'run-triage-split-layout.test.sh: PASS\n'
