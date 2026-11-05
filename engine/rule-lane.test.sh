#!/usr/bin/env bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
rule_lane="$script_dir/rule-lane.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/rule-lane-test.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/repo"
log="$tmp/rule-lane.log"

fail() {
  printf 'rule-lane.test.sh: %s\n' "$*" >&2
  exit 1
}

git init -q "$repo"
git -C "$repo" config user.name 'rule-lane fixture'
git -C "$repo" config user.email 'rule-lane@example.invalid'
mkdir -p "$repo/engine/state"
cat > "$repo/engine/state/rule-files.json" <<'JSON'
{
  "schema": "zf-rule-files/v1",
  "files": {
    "engine/state/rule-files.json": "manifest",
    "engine/state/rulings.json": "rulings"
  }
}
JSON
printf '{"rulings":[]}\n' > "$repo/engine/state/rulings.json"
git -C "$repo" add engine/state
git -C "$repo" commit -q -m 'fixture: seed rule manifest'
base="$(git -C "$repo" rev-parse HEAD)"

new_rulings_head() {
  local contents="$1"
  git -C "$repo" reset --hard -q "$base"
  printf '%s\n' "$contents" > "$repo/engine/state/rulings.json"
  git -C "$repo" add engine/state/rulings.json
  git -C "$repo" commit -q -m 'fixture: change rulings'
  git -C "$repo" rev-parse HEAD
}

# Units remain unable to change control rules.
head="$(new_rulings_head '{"rulings":["unit"]}')"
if (cd -- "$repo" && ZF_AGENT_NAME=unit ZF_PACK_REL=engine bash "$rule_lane" "$base" "$head") > "$log" 2>&1; then
  fail 'unit change to a rule file was accepted'
else
  status=$?
fi
[[ "$status" == 1 ]] || fail "unit rejection exited $status instead of 1"
grep -Fq 'rule-lane: decision=unit-reject refused=rule-files actor=unit touched=1 files=engine/state/rulings.json' "$log" \
  || fail 'unit rejection did not retain its authority-boundary decision'

# Supervisors can land valid rule JSON without a Rule-Replay trailer.
head="$(new_rulings_head '{"rulings":["supervisor"]}')"
if (cd -- "$repo" && ZF_AGENT_NAME=supervisor ZF_PACK_REL=engine bash "$rule_lane" "$base" "$head") > "$log" 2>&1; then
  status=0
else
  status=$?
fi
[[ "$status" == 0 ]] || { cat "$log" >&2; fail "valid supervisor rule edit exited $status"; }
grep -Fq 'rule-lane: decision=rule-lane actor=supervisor touched=1 check=syntax' "$log" \
  || fail 'supervisor syntax-only decision line missing'

# Invalid rule JSON is still rejected at the candidate head.
head="$(new_rulings_head '{ invalid json')"
if (cd -- "$repo" && ZF_AGENT_NAME=supervisor ZF_PACK_REL=engine bash "$rule_lane" "$base" "$head") > "$log" 2>&1; then
  fail 'invalid supervisor rule JSON was accepted'
else
  status=$?
fi
[[ "$status" == 1 ]] || fail "invalid JSON rejection exited $status instead of 1"
grep -Fq 'rule-lane: decision=rule-reject refused=syntax path=engine/state/rulings.json' "$log" \
  || fail 'invalid JSON rejection did not identify the syntax failure'

# The copied manifest keeps legacy paths but protects target-config copies too.
git -C "$repo" reset --hard -q "$base"
mkdir -p "$repo/.zenoforge/state"
cp "$repo/engine/state/rule-files.json" "$repo/.zenoforge/state/rule-files.json"
cp "$repo/engine/state/rulings.json" "$repo/.zenoforge/state/rulings.json"
git -C "$repo" add .zenoforge
git -C "$repo" commit -q -m 'fixture: add target config overrides'
config_base="$(git -C "$repo" rev-parse HEAD)"
printf '{"rulings":["config-unit"]}\n' > "$repo/.zenoforge/state/rulings.json"
git -C "$repo" add .zenoforge/state/rulings.json
git -C "$repo" commit -q -m 'fixture: change target config ruling'
config_head="$(git -C "$repo" rev-parse HEAD)"
if (cd -- "$repo" && ZF_AGENT_NAME=unit ZF_REPO_DIR="$repo" ZF_ENGINE_DIR="$script_dir" \
  bash "$rule_lane" "$config_base" "$config_head") > "$log" 2>&1; then
  fail 'unit change to a target-config rule file was accepted'
else
  status=$?
fi
[[ "$status" == 1 ]] || fail "target-config rule rejection exited $status instead of 1"
grep -Fq 'rule-lane: decision=unit-reject refused=rule-files actor=unit touched=1 files=.zenoforge/state/rulings.json' "$log" \
  || fail 'legacy manifest path was not mapped to the target-config copy'

# A vendored pack (ZF_PACK_REL) is protected under its prefix, a trailing-slash key covers a directory,
# and the rest of the scheduler stays open to units.
git -C "$repo" reset --hard -q "$base"
pack=.zenoforge/build/pack
mkdir -p "$repo/$pack/state" "$repo/$pack/supervisor/hooks" "$repo/$pack/mac-autopilot"
cat > "$repo/$pack/state/rule-files.json" <<'JSON'
{
  "schema": "zf-rule-files/v1",
  "files": {
    "engine/state/rule-files.json": "manifest",
    "engine/rule-lane.sh": "the check",
    "engine/supervisor/hooks/": "hooks directory"
  }
}
JSON
printf 'x\n' > "$repo/$pack/supervisor/hooks/gate.cjs"
printf 'x\n' > "$repo/$pack/mac-autopilot/scheduler.sh"
printf 'x\n' > "$repo/$pack/rule-lane.sh"
git -C "$repo" add .zenoforge
git -C "$repo" commit -q -m 'fixture: vendored pack'
pack_base="$(git -C "$repo" rev-parse HEAD)"
pack_run() { (cd -- "$repo" && ZF_AGENT_NAME=unit ZF_PACK_REL="$pack" bash "$rule_lane" "$pack_base" "$1") > "$log" 2>&1; }
for changed in supervisor/hooks/gate.cjs rule-lane.sh; do
  git -C "$repo" reset --hard -q "$pack_base"
  printf 'y\n' > "$repo/$pack/$changed"
  git -C "$repo" commit -q -am 'fixture: unit edit'
  if pack_run "$(git -C "$repo" rev-parse HEAD)"; then fail "unit edit to vendored $changed was accepted"; fi
  grep -Fq "decision=unit-reject refused=rule-files actor=unit touched=1 files=$pack/$changed" "$log" \
    || fail "vendored $changed rejection line missing"
done
git -C "$repo" reset --hard -q "$pack_base"
printf 'y\n' > "$repo/$pack/mac-autopilot/scheduler.sh"
git -C "$repo" commit -q -am 'fixture: unit scheduler edit'
pack_run "$(git -C "$repo" rev-parse HEAD)" || { cat "$log" >&2; fail 'unit scheduler edit was refused'; }

# The shipped manifest names the check, itself, and at least one file per protected area.
for key in engine/rule-lane.sh engine/state/rule-files.json tools/merge-pr.sh engine/mac-autopilot/scheduler.d/merge-lane.sh \
  engine/mac-autopilot/scheduler.d/review-rules.sh engine/mac-autopilot/scheduler.d/evals-arbiter.sh tools/pin-vecta.sh \
  engine/supervisor/watch/ engine/deploy-culprit.sh engine/redact-secrets.sh; do
  jq -e --arg key "$key" '.files | has($key)' "$script_dir/state/rule-files.json" >/dev/null \
    || fail "shipped rule-files.json does not protect $key"
done

printf 'rule-lane tests passed\n'
