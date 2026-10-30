#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/call-profile.sh"
[[ "${ZF_PIPELINE_CALL_PROFILE_ENABLED:-0}" == 0 ]] || exit 1
if declare -F _call_profile_record >/dev/null; then
  echo 'unexpected function declaration' >&2
  exit 1
fi

isolated_scripts="$AGENT_HOME/isolated/engine"
copy_agent_library "$isolated_scripts"
env -u ZF_PIPELINE_CALL_PROFILE_FILE bash -euo pipefail -c '
  source "$1/lib.sh"
  [[ "${ZF_PIPELINE_CALL_PROFILE_ENABLED:-0}" == 0 ]]
  ! declare -F _call_profile_record >/dev/null
' _ "$isolated_scripts"

fake_bin="$AGENT_HOME/fake-bin"
mkdir -p "$fake_bin"
export CALL_PROFILE_TEST_COMMAND_LOG="$AGENT_HOME/commands.log"
cat > "$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
printf 'gh\n' >> "$CALL_PROFILE_TEST_COMMAND_LOG"
if [[ "${GH_DELAY_API:-}" == 1 && " $* " == *'repos/fixture/issues/slow '* ]]; then
  for ((delay_counter=0; delay_counter<200000; delay_counter++)); do :; done
fi
printf 'same\n'
EOF
cat > "$fake_bin/git" <<'EOF'
#!/usr/bin/env bash
printf 'git\n' >> "$CALL_PROFILE_TEST_COMMAND_LOG"
printf 'same\n'
EOF
cat > "$fake_bin/jq" <<'EOF'
#!/usr/bin/env bash
printf 'jq\n' >> "$CALL_PROFILE_TEST_COMMAND_LOG"
printf 'same\n'
EOF
cat > "$fake_bin/node" <<'EOF'
#!/usr/bin/env bash
printf 'node\n' >> "$CALL_PROFILE_TEST_COMMAND_LOG"
printf 'same\n'
EOF
cat > "$fake_bin/systemd-run" <<'EOF'
#!/usr/bin/env bash
printf 'systemd-run\n' >> "$CALL_PROFILE_TEST_COMMAND_LOG"
EOF
chmod +x "$fake_bin"/*
PATH="$fake_bin:$PATH"
export PATH

run_same_input() {
  gh issue list --repo fixture --limit 1
  git status --short
  jq -n '"fixture"'
  node -e 'process.stdout.write("fixture")'
}
dispatch_fixture() {
  guarded_write gh issue edit 42 --repo fixture --add-label ready-for-agent
}
record_fixture() {
  guarded_write gh issue comment 42 --repo fixture --body 'fixture body'
}
dispatch_unit_fixture() {
  guarded_write systemd-run --user --unit zf-triage-42 --collect true
}
graphql_query_fixture() {
  gh api graphql -f 'query=query { viewer { login } }'
}
dispatch_graphql_fixture() {
  gh api graphql -f 'query=mutation { closeIssue }'
}
dynamic_category_fixture() {
  local candidate_lane=product
  gh issue list --repo fixture --limit 1
  candidate_lane=pipeline-system
  gh issue list --repo fixture --limit 1
}

DRY_RUN=1 dispatch_fixture 2> "$AGENT_HOME/dispatch.before"
DRY_RUN=1 record_fixture 2> "$AGENT_HOME/record.before"
run_same_input > "$AGENT_HOME/before.out"
cp "$CALL_PROFILE_TEST_COMMAND_LOG" "$AGENT_HOME/before.calls"
rm -f "$CALL_PROFILE_TEST_COMMAND_LOG"

export ZF_PIPELINE_CALL_PROFILE_FILE="$AGENT_HOME/calls.tsv"
export ZF_CALL_PROFILE_TICK_ID=fixture-tick
export ZF_CALL_PROFILE_STAGE=triage
export ZF_CALL_PROFILE_SECTION=triage
export ZF_CALL_PROFILE_TICKET_CATEGORY=pipeline-system
source "$SCRIPT_DIR/call-profile.sh"
DRY_RUN=1 dispatch_fixture 2> "$AGENT_HOME/dispatch.after"
DRY_RUN=1 record_fixture 2> "$AGENT_HOME/record.after"
run_same_input > "$AGENT_HOME/after.out"
cp "$CALL_PROFILE_TEST_COMMAND_LOG" "$AGENT_HOME/after.calls"
cmp "$AGENT_HOME/before.out" "$AGENT_HOME/after.out"
cmp "$AGENT_HOME/before.calls" "$AGENT_HOME/after.calls"
cmp "$AGENT_HOME/dispatch.before" "$AGENT_HOME/dispatch.after"
cmp "$AGENT_HOME/record.before" "$AGENT_HOME/record.after"

DRY_RUN=0 dispatch_unit_fixture
graphql_query_fixture > /dev/null
dispatch_graphql_fixture > /dev/null
gh_timeout -k 1 1s issue list --repo fixture --limit 1 > /dev/null
ZF_CALL_PROFILE_TICK_ID=child-tick bash -c 'source "$1"; gh issue list --repo fixture --limit 1' _ "$SCRIPT_DIR/lib.sh" > /dev/null
unset ZF_CALL_PROFILE_TICKET_CATEGORY
dynamic_category_fixture > /dev/null
export ZF_CALL_PROFILE_TICKET_CATEGORY=pipeline-system
delayed_api_fixture() {
  GH_DELAY_API=1 gh api --method GET repos/fixture/issues/slow --body 'secret-body-must-not-appear'
}
delayed_api_fixture > /dev/null

summary="$(python3 "$SCRIPT_DIR/call-profile-summary.py" "$ZF_PIPELINE_CALL_PROFILE_FILE")"
grep -Fq $'section-v2\tfixture-tick\ttriage\ttriage\tpipeline-system\tgh\tapi-read\tcall-profile.test.sh:delayed_api_fixture:' <<< "$summary"
grep -Fq $'pipeline-system\tgh\tdispatch-write\tcall-profile.test.sh:dispatch_fixture:' <<< "$summary"
grep -Fq $'pipeline-system\tgh\trecord-write\tcall-profile.test.sh:record_fixture:' <<< "$summary"
grep -Fq $'pipeline-system\tgh\tapi-read\tcall-profile.test.sh:delayed_api_fixture:' <<< "$summary"
grep -Fq $'pipeline-system\tsystemd-run\tdispatch-write\tcall-profile.test.sh:dispatch_unit_fixture:' <<< "$summary"
grep -Fq $'pipeline-system\tgh\tapi-read\tcall-profile.test.sh:graphql_query_fixture:' <<< "$summary"
grep -Fq $'pipeline-system\tgh\tdispatch-write\tcall-profile.test.sh:dispatch_graphql_fixture:' <<< "$summary"
grep -Fq $'pipeline-system\tgit\texternal-read\tcall-profile.test.sh:run_same_input:' <<< "$summary"
grep -Fq $'pipeline-system\tjq\tlocal\tcall-profile.test.sh:run_same_input:' <<< "$summary"
grep -Fq $'pipeline-system\tnode\tlocal\tcall-profile.test.sh:run_same_input:' <<< "$summary"
grep -Fq $'section-v2\tfixture-tick\ttriage\ttriage\tproduct\tgh\tapi-read\tcall-profile.test.sh:dynamic_category_fixture:' <<< "$summary"
grep -Fq $'section-v2\tfixture-tick\ttriage\ttriage\tpipeline-system\tgh\tapi-read\tcall-profile.test.sh:dynamic_category_fixture:' <<< "$summary"
grep -Fq $'section-v2\tchild-tick\ttriage\ttriage\tpipeline-system\tgh\tapi-read\t' <<< "$summary"
if grep -Eq 'secret-body|fixture/issues/slow|--body' "$ZF_PIPELINE_CALL_PROFILE_FILE"; then
  echo 'unexpected match' >&2
  exit 1
fi

delayed_ms="$(awk -F '\t' '$7 == "api-read" && $8 ~ /delayed_api_fixture/ { if ($12 > max) max=$12 } END { print max+0 }' <<< "$summary")"
(( delayed_ms >= 1 )) || { printf 'delayed API attributed with only %sms\n' "$delayed_ms" >&2; exit 1; }
same_input_calls="$(wc -l < "$AGENT_HOME/before.calls")"
printf 'ok - same-input commands/results unchanged (%s calls before and after); delayed API attributed to callsite (%sms)\n' \
  "$same_input_calls" "$delayed_ms"
