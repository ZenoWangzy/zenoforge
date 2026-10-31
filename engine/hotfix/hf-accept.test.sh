#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../test-env.sh"
p=$(cd "$(dirname "$0")" && pwd); t=$(mktemp -d)
mkdir -p "$t/config" "$t/pack" "$t/repo"
cat > "$t/node" <<'STUB'
#!/usr/bin/env bash
pwd > "$CWD_LOG"
printf '%s\n' "$@" > "$ARGS_LOG"
echo done
exit "${NODE_RC:-0}"
STUB
chmod +x "$t/node"
export PATH="$t:$PATH" AGENT_HOME=$t ZF_CONFIG_ROOT=$t/config ZF_PACK_DIR=$t/pack ZF_REPO_DIR=$t/repo HF_ACCEPT_LOG=$t/accept.log CWD_LOG=$t/cwd ARGS_LOG=$t/args HF_ISSUE='12 13' HF_PR=14 HF_SHA=abc
printf '%s\n' '{"acceptance":{"command":["node","pack.js"],"person":"pack","target":"pack"}}' > "$t/pack/hotfix.json"
printf '%s\n' '{"acceptance":{"command":["node","override.js"],"person":"tester","target":"localhost"}}' > "$t/config/hotfix.json"
NODE_RC=1 "$p/hf-accept.sh" >/dev/null || true
[[ ! -e $t/hotfix-live.jsonl ]]
"$p/hf-accept.sh" >/dev/null
[[ $(cat "$t/cwd") == "$t/repo" ]]
grep -Fxq override.js "$t/args"
grep -Fxq localhost "$t/args"
[[ $(wc -l < "$t/hotfix-live.jsonl") == 2 ]]
jq -e '.accepted_by == "tester" and .issue == 13' <(tail -n 1 "$t/hotfix-live.jsonl") >/dev/null
jq -e '.rc == 0 and .set == "full"' <(tail -n 1 "$t/hf-demo-accept.jsonl") >/dev/null
mv "$t/config/hotfix.json" "$t/override.json"
"$p/hf-accept.sh" >/dev/null
grep -Fxq pack.js "$t/args"
mv "$t/pack/hotfix.json" "$t/pack.json"
! "$p/hf-accept.sh" >/dev/null 2>&1
mkdir -p "$t/pack/hotfix"
printf '#!/usr/bin/env bash\nprintf legacy > "$LEGACY_LOG"\n' > "$t/pack/hotfix/hf-accept.sh"
export LEGACY_LOG=$t/legacy
"$p/hf-accept.sh"
[[ $(cat "$LEGACY_LOG") == legacy ]]
