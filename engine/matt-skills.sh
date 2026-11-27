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
matt_version_root() {
  local skills_parent
  skills_parent="$(dirname -- "$_MATT_SKILLS_ENGINE_DIR")"
  if [[ -d "$skills_parent" ]]; then
    (cd -- "$skills_parent/.." && pwd -P)
  else
    (cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
  fi
}

# matt_engine_skill_md <name> -> absolute path of the engine's own copy; for stages that must not follow a method file
# from the code under review (reviewers).
matt_engine_skill_md() { printf '%s/%s/SKILL.md\n' "$_MATT_SKILLS_ENGINE_DIR" "$1"; }

matt_target_file_revision_is_pinned() {
  local checkout="$1" path="$2" version_root product_sha
  version_root="$(matt_version_root)"
  [[ -r "$version_root/BUILD-INFO" ]] || return 1
  product_sha="$(sed -n 's/^product_sha=//p' "$version_root/BUILD-INFO" | head -n1)"
  [[ -n "$product_sha" ]] || product_sha="$(sed -n 's/^pack_sha=\([0-9a-f]*\):.*/\1/p' "$version_root/BUILD-INFO" | head -n1)"
  [[ -n "$product_sha" ]] || return 1
  if [[ -e "$checkout/$path" ]]; then
    git -C "$checkout" ls-files --error-unmatch -- "$path" >/dev/null 2>&1 || return 1
  fi
  git -C "$checkout" diff --quiet "$product_sha" -- "$path" 2>/dev/null
}

matt_target_product_file() {
  [[ $# -eq 2 ]] || return 2
  local checkout="$1" path="$2" version_root product_sha
  version_root="$(matt_version_root)"
  [[ -r "$version_root/BUILD-INFO" ]] || return 1
  product_sha="$(sed -n 's/^product_sha=//p' "$version_root/BUILD-INFO" | head -n1)"
  [[ -n "$product_sha" ]] || product_sha="$(sed -n 's/^pack_sha=\([0-9a-f]*\):.*/\1/p' "$version_root/BUILD-INFO" | head -n1)"
  [[ -n "$product_sha" ]] || return 1
  git -C "$checkout" cat-file -e "$product_sha:$path" 2>/dev/null || return 1
  [[ -f "$version_root/$path" ]] || return 1
  printf '%s\n' "$version_root/$path"
}

matt_codex_context_root() {
  local checkout="$1" path version_root
  version_root="$(matt_version_root)"
  for path in CLAUDE.md AGENTS.md AGENTS.override.md; do
    if ! matt_target_file_revision_is_pinned "$checkout" "$path"; then
      printf '%s\n' "$version_root"
      return
    fi
  done
  printf '%s\n' "$checkout"
}

matt_codex_context_prepare() {
  local checkout="$1" product_root="${2:-}"
  MATT_CODEX_CONTEXT_ROOT="$(matt_codex_context_root "$checkout")"
  MATT_CODEX_INSTRUCTIONS_ROOT="${ZF_EVAL_CANDIDATE_ROOT:-$MATT_CODEX_CONTEXT_ROOT}"
  MATT_CODEX_CONTEXT_ARGS=(--cd "$MATT_CODEX_CONTEXT_ROOT" --skip-git-repo-check)
  MATT_CODEX_CONTEXT_NOTE=''
  if [[ "$MATT_CODEX_CONTEXT_ROOT" != "$checkout" ]]; then
    MATT_CODEX_CONTEXT_ARGS+=(--add-dir "$checkout")
    MATT_CODEX_CONTEXT_NOTE=$'\n\nTarget checkout path: '"$checkout"$'\nUse that checkout for repository files and commands.'
  fi
  if [[ -n "$product_root" && "$product_root" != "$MATT_CODEX_CONTEXT_ROOT" && "$product_root" != "$checkout" ]]; then
    MATT_CODEX_CONTEXT_ARGS+=(--add-dir "$product_root")
    MATT_CODEX_CONTEXT_NOTE+=$'\n\nCandidate product root path: '"$product_root"$'\nUse it for the skill files named in this evaluation prompt.'
  fi
}

matt_instruction_context_text() {
  local root="$1" path
  for path in CLAUDE.md AGENTS.md AGENTS.override.md; do
    [[ -f "$root/$path" ]] || continue
    printf '\n\n## Project instruction file: %s\n' "$path"
    cat -- "$root/$path" || return
  done
}

matt_codex_prompt_input() {
  [[ $# -eq 3 ]] || return 2
  cat -- "$1" || return
  if [[ -n "${MATT_CODEX_CONTEXT_NOTE:-}" ]]; then
    printf '%s\n' "$MATT_CODEX_CONTEXT_NOTE"
  elif [[ "$2" != "$3" ]]; then
    printf '\nTarget checkout path: %s\nUse that checkout for repository files and commands.\n' "$2"
  fi
  if [[ -n "${ZF_EVAL_CANDIDATE_ROOT:-}" ]]; then
    matt_instruction_context_text "$MATT_CODEX_INSTRUCTIONS_ROOT"
  fi
}

matt_claude_prompt_input() {
  [[ $# -eq 3 ]] || return 2
  matt_codex_prompt_input "$1" "$2" "$3" || return
  if [[ -z "${ZF_EVAL_CANDIDATE_ROOT:-}" ]]; then
    matt_instruction_context_text "$MATT_CODEX_INSTRUCTIONS_ROOT"
  fi
}

# matt_skill_md <name> [<checkout>] -> path of that skill's SKILL.md, readable from <checkout> (default: cwd)
matt_skill_md() {
  local name="$1" checkout="${2:-.}" path
  for path in ".zenoforge/skills/$name/SKILL.md" ".agents/skills/$name/SKILL.md"; do
    if [[ -f "$checkout/$path" ]]; then
      if matt_target_file_revision_is_pinned "$checkout" "$path"; then
        printf '%s\n' "$path"
      else
        matt_target_product_file "$checkout" "$path" || matt_engine_skill_md "$name"
      fi
      return
    fi
    if ! matt_target_file_revision_is_pinned "$checkout" "$path"; then
      matt_target_product_file "$checkout" "$path" || matt_engine_skill_md "$name"
      return
    fi
  done
  matt_engine_skill_md "$name"
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
