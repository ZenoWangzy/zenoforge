#!/usr/bin/env bash
# tools/sync-matt-skills.sh against a local fake upstream: vendors every non-deprecated bucket byte-identical (even skills
# outside plugin.json), skips skills/deprecated/, writes the manifest and symlinks, and a second sync at a newer commit
# drops files upstream removed.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fail() { echo "sync-matt-skills.test.sh: $*" >&2; exit 1; }

up="$test_env_root/upstream"
mkdir -p "$up/skills/engineering/alpha/sub" "$up/skills/engineering/beta" "$up/skills/misc/skipped" "$up/skills/deprecated/old" "$up/.claude-plugin"
echo alpha > "$up/skills/engineering/alpha/SKILL.md"
echo helper > "$up/skills/engineering/alpha/sub/notes.md"
echo beta > "$up/skills/engineering/beta/SKILL.md"
echo skipped > "$up/skills/misc/skipped/SKILL.md"
echo old > "$up/skills/deprecated/old/SKILL.md"
echo 'MIT fake' > "$up/LICENSE"
echo '{"skills":["./skills/engineering/alpha","./skills/engineering/beta"]}' > "$up/.claude-plugin/plugin.json"
git -C "$up" init -q
git -C "$up" add -A
git -C "$up" -c user.name=ci -c user.email=ci@example.com commit -qm one
first="$(git -C "$up" rev-parse HEAD)"

repo="$test_env_root/repo"
mkdir -p "$repo/tools"
cp "$SCRIPT_DIR/../tools/sync-matt-skills.sh" "$repo/tools/"
export MATT_SKILLS_UPSTREAM="file://$up"
bash "$repo/tools/sync-matt-skills.sh" "$first" > /dev/null

cmp "$up/skills/engineering/alpha/sub/notes.md" "$repo/.agents/skills/alpha/sub/notes.md" || fail "file not byte-identical"
cmp "$up/LICENSE" "$repo/.agents/skills/LICENSE-mattpocock-skills" || fail "upstream license not kept"
[[ -f "$repo/.agents/skills/skipped/SKILL.md" && -L "$repo/.claude/skills/skipped" ]] || fail "a non-deprecated skill outside plugin.json was not vendored"
[[ ! -e "$repo/.agents/skills/old" && ! -e "$repo/.claude/skills/old" ]] || fail "a deprecated skill was vendored"
[[ "$(readlink "$repo/.claude/skills/beta")" == ../../.agents/skills/beta ]] || fail "symlink must be relative"
[[ "$(cat "$repo/.claude/skills/alpha/SKILL.md")" == alpha ]] || fail "symlink must resolve"
jq -e --arg c "$first" '.upstream == env.MATT_SKILLS_UPSTREAM and .commit == $c and (.date | length > 0)
  and (.files | index("alpha/sub/notes.md")) != null and (.files | index("LICENSE-mattpocock-skills")) != null' \
  "$repo/.agents/matt-skills.manifest.json" > /dev/null || fail "manifest wrong: $(cat "$repo/.agents/matt-skills.manifest.json")"

git -C "$up" rm -q -r skills/engineering/alpha/sub skills/engineering/beta
echo '{"skills":["./skills/engineering/alpha"]}' > "$up/.claude-plugin/plugin.json"
git -C "$up" add -A
git -C "$up" -c user.name=ci -c user.email=ci@example.com commit -qm two
second="$(git -C "$up" rev-parse HEAD)"
bash "$repo/tools/sync-matt-skills.sh" "$second" > /dev/null

[[ ! -e "$repo/.agents/skills/alpha/sub" ]] || fail "a file removed upstream survived the re-sync"
[[ ! -e "$repo/.agents/skills/beta" && ! -L "$repo/.claude/skills/beta" ]] || fail "a skill removed upstream survived"
[[ "$(jq -r .commit "$repo/.agents/matt-skills.manifest.json")" == "$second" ]] || fail "manifest not repinned"
echo 'sync-matt-skills.test.sh: PASS'
