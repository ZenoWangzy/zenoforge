#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
engine=$(cd -- "$here/.." && pwd -P)
trap 'rm -rf -- "$test_env_root"' EXIT
t="$test_env_root/prompt-contract"
mkdir -p "$t/new/engine/publish-preflight" "$t/repo/.zenoforge/prompts"
cp -R "$engine/prompts" "$t/new/engine/prompts"
cp "$here/prompt-contract.json" "$t/new/engine/publish-preflight/"
cp "$engine/prompts/"* "$t/repo/.zenoforge/prompts/"
git -C "$t/repo" init -q && git -C "$t/repo" config user.email test && git -C "$t/repo" config user.name test
fail() { echo "FAIL: $*"; exit 1; }
commit() { git -C "$t/repo" add -A && git -C "$t/repo" commit -qm "$1"; }
run() { python3 -I "$here/prompt-contract-check.py" "$t/new" "$t/repo" HEAD; }
prompts="$t/repo/.zenoforge/prompts"
restore() { cp "$engine/prompts/$1" "$prompts/$1"; }
commit forks

run | grep -q 'prompt-contract: OK' || fail 'the engine copies must meet their own contract'

python3 -I - "$here/prompt-contract.json" "$engine/mac-autopilot/scheduler.d/review-rules.sh" <<'E' || fail 'an implementation report gate section is missing from the prompt contract'
import json, re, sys

contract = json.load(open(sys.argv[1], encoding='utf-8'))
source = open(sys.argv[2], encoding='utf-8').read()
starts = list(re.finditer(r'(?m)^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{', source))
required = set()
for index, match in enumerate(starts):
    if not match.group(1).endswith('_gate_reason'):
        continue
    end = starts[index + 1].start() if index + 1 < len(starts) else len(source)
    body = source[match.end():end]
    required.update(re.findall(r'\^##[ \t]+([a-z0-9-]+)', body))
tokens = set(contract['prompts']['implement-contract.md'].get('tokens', []))
missing = sorted('## ' + name for name in required if '## ' + name not in tokens)
if missing:
    sys.exit(f'gate-required sections missing from implement-contract.md tokens: {missing}')
E

python3 -I - "$here/prompt-contract.json" "$engine" <<'E' || fail 'a contract token no engine code reads is wording, not a contract'
import json, os, re, sys
contract = json.load(open(sys.argv[1]))
code = ''
for root, _, files in os.walk(sys.argv[2]):
    if os.path.basename(root) == 'prompts':
        continue
    for name in files:
        if re.search(r'\.(sh|mjs|py)$', name) and '.test.' not in name and name != 'prompt-contract-check.py':
            code += open(os.path.join(root, name), encoding='utf-8', errors='replace').read()
tokens = {t for want in contract['prompts'].values() for t in want.get('tokens', [])}
missing = sorted(t for t in tokens if t not in code)
if missing:
    sys.exit(f'unread: {missing}')
E

# Wording is free: a fork may rewrite every sentence while it names the identifiers.
sed -i 's/advisor/reviewer of the ticket/g' "$prompts/advisor-batch.md"; printf '\nOur own closing sentence.\n' >> "$prompts/triage.md"
commit reworded
run | grep -q 'prompt-contract: OK' || fail 'rewording tripped the contract'
restore advisor-batch.md; restore triage.md; commit restored

sed -i 's/tests_fail_first/tests_first/g' "$prompts/advisor-batch.md"; commit drifted
rc=0; out=$(run 2>&1) || rc=$?
[[ $rc == 1 ]] && grep -q 'advisor-batch.md never names tests_fail_first' <<<"$out" || fail "a fork without a required field passed: $out"
restore advisor-batch.md; commit restored

sed -i 's/OBSOLETE/RETIRED/g' "$prompts/implement-contract.md"; commit obsolete-renamed
rc=0; out=$(run 2>&1) || rc=$?
[[ $rc == 1 ]] && grep -q 'implement-contract.md never names OBSOLETE' <<<"$out" || fail "a fork that renamed the OBSOLETE first line passed: $out"
restore implement-contract.md; commit restored

# A fork that mentions "how" in prose still has to request the ## how section.
sed -i 's/## how/how/g' "$prompts/implement-contract.md"; commit bare-how
rc=0; out=$(run 2>&1) || rc=$?
[[ $rc == 1 ]] && grep -q 'implement-contract.md never names ## how' <<<"$out" || fail "a fork with prose but no ## how section passed: $out"
restore implement-contract.md; commit restored

python3 -I - "$prompts/triage.schema.json" <<'E'
import json, sys
path = sys.argv[1]; s = json.load(open(path)); s['properties']['state']['enum'].remove('awaiting-release'); json.dump(s, open(path, 'w'))
E
commit enum
rc=0; out=$(run 2>&1) || rc=$?
[[ $rc == 1 ]] && grep -q 'triage.schema.json enum state lacks awaiting-release' <<<"$out" || fail "a fork without an enum value passed: $out"
restore triage.schema.json; commit restored

python3 -I - "$prompts/triage.schema.json" <<'E'
import json, sys
path = sys.argv[1]; s = json.load(open(path)); s['properties']['entry_surface']['enum'] = ['Portal']; json.dump(s, open(path, 'w'))
E
commit open-enum
run | grep -q 'prompt-contract: OK' || fail 'a product enum must stay the product'"'"'s'
restore triage.schema.json; commit restored

python3 -I - "$prompts/advisor.schema.json" <<'E'
import json, sys
path = sys.argv[1]; s = json.load(open(path)); v = s['properties']['verdict']['enum']; v[v.index('maintainer')] = 'founder'; json.dump(s, open(path, 'w'))
E
commit alias
run | grep -q 'prompt-contract: OK' || fail 'a renamed value must pass through its alias'
restore advisor.schema.json; commit restored

python3 -I - "$prompts/advisor.schema.json" <<'E'
import json, sys
path = sys.argv[1]; raw = open(path).read(); open(path, 'w').write(raw.replace('"tests_fail_first"', '"tests_first"'))
E
commit required
rc=0; out=$(run 2>&1) || rc=$?
[[ $rc == 1 ]] && grep -q 'advisor.schema.json does not require tests_fail_first' <<<"$out" || fail "a fork that stopped requiring a field passed: $out"
restore advisor.schema.json; commit restored

# A name kept in one place of a schema does not stand in for losing it in another.
python3 -I - "$prompts/advisor.schema.json" <<'E'
import json, sys
path = sys.argv[1]; s = json.load(open(path)); s['required'].remove('verdict'); s['properties']['verdict']['enum'].remove('tracker'); json.dump(s, open(path, 'w'))
E
commit relocated
rc=0; out=$(run 2>&1) || rc=$?
[[ $rc == 1 ]] && grep -q 'advisor.schema.json does not require verdict at root' <<<"$out" && grep -q 'advisor.schema.json enum verdict lacks tracker at properties/verdict' <<<"$out" || fail "a value kept only in a conditional passed: $out"
restore advisor.schema.json; commit restored

# A fork may delegate its contract to a skill it names, and the skill must then carry it.
mkdir -p "$t/repo/.agents/skills/review"
printf 'VERDICT READY NOT_READY INPUT_INCOMPLETE BLOCKED-ON review-findings decision_log_flags\n' > "$t/repo/.agents/skills/review/SKILL.md"
printf 'Follow `.agents/skills/review/SKILL.md`.\n' > "$prompts/review-contract.md"; commit delegated
run | grep -q 'prompt-contract: OK' || fail 'a delegated contract was not followed'
printf 'VERDICT READY\n' > "$t/repo/.agents/skills/review/SKILL.md"; commit thin-skill
rc=0; out=$(run 2>&1) || rc=$?
[[ $rc == 1 ]] && grep -q 'review-contract.md never names NOT_READY' <<<"$out" || fail "a thin skill passed: $out"
restore review-contract.md

# A rollback target from before this gate carries no contract.
mkdir -p "$t/live/engine"; rc=0; out=$(python3 -I "$here/prompt-contract-check.py" "$t/live" "$t/repo" HEAD 2>&1) || rc=$?
[[ $rc == 0 ]] && grep -q 'declares none' <<<"$out" || fail "a version with no contract must pass: $out"

# No fork means the engine's own copy runs: nothing to check.
git -C "$t/repo" rm -qrf .zenoforge/prompts; mkdir -p "$prompts"; printf 'x\n' > "$prompts/keep"; commit no-forks
run | grep -q 'prompt-contract: OK' || fail 'no fork must pass'
echo "prompt-contract-check.test.sh: PASS"
