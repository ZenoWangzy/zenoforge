#!/usr/bin/env bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
land_script="$script_dir/land-direct-main.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/syntax-only-landing-test.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/repo"
function_file="$tmp/syntax-only-landing.sh"

fail() {
  printf 'syntax-only-landing.test.sh: %s\n' "$*" >&2
  exit 1
}

sed -n '/^syntax_only_landing() {$/,/^}$/p' "$land_script" > "$function_file"
[[ -s "$function_file" ]] || fail 'could not extract syntax_only_landing'
source "$function_file"
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
printf 'syntax-only-landing tests passed\n'
