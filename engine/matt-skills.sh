#!/usr/bin/env bash
# Resolve Matt skill files for a worker checkout and for the pinned engine checkout.
# the product keeps engine two levels below the repository root, unlike the public engine layout.
_MATT_SKILLS_ENGINE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/.agents/skills"

# matt_engine_skill_md <name> -> absolute path in the pinned engine checkout.
matt_engine_skill_md() { printf '%s/%s/SKILL.md\n' "$_MATT_SKILLS_ENGINE_DIR" "$1"; }

# matt_skill_md <name> [<checkout>] -> path readable from the worker's checkout.
matt_skill_md() {
  local name="$1" checkout="${2:-.}"
  if [ -f "$checkout/.agents/skills/$name/SKILL.md" ]; then
    printf '.agents/skills/%s/SKILL.md\n' "$name"
  else
    matt_engine_skill_md "$name"
  fi
}

# matt_skills_note <checkout> <name>... -> one prompt line naming the skills for a stage.
matt_skills_note() {
  local checkout="$1" name out=""
  shift
  for name in "$@"; do out+="${out:+; }$name=$(matt_skill_md "$name" "$checkout")"; done
  printf 'Matt skill files for this run: %s\n' "$out"
}

# pstack_skill_md <name> -> absolute path of a vendored pstack skill (vendor/pstack, see its UPSTREAM file).
_PSTACK_SKILLS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/vendor/pstack/skills"
pstack_skill_md() { printf '%s/%s/SKILL.md\n' "$_PSTACK_SKILLS_DIR" "$1"; }
