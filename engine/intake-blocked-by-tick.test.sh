#!/usr/bin/env bash
# The per-tick "Blocked by: #N" -> native blockedBy step (intake_tick_sync_blocked_by): one edge per
# body blocker, a rerun adds nothing, at most ZF_INTAKE_BLOCKED_BY_CAP (default 30) new edges per run,
# and the TypeSafe judge is never called. Runs the real lib.sh path against a fake gh.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TEST_HOME="$(mktemp -d)"
trap 'rm -rf -- "$TEST_HOME" "$test_env_root"' EXIT
export AGENT_HOME="$TEST_HOME/agent" REPO=fixture/repo
export FAKE_GH_LOG="$TEST_HOME/gh.log" FAKE_ISSUES_FILE="$TEST_HOME/issues.json"
export FAKE_DEPS_DIR="$TEST_HOME/deps" FAKE_CLOSED_FILE="$TEST_HOME/closed.txt"
export ZF_TS_JUDGE_SCRIPT="$TEST_HOME/judge.sh" TYPESAFE_API_KEY=fixture-key
mkdir -p "$AGENT_HOME/state" "$TEST_HOME/bin" "$FAKE_DEPS_DIR"
: > "$FAKE_GH_LOG"
: > "$FAKE_CLOSED_FILE"
printf '%s\n' '{"founder_login":"maintainer"}' >"$AGENT_HOME/recipients.json"
printf '#!/usr/bin/env bash\necho judged >> "%s/judge.log"\nexit 0\n' "$TEST_HOME" > "$ZF_TS_JUDGE_SCRIPT"
chmod +x "$ZF_TS_JUDGE_SCRIPT"

cat >"$TEST_HOME/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
if [[ "$1 $2" == 'issue list' ]]; then
  cat "$FAKE_ISSUES_FILE"
  exit 0
fi
if [[ "$1" == api && "$2" == --method && "$3" == POST ]]; then
  number="$(sed -nE 's#^repos/[^/]+/[^/]+/issues/([0-9]+)/dependencies/blocked_by$#\1#p' <<< "$4")"
  blocker=$(( ${6#issue_id=} - 10000 ))
  deps="$FAKE_DEPS_DIR/$number.json"
  [[ -f "$deps" ]] || printf '[]' > "$deps"
  jq -c --argjson n "$blocker" '. + [{"id":(10000+$n),"number":$n}]' "$deps" > "$deps.tmp" && mv "$deps.tmp" "$deps"
  exit 0
fi
if [[ "$1" == api && "$2" =~ ^repos/[^/]+/[^/]+/issues/([0-9]+)/dependencies/blocked_by$ ]]; then
  deps="$FAKE_DEPS_DIR/${BASH_REMATCH[1]}.json"
  if [[ -f "$deps" ]]; then cat "$deps"; else printf '[]\n'; fi
  exit 0
fi
if [[ "$1" == api && "$2" =~ ^repos/[^/]+/[^/]+/issues/([0-9]+)$ ]]; then
  n="${BASH_REMATCH[1]}"
  state=open
  grep -qx "$n" "$FAKE_CLOSED_FILE" && state=closed
  printf '{"id":%s,"number":%s,"state":"%s"}\n' "$((10000 + n))" "$n" "$state"
  exit 0
fi
echo "fake gh: unexpected $*" >&2
exit 2
FAKE_GH
chmod +x "$TEST_HOME/bin/gh"
export PATH="$TEST_HOME/bin:$PATH"

run_tick() { bash -e -u -o pipefail -c 'source "$1/lib.sh"; intake_tick_sync_blocked_by' _ "$SCRIPT_DIR"; }
posts() { grep -c -- '--method POST' "$FAKE_GH_LOG" || true; }

# Case 1: one body line, one edge; a rerun adds nothing.
cat >"$FAKE_ISSUES_FILE" <<'JSON'
[
  {"number":10,"body":""},
  {"number":11,"body":"Blocked by: #10"},
  {"number":12,"body":"**Blocked by:** #11"},
  {"number":15,"body":"Blocked by: #99"},
  {"number":16,"body":"Blocked by: #16"},
  {"number":17,"body":"no blockers here"}
]
JSON
printf '99\n' > "$FAKE_CLOSED_FILE"
run_tick
[[ "$(posts)" == 2 ]]
jq -e 'any(.[]; .number == 10)' "$FAKE_DEPS_DIR/11.json" >/dev/null
jq -e 'any(.[]; .number == 11)' "$FAKE_DEPS_DIR/12.json" >/dev/null
[[ ! -f "$FAKE_DEPS_DIR/15.json" && ! -f "$FAKE_DEPS_DIR/16.json" ]]
run_tick
[[ "$(posts)" == 2 ]]
grep -Fq -- '--state open --limit 1000 --json number,body' "$FAKE_GH_LOG"
[[ ! -f "$TEST_HOME/judge.log" ]]
echo 'case1 ok'

# Case 2: 40 pending edges, default cap 30: first tick adds 30, the next adds the remaining 10.
rm -rf -- "$FAKE_DEPS_DIR" && mkdir -p "$FAKE_DEPS_DIR" && : > "$FAKE_GH_LOG"
unset ZF_INTAKE_BLOCKED_BY_CAP
jq -cn '[{number:100,body:""}] + [range(101; 141) | {number:., body:"Blocked by: #100"}]' > "$FAKE_ISSUES_FILE"
run_tick
[[ "$(posts)" == 30 ]]
run_tick
[[ "$(posts)" == 40 ]]
run_tick
[[ "$(posts)" == 40 ]]
echo 'case2 ok'

# Case 3: kill switch and a failed issue list never fail the caller, and no write happens.
: > "$FAKE_GH_LOG"
ZF_INTAKE_BLOCKED_BY_ENABLED=0 run_tick
[[ ! -s "$FAKE_GH_LOG" ]]
FAKE_ISSUES_FILE=/nonexistent/issues.json bash -e -u -o pipefail -c 'source "$1/lib.sh"; intake_tick_sync_blocked_by || echo caller-kept-going' _ "$SCRIPT_DIR" > "$TEST_HOME/fail.out" 2>&1
grep -Fq 'caller-kept-going' "$TEST_HOME/fail.out"
echo 'case3 ok'
echo 'intake-blocked-by-tick: all cases passed'
