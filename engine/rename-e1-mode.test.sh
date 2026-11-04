#!/usr/bin/env bash
# Exercise the actual feeder gate and slice runner using isolated gh replies.
set -euo pipefail
if [[ "${1:-}" == --race-only ]]; then
  exec bash "$(dirname "$0")/rename-e1-race.test.sh"
fi
source "$(dirname "$0")/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd -P)"
source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/issue-pipeline-slices.sh"

FEEDER_GATE="$(sed -n '/^if \[ -e "\$PAUSE_FILE" \]; then$/,/^\[ "\$MODE" = "off" \] \&\&/p' "$SCRIPT_DIR/issue-pipeline.sh")"
[[ "$FEEDER_GATE" == *'off, exiting without touching anything'* ]] || { echo 'not ok - feeder gate not found' >&2; exit 1; }
FAKE_VARIABLES="$test_env_root/variables.json"
FAKE_FAILURE=0
FAKE_JQ_FAILURE=0
REAL_JQ="$(command -v jq)"
FAKE_SEQUENCE=0
FAKE_SEQUENCE_FIRST="$test_env_root/sequence-first.json"
FAKE_SEQUENCE_SECOND="$test_env_root/sequence-second.json"
FAKE_SEQUENCE_COUNT="$test_env_root/sequence-count"
export FAKE_VARIABLES FAKE_FAILURE FAKE_JQ_FAILURE REAL_JQ FAKE_SEQUENCE FAKE_SEQUENCE_FIRST FAKE_SEQUENCE_SECOND FAKE_SEQUENCE_COUNT
STAGE_LOG="$test_env_root/stages"
export STAGE_LOG
# Run the real feeder through its decision gate, then stop the fixture before
# it can dispatch. Only the source directory and the post-gate sentinel differ.
FEEDER_FIXTURE="$test_env_root/feeder.sh"
awk '
  /^SCRIPT_DIR=/ { print "SCRIPT_DIR=\"$ZF_TEST_ENGINE_DIR\""; next }
  /^\[ "\$MODE" = "off" \] \&\&/ { print; print "echo feeder-dispatch-allowed"; print "exit 0"; next }
  { print }
' "$SCRIPT_DIR/issue-pipeline.sh" > "$FEEDER_FIXTURE"
export ZF_TEST_ENGINE_DIR="$SCRIPT_DIR"
mkdir -p "$test_env_root/repo" "$test_env_root/config/state"
printf '%s\n' '{"rulings":[{"id":"nonproduct-lane-routing","membership":{"labels":["pipeline-system"]}}]}' > "$test_env_root/config/state/rulings.json"
cat > "$test_env_bin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == 'variable list' ]]; then
  case "$FAKE_FAILURE" in
    auth) echo 'fixture authentication rejected' >&2; exit 4 ;;
    transport) echo 'fixture network connection reset' >&2; exit 1 ;;
  esac
  if [[ "$FAKE_SEQUENCE" == 1 ]]; then
    if [[ "$(cat "$FAKE_SEQUENCE_COUNT")" == 0 ]]; then
      printf 1 > "$FAKE_SEQUENCE_COUNT"; cat "$FAKE_SEQUENCE_FIRST"
    else cat "$FAKE_SEQUENCE_SECOND"; fi
  else cat "$FAKE_VARIABLES"; fi
elif [[ "$1 $2" == 'variable get' && "$3" == AGENT_PIPELINE ]]; then
  [[ " $* " != *' --json '* ]] || { echo 'unsupported get option' >&2; exit 1; }
  file="$FAKE_VARIABLES"
  [[ "$FAKE_SEQUENCE" != 1 ]] || file="$FAKE_SEQUENCE_SECOND"
  found="$("$REAL_JQ" -re '[.[] | select(.name == "AGENT_PIPELINE")][0].value // empty' "$file")" \
    || { echo 'variable AGENT_PIPELINE was not found' >&2; exit 1; }
  printf '%s\n' "$found"
else
  echo '[]'
fi
EOF
cat > "$test_env_bin/jq" <<'EOF'
#!/usr/bin/env bash
if [[ "$FAKE_JQ_FAILURE" == 1 && "$*" == *'def normalize:'* ]]; then
  echo 'fixture mode parse failure' >&2
  exit 2
fi
exec "$REAL_JQ" "$@"
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$test_env_bin/codex"
printf '#!/usr/bin/env bash\nexit 0\n' > "$test_env_bin/systemctl"
chmod +x "$test_env_bin/gh" "$test_env_bin/jq" "$test_env_bin/codex" "$test_env_bin/systemctl"
PATH="$test_env_bin:$PATH"
export PATH
hash -r
cat > "$test_env_root/stage" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$2" >> "$STAGE_LOG"
EOF
chmod +x "$test_env_root/stage"
gh() {
  if [[ "$1 $2" == 'variable get' && "$3" == AGENT_PIPELINE ]]; then
    [[ " $* " != *' --json '* ]] || { echo 'unsupported get option' >&2; return 1; }
    local file="$FAKE_VARIABLES" found
    [[ "$FAKE_SEQUENCE" != 1 ]] || file="$FAKE_SEQUENCE_SECOND"
    found="$("$REAL_JQ" -re '[.[] | select(.name == "AGENT_PIPELINE")][0].value // empty' "$file")" \
      || { echo 'variable AGENT_PIPELINE was not found' >&2; return 1; }
    printf '%s\n' "$found"
    return 0
  fi
  [[ "$1 $2" == 'variable list' ]] || { echo 'unexpected gh call' >&2; return 1; }
  case "$FAKE_FAILURE" in
    auth) echo 'fixture authentication rejected' >&2; return 4 ;;
    transport) echo 'fixture network connection reset' >&2; return 1 ;;
  esac
  if [[ "$FAKE_SEQUENCE" == 1 ]]; then
    if [[ "$(cat "$FAKE_SEQUENCE_COUNT")" == 0 ]]; then
      printf 1 > "$FAKE_SEQUENCE_COUNT"; cat "$FAKE_SEQUENCE_FIRST"
    else cat "$FAKE_SEQUENCE_SECOND"; fi
  else cat "$FAKE_VARIABLES"; fi
}
check_gmail_credential() { :; }
main_red_paused_discovery() { :; }
roadmap_switch_value() { echo false; }
roadmap_cache_path() { echo "$1.tree.json"; }

check_case() {
  local name="$1" old="$2" new="$3" expected="$4" pause="${5:-none}" error="${6:-0}" jq_error="${7:-0}"
  FAKE_JQ_FAILURE=0
  jq -cn --arg old "$old" --arg new "$new" \
    '[] + (if $old == "<missing>" then [] else [{name:"AGENT_PIPELINE",value:$old}] end)
        + (if $new == "<missing>" then [] else [{name:"AGENT_ZENOFORGE",value:$new}] end)' > "$FAKE_VARIABLES"
  FAKE_FAILURE="$error" FAKE_JQ_FAILURE="$jq_error"
  case "$pause" in
    none) rm -f "$PAUSE_FILE" ;;
    invalid) printf '{}\n' > "$PAUSE_FILE" ;;
    valid) printf '%s\n' '{"caller":"operator","reason":"fixture","issue":"1","provider":"test","model":"test","timestamp":"2026-01-01T00:00:00Z"}' > "$PAUSE_FILE" ;;
  esac
  : > "$STAGE_LOG"
  (
    PIPELINE_STAGE=triage
    ZF_RELEASE_TRAIN_DELEGATE=0
    eval "$FEEDER_GATE"$'\n''echo dispatched'
  ) > "$test_env_root/feeder.out" 2> "$test_env_root/feeder.err"
  if ! ZF_CONFIG_ROOT="$test_env_root/config" ZF_REPO_DIR="$test_env_root/repo" \
      ZF_ENGINE_DIR="$SCRIPT_DIR" ZF_PIPELINE_ROADMAP_SWITCH=false ZF_PIPELINE_SLICE_TICK=fixture \
      AGENT_DRY_RUN=1 bash "$FEEDER_FIXTURE" --stage triage 9>"$test_env_root/feeder.lock" \
      > "$test_env_root/real-feeder.out" 2> "$test_env_root/real-feeder.err"; then
    cat "$test_env_root/real-feeder.err" >&2
    echo "not ok - $name real feeder failed before its gate" >&2; exit 1
  fi
  run_pipeline_slices "$test_env_root/stage" 2> "$test_env_root/slices.err"
  local feeder=off real_feeder=off slices=off
  grep -qx dispatched "$test_env_root/feeder.out" && feeder=triage
  grep -qx feeder-dispatch-allowed "$test_env_root/real-feeder.out" && real_feeder=triage
  [[ -s "$STAGE_LOG" ]] && slices=triage
  [[ "$feeder" == "$expected" && "$real_feeder" == "$expected" && "$slices" == "$expected" ]] || {
    printf 'not ok - %s: feeder=%s real-feeder=%s slices=%s expected=%s\n' "$name" "$feeder" "$real_feeder" "$slices" "$expected" >&2
    cat "$test_env_root/feeder.err" "$test_env_root/real-feeder.err" "$test_env_root/slices.err" >&2
    exit 1
  }
  if [[ "$expected" == triage ]]; then
    [[ "$(cat "$STAGE_LOG")" == $'fastlane\ntriage\nadvisor\nrecut\nmaintenance' ]] || { echo "not ok - $name stage dispatch differs" >&2; exit 1; }
  fi
  if [[ "$old" != '<missing>' && "$pause" != valid && "$error" == 0 && "$jq_error" == 0 ]]; then
    grep -q 'legacy AGENT_PIPELINE read by feeder' "$test_env_root/feeder.err"
    grep -q 'legacy AGENT_PIPELINE read by slices' "$test_env_root/slices.err"
  fi
  if [[ "$pause" != valid && "$error" == 0 && "$jq_error" == 0 && ( "$old" == off || "$new" == off ) ]]; then
    grep -Eq 'repository mode (requests off|conflict or malformed)' "$test_env_root/feeder.err"
    grep -Eq 'repository mode (requests off|conflict or malformed)' "$test_env_root/slices.err"
  fi
  if [[ "$jq_error" == 1 ]]; then
    grep -q 'received invalid repository mode data; off' "$test_env_root/feeder.err" || { cat "$test_env_root/feeder.err" >&2; echo 'not ok - feeder parse failure diagnostic' >&2; exit 1; }
    grep -q 'received invalid repository mode data; off' "$test_env_root/slices.err" || { cat "$test_env_root/slices.err" >&2; echo 'not ok - slice parse failure diagnostic' >&2; exit 1; }
  fi
  if grep -q 'secret-mode-value' "$test_env_root/feeder.err" "$test_env_root/real-feeder.err" "$test_env_root/slices.err"; then
    echo 'not ok - mode value leaked to diagnostics' >&2; exit 1
  fi
  printf 'ok - %s\n' "$name"
}

if [[ "${1:-}" == --parse-only ]]; then
  check_case 'mode parse failure cannot hide legacy off' off triage off none 0 1
  exit 0
fi
check_case 'preferred-only triage' '<missing>' triage triage
for value in off triage implement release; do
  expected=triage; [[ "$value" == off ]] && expected=off
  check_case "legacy-only $value" "$value" '<missing>' "$expected"
  [[ "$value" == triage ]] || check_case "preferred-only $value" '<missing>' "$value" "$expected"
done
check_case 'both triage' triage triage triage
check_case 'equivalent normalized values' implement release triage
check_case 'both off' off off off
check_case 'legacy off dominates' off triage off
check_case 'preferred off dominates' triage off off
check_case 'both missing' '<missing>' '<missing>' off
check_case 'malformed legacy' secret-mode-value triage off
check_case 'malformed preferred' triage secret-mode-value off
check_case 'empty value' '' triage off
check_case 'ASCII whitespace normalizes consistently' $'im ple\tment' triage triage
check_case 'non-ASCII next-line stays invalid' '<missing>' $'tri\u0085age' off
check_case 'non-ASCII byte-order mark stays invalid' '<missing>' $'tri\ufeffage' off
check_case 'authentication failure' triage triage off none auth
check_case 'transport failure' triage triage off none transport
check_case 'mode parse failure cannot hide legacy off' off triage off none 0 1
for value in off triage implement release; do
  check_case "manual pause legacy-only $value" "$value" '<missing>' off valid
  check_case "manual pause preferred-only $value" '<missing>' "$value" off valid
done
check_case 'invalid pause with legacy name' triage '<missing>' triage invalid
check_case 'invalid pause with preferred name' '<missing>' triage triage invalid

# Corrupt or duplicated snapshots cannot be accepted as a partial valid read.
FAKE_FAILURE=0 FAKE_JQ_FAILURE=0
for corrupt in \
  '{bad-json' \
  '[{"name":"AGENT_PIPELINE","value":"triage"},{"name":"AGENT_PIPELINE","value":"off"}]' \
  $'[{"name":"AGENT_ZENOFORGE","value":"triage"}]\n[{"name":"AGENT_PIPELINE","value":"off"}]'; do
  printf '%s\n' "$corrupt" > "$FAKE_VARIABLES"
  [[ "$(read_zenoforge_mode malformed 2> "$test_env_root/malformed.err")" == off ]]
  grep -q 'received invalid repository mode data; off' "$test_env_root/malformed.err"
done
echo 'ok - malformed, duplicate and multiple-document snapshots stop dispatch'

# A paginated listing can combine an older legacy page with a newer preferred
# page. A direct legacy read after it must observe a stop before dispatching.
FAKE_FAILURE=0 FAKE_JQ_FAILURE=0 FAKE_SEQUENCE=1
printf '%s\n' '[{"name":"AGENT_PIPELINE","value":"off"},{"name":"AGENT_ZENOFORGE","value":"triage"}]' > "$FAKE_SEQUENCE_SECOND"
for initial in \
  '[{"name":"AGENT_PIPELINE","value":"triage"},{"name":"AGENT_ZENOFORGE","value":"triage"}]' \
  '[{"name":"AGENT_ZENOFORGE","value":"triage"}]'; do
  printf '%s\n' "$initial" > "$FAKE_SEQUENCE_FIRST"
  printf 0 > "$FAKE_SEQUENCE_COUNT"
  [[ "$(read_zenoforge_mode race 2> "$test_env_root/race.err")" == off ]]
  grep -q 'repository mode changed during read; off' "$test_env_root/race.err"
  printf 0 > "$FAKE_SEQUENCE_COUNT"
  : > "$STAGE_LOG"
  run_pipeline_slices "$test_env_root/stage" 2> "$test_env_root/race-slices.err"
  [[ ! -s "$STAGE_LOG" ]]
  grep -q 'repository mode changed during read; off' "$test_env_root/race-slices.err"
done
FAKE_SEQUENCE=0
echo 'ok - a legacy stop after a paginated listing blocks slices'

# The existing release-train delegation is the only stage allowed past PAUSE;
# it still cannot bypass either off switch.
check_delegate() {
  local name="$1" mode="$2" expected="$3"
  FAKE_JQ_FAILURE=0
  jq -cn --arg name "$name" --arg mode "$mode" '[{name:$name,value:$mode}]' > "$FAKE_VARIABLES"
  printf '%s\n' '{"caller":"operator","reason":"fixture","issue":"1","provider":"test","model":"test","timestamp":"2026-01-01T00:00:00Z"}' > "$PAUSE_FILE"
  FAKE_FAILURE=0
  ( PIPELINE_STAGE=release; ZF_RELEASE_TRAIN_DELEGATE=1; eval "$FEEDER_GATE"$'\n''echo "$MODE"' ) > "$test_env_root/delegate.out" 2> "$test_env_root/delegate.err"
  [[ "$(cat "$test_env_root/delegate.out")" == "$expected" ]] || { echo 'not ok - delegated release PAUSE gate' >&2; exit 1; }
  if ! ZF_CONFIG_ROOT="$test_env_root/config" ZF_REPO_DIR="$test_env_root/repo" \
      ZF_ENGINE_DIR="$SCRIPT_DIR" ZF_PIPELINE_ROADMAP_SWITCH=false ZF_PIPELINE_SLICE_TICK=fixture \
      ZF_RELEASE_TRAIN_DELEGATE=1 AGENT_DRY_RUN=1 bash "$FEEDER_FIXTURE" --stage release 9>"$test_env_root/feeder.lock" \
      > "$test_env_root/delegate-real.out" 2> "$test_env_root/delegate-real.err"; then
    cat "$test_env_root/delegate-real.err" >&2; echo 'not ok - delegated feeder failed' >&2; exit 1
  fi
  if [[ "$expected" == release ]]; then
    grep -qx feeder-dispatch-allowed "$test_env_root/delegate-real.out"
  else
    [[ ! -s "$test_env_root/delegate-real.out" ]]
  fi
  echo "ok - delegated release under PAUSE with $name $mode"
}
for name in AGENT_PIPELINE AGENT_ZENOFORGE; do
  check_delegate "$name" off ''
  for value in triage implement release; do check_delegate "$name" "$value" release; done
done
bash "$SCRIPT_DIR/rename-e1-race.test.sh"
echo 'rename-e1-mode.test.sh: PASS'
