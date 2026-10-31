#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../test-env.sh"
p=$(cd "$(dirname "$0")" && pwd); t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin" "$t/root"
cat > "$t/bin/git" <<'STUB'
#!/usr/bin/env bash
case "$*" in
 'rev-parse --show-toplevel') echo "$ROOT" ;;
 'rev-parse '*) echo candidate ;;
 'merge-base '*) echo base ;;
 'rev-list --count '*) echo "${COUNT:-1}" ;;
 'worktree add '*) d="${@: -2:1}"; mkdir -p "$d/.zenoforge"
    if [[ "${TARGET_GATE_ONLY:-0}" == 1 ]]; then
      printf '%s\n' 'echo target-gate-ran' > "$d/.zenoforge/prepush-gates"
    else
      printf '%s\n' '# example gates' '' 'echo gate-one' 'exit "${FAIL:-0}"' > "$d/.zenoforge/prepush-gates"
    fi ;;
esac
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
