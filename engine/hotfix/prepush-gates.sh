#!/usr/bin/env bash
# Run the CI PR gates against an immutable candidate commit.
# Gates come from the pack (hotfix/prepush-gates.d/*.sh) and from the target repo's .zenoforge/prepush-gates.
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
# 10-30 02:35Z two concurrent gate runs (example + shared builds) pushed WSL load5 to 31, PSI 56%: one run at a time, niced.
exec 8>"$PREPUSH_TMP/.gates.lock"
flock -n 8 || { echo "prepush-gates: another gate run is active; waiting" >&2; flock 8; }
renice -n 5 $$ >/dev/null 2>&1 || true
tmp=$(mktemp -d -p "$PREPUSH_TMP")
cleanup() { git -C "$root" worktree remove --force "$tmp/tree" >/dev/null 2>&1 || true; rm -rf "$tmp"; }
trap cleanup EXIT
git worktree add --quiet --detach "$tmp/tree" "$sha"
cd "$tmp/tree"
export PREPUSH_BASE="$base" PREPUSH_HEAD="$sha"
rc=0
run() { printf '=='; printf ' %q' "$@"; printf '\n'; if "$@"; then :; else rc=1; fi; }
# Resolve configuration against the original target, not the candidate worktree.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ZF_REPO_DIR=${ZF_REPO_DIR:-$root}
source "$here/config.sh"
config=$(zf_config_file hotfix.json || true)
legacy_name=
if [[ -n $config ]]; then
  legacy_name=$(node "$here/hotfix/prepush-config.mjs" "$config" --legacy-name) || exit 1
fi
pack_dir=${ZF_PACK_DIR-} # PACK_DIR_DEFAULT: the public export rewrites this default to empty
gates=()
if [[ -n $pack_dir ]]; then
  for gate_file in "$pack_dir"/hotfix/prepush-gates.d/*.sh; do
    [[ -f $gate_file ]] && gates+=("${gate_file##*/}")
  done
fi
if [[ -n $legacy_name ]]; then gates+=("$legacy_name"); fi
if ((${#gates[@]})); then
  while IFS= read -r gate_name; do
    if [[ -n $legacy_name && $gate_name == "$legacy_name" ]]; then
      if node "$here/hotfix/prepush-config.mjs" "$config"; then :; else
        status=$?
        [[ $status == 1 ]] || exit 1
        rc=1
      fi
      while IFS= read -r -d "" name && IFS= read -r -d "" value; do
        export "$name=$value"
      done < <(node "$here/hotfix/prepush-config.mjs" "$config" --exports)
    else
      # shellcheck source=/dev/null
      source "$pack_dir/hotfix/prepush-gates.d/$gate_name"
    fi
  done < <(printf '%s\n' "${gates[@]}" | LC_ALL=C sort -u)
fi
# The target repo lists its own gates, one shell command per line, in .zenoforge/prepush-gates (blank lines and # comments are skipped).
if [[ -f .zenoforge/prepush-gates ]]; then
  while IFS= read -r gate; do
    [[ -z $gate || $gate == \#* ]] && continue
    run bash -c "$gate" < /dev/null
  done < .zenoforge/prepush-gates
fi
printf 'prepush-gates rc=%s\n' "$rc"
exit "$rc"
