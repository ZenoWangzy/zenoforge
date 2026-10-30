#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
CHECKER="$REPO_DIR/engine/check-pipeline-lesson-window.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/repo"

mkdir -p "$repo/engine" "$repo/lessons"
git -C "$repo" init -q
git -C "$repo" config user.name test
git -C "$repo" config user.email test@example.invalid
printf 'base\n' > "$repo/engine/base.sh"
printf 'base\n' > "$repo/lessons/RULES.md"
printf 'base\n' > "$repo/lessons/CATALOG.md"
git -C "$repo" add .
git -C "$repo" commit -qm base

printf 'fix\n' > "$repo/engine/check-rulings.sh"
git -C "$repo" add engine/check-rulings.sh
git -C "$repo" commit -qm 'pipeline fix'
bash "$CHECKER" "$repo"

printf 'lesson\n' >> "$repo/lessons/RULES.md"
printf 'lesson\n' >> "$repo/lessons/CATALOG.md"
git -C "$repo" add lessons/RULES.md lessons/CATALOG.md
git -C "$repo" commit -qm 'separate lesson docs push'
bash "$CHECKER" "$repo"

printf 'late fix\n' >> "$repo/engine/check-rulings.sh"
git -C "$repo" add engine/check-rulings.sh
GIT_AUTHOR_DATE='2000-01-01T00:00:00Z' GIT_COMMITTER_DATE='2000-01-01T00:00:00Z' \
  git -C "$repo" commit -qm 'late unrecorded fix'
set +e
bash "$CHECKER" "$repo"
status=$?
set -e
[[ "$status" -ne 0 ]]

echo "check-pipeline-lesson-window.test.sh: PASS"
