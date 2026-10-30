#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DEFAULT_REPO="${ZF_REPO_DIR:-$(cd -- "$SCRIPT_DIR/.." && pwd -P)}"

usage() {
  echo "Usage: $0 --check|--fold [repo-root] [incident-guards.json] [--files fragment.json ...]" >&2
}

# A fragment whose guard is already registered and whose full lesson no longer says V-NEXT was folded before.
# A branch that carried a copy of it (cherry-pick, long-lived hot-fix chain) brings the JSON back on merge,
# and --check then failed every landing (2026-10-04: 16 such files on main after PR 2457). --check skips
# these and --fold deletes them.
stale_fragment() {
  local repo="$1" registry="$2" file="$3" id lesson_path
  id="$(jq -r '.guard.id // empty' "$file" 2>/dev/null)" && [[ -n "$id" ]] || return 1
  jq -e --arg id "$id" 'any(.incidents[]; .id == $id)' "$registry" >/dev/null 2>&1 || return 1
  lesson_path="$(jq -r '.full_lesson_path // empty' "$file")"
  [[ -n "$lesson_path" && -f "$repo/$lesson_path" ]] && ! grep -Fq 'V-NEXT' "$repo/$lesson_path"
}

# Prints the pending fragments still to fold, or with "stale" the already-folded ones.
fragment_files() {
  local repo="$1" registry="$2" kind="${3:-fresh}" file
  shopt -s nullglob
  local -a found=("$repo"/lessons/pending/*.json)
  shopt -u nullglob
  ((${#found[@]})) || return 0
  while IFS= read -r file; do
    if stale_fragment "$repo" "$registry" "$file"; then
      [[ "$kind" == stale ]] && printf '%s\n' "$file"
    else
      [[ "$kind" == fresh ]] && printf '%s\n' "$file"
    fi
  done < <(printf '%s\n' "${found[@]}" | LC_ALL=C sort)
  return 0
}

validate_fragments() {
  local repo="$1" registry="$2" file fragment_id lesson_path
  local -a fragments=()
  shift 2
  if (($#)); then
    for file in "$@"; do
      [[ "$file" == "$repo"/lessons/pending/*.json && -f "$file" ]] || {
        echo "ERROR lesson-fragments: invalid selected fragment path: $file" >&2
        return 2
      }
      stale_fragment "$repo" "$registry" "$file" || fragments+=("$file")
    done
  else
    while IFS= read -r file; do
      [[ -n "$file" ]] && fragments+=("$file")
    done < <(fragment_files "$repo" "$registry")
  fi
  ((${#fragments[@]})) || return 0

  for file in "${fragments[@]}"; do
    fragment_id="${file##*/}"
    fragment_id="${fragment_id%.json}"
    if ! jq -e --arg expected_id "$fragment_id" '
      . as $fragment |
      ($fragment.id | type == "string" and test("^[a-z0-9]+(?:-[a-z0-9]+)*$")) and
      ($fragment.id == $expected_id) and
      ($fragment.rule | type == "string" and length > 0 and contains("<a id=\"v-next\"></a>") and ([scan("\\*\\*V-NEXT\\*\\*")] | length == 1)) and
      ($fragment.catalog_entry | type == "string" and length > 0 and contains("V-NEXT") and contains("#v-next")) and
      ($fragment.full_lesson_path == ("lessons/full/" + $fragment.id + ".md"))
    ' "$file" >/dev/null; then
      # Name the contract: an agent shown only the path re-ran implement five times (1878).
      echo "ERROR lesson-fragments: invalid documentation fragment: $file (needs matching id, V-NEXT rule/catalog links and lessons/full/<id>.md)" >&2
      return 2
    fi
    lesson_path="$(jq -r '.full_lesson_path' "$file")"
    if [[ ! -f "$repo/$lesson_path" ]]; then
      echo "ERROR lesson-fragments: missing full lesson: $lesson_path" >&2
      return 2
    fi
    if ! grep -Fq 'V-NEXT' "$repo/$lesson_path" || ! grep -Fq '#v-next' "$repo/$lesson_path"; then
      echo "ERROR lesson-fragments: full lesson must link the pending rule: $lesson_path" >&2
      return 2
    fi
  done
}

fold_fragments() {
  local repo="$1" registry="$2" file fragment_id
  local -a fragments=() full_paths=() stale=()
  while IFS= read -r file; do
    [[ -n "$file" ]] && stale+=("$file")
  done < <(fragment_files "$repo" "$registry" stale)
  if ((${#stale[@]})); then
    rm -- "${stale[@]}"
    printf 'lesson-fragments: removed %s already-folded fragment(s)\n' "${#stale[@]}"
  fi
  while IFS= read -r file; do
    [[ -n "$file" ]] && fragments+=("$file")
  done < <(fragment_files "$repo" "$registry")
  if ((${#fragments[@]} == 0)); then
    if ((${#stale[@]})); then
      git -C "$repo" add -u -- lessons/pending
      git -C "$repo" commit -m '[skip ci] fold lesson documentation'
    fi
    return 0
  fi
  validate_fragments "$repo" "$registry"

  for file in "${fragments[@]}"; do
    fragment_id="${file##*/}"
    fragment_id="${fragment_id%.json}"
    full_paths+=("$(jq -r '.full_lesson_path' "$file")")
    {
      printf '\n'
      jq -r '.rule | sub("\n+$"; "")' "$file" | sed \
        -e "s/V-NEXT/V-NEXT-$fragment_id/g" \
        -e "s/v-next/v-next-$fragment_id/g"
    } >> "$repo/lessons/RULES.md"
    {
      printf '\n'
      jq -r '.catalog_entry | sub("\n+$"; "")' "$file" | sed \
        -e "s/V-NEXT/V-NEXT-$fragment_id/g" \
        -e "s/v-next/v-next-$fragment_id/g"
    } >> "$repo/lessons/CATALOG.md"
    sed -i \
      -e "s/V-NEXT/V-NEXT-$fragment_id/g" \
      -e "s/v-next/v-next-$fragment_id/g" \
      "$repo/$(jq -r '.full_lesson_path' "$file")"
    rm -- "$file"
  done

  git -C "$repo" add -- lessons/RULES.md lessons/CATALOG.md "${full_paths[@]}"
  git -C "$repo" add -u -- lessons/pending
  git -C "$repo" commit -m '[skip ci] fold lesson documentation'
  printf 'lesson-fragments: folded %s fragment(s)\n' "${#fragments[@]}"
}

mode="${1:-}"
[[ -n "$mode" ]] || { usage; exit 2; }
shift
repo="${1:-$DEFAULT_REPO}"
[[ $# -eq 0 ]] || shift
registry="$repo/${ZF_PACK_REL:-engine}/state/incident-guards.json"
if [[ $# -gt 0 && "$1" != --files ]]; then
  registry="$1"
  shift
fi
selected_fragments=()
if [[ $# -gt 0 ]]; then
  [[ "$1" == --files ]] || { usage; exit 2; }
  shift
  selected_fragments=("$@")
fi
repo="$(cd -- "$repo" 2>/dev/null && pwd -P)" || { echo "ERROR lesson-fragments: repo unavailable: $repo" >&2; exit 2; }

case "$mode" in
  --check)
    validate_fragments "$repo" "$registry" "${selected_fragments[@]}"
    ;;
  --fold)
    ((${#selected_fragments[@]} == 0)) || { usage; exit 2; }
    fold_fragments "$repo" "$registry"
    ;;
  *)
    usage
    exit 2
    ;;
esac
