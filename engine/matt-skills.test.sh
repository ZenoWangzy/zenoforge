#!/usr/bin/env bash
# matt-skills.sh: a target repository's own skill wins, otherwise the engine's vendored copy answers.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/matt-skills.sh"
fail() { echo "matt-skills.test.sh: $*" >&2; exit 1; }

engine_skills="$(cd -- "$SCRIPT_DIR/.." && pwd -P)/.agents/skills"
target="$test_env_root/target"
mkdir -p "$target/.agents/skills/tdd"
: > "$target/.agents/skills/tdd/SKILL.md"
mkdir -p "$target/.zenoforge/skills/tdd"
: > "$target/.zenoforge/skills/tdd/SKILL.md"

[[ "$(matt_skill_md tdd "$target")" == .zenoforge/skills/tdd/SKILL.md ]] || fail "target config skill must win, as a relative path"
rm "$target/.zenoforge/skills/tdd/SKILL.md"
[[ "$(matt_skill_md tdd "$target")" == .agents/skills/tdd/SKILL.md ]] || fail "target's migration skill must win, as a relative path"
[[ "$(matt_skill_md triage "$target")" == "$engine_skills/triage/SKILL.md" ]] || fail "missing in target must fall back to the engine copy"
[[ "$(cd "$test_env_root" && matt_skill_md triage)" == "$engine_skills/triage/SKILL.md" ]] || fail "no checkout argument must fall back to the engine copy outside a repo with skills"
mkdir -p "$target/.agents/skills/code-review"; : > "$target/.agents/skills/code-review/SKILL.md"
mkdir -p "$target/.zenoforge/skills/code-review"; : > "$target/.zenoforge/skills/code-review/SKILL.md"
[[ "$(matt_skill_md code-review "$target")" == .zenoforge/skills/code-review/SKILL.md ]] || fail "target config review skill must win for normal lookup"
[[ "$(matt_engine_skill_md code-review)" == "$engine_skills/code-review/SKILL.md" ]] || fail "engine-only lookup must ignore the target's own skill"
for name in ask-matt triage to-spec to-tickets implement tdd diagnosing-bugs code-review setup-matt-pocock-skills; do
  [[ -f "$engine_skills/$name/SKILL.md" ]] || fail "the engine must vendor $name"
done
note="$(matt_skills_note "$target" tdd triage)"
[[ "$note" == *"tdd=.agents/skills/tdd/SKILL.md; triage=$engine_skills/triage/SKILL.md" ]] || fail "unexpected note: $note"
# Every stage prompt builder names its Matt skill. Exception: release (engine/run-release.sh has no agent prompt on origin/main).
for entry in run-triage.sh:ask-matt run-triage-batch.sh:ask-matt run-recut.sh:to-tickets run-advisor.sh:ask-matt run-advisor-batch.sh:ask-matt; do
  script="${entry%%:*}" skill="${entry##*:}"
  grep -Eq "matt_skills_note .*\b$skill\b" "$SCRIPT_DIR/$script" || fail "$script must name Matt skill $skill in its prompt"
  [[ -f "$engine_skills/$skill/SKILL.md" ]] || fail "Matt skill $skill for $script is not vendored"
done
echo 'matt-skills.test.sh: PASS'
