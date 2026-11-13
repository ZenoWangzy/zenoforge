#!/usr/bin/env bash
# Record one test command's exit code for the current HEAD under the Git common
# dir (zf-test-receipts/<sha>), so tools/merge-pr.sh can refuse a merge whose
# last test run at that SHA failed. Receipts stay local to this clone.
set -uo pipefail

test_receipt_main() {
  local repo git_dir sha rc
  if [[ $# -eq 0 ]]; then
    printf 'usage: tools/test-receipt.sh <command...>\n' >&2
    return 2
  fi
  repo="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    printf 'test-receipt: run inside a Git checkout\n' >&2
    return 2
  }
  git_dir="$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null)" || {
    printf 'test-receipt: cannot read the Git common dir\n' >&2
    return 2
  }
  case "$git_dir" in
    /*) ;;
    *) git_dir="$repo/$git_dir" ;;
  esac
  sha="$(git -C "$repo" rev-parse HEAD 2>/dev/null)" || {
    printf 'test-receipt: cannot read HEAD\n' >&2
    return 2
  }
  # 11-13 #1113: a fix sat uncommitted (amend without -a); the tests passed on the working tree, the receipt was
  # filed under HEAD, and main got the broken line. A receipt is for HEAD only, so tracked changes refuse it.
  if ! git -C "$repo" diff --quiet HEAD -- 2>/dev/null; then
    printf 'test-receipt: refused: tracked files differ from HEAD %.12s; commit them first (git status)\n' "$sha" >&2
    return 2
  fi
  "$@"
  rc=$?
  if ! mkdir -p "$git_dir/zf-test-receipts" 2>/dev/null \
    || ! printf '%s\t%s\n' "$rc" "$*" >>"$git_dir/zf-test-receipts/$sha"; then
    printf 'test-receipt: cannot record a receipt under %s/zf-test-receipts\n' "$git_dir" >&2
    return 2
  fi
  return "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  test_receipt_main "$@"
fi
