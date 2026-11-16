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
PREPUSH_TMP=$(cd -- "$PREPUSH_TMP" && pwd -P)
sweep_stale_pre_push_dirs() {
  local now worktrees stale_tmp owner_file owner_pid modified bytes tree swept_count=0 swept_bytes=0
  now=$(date +%s)
  worktrees=$(git -C "$root" worktree list --porcelain)
  for stale_tmp in "$PREPUSH_TMP"/tmp.*; do
    [[ -d $stale_tmp && ! -L $stale_tmp ]] || continue
    owner_file="$stale_tmp/owner.pid"
    if [[ -f $owner_file && ! -L $owner_file ]]; then
      owner_pid=
      IFS= read -r owner_pid < "$owner_file" || :
      if [[ $owner_pid =~ ^[1-9][0-9]*$ ]] && kill -0 "$owner_pid" 2>/dev/null; then continue; fi
    else
      modified=$(stat -c %Y -- "$stale_tmp" 2>/dev/null || printf '%s' "$now")
      [[ $modified =~ ^[0-9]+$ ]] || modified=$now
      (( now - modified < 600 )) && continue
    fi
    bytes=$(du -sb -- "$stale_tmp" 2>/dev/null | awk 'NR == 1 { print $1 }' || true)
    [[ $bytes =~ ^[0-9]+$ ]] || bytes=0
    tree="$stale_tmp/tree"
    if [[ ! -L $tree ]] && grep -Fxq -- "worktree $tree" <<< "$worktrees"; then
      git -C "$root" worktree remove --force "$tree" >/dev/null 2>&1 || true
    fi
    rm -rf -- "$stale_tmp"
    ((swept_count += 1))
    ((swept_bytes += bytes))
  done
  git -C "$root" worktree prune
  printf 'prepush-gates: stale tmp dirs removed=%s bytes=%s\n' "$swept_count" "$swept_bytes" >&2
}
sweep_stale_pre_push_dirs
gate_slots=${PREPUSH_GATE_SLOTS:-2}
[[ $gate_slots =~ ^[1-9][0-9]*$ ]] || { echo 'prepush-gates: PREPUSH_GATE_SLOTS must be a positive integer' >&2; exit 2; }
mkdir -p "$PREPUSH_TMP/waiting"
wait_file="$PREPUSH_TMP/waiting/$$"
branch=$(git -C "$root" branch --show-current)
branch=${branch:-detached}
tmp=
gate_slot_fd=
cleanup() {
  rm -f -- "$wait_file"
  if [[ -n ${tmp:-} ]]; then
    git -C "$root" worktree remove --force "$tmp/tree" >/dev/null 2>&1 || true
    rm -rf -- "$tmp"
  fi
  if [[ -n ${gate_slot_fd:-} ]]; then exec {gate_slot_fd}>&-; fi
}
trap cleanup EXIT
wait_started=$(date +%s)
gate_slot_index=
try_gate_slot() {
  local mode="$1" i status
  for ((i=0; i<gate_slots; i++)); do
    exec {gate_slot_fd}>"$PREPUSH_TMP/.gates.slot-$i.lock"
    if [[ $mode == blocking ]]; then
      if flock -w 1 "$gate_slot_fd"; then status=0; else status=$?; fi
    else
      if flock -n "$gate_slot_fd"; then status=0; else status=$?; fi
    fi
    if (( status == 0 )); then
      gate_slot_index=$i
      rm -f -- "$wait_file"
      printf 'prepush-gates: slot %s acquired after %ss\n' "$i" "$(( $(date +%s) - wait_started ))" >&2
      return 0
    fi
    exec {gate_slot_fd}>&-
    gate_slot_fd=
    (( status == 1 )) || return "$status"
  done
  return 1
}
waiting=0
while :; do
  if try_gate_slot nonblocking; then break; else status=$?; fi
  (( status == 1 )) || exit "$status"
  if (( waiting == 0 )); then
    wait_started=$(date +%s)
    printf '%s %s %s\n' "$wait_started" "$sha" "$branch" > "$wait_file"
    waiting=1
  fi
  # flock has no wait-any operation; cycle timed blocking attempts so any freed slot is noticed.
  if try_gate_slot blocking; then break; else status=$?; fi
  (( status == 1 )) || exit "$status"
done
renice -n 5 $$ >/dev/null 2>&1 || true
tmp=$(mktemp -d -p "$PREPUSH_TMP")
printf '%s\n' "$$" > "$tmp/owner.pid"
git -C "$root" worktree add --quiet --detach "$tmp/tree" "$sha"
cd "$tmp/tree"
# Target gates can map these newline-separated package paths to workspace package names.
PREPUSH_CHANGED_PACKAGES=$(git diff --name-only "$base" "$sha" | awk -F/ '$1 == "packages" && NF > 1 { print "packages/" $2 }' | LC_ALL=C sort -u)
export PREPUSH_BASE="$base" PREPUSH_HEAD="$sha" PREPUSH_CHANGED_PACKAGES
rc=0
run() { printf '=='; printf ' %q' "$@"; printf '\n'; if "$@"; then :; else rc=1; fi; }
# Resolve configuration against the original target, not the candidate worktree.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ZF_REPO_DIR=${ZF_REPO_DIR:-$root}
source "$here/config.sh"
config=$(zf_config_file hotfix.json || true)
# The engine's shipped default hotfix.json carries other seams' keys: without a prepush key it is no prepush
# config. A config-root or pack file still selects the seam exactly as before (a keyless override fails closed).
if [[ -n $config && $config == "${ZF_ENGINE_DIR%/}/hotfix.json" ]]; then
  jq -e . "$config" >/dev/null 2>&1 || { echo 'prepush-gates: invalid hotfix.json' >&2; exit 1; }
  jq -e 'type == "object" and has("prepush")' "$config" >/dev/null 2>&1 || config=
fi
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
