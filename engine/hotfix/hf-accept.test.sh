#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../test-env.sh"
p=$(cd "$(dirname "$0")" && pwd); t=$(mktemp -d)
unset HF_ACCEPT_SET HF_HARNESS_SHA VECTA_REPO_DIR
mkdir -p "$t/config" "$t/pack" "$t/repo"
git -C "$t/repo" init -q
git -C "$t/repo" config user.name 'Zenoforge Test'
git -C "$t/repo" config user.email 'zenoforge-test@example.invalid'
touch "$t/repo/.fixture"
git -C "$t/repo" add .fixture
git -C "$t/repo" commit -qm 'test fixture'
harness_head=$(git -C "$t/repo" rev-parse HEAD)
cat > "$t/node" <<'STUB'
#!/usr/bin/env bash
printf 'called\n' >> "$CALLS_LOG"
pwd > "$CWD_LOG"
printf '%s\n' "$@" > "$ARGS_LOG"
echo done
exit "${NODE_RC:-0}"
STUB
chmod +x "$t/node"
export PATH="$t:$PATH" AGENT_HOME=$t ZF_CONFIG_ROOT=$t/config ZF_PACK_DIR=$t/pack ZF_REPO_DIR=$t/repo HF_ACCEPT_LOG=$t/accept.log CWD_LOG=$t/cwd ARGS_LOG=$t/args CALLS_LOG=$t/calls HF_ISSUE='12 13' HF_PR=14 HF_SHA=abc
printf '%s\n' '{"acceptance":{"command":["node","pack.js"],"person":"pack","target":"pack"}}' > "$t/pack/hotfix.json"
printf '%s\n' '{"acceptance":{"command":["node","override.js"],"person":"tester","target":"localhost","repo_env":"VECTA_REPO_DIR"}}' > "$t/config/hotfix.json"
mkdir -p "$t/checkout"
ln -s "$t/checkout" "$t/checkout-link"
resolved_checkout=$(cd "$t/checkout-link" && pwd -P)
# With no hotfix.json the pack's legacy acceptance is the executable fallback.
mkdir -p "$t/pack/hotfix"
printf '#!/usr/bin/env bash\nprintf legacy > "$LEGACY_LOG"\nprintf "%%s" "${VECTA_REPO_DIR:-}" > "$LEGACY_REPO_LOG"\n' > "$t/pack/hotfix/hf-accept.sh"
export LEGACY_LOG=$t/legacy LEGACY_REPO_LOG=$t/legacy-repo
mv "$t/config/hotfix.json" "$t/configured.json"
mv "$t/pack/hotfix.json" "$t/pack-configured.json"
rc=0
HF_ACCEPT_SET=demo HF_HARNESS_SHA="$harness_head" VECTA_REPO_DIR="$t/checkout-link" "$p/hf-accept.sh" > "$t/legacy-live.out" 2>&1 || rc=$?
if [[ $rc != 3 ]]; then
  echo "expected legacy demo acceptance from the live checkout to be refused with rc=3; got $rc" >&2
  exit 1
fi
grep -Fq "refusing demo acceptance from the live checkout: $resolved_checkout" "$t/legacy-live.out"
[[ ! -e $LEGACY_LOG ]]
jq -e '.rc == 3 and .set == "demo-refused"' <(tail -n 1 "$t/hf-demo-accept.jsonl") >/dev/null
rc=0
HF_ACCEPT_SET=demo HF_HARNESS_SHA="$harness_head" env -u VECTA_REPO_DIR "$p/hf-accept.sh" > "$t/legacy-default-live.out" 2>&1 || rc=$?
[[ $rc == 3 && ! -e $LEGACY_LOG ]]
grep -Fq "refusing demo acceptance from the live checkout: $resolved_checkout" "$t/legacy-default-live.out"
rc=0
HF_ACCEPT_SET=demo VECTA_REPO_DIR="$t/repo" "$p/hf-accept.sh" > "$t/legacy-missing-sha.out" 2>&1 || rc=$?
[[ $rc == 3 && ! -e $LEGACY_LOG ]]
grep -Fq 'refusing demo acceptance without HF_HARNESS_SHA' "$t/legacy-missing-sha.out"
rc=0
HF_ACCEPT_SET=demo HF_HARNESS_SHA=wrong VECTA_REPO_DIR="$t/repo" "$p/hf-accept.sh" > "$t/legacy-sha-mismatch.out" 2>&1 || rc=$?
[[ $rc == 3 && ! -e $LEGACY_LOG ]]
grep -Fq 'refusing harness SHA mismatch' "$t/legacy-sha-mismatch.out"
HF_ACCEPT_SET=demo HF_HARNESS_SHA="$harness_head" VECTA_REPO_DIR="$t/repo" "$p/hf-accept.sh"
[[ $(cat "$LEGACY_LOG") == legacy && $(cat "$LEGACY_REPO_LOG") == "$t/repo" ]]
rm -f "$LEGACY_LOG" "$LEGACY_REPO_LOG" "$t/hf-demo-accept.jsonl" "$t/accept.log"
mv "$t/configured.json" "$t/config/hotfix.json"
mv "$t/pack-configured.json" "$t/pack/hotfix.json"
# An explicit live VECTA_REPO_DIR is refused even if a configuration selects another repo.
mv "$t/config/hotfix.json" "$t/repo-env-config.json"
printf '%s\n' '{"acceptance":{"command":["node","override.js"],"person":"tester","target":"localhost"}}' > "$t/config/hotfix.json"
rc=0
HF_ACCEPT_SET=demo HF_HARNESS_SHA="$harness_head" VECTA_REPO_DIR="$t/checkout-link" "$p/hf-accept.sh" > "$t/live-other-repo.out" 2>&1 || rc=$?
[[ $rc == 3 && ! -e $CALLS_LOG ]]
grep -Fq "refusing demo acceptance from the live checkout: $resolved_checkout" "$t/live-other-repo.out"
mv "$t/repo-env-config.json" "$t/config/hotfix.json"
if HF_ACCEPT_SET=demo HF_HARNESS_SHA="$harness_head" VECTA_REPO_DIR="$t/checkout-link" "$p/hf-accept.sh" > "$t/live-guard.out" 2>&1; then
  echo 'expected demo acceptance from the live checkout to be refused' >&2
  exit 1
fi
grep -Fq "$resolved_checkout" "$t/live-guard.out"
[[ ! -e $CALLS_LOG ]]
[[ ! -e $t/hotfix-live.jsonl ]]
resolved_repo=$(cd "$t/repo" && pwd -P)
rm -f "$CALLS_LOG" "$t/hf-demo-accept.jsonl" "$t/hotfix-live.jsonl"
HF_ACCEPT_SET=demo HF_HARNESS_SHA="$harness_head" VECTA_REPO_DIR="$t/repo" "$p/hf-accept.sh" >/dev/null
[[ $(cat "$CALLS_LOG") == called ]]
grep -Fxq "harness_path=$resolved_repo" "$t/accept.log"
grep -Fxq "harness_head=$harness_head" "$t/accept.log"
jq -e --arg path "$resolved_repo" --arg head "$harness_head" '.harness_path == $path and .harness_head == $head and .set == "demo"' <(tail -n 1 "$t/hf-demo-accept.jsonl") >/dev/null
jq -e --arg path "$resolved_repo" --arg head "$harness_head" '.harness_path == $path and .harness_head == $head' <(tail -n 1 "$t/hotfix-live.jsonl") >/dev/null
rm -f "$CALLS_LOG" "$t/hf-demo-accept.jsonl" "$t/hotfix-live.jsonl" "$t/accept.log"
if HF_ACCEPT_SET=full HF_HARNESS_SHA=not-the-current-head VECTA_REPO_DIR="$t/repo" "$p/hf-accept.sh" > "$t/sha-mismatch.out" 2>&1; then
  echo 'expected acceptance with a mismatched harness SHA to be refused' >&2
  exit 1
fi
grep -Fq "$resolved_repo" "$t/sha-mismatch.out"
[[ ! -e $CALLS_LOG ]]
grep -Fxq "harness_path=$resolved_repo" "$t/accept.log"
grep -Fxq "harness_head=$harness_head" "$t/accept.log"
jq -e --arg path "$resolved_repo" --arg head "$harness_head" '.rc == 3 and .set == "full-refused" and .harness_path == $path and .harness_head == $head' <(tail -n 1 "$t/hf-demo-accept.jsonl") >/dev/null
[[ ! -e $t/hotfix-live.jsonl ]]
mkdir -p "$t/no-git"
if HF_ACCEPT_SET=full HF_HARNESS_SHA= VECTA_REPO_DIR="$t/no-git" "$p/hf-accept.sh" > "$t/sha-unavailable.out" 2>&1; then
  echo 'expected acceptance with an unavailable harness HEAD to be refused' >&2
  exit 1
fi
grep -Fq "$t/no-git" "$t/sha-unavailable.out"
[[ ! -e $CALLS_LOG ]]
mkdir -p "$t/unborn"
git -C "$t/unborn" init -q
if HF_ACCEPT_SET=full HF_HARNESS_SHA=HEAD VECTA_REPO_DIR="$t/unborn" "$p/hf-accept.sh" > "$t/sha-unborn.out" 2>&1; then
  echo 'expected acceptance with an unresolved harness HEAD to be refused' >&2
  exit 1
fi
grep -Fq "$t/unborn" "$t/sha-unborn.out"
[[ ! -e $CALLS_LOG ]]
HF_ACCEPT_SET=full VECTA_REPO_DIR="$t/checkout-link" "$p/hf-accept.sh" >/dev/null
[[ -e $CALLS_LOG ]]
rm -f "$CALLS_LOG" "$t/hf-demo-accept.jsonl" "$t/hotfix-live.jsonl" "$t/accept.log"
rc=0
HF_ACCEPT_SET=demo VECTA_REPO_DIR="$t/repo" "$p/hf-accept.sh" > "$t/missing-sha.out" 2>&1 || rc=$?
[[ $rc == 3 && ! -e $CALLS_LOG ]]
grep -Fq 'refusing demo acceptance without HF_HARNESS_SHA' "$t/missing-sha.out"
jq -e '.rc == 3 and .set == "demo-refused"' <(tail -n 1 "$t/hf-demo-accept.jsonl") >/dev/null
rc=0
HF_ACCEPT_SET=demo HF_HARNESS_SHA= VECTA_REPO_DIR="$t/repo" "$p/hf-accept.sh" > "$t/empty-sha.out" 2>&1 || rc=$?
[[ $rc == 3 && ! -e $CALLS_LOG ]]
grep -Fq 'refusing demo acceptance without HF_HARNESS_SHA' "$t/empty-sha.out"
HF_ACCEPT_SET=demo HF_HARNESS_SHA="$harness_head" VECTA_REPO_DIR="$t/repo" "$p/hf-accept.sh" >/dev/null
[[ -e $CALLS_LOG ]]
rm -f "$CALLS_LOG" "$t/hf-demo-accept.jsonl" "$t/hotfix-live.jsonl" "$t/accept.log"
# A refusal between successful demo runs must not break the gate's streak.
for minutes in 50 25; do
  jq -cn --arg at "$(date -u -d "-$minutes minutes" +%FT%TZ)" '{at:$at,rc:0,set:"demo",log:"green"}' >> "$t/hf-demo-accept.jsonl"
done
HF_DEMO_GREENS=2 HF_DEMO_MIN_GAP_MIN=20 HF_DEMO_MAX_AGE_MIN=90 "$p/hf-demo-gate.sh" >/dev/null
rc=0
HF_ACCEPT_SET=demo HF_HARNESS_SHA="$harness_head" VECTA_REPO_DIR="$t/checkout-link" "$p/hf-accept.sh" > "$t/streak-refused.out" 2>&1 || rc=$?
[[ $rc == 3 && ! -e $CALLS_LOG ]]
HF_DEMO_GREENS=2 HF_DEMO_MIN_GAP_MIN=20 HF_DEMO_MAX_AGE_MIN=90 "$p/hf-demo-gate.sh" >/dev/null
HF_ACCEPT_SET=demo HF_HARNESS_SHA="$harness_head" VECTA_REPO_DIR="$t/repo" "$p/hf-accept.sh" >/dev/null
HF_DEMO_GREENS=3 HF_DEMO_MIN_GAP_MIN=20 HF_DEMO_MAX_AGE_MIN=90 "$p/hf-demo-gate.sh" >/dev/null
jq -s -e '[.[] | select(.set == "demo")] | length == 3' "$t/hf-demo-accept.jsonl" >/dev/null
jq -s -e '[.[] | select(.set == "demo-refused" and .rc == 3)] | length == 1' "$t/hf-demo-accept.jsonl" >/dev/null
rm -f "$CALLS_LOG" "$t/hf-demo-accept.jsonl" "$t/hotfix-live.jsonl" "$t/accept.log"
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
rm -f "$t/pack/hotfix/hf-accept.sh"
if "$p/hf-accept.sh" >/dev/null 2>&1; then
  echo 'expected acceptance to fail when neither configuration nor legacy fallback exists' >&2
  exit 1
fi
mkdir -p "$t/pack/hotfix"
printf '#!/usr/bin/env bash\nprintf legacy > "$LEGACY_LOG"\n' > "$t/pack/hotfix/hf-accept.sh"
export LEGACY_LOG=$t/legacy
"$p/hf-accept.sh"
[[ $(cat "$LEGACY_LOG") == legacy ]]
