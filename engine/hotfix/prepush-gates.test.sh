#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../test-env.sh"
p=$(cd "$(dirname "$0")" && pwd); t=$(mktemp -d)
gate_release="$t/gate-release"
gate_children=()
cleanup_test() {
  touch "$gate_release" 2>/dev/null || :
  local child
  for child in "${gate_children[@]}"; do wait "$child" 2>/dev/null || :; done
  rm -rf "$t"
  test_env_chain_exit "$test_env_root" "$test_env_prior_exit"
}
trap 'cleanup_test' EXIT
mkdir -p "$t/bin" "$t/root"
cat > "$t/bin/git" <<'STUB'
#!/usr/bin/env bash
case "$*" in
 'rev-parse --show-toplevel') echo "$ROOT" ;;
 'rev-parse '*) echo candidate ;;
 'merge-base '*) echo base ;;
 'rev-list --count '*) echo "${COUNT:-1}" ;;
 'diff --name-only '*) echo packages/changed/src/file.ts ;;
 '-C '*branch' --show-current') echo hotfix/test ;;
 'worktree add '*) d="${@: -2:1}"; mkdir -p "$d/.zenoforge"
    if [[ "${TARGET_GATE_ONLY:-0}" == 1 ]]; then
      printf '%s\n' 'echo target-gate-ran' > "$d/.zenoforge/prepush-gates"
    else
      printf '%s\n' '# example gates' '' 'echo gate-one' 'exit "${FAIL:-0}"' > "$d/.zenoforge/prepush-gates"
    fi ;;
esac
STUB
cat > "$t/bin/zf-batch" <<'STUB'
#!/usr/bin/env bash
ZF_BATCH_SLOT=test exec "$@"
STUB
chmod +x "$t/bin/"*; export PATH="$t/bin:$PATH" ROOT="$t/root" GH_TOKEN=secret
mkdir -p "$t/pack/hotfix/prepush-gates.d" "$t/config"
printf '%s\n' 'echo legacy-pack' > "$t/pack/hotfix/prepush-gates.d/10-example.sh"
export ZF_PACK_DIR="$t/pack" ZF_CONFIG_ROOT="$t/config"
FAIL=0 "$p/prepush-gates.sh" | grep -q 'rc=0'
FAIL=0 "$p/prepush-gates.sh" > "$t/out"; grep -q 'bash -c .*gate-one' "$t/out"
rc=0; FAIL=1 "$p/prepush-gates.sh" > "$t/out" || rc=$?; [[ $rc == 1 ]]; grep -q 'rc=1' "$t/out"
rc=0; COUNT=0 "$p/prepush-gates.sh" > "$t/out" 2>&1 || rc=$?; [[ $rc == 2 ]]; grep -q 'commit first' "$t/out"

# Target configuration replaces the matching legacy gate in filename order.
cat > "$t/bin/check" <<'STUB'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$*" "${WORKERS:-}" "${RUN_INTEGRATION:-}" >> "$LOG"
case "$1" in
 select-boolean) printf '%s\n' "${BOOL:-true}" ;;
 select-packages) echo '{"rootNames":["special","other"],"affectedNames":["other"]}' ;;
 fail) exit 1 ;;
esac
STUB
chmod +x "$t/bin/check"
export LOG="$t/log"
cat > "$t/config/hotfix.json" <<'JSON'
{"prepush":{"legacy_gate":"10-example.sh","env":{},"rules":[
 {"type":"command","command":["check","install"],"fatal":true},
 {"type":"environment","env":{"WORKERS":"1"}},
 {"type":"boolean","name":"choice","selector":["check","select-boolean"],"error":"selector failed","when_true":[{"type":"command","command":["check","selected"]}]},
 {"type":"packages","selector":["check","select-packages"],"error":"package selector failed","before":["check","before"],"test":["check","test","{{package}}"],"special_package":"special","boolean_name":"choice","special_test":["check","hooks"],"integration_diff":["check","diff"],"integration_pattern":"^packages/([^/]+)/(.+)$","integration_env":{"RUN_INTEGRATION":"1"},"integration_env_defaults":{"TEST_URL":"local"},"integration_test":["check","integration","{{package}}","{{relative_file}}"]},
 {"type":"command","command":["check","last"]}
]}}
JSON
# Emit an integration path from the configured diff command.
python3 - "$t/bin/check" <<'PYTEST'
import sys
p=sys.argv[1]; s=open(p).read().replace(' select-boolean)', ' diff) echo packages/other/example.test ;;\n select-boolean)'); open(p,'w').write(s)
PYTEST
printf '%s\n' '{}' > "$t/pack/hotfix.json"
FAIL=0 "$p/prepush-gates.sh" > "$t/out"
! grep -q legacy-pack "$t/out"
grep -q '^install||' "$LOG"
grep -q '^selected|1|' "$LOG"
! grep -q '^test special|' "$LOG"
grep -q '^test other|1|' "$LOG"
grep -q '^hooks|1|' "$LOG"
grep -q '^integration other example.test|1|1' "$LOG"
grep -q '^last|1|' "$LOG"
rc=0; BOOL=invalid "$p/prepush-gates.sh" > "$t/out" 2>&1 || rc=$?; [[ $rc == 1 ]]; grep -q 'invalid choice selector result' "$t/out"
# Ordinary failures accumulate while later checks still run; fatal install failures stop.
python3 - "$t/config/hotfix.json" <<'PYTEST'
import json,sys
p=sys.argv[1]; x=json.load(open(p)); x['prepush']['rules'].insert(-1, {'type':'command','command':['check','fail']}); json.dump(x,open(p,'w'))
PYTEST
: > "$LOG"
rc=0; "$p/prepush-gates.sh" > "$t/out" 2>&1 || rc=$?; [[ $rc == 1 ]]; grep -q '^last|' "$LOG"
python3 - "$t/config/hotfix.json" <<'PYTEST'
import json,sys
p=sys.argv[1]; x=json.load(open(p)); x['prepush']['rules'][0]['command']=['check','fail']; json.dump(x,open(p,'w'))
PYTEST
: > "$LOG"
rc=0; "$p/prepush-gates.sh" > "$t/out" 2>&1 || rc=$?; [[ $rc == 1 ]]; ! grep -q '^last|' "$LOG"
# A malformed override fails closed.
printf '%s\n' '{}' > "$t/config/hotfix.json"
rc=0; "$p/prepush-gates.sh" > "$t/out" 2>&1 || rc=$?; [[ $rc == 1 ]]; grep -q 'invalid prepush configuration' "$t/out"

# With no pack or hotfix.json, a target-repository gate still runs.
rc=0; TARGET_GATE_ONLY=1 ZF_CONFIG_ROOT="$t/missing" ZF_PACK_DIR='' "$p/prepush-gates.sh" > "$t/out" 2>&1 || rc=$?
[[ $rc == 0 ]]; grep -qx 'target-gate-ran' "$t/out"; grep -q 'rc=0' "$t/out"

# Two slots admit two gate processes; a third advertises its wait and starts after one frees.
mkdir -p "$t/pack/hotfix/prepush-gates.d" "$t/slots2-started"
export ZF_CONFIG_ROOT="$t/missing"
rm -f "$t/pack/hotfix.json"
cat > "$t/pack/hotfix/prepush-gates.d/99-blocker.sh" <<'STUB'
mkdir -p "$GATE_STARTED"
touch "$GATE_STARTED/$BASHPID"
while [[ ! -e "$GATE_RELEASE" ]]; do sleep 0.025; done
STUB
export GATE_RELEASE="$gate_release" ZF_BATCH_SLOT=test
wait_for_started() {
  local dir="$1" wanted="$2" count
  for _ in {1..200}; do
    count=$(count_started "$dir")
    (( count >= wanted )) && return 0
    sleep 0.025
  done
  return 1
}
wait_for_file() {
  for _ in {1..200}; do [[ -e "$1" ]] && return 0; sleep 0.025; done
  return 1
}
count_started() {
  local -a files
  shopt -s nullglob
  files=("$1"/*)
  shopt -u nullglob
  printf '%s' "${#files[@]}"
}
PREPUSH_TMP="$t/slots2-tmp" PREPUSH_GATE_SLOTS=2 GATE_STARTED="$t/slots2-started" "$p/prepush-gates.sh" > "$t/slots2-a.out" 2>&1 &
slots2_a=$!; gate_children+=("$slots2_a")
PREPUSH_TMP="$t/slots2-tmp" PREPUSH_GATE_SLOTS=2 GATE_STARTED="$t/slots2-started" "$p/prepush-gates.sh" > "$t/slots2-b.out" 2>&1 &
slots2_b=$!; gate_children+=("$slots2_b")
wait_for_started "$t/slots2-started" 2 || {
  echo 'slots=2 did not start two gates concurrently' >&2
  cat "$t/slots2-a.out" "$t/slots2-b.out" 2>/dev/null || :
  ls -1 "$t/slots2-tmp" "$t/slots2-tmp/waiting" 2>/dev/null || :
  exit 1
}
[[ ! -e "$t/slots2-tmp/waiting/$slots2_a" && ! -e "$t/slots2-tmp/waiting/$slots2_b" ]]
PREPUSH_TMP="$t/slots2-tmp" PREPUSH_GATE_SLOTS=2 GATE_STARTED="$t/slots2-started" "$p/prepush-gates.sh" > "$t/slots2-c.out" 2>&1 &
slots2_c=$!; gate_children+=("$slots2_c")
wait_for_file "$t/slots2-tmp/waiting/$slots2_c" || { echo 'third slots=2 gate did not publish its wait file' >&2; exit 1; }
grep -Eq '^[0-9]+ candidate hotfix/test$' "$t/slots2-tmp/waiting/$slots2_c"
[[ $(count_started "$t/slots2-started") -eq 2 ]]
touch "$gate_release"
wait "$slots2_a"; wait "$slots2_b"; wait "$slots2_c"
[[ ! -e "$t/slots2-tmp/waiting/$slots2_c" ]]
grep -Eq 'slot [0-9]+ acquired after [0-9]+s' "$t/slots2-c.out"

# One slot preserves serial execution and removes the queued process's marker on admission.
rm -f "$gate_release"
mkdir -p "$t/slots1-started"
PREPUSH_TMP="$t/slots1-tmp" PREPUSH_GATE_SLOTS=1 GATE_STARTED="$t/slots1-started" "$p/prepush-gates.sh" > "$t/slots1-a.out" 2>&1 &
slots1_a=$!; gate_children+=("$slots1_a")
wait_for_started "$t/slots1-started" 1 || { echo 'slots=1 first gate did not start' >&2; exit 1; }
PREPUSH_TMP="$t/slots1-tmp" PREPUSH_GATE_SLOTS=1 GATE_STARTED="$t/slots1-started" "$p/prepush-gates.sh" > "$t/slots1-b.out" 2>&1 &
slots1_b=$!; gate_children+=("$slots1_b")
wait_for_file "$t/slots1-tmp/waiting/$slots1_b" || { echo 'slots=1 second gate did not publish its wait file' >&2; exit 1; }
[[ $(count_started "$t/slots1-started") -eq 1 ]]
touch "$gate_release"
wait "$slots1_a"; wait "$slots1_b"
[[ ! -e "$t/slots1-tmp/waiting/$slots1_b" ]]

# Package-capable target gates receive the changed paths from the candidate diff.
scope_log="$t/scope.log"
printf '%s\n' 'printf "%s" "$PREPUSH_CHANGED_PACKAGES" > "$SCOPE_LOG"' > "$t/pack/hotfix/prepush-gates.d/99-blocker.sh"
PREPUSH_TMP="$t/scope-tmp" SCOPE_LOG="$scope_log" "$p/prepush-gates.sh" > "$t/out" 2>&1
[[ $(cat "$scope_log") == 'packages/changed' ]]
