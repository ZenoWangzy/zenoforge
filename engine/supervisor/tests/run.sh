#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/supervisor-test.XXXXXXXX")
export HOME="$work/home" ZF_SUPERVISOR_CONFIG="$work/config.json"
mkdir -p "$HOME/roles" "$HOME/state" "$HOME/bin" "$work/stubs"
printf 'policy\n' > "$HOME/policy"
printf '{"sessionId":"s"}' > "$HOME/claim"
printf '#!/bin/bash\necho waiting\nexit 1\n' > "$HOME/bin/gate"
printf '#!/bin/bash\necho ledger\n' > "$HOME/bin/ledger"
printf 'target\n' > "$HOME/old"
printf 'target\n' > "$HOME/target"
node - "$ZF_SUPERVISOR_CONFIG" <<'NODE'
const fs=require('fs'); fs.writeFileSync(process.argv[2],JSON.stringify({
 role_env:'TEST_ROLE',sources:{policy:'~/policy',claude_quota:'~/q1',zcode_quota:'~/q2',role_dir:'~/roles'}, state_dir:'~/state',seen_state_template:'seen-{session}',coach:{enabled:true,role:'lead',report_dir:'~/reports',marker_file:'~/state/marker',stale_days:8,new:'new {path}',stale:'stale'},labels:{policy:'policy {path}\n',role:'role {role}\n',quotas:['one','two'],quota:'quota '},
 claim_path:'~/claim', demo_gate:'~/bin/gate',demo_gate_env:'TEST_GATE',ledger_script:'~/bin/ledger',ledger_env:'TEST_LEDGER',ledger_label:'ledger: ',readiness_pattern:'READY',claim_message:'blocked {result}\n',ruling_trigger:'must',ruling_carrier:'carrier:',ignored_user_prefixes:['<'],ruling_message:'ruling {text}\n',
 command_patterns:['land','state/','helper','checkout','ssh','docker','gh','rebase','exempt'],push_pattern:'git push',command_messages:['heredoc {delimiter}\n','push\n','state\n','worktree\n','cd\n','hands\n'], launcher:{cwd:'~',roles:['lead'],role_dir:'~/roles',prefix:'acme-'}, links:[{link:'~/old',target:'~/target'}],rulings_clone:'~',
 watch:{autopi:'~/logs',inbox:'~/inbox',pause:'~/pause',release_events:'FAILED',inbox_events:'notice',units_pattern:'unit',pause_units:[],tick_seconds:900,cpu_high:90,cpu_low:15,memory_min:2048,alert_seconds:1800,temp_root:'/tmp',temp_min:1024,chrome_endpoint:'http://127.0.0.1:1/',chrome_patterns:['foo','bar'],chrome_limits:[1,4],chrome_label:'other',interval:0,cgroup:'~/none',scope_glob:'worker-*.scope',scope_prefix:'worker-',lane_pattern:'lead-*',lane_labels:['one','two'],lane_limit:6,cpu_idle:100000,pr_search:'head:topic/',pr_label:'topic',pr_limit:3,pr_idle:1800,migration_repo:'acme/repo',migration_issue:1,migration_label:'acme#1'} }));
NODE
run() { local file=$1 input=$2 expected=$3 rc=0; printf '%s' "$input" | node "$root/hooks/$file" > "$work/out" 2> "$work/err" || rc=$?; [ "$rc" = "$expected" ] || { echo "FAIL $file expected $expected got $rc"; cat "$work/err"; exit 1; }; }
mkdir -p "$work/links"
ln -s "$root/hooks/policy-inject.mjs" "$work/links/legacy.mjs"
printf '{"session_id":"s"}' | node "$work/links/legacy.mjs" > "$work/linked"
grep -q policy "$work/linked"
run policy-inject.mjs '{"session_id":"s"}' 0
grep -q 'policy' "$work/out"
run command-gate.cjs '{"tool_name":"Bash","tool_input":{"command":"echo ok"}}' 0
run command-gate.cjs '{"tool_name":"Bash","tool_input":{"command":"git push"}}' 2
run command-gate.cjs '{"tool_name":"Bash","tool_input":{"command":"pnpm test && gh pr create --title x"}}' 2
run command-gate.cjs '{"tool_name":"Bash","tool_input":{"command":"pnpm --filter a test:hooks; gh pr create"}}' 2
run command-gate.cjs '{"tool_name":"Bash","tool_input":{"command":"npx tsc --noEmit | tail -3; gh pr edit 1 --body-file b.md"}}' 2
run command-gate.cjs '{"tool_name":"Bash","tool_input":{"command":"vitest run a.test.ts\ngh issue comment 1 --body done"}}' 2
run command-gate.cjs '{"tool_name":"Bash","tool_input":{"command":"$P/run-test.sh bash -c x; gh pr create"}}' 2
run command-gate.cjs '{"tool_name":"Bash","tool_input":{"command":"gh pr create --title x"}}' 0
run command-gate.cjs '{"tool_name":"Bash","tool_input":{"command":"gh pr edit 1 --add-label x; pnpm test"}}' 0
run command-gate.cjs '{"tool_name":"Bash","tool_input":{"command":"gh issue comment 1 --body \"tsc passed\""}}' 0
run command-gate.cjs '{"tool_name":"Bash","tool_input":{"command":"cat tsc.log; gh pr create"}}' 0
run command-gate.cjs '{"tool_name":"Bash","tool_input":{"command":"pnpm test"}}' 0
printf '%s\n' '{"type":"assistant","message":{"content":"READY"}}' > "$HOME/transcript"
input=$(printf '{"session_id":"s","transcript_path":"%s/transcript"}' "$HOME")
run claim-gate.cjs "$input" 2
printf '#!/bin/bash\nexit 0\n' > "$HOME/bin/gate"
run claim-gate.cjs "$input" 0
printf '#!/bin/bash\ntouch "$HOME/gate-ran"\nexit 1\n' > "$HOME/bin/gate"
printf '%s\n' '{"type":"user","message":{"content":"first task"}}' '{"type":"assistant","message":{"content":"still working"}}' '{"type":"user","message":{"content":"second task"}}' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}' > "$HOME/transcript"
rm -f "$HOME/gate-ran"
run claim-gate.cjs "$(printf '{"session_id":"s","transcript_path":"%s/transcript","last_assistant_message":"demo finished, READY to ship"}' "$HOME")" 2
[ -e "$HOME/gate-ran" ]
printf '%s\n' '{"type":"user","message":{"content":"first task"}}' '{"type":"assistant","message":{"content":"all READY now"}}' '{"type":"user","message":{"content":"second task"}}' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{}}]}}' > "$HOME/transcript"
rm -f "$HOME/gate-ran"
run claim-gate.cjs "$input" 0
[ ! -e "$HOME/gate-ran" ]
printf '%s\n' '{"type":"user","message":{"content":"go"}}' '{"type":"assistant","message":{"content":[{"type":"text","text":"the demo is READY"}]}}' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}' '{"type":"assistant","message":{"content":[{"type":"text","text":"wrapping up now"}]}}' > "$HOME/transcript"
rm -f "$HOME/gate-ran"
run claim-gate.cjs "$input" 2
[ -e "$HOME/gate-ran" ]
printf '%s\n' '{"type":"user","message":{"content":"go"}}' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{}}]}}' > "$HOME/transcript"
rm -f "$HOME/gate-ran"
run claim-gate.cjs "$input" 0
[ ! -e "$HOME/gate-ran" ]
printf '%s\n' '{"type":"user","message":{"content":"must"}}' '{"type":"assistant","message":{"content":"done"}}' > "$HOME/transcript"
run ruling-gate.cjs "$input" 2
printf '%s\n' '{"type":"user","message":{"content":"please"}}' '{"type":"assistant","message":{"content":"done"}}' > "$HOME/transcript"
run ruling-gate.cjs "$input" 0
run ledger-inject.cjs '{"session_id":"s","source":"compact"}' 0
grep -q ledger "$work/out"
run ledger-inject.cjs '{"session_id":"other","source":"resume"}' 0
[ ! -s "$work/out" ]
for hook in "$root"/hooks/*; do
 printf "{invalid" > "$work/invalid"
for kind in missing broken invalid; do
  config="$work/$kind"; [ "$kind" != broken ] || ln -s "$work/absent" "$config" 2>/dev/null || :
  rc=0; ZF_SUPERVISOR_CONFIG="$config" node "$hook" < /dev/null > "$work/out" 2> "$work/err" || rc=$?
  [ "$rc" = 1 ]; grep -q '^zenoforge supervisor: config unavailable: ' "$work/err"; [ "$(wc -l < "$work/err")" = 1 ]
 done
done
printf 'newer\n' > "$HOME/old"
rc=0; bash "$root/install.sh" --apply --config "$ZF_SUPERVISOR_CONFIG" > "$work/out" 2> "$work/err" || rc=$?
[ "$rc" = 1 ]; grep -q "refuse: $HOME/old differs from $HOME/target" "$work/err"
[ ! -L "$HOME/old" ]; [ ! -e "$HOME/.zenoforge" ]
printf 'target\n' > "$HOME/old"
bash "$root/install.sh" --config "$ZF_SUPERVISOR_CONFIG" > "$work/dry"
[ ! -L "$HOME/old" ]; [ ! -e "$HOME/.zenoforge" ]
bash "$root/install.sh" --apply --config "$ZF_SUPERVISOR_CONFIG" > "$work/apply"
[ -L "$HOME/old" ]; [ -L "$HOME/.zenoforge/supervisor/config.json" ]; [ "$(find "$HOME/.zenoforge/backups" -name old | wc -l)" = 1 ]
bash "$root/install.sh" --apply --config "$ZF_SUPERVISOR_CONFIG" > "$work/again"
[ ! -s "$work/again" ]
printf '#!/bin/sh\necho "[]"\n' > "$work/stubs/gh"; chmod +x "$work/stubs/gh"
export PATH="$work/stubs:$PATH"
printf 'changed\n' > "$HOME/regular"; mv -T "$HOME/regular" "$HOME/old"
bash "$root/watch/oversight.sh" > "$work/watch" 2>/dev/null
grep -q '^LINK not-a-link ~/old' "$work/watch"
ln -s "$HOME/other" "$HOME/repoint"; mv -T "$HOME/repoint" "$HOME/old"
bash "$root/watch/oversight.sh" > "$work/watch" 2>/dev/null
grep -q '^LINK wrong-target ~/old' "$work/watch"
# supervisors registry
cp "$ZF_SUPERVISOR_CONFIG" "$work/base.json"
printf '#!/bin/sh\nexit 0\n' > "$work/stubs/claude"; chmod +x "$work/stubs/claude"
printf 'role\n' > "$HOME/roles/head.md"; printf 'role\n' > "$HOME/roles/lead.md"
# Run a copy outside the repo: its package.json has "type":"module", and the published engine runs vrole as CommonJS.
cp -r "$root" "$work/published"
vr() { rc=0; PATH="$work/stubs:$PATH" node "$work/published/bin/vrole" "$@" > "$work/out" 2> "$work/err" || rc=$?; }
vr lead; [ "$rc" = 0 ]
vr head; [ "$rc" = 2 ]; grep -q 'no role file' "$work/err"
vr --list; [ "$rc" = 0 ]; [ "$(wc -l < "$work/out")" = 4 ]; grep -q "^coach	active	founder	-	" "$work/out"
sup() { node -e 'const f=process.argv[1],c=require(f);c.supervisors=JSON.parse(process.argv[2]);c.launcher.roles.push("head");require("fs").writeFileSync(f,JSON.stringify(c))' "$ZF_SUPERVISOR_CONFIG" "$1"; }
sup '{"head":{"state":"closed","ruling":"r-1"}}'
vr head; [ "$rc" = 3 ]; grep -q 'closed.*r-1' "$work/err"
vr --list; grep -q "^head	closed	founder	r-1	" "$work/out"
sup '{"head":{"scope":"mine"}}'
vr head; [ "$rc" = 0 ]
vr --list; grep -q "^head	active	founder	-	mine$" "$work/out"
sup '{"head":{"state":"paused"}}'
vr head; [ "$rc" = 1 ]; grep -q 'state must be active or closed' "$work/err"
cp "$work/base.json" "$ZF_SUPERVISOR_CONFIG"
echo 'supervisor tests: all checks passed'
