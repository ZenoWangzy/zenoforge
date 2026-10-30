#!/usr/bin/env bash
# Re-vendor Matt Pocock's skills (MIT, https://github.com/mattpocock/skills) into .agents/skills at one upstream commit.
# Usage: tools/sync-matt-skills.sh [<full-sha|tag|branch>]    (default: main)
# The skill set is the "skills" array of upstream .claude-plugin/plugin.json at that commit, the promoted set the upstream
# plugin ships. Files are extracted byte-identical with git archive; .agents/matt-skills.manifest.json is rewritten and the
# .claude/skills/<name> relative symlinks are recreated. Nothing here is hand-edited: re-run this script to change a pin.
set -euo pipefail
cd "$(dirname "$0")/.."
upstream=${MATT_SKILLS_UPSTREAM:-https://github.com/mattpocock/skills}
ref=${1:-main}
manifest=.agents/matt-skills.manifest.json
license=LICENSE-mattpocock-skills

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
git init -q "$tmp/up"
git -C "$tmp/up" fetch -q --depth 1 "$upstream" "$ref"
commit=$(git -C "$tmp/up" rev-parse FETCH_HEAD)
date=$(git -C "$tmp/up" show -s --format=%cI "$commit")
mkdir "$tmp/src"
git -C "$tmp/up" archive "$commit" | tar -x -C "$tmp/src"

mapfile -t paths < <(jq -r '.skills[]' "$tmp/src/.claude-plugin/plugin.json")
[ "${#paths[@]}" -gt 0 ] || { echo "sync-matt-skills: no skills in upstream plugin.json at $commit" >&2; exit 1; }
for p in "${paths[@]}"; do
  [ -f "$tmp/src/$p/SKILL.md" ] || { echo "sync-matt-skills: $p has no SKILL.md at $commit" >&2; exit 1; }
done

# Drop what the previous sync installed (so files removed upstream disappear), then install the new set.
if [ -f "$manifest" ]; then
  jq -r '.files[] | split("/")[0]' "$manifest" | sort -u | while read -r name; do
    if [ "$name" = "$license" ]; then rm -f ".agents/skills/$name"; else rm -rf ".agents/skills/$name" ".claude/skills/$name"; fi
  done
fi
mkdir -p .agents/skills .claude/skills
for p in "${paths[@]}"; do
  name=$(basename "$p")
  cp -a "$tmp/src/$p" ".agents/skills/$name"
  ln -sfn "../../.agents/skills/$name" ".claude/skills/$name"
done
cp "$tmp/src/LICENSE" ".agents/skills/$license"

{ cd .agents/skills && for p in "${paths[@]}"; do find "$(basename "$p")" -type f; done; echo "$license"; } | LC_ALL=C sort \
  | jq -R . | jq -s --arg upstream "$upstream" --arg commit "$commit" --arg date "$date" \
    '{upstream: $upstream, commit: $commit, date: $date, files: .}' > "$manifest"

echo "sync-matt-skills: ${#paths[@]} skills at $commit ($date), $(jq '.files | length' "$manifest") files"
