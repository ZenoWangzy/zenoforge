#!/usr/bin/env bash
# Where an agent finds a Matt skill. Source this, do not execute it. Needs no other engine file, so lib.sh,
# the unit-loop scheduler (which does not source lib.sh) and engine/bin/* all use this one definition.
#
# The target repository's own .agents/skills/<name>/SKILL.md wins (the path is relative: the agent works in
# that checkout). When the target has none, the engine's vendored copy (<engine repo>/.agents/skills, pinned by
# .agents/matt-skills.manifest.json) is used by absolute path. Skill files link to their siblings relatively,
# so both forms resolve.
_MATT_SKILLS_ENGINE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/.agents/skills"

# matt_engine_skill_md <name> -> absolute path of the engine's own copy; for stages that must not follow a method file
# from the code under review (reviewers).
matt_engine_skill_md() { printf '%s/%s/SKILL.md\n' "$_MATT_SKILLS_ENGINE_DIR" "$1"; }

# matt_skill_md <name> [<checkout>] -> path of that skill's SKILL.md, readable from <checkout> (default: cwd)
matt_skill_md() {
  local name="$1" checkout="${2:-.}"
  if [ -f "$checkout/.agents/skills/$name/SKILL.md" ]; then
    printf '.agents/skills/%s/SKILL.md\n' "$name"
  else
    matt_engine_skill_md "$name"
  fi
}

# matt_skills_note <checkout> <name>... -> the one prompt line that tells a stage where its skills are
matt_skills_note() {
  local checkout="$1" name out=""
  shift
  for name in "$@"; do out+="${out:+; }$name=$(matt_skill_md "$name" "$checkout")"; done
  printf 'Matt skill files for this run (the Method section names the ones to read): %s\n' "$out"
}
