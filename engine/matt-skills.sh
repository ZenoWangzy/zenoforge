#!/usr/bin/env bash
# Where an agent finds a Matt skill. Source this, do not execute it. Needs no other engine file, so lib.sh,
# the unit-loop scheduler (which does not source lib.sh) and engine/bin/* all use this one definition.
#
# The target repository's .zenoforge/skills/<name>/SKILL.md wins, followed by its migration
# .agents/skills/<name>/SKILL.md. Both paths are relative because the agent works in that checkout.
# When neither target copy exists, the engine's vendored copy (.agents/skills, pinned by
# .agents/matt-skills.manifest.json) is used by absolute path. Skill files link to their siblings
# relatively, so all three forms resolve.
_MATT_SKILLS_ENGINE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/.agents/skills"

# matt_engine_skill_md <name> -> absolute path of the engine's own copy; for stages that must not follow a method file
# from the code under review (reviewers).
matt_engine_skill_md() { printf '%s/%s/SKILL.md\n' "$_MATT_SKILLS_ENGINE_DIR" "$1"; }

matt_target_skill_revision_is_pinned() {
  local checkout="$1" path="$2" version_root product_sha
  version_root="$(cd -- "$(dirname -- "$_MATT_SKILLS_ENGINE_DIR")/.." && pwd -P)"
  [[ -r "$version_root/BUILD-INFO" ]] || return 0
  product_sha="$(sed -n 's/^product_sha=//p' "$version_root/BUILD-INFO" | head -n1)"
  [[ -n "$product_sha" ]] || product_sha="$(sed -n 's/^pack_sha=\([0-9a-f]*\):.*/\1/p' "$version_root/BUILD-INFO" | head -n1)"
  [[ -n "$product_sha" ]] || return 1
  git -C "$checkout" diff --quiet "$product_sha" -- "$path" 2>/dev/null
}

# matt_skill_md <name> [<checkout>] -> path of that skill's SKILL.md, readable from <checkout> (default: cwd)
matt_skill_md() {
  local name="$1" checkout="${2:-.}"
  if [ -f "$checkout/.zenoforge/skills/$name/SKILL.md" ]; then
    if matt_target_skill_revision_is_pinned "$checkout" ".zenoforge/skills/$name/SKILL.md"; then
      printf '.zenoforge/skills/%s/SKILL.md\n' "$name"
    else
      matt_engine_skill_md "$name"
    fi
  elif [ -f "$checkout/.agents/skills/$name/SKILL.md" ]; then
    if matt_target_skill_revision_is_pinned "$checkout" ".agents/skills/$name/SKILL.md"; then
      printf '.agents/skills/%s/SKILL.md\n' "$name"
    else
      matt_engine_skill_md "$name"
    fi
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

# pstack_skill_md <name> -> absolute path of a vendored pstack skill (vendor/pstack, see its UPSTREAM file).
_PSTACK_SKILLS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/vendor/pstack/skills"
pstack_skill_md() { printf '%s/%s/SKILL.md\n' "$_PSTACK_SKILLS_DIR" "$1"; }
