#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage:
  bash engine/land-gate.sh <files...>
  bash engine/land-gate.sh --tree <commit-sha>

File mode overlays the listed working-tree paths onto a temporary worktree at
origin/main. --tree checks the named commit directly.
USAGE
}

fail() {
  local lesson="$1"
  shift
  printf 'land-gate: BLOCKED [%s] %s\n' "$lesson" "$*" >&2
  exit 1
}

TREE_ARG=''
FILES=()
OPTIONS_DONE=0
while (($#)); do
  if (( OPTIONS_DONE )); then
    FILES+=("$1")
    shift
    continue
  fi
  case "$1" in
    --)
      OPTIONS_DONE=1
      shift
      ;;
    --tree)
      (($# >= 2)) || { usage; fail L24 '--tree requires a commit SHA'; }
      TREE_ARG="$2"
      shift 2
      ;;
    -* )
      usage
      fail L24 "unknown option: $1"
      ;;
    *)
      FILES+=("$1")
      shift
      ;;
  esac
done

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || fail L24 'run from a Git checkout'
ROOT="$(cd -- "$ROOT" && pwd -P)"
PREFIX="$(git rev-parse --show-prefix)"

if [[ -n "$TREE_ARG" ]]; then
  (( ${#FILES[@]} == 0 )) || fail L24 '--tree cannot be combined with file paths'
else
  (( ${#FILES[@]} > 0 )) || { usage; fail L24 'provide one or more files or use --tree <commit-sha>'; }
fi

NORMALIZED_FILES=()
for path in "${FILES[@]}"; do
  [[ "$path" != /* ]] || fail L24 "file path must be relative to the checkout: $path"
  [[ "$path" != *$'\n'* ]] || fail L24 'file paths containing newlines are unsupported'
  path="${path#./}"
  path="${PREFIX}${path}"
  case "/$path/" in
    *'/../'*) fail L24 "file path escapes the checkout: $path" ;;
  esac
  [[ -n "$path" && "$path" != '.' ]] || fail L24 'empty file path'
  NORMALIZED_FILES+=("$path")
done
FILES=("${NORMALIZED_FILES[@]}")

if ! git -C "$ROOT" fetch --quiet origin main; then
  fail L21 'could not fetch origin/main; target-tree checks cannot be trusted'
fi
BASE_SHA="$(git -C "$ROOT" rev-parse --verify --end-of-options 'origin/main^{commit}' 2>/dev/null)" \
  || fail L21 'origin/main is not a commit after fetch'

TARGET_SHA=''
if [[ -n "$TREE_ARG" ]]; then
  TARGET_SHA="$(git -C "$ROOT" rev-parse --verify --end-of-options "$TREE_ARG^{commit}" 2>/dev/null)" \
    || fail L21 "--tree target is not an available commit: $TREE_ARG"
fi

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/land-gate.XXXXXX")" || fail L24 'could not create temporary directory'
TREE_DIR="$TEMP_ROOT/tree"
cleanup() {
  if [[ -n "${ROOT:-}" && -d "${TREE_DIR:-}" ]]; then
    git -C "$ROOT" worktree remove --force "$TREE_DIR" >/dev/null 2>&1 || rm -rf "$TREE_DIR"
  fi
  [[ -z "${TEMP_ROOT:-}" ]] || rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

WORKTREE_SHA="$BASE_SHA"
if [[ -n "$TARGET_SHA" ]]; then
  WORKTREE_SHA="$TARGET_SHA"
fi
if ! git -C "$ROOT" worktree add --quiet --detach "$TREE_DIR" "$WORKTREE_SHA"; then
  fail L21 "could not create aligned worktree at $WORKTREE_SHA"
fi

if [[ -z "$TARGET_SHA" ]]; then
  for path in "${FILES[@]}"; do
    source_path="$ROOT/$path"
    target_path="$TREE_DIR/$path"
    if [[ -e "$source_path" || -L "$source_path" ]]; then
      [[ ! -d "$source_path" ]] || fail L24 "expected a file path, got a directory: $path"
      mkdir -p "$(dirname -- "$target_path")" || fail L21 "could not prepare overlay path: $path"
      rm -f "$target_path" || fail L21 "could not replace base file: $path"
      cp -pP "$source_path" "$target_path" || fail L21 "could not overlay working-tree file: $path"
    else
      rm -f "$target_path" || fail L21 "could not apply deletion: $path"
    fi
  done
  if ! git -C "$TREE_DIR" add -A -- "${FILES[@]}"; then
    fail L21 'could not stage the temporary overlay'
  fi
  for path in "${FILES[@]}"; do
    if [[ -e "$ROOT/$path" || -L "$ROOT/$path" ]]; then
      git -C "$TREE_DIR" ls-files --error-unmatch -- "$path" >/dev/null 2>&1 \
        || fail L21 "overlay path is ignored or untracked by Git: $path"
    fi
  done
else
  diff_file="$TEMP_ROOT/changed-files"
  if ! git -C "$ROOT" diff --name-only -z --diff-filter=ACDMRT "$BASE_SHA" "$TARGET_SHA" > "$diff_file"; then
    fail L21 'could not calculate files changed by --tree target'
  fi
  while IFS= read -r -d '' path; do
    FILES+=("$path")
  done < "$diff_file"
fi

NEW_SHELL_TESTS=()
for path in "${FILES[@]}"; do
  case "$path" in
    .github/workflows/*) printf 'land-gate: WARNING [L24] workflow trigger surface changed: %s; human confirmation required before landing\n' "$path" >&2 ;;
  esac
  [[ -f "$TREE_DIR/$path" ]] || continue
  case "$path" in
    *.test.*)
      if ! git -C "$ROOT" cat-file -e "$BASE_SHA:$path" 2>/dev/null; then
        case "$path" in
          *.test.sh) NEW_SHELL_TESTS+=("$path") ;;
        esac
      fi
      ;;
  esac
done

for path in "${FILES[@]}"; do
  [[ -f "$TREE_DIR/$path" ]] || continue
  case "$path" in
    *.sh)
      if ! bash -n "$TREE_DIR/$path"; then
        fail L24 "shell syntax failed: $path"
      fi
      ;;
    *.json)
      if ! jq -e . "$TREE_DIR/$path" >/dev/null; then
        fail L24 "JSON syntax or jq -e validation failed: $path"
      fi
      ;;
  esac
done

if (( ${#NEW_SHELL_TESTS[@]} )); then
  if ! (cd -- "$TREE_DIR" && bash engine/test-bootstrap-check.sh "${NEW_SHELL_TESTS[@]}"); then
    fail L21 'new shell test is missing the required set -euo pipefail and test-env.sh bootstrap'
  fi
fi

TARGET_LABEL="${TARGET_SHA:-working-tree-overlay(not-landable)}"

printf 'land-gate: PASS base=%s target=%s files=%s\n' \
  "$BASE_SHA" "$TARGET_LABEL" "${#FILES[@]}"
