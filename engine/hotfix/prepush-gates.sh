#!/usr/bin/env bash
# Run the CI PR gates against an immutable candidate commit.
# The target repo lists its own gates, one shell command per line, in .zenoforge/prepush-gates (blank lines and # comments are skipped).
set -euo pipefail
unset GH_TOKEN
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
root=$(git rev-parse --show-toplevel)
sha=$(git rev-parse "${1:-HEAD}^{commit}")
git fetch -q origin main
base=$(git merge-base origin/main "$sha")
# A candidate with no commits over main selects no gate and passes vacuously (hf-4620-a12 ran it before committing).
[[ $(git rev-list --count "$base..$sha") -gt 0 ]] || { echo "prepush-gates: $sha has no commits over origin/main; commit first" >&2; exit 2; }
# Not /tmp: WSL /tmp is a 3.9 GB tmpfs and a dependency install plus build filled it (ENOSPC, 10-23).
mkdir -p "${PREPUSH_TMP:=$HOME/.cache/zf-prepush}"
tmp=$(mktemp -d -p "$PREPUSH_TMP")
cleanup() { git -C "$root" worktree remove --force "$tmp/tree" >/dev/null 2>&1 || true; rm -rf "$tmp"; }
trap cleanup EXIT
git worktree add --quiet --detach "$tmp/tree" "$sha"
cd "$tmp/tree"
export PREPUSH_BASE="$base" PREPUSH_HEAD="$sha"
rc=0
run() { printf '=='; printf ' %q' "$@"; printf '\n'; if "$@"; then :; else rc=1; fi; }
if [[ -f .zenoforge/prepush-gates ]]; then
  while IFS= read -r gate; do
    [[ -z $gate || $gate == \#* ]] && continue
    run bash -c "$gate" < /dev/null
  done < .zenoforge/prepush-gates
fi
printf 'prepush-gates rc=%s\n' "$rc"
exit "$rc"
