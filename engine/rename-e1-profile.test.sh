#!/usr/bin/env bash
# Profile input and enabled-state aliases through the real consumers.
set -euo pipefail
source "$(dirname "$0")/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname "$0")" && pwd -P)"
fake_bin="$test_env_root/profile-bin"
mkdir -p "$fake_bin"
PROFILE_REAL_DATE="$(command -v date)"
export PROFILE_REAL_DATE
cat > "$fake_bin/date" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == '-u +%Y%m%dT%H%M%SZ' ]]; then echo 20260101T000000Z; else exec "$PROFILE_REAL_DATE" "$@"; fi
EOF
cat > "$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == 'variable list' ]]; then
  printf '%s\n' '[{"name":"AGENT_ZENOFORGE","value":"triage"}]'
elif [[ "$1 $2" == 'variable get' && "$3" == AGENT_PIPELINE ]]; then
  [[ " $* " != *' --json '* ]] || { echo 'unsupported get option' >&2; exit 1; }
  echo 'variable AGENT_PIPELINE was not found' >&2; exit 1
else
  printf '%s\n' '[]'
fi
EOF
cat > "$fake_bin/systemd-run" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$test_env_root/stage" <<'EOF'
#!/usr/bin/env bash
printf '%s:%s\n' "$2" "${ZF_CALL_PROFILE_STAGE:-disabled}" >> "$PROFILE_STAGE_LOG"
EOF
chmod +x "$fake_bin/gh" "$fake_bin/date" "$fake_bin/systemd-run" "$test_env_root/stage"
export PATH="$fake_bin:$PATH"

profile_case() (
  local name="$1" file_case="$2" flag_case="$3" expected="$4"
  local dest="$AGENT_HOME/secret-profile-target-$name.tsv"
  unset ZF_CALL_PROFILE_FILE ZF_PIPELINE_CALL_PROFILE_FILE ZF_CALL_PROFILE_ENABLED ZF_PIPELINE_CALL_PROFILE_ENABLED
  ZF_CALL_PROFILE_TICK_ID=fixture-tick
  export ZF_CALL_PROFILE_TICK_ID
  case "$file_case" in
    legacy) ZF_PIPELINE_CALL_PROFILE_FILE="$dest"; export ZF_PIPELINE_CALL_PROFILE_FILE ;;
    preferred) ZF_CALL_PROFILE_FILE="$dest"; export ZF_CALL_PROFILE_FILE ;;
    both) ZF_CALL_PROFILE_FILE="$dest"; ZF_PIPELINE_CALL_PROFILE_FILE="$dest"; export ZF_CALL_PROFILE_FILE ZF_PIPELINE_CALL_PROFILE_FILE ;;
    old-empty) ZF_PIPELINE_CALL_PROFILE_FILE=''; export ZF_PIPELINE_CALL_PROFILE_FILE ;;
    new-empty) ZF_CALL_PROFILE_FILE=''; export ZF_CALL_PROFILE_FILE ;;
    both-empty) ZF_CALL_PROFILE_FILE=''; ZF_PIPELINE_CALL_PROFILE_FILE=''; export ZF_CALL_PROFILE_FILE ZF_PIPELINE_CALL_PROFILE_FILE ;;
    different) ZF_CALL_PROFILE_FILE="$dest"; ZF_PIPELINE_CALL_PROFILE_FILE="$dest.other"; export ZF_CALL_PROFILE_FILE ZF_PIPELINE_CALL_PROFILE_FILE ;;
    old-empty-new) ZF_CALL_PROFILE_FILE="$dest"; ZF_PIPELINE_CALL_PROFILE_FILE=''; export ZF_CALL_PROFILE_FILE ZF_PIPELINE_CALL_PROFILE_FILE ;;
    new-empty-old) ZF_CALL_PROFILE_FILE=''; ZF_PIPELINE_CALL_PROFILE_FILE="$dest"; export ZF_CALL_PROFILE_FILE ZF_PIPELINE_CALL_PROFILE_FILE ;;
  esac
  source "$SCRIPT_DIR/lib.sh" || exit 1
  PATH="$fake_bin:$PATH"
  export PATH
  hash -r
  [[ "$ZF_CALL_PROFILE_ENABLED" == "$expected" && "$ZF_PIPELINE_CALL_PROFILE_ENABLED" == "$expected" ]] || {
    echo "not ok - $name initialization flags" >&2; exit 1;
  }
  case "$flag_case" in
    legacy) unset ZF_CALL_PROFILE_ENABLED; ZF_PIPELINE_CALL_PROFILE_ENABLED=1 ;;
    preferred) unset ZF_PIPELINE_CALL_PROFILE_ENABLED; ZF_CALL_PROFILE_ENABLED=1 ;;
    disabled) ZF_PIPELINE_CALL_PROFILE_ENABLED=0; ZF_CALL_PROFILE_ENABLED=0 ;;
    conflict) ZF_PIPELINE_CALL_PROFILE_ENABLED=1; ZF_CALL_PROFILE_ENABLED=0 ;;
  esac
  source "$SCRIPT_DIR/issue-pipeline-slices.sh" || exit 1
  check_gmail_credential() { :; }
  manual_pause_is_valid() { return 1; }
  roadmap_switch_value() { echo false; }
  roadmap_cache_path() { echo "$1.tree.json"; }
  PROFILE_STAGE_LOG="$test_env_root/stages-$name"
  export PROFILE_STAGE_LOG
  LOCK_FILE="$test_env_root/lock-$name"
  gh issue list --repo fixture --limit 1 >/dev/null || exit 1
  dispatch_fixture() { DRY_RUN=1 guarded_write gh issue edit 42 --repo fixture --add-label ready-for-agent; }
  dispatch_fixture || exit 1
  dispatch_unit_fixture() { DRY_RUN=0 guarded_write systemd-run --user --unit zf-triage-42 --collect true; }
  dispatch_unit_fixture || exit 1
  run_pipeline_slices "$test_env_root/stage" || exit 1
  if [[ "$expected" == 1 && "$flag_case" != disabled && "$flag_case" != conflict ]]; then
    [[ -s "$dest" ]] || { echo "not ok - $name produced no records" >&2; exit 1; }
    awk -F '\t' 'BEGIN { OFS="\t" } { $10="<duration>"; print }' "$dest" | sort > "$test_env_root/records-$name" || exit 1
    awk -F '\t' '$7 == "gh" && $8 == "api-read" { found=1 } END { exit !found }' "$dest" || exit 1
    awk -F '\t' '$7 == "gh" && $8 == "dispatch-write" { found=1 } END { exit !found }' "$dest" || exit 1
    awk -F '\t' '$7 == "systemd-run" && $8 == "dispatch-write" { found=1 } END { exit !found }' "$dest" || exit 1
    [[ "$(cat "$PROFILE_STAGE_LOG")" == $'fastlane:fastlane\ntriage:triage\nadvisor:advisor\nrecut:recut\nmaintenance:maintenance' ]] || exit 1
  else
    [[ ! -s "$dest" && ! -s "$dest.other" ]] || { echo "not ok - $name recorded while disabled" >&2; exit 1; }
    [[ "$(cat "$PROFILE_STAGE_LOG")" == $'fastlane:disabled\ntriage:disabled\nadvisor:disabled\nrecut:disabled\nmaintenance:disabled' ]] || exit 1
  fi
)

run_case() {
  local name="$1"
  profile_case "$@" > "$test_env_root/out-$name" 2> "$test_env_root/err-$name" || {
    cat "$test_env_root/err-$name" >&2; echo "not ok - $name" >&2; exit 1;
  }
  if grep -q 'secret-profile-target' "$test_env_root/out-$name" "$test_env_root/err-$name"; then
    echo "not ok - $name leaked a profile file value" >&2; exit 1
  fi
  printf 'ok - profile %s\n' "$name"
}

run_case legacy-file legacy legacy 1
run_case preferred-file preferred preferred 1
run_case both-files both preferred 1
run_case both-flags preferred unchanged 1
cmp "$test_env_root/records-legacy-file" "$test_env_root/records-preferred-file"
cmp "$test_env_root/records-preferred-file" "$test_env_root/records-both-files"
cmp "$test_env_root/records-preferred-file" "$test_env_root/records-both-flags"
grep -q 'legacy ZF_PIPELINE_CALL_PROFILE_ENABLED read by transport' "$test_env_root/err-legacy-file"
grep -q 'legacy ZF_PIPELINE_CALL_PROFILE_ENABLED read by guarded-write' "$test_env_root/err-legacy-file"
grep -q 'legacy ZF_PIPELINE_CALL_PROFILE_ENABLED read by slices' "$test_env_root/err-legacy-file"
for consumer in transport guarded-write slices; do
  grep -q "legacy ZF_PIPELINE_CALL_PROFILE_ENABLED read by $consumer" "$test_env_root/err-both-flags"
done
run_case disabled-flags preferred disabled 1
grep -q 'legacy ZF_PIPELINE_CALL_PROFILE_ENABLED read by transport' "$test_env_root/err-disabled-flags"
run_case conflict-flags preferred conflict 1
grep -q 'conflicting profile enabled flags ZF_PIPELINE_CALL_PROFILE_ENABLED and ZF_CALL_PROFILE_ENABLED' "$test_env_root/err-conflict-flags"
run_case legacy-empty old-empty unchanged 0
run_case preferred-empty new-empty unchanged 0
run_case both-empty both-empty unchanged 0
run_case different-files different unchanged 0
run_case old-empty-conflict old-empty-new unchanged 0
run_case new-empty-conflict new-empty-old unchanged 0
for name in different-files old-empty-conflict new-empty-conflict; do
  grep -q 'conflicting ZF_PIPELINE_CALL_PROFILE_FILE' "$test_env_root/err-$name"
done

dynamic_file_case() (
  local first="$AGENT_HOME/secret-profile-target-first" second="$AGENT_HOME/secret-profile-target-second"
  local legacy="$AGENT_HOME/secret-profile-target-legacy" before
  unset ZF_PIPELINE_CALL_PROFILE_FILE
  ZF_CALL_PROFILE_FILE="$first"; export ZF_CALL_PROFILE_FILE
  source "$SCRIPT_DIR/lib.sh"
  gh issue list --repo fixture >/dev/null
  [[ -s "$first" ]]
  ZF_CALL_PROFILE_FILE="$second"
  gh issue list --repo fixture >/dev/null
  [[ -s "$second" ]]
  before="$(wc -l < "$second")"
  ZF_PIPELINE_CALL_PROFILE_FILE="$legacy"; export ZF_PIPELINE_CALL_PROFILE_FILE
  gh issue list --repo fixture >/dev/null
  [[ "$(wc -l < "$second")" == "$before" && ! -e "$legacy" ]]
  unset ZF_CALL_PROFILE_FILE
  gh issue list --repo fixture >/dev/null
  [[ -s "$legacy" ]]
  before="$(wc -l < "$legacy")"
  ZF_PIPELINE_CALL_PROFILE_FILE=''
  gh issue list --repo fixture >/dev/null
  [[ "$(wc -l < "$legacy")" == "$before" ]]
  ZF_PIPELINE_CALL_PROFILE_FILE="$AGENT_HOME/secret-profile-target-missing/record"
  gh issue list --repo fixture >/dev/null
)
dynamic_file_case > "$test_env_root/dynamic.out" 2> "$test_env_root/dynamic.err"
grep -q 'conflicting ZF_PIPELINE_CALL_PROFILE_FILE' "$test_env_root/dynamic.err"
if grep -q 'secret-profile-target' "$test_env_root/dynamic.out" "$test_env_root/dynamic.err"; then
  echo 'not ok - dynamic profile destination leaked' >&2; exit 1
fi
echo 'ok - changed, empty, conflicting and unwritable profile destinations are rechecked for every record'

# Scheduler and bell source transport without lib.sh; this must supply the
# same state check without relying on the full engine initializer.
standalone_transport() (
  local spelling="$1" record="$test_env_root/standalone-$1"
  unset ZF_CALL_PROFILE_ENABLED ZF_PIPELINE_CALL_PROFILE_ENABLED
  case "$spelling" in
    old) ZF_PIPELINE_CALL_PROFILE_ENABLED=1 ;;
    new) ZF_CALL_PROFILE_ENABLED=1 ;;
    conflict) ZF_PIPELINE_CALL_PROFILE_ENABLED=1; ZF_CALL_PROFILE_ENABLED=0 ;;
    disabled) ZF_CALL_PROFILE_ENABLED=0 ;;
  esac
  source "$SCRIPT_DIR/lib.d/transport.sh"
  _call_profile_record() { printf '%s\n' "$1" >> "$record"; }
  gh issue list --repo fixture --limit 1 >/dev/null
  gh_timeout 5s issue list --repo fixture --limit 1 >/dev/null
)
for spelling in old new conflict disabled; do
  standalone_transport "$spelling" 2> "$test_env_root/standalone-$spelling.err"
done
cmp "$test_env_root/standalone-old" "$test_env_root/standalone-new"
[[ "$(wc -l < "$test_env_root/standalone-old")" == 2 ]]
[[ ! -e "$test_env_root/standalone-conflict" && ! -e "$test_env_root/standalone-disabled" ]]
grep -q 'conflicting profile enabled flags' "$test_env_root/standalone-conflict.err"
echo 'ok - standalone transport honors either enabled flag and disables conflicts'
echo 'rename-e1-profile.test.sh: PASS'
