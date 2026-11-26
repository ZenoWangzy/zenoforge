#!/usr/bin/env bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
land_script="$script_dir/land-direct-main.sh"
land_script_dir="$script_dir"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/syntax-only-landing-test.XXXXXX")"
trap 'rm -rf -- "$tmp" "$test_env_root"' EXIT
repo="$tmp/repo"
lane_log="$tmp/rule-lane.log"

fail() {
  printf 'syntax-only-landing.test.sh: %s\n' "$*" >&2
  exit 1
}

source "$script_dir/land-direct-main-policy.sh"
export ZF_PACK_REL=engine

git init -q "$repo"
git -C "$repo" config user.name 'syntax-only-landing fixture'
git -C "$repo" config user.email 'syntax-only-landing@example.invalid'
mkdir -p "$repo/seed"
printf 'fixture\n' > "$repo/seed/base.txt"
git -C "$repo" add seed/base.txt
git -C "$repo" commit -q -m 'fixture: seed classifier repo'
base="$(git -C "$repo" rev-parse HEAD)"

new_case() {
  git -C "$repo" reset --hard -q "$base"
  git -C "$repo" clean -fdq
}

assert_result() {
  local expected="$1" head="$2" label="$3" status
  if (cd -- "$repo" && syntax_only_landing "$base" "$head"); then
    status=0
  else
    status=$?
  fi
  [[ "$status" == "$expected" ]] || fail "$label classified with exit $status, expected $expected"
}

# Markdown-only documentation is syntax-only.
new_case
mkdir -p "$repo/docs"
printf '# Guide\n' > "$repo/docs/guide.md"
git -C "$repo" add docs/guide.md
git -C "$repo" commit -q -m 'fixture: docs only'
assert_result 0 "$(git -C "$repo" rev-parse HEAD)" 'docs-only range'

# A ruling and a lesson remain syntax-only together.
new_case
mkdir -p "$repo/engine/state" "$repo/lessons"
printf '{"rulings":[]}\n' > "$repo/engine/state/rulings.json"
printf '# Lesson\n' > "$repo/lessons/L1.md"
git -C "$repo" add engine/state/rulings.json lessons/L1.md
git -C "$repo" commit -q -m 'fixture: ruling and lesson'
assert_result 0 "$(git -C "$repo" rev-parse HEAD)" 'ruling plus lesson range'

# Product source and engine code stay on the full verification path.
new_case
mkdir -p "$repo/packages"
printf 'export const x = 1;\n' > "$repo/packages/x.ts"
git -C "$repo" add packages/x.ts
git -C "$repo" commit -q -m 'fixture: product source'
assert_result 1 "$(git -C "$repo" rev-parse HEAD)" 'package source range'

new_case
mkdir -p "$repo/engine"
printf '#!/usr/bin/env bash\n' > "$repo/engine/foo.sh"
git -C "$repo" add engine/foo.sh
git -C "$repo" commit -q -m 'fixture: engine source'
assert_result 1 "$(git -C "$repo" rev-parse HEAD)" 'engine shell range'

assert_result 1 "$base" 'empty range'

assert_actor() {
  local expected="$1" actor_name="$2" head="$3" label="$4" actor
  actor="$(cd -- "$repo" && ZF_AGENT_NAME="$actor_name" land_direct_main_rule_actor "$base" "$head")"
  [[ "$actor" == "$expected" ]] || fail "$label routed as $actor instead of $expected"
}

assert_unit_rejected() {
  local path="$1" head="$2" label="$3" actor status
  actor="$(cd -- "$repo" && ZF_AGENT_NAME=unit:agent/issue-probe land_direct_main_rule_actor "$base" "$head")"
  if (cd -- "$repo" && ZF_AGENT_NAME="$actor" ZF_ENGINE_DIR="$script_dir" ZF_REPO_DIR="$repo" \
    ZF_CONFIG_ROOT="$repo/.zenoforge" bash "$script_dir/rule-lane.sh" "$base" "$head") > "$lane_log" 2>&1; then
    fail "$label unit actor was accepted by rule-lane"
  else
    status=$?
  fi
  [[ "$status" == 1 ]] || fail "$label unit rejection exited $status instead of 1"
  grep -Fq "rule-lane: decision=unit-reject refused=rule-files actor=unit:agent/issue-probe touched=1 files=$path" "$lane_log" \
    || fail "$label unit rejection decision missing"
}

assert_supervisor_actor() {
  local path="$1" contents="$2" label="$3" head
  new_case
  mkdir -p "$(dirname -- "$repo/$path")"
  printf '%s\n' "$contents" > "$repo/$path"
  git -C "$repo" add "$path"
  git -C "$repo" commit -q -m 'fixture: change judged config'
  head="$(git -C "$repo" rev-parse HEAD)"
  assert_result 0 "$head" "$label"
  assert_actor supervisor head "$head" "$label owner session"
  assert_actor supervisor '' "$head" "$label unlabelled session"
  assert_actor unit:agent/issue-probe unit:agent/issue-probe "$head" "$label unit actor"
  assert_unit_rejected "$path" "$head" "$label"
}

assert_supervisor_actor .zenoforge/prompts/review-contract.md 'Review contract' 'review contract'
assert_supervisor_actor .zenoforge/state/risk-paths.json '{"rules":[]}' 'risk path rules'
assert_supervisor_actor .zenoforge/eval/cases/triage.json '{"case":"unit"}' 'eval case'

pack=.zenoforge/build/pack
export ZF_PACK_REL="$pack"
assert_supervisor_actor "$pack/prompts/review-contract.md" 'Review contract' 'vendored review contract'
assert_supervisor_actor "$pack/state/risk-paths.json" '{"rules":[]}' 'vendored risk path rules'
assert_supervisor_actor "$pack/eval/cases/triage.json" '{"case":"unit"}' 'vendored eval case'
export ZF_PACK_REL=engine

new_case
mkdir -p "$repo/packages"
printf 'export const value = 1;\n' > "$repo/packages/value.ts"
git -C "$repo" add packages/value.ts
git -C "$repo" commit -q -m 'fixture: change product source'
head="$(git -C "$repo" rev-parse HEAD)"
assert_result 1 "$head" 'product source range'
assert_actor unit:agent/issue-probe unit:agent/issue-probe "$head" 'product source range'

printf 'syntax-only-landing tests passed\n'
