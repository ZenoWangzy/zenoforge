#!/usr/bin/env bash
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$here/../config.sh"
config=$(zf_config_file hotfix.json) || {
  legacy=$(pack_file hotfix/hf-apply-hook.sh) && exec bash "$legacy" "$@"
  echo 'hf-apply-hook: configure hook installation in hotfix.json' >&2; exit 1
}
(($# == 3)) && [[ -f $1 && -f $3 && $2 =~ ^[a-z0-9-]+$ ]] || { echo 'usage: hf-apply-hook.sh <hook> <tag> <coord.md>' >&2; exit 2; }
if ! jq -e '.apply_hook | type == "object" and ([.host,.host_env,.release_unit,.backup_root,.coord_root,.container,.container_path,.profiles_root,.profile_path,.registry] | all(.[]; type == "string" and test("^[A-Za-z0-9_./@-]+$"))) and (.host_env | test("^[A-Za-z_][A-Za-z0-9_]*$")) and ([.backup_root,.coord_root,.container_path,.profiles_root,.registry] | all(.[]; startswith("/"))) and (.profile_path | startswith("/") | not) and (.restart | type == "array" and length > 0 and all(.[]; type == "string" and length > 0 and (contains("\n") | not)))' "$config" >/dev/null; then
  echo 'hf-apply-hook: invalid hook installation configuration' >&2; exit 1
fi
mapfile -t fields < <(jq -r '.apply_hook | .host,.host_env,.release_unit,.backup_root,.coord_root,.container,.container_path,.profiles_root,.profile_path,.registry' "$config")
read -r host host_env unit backup coord_root container target profiles profile_path registry < <(printf '%s ' "${fields[@]}"; printf '\n')
host=${!host_env:-$host}
[[ $host =~ ^[A-Za-z0-9_][A-Za-z0-9_.@-]*$ && $unit =~ ^[A-Za-z0-9_][A-Za-z0-9_.@-]*$ && $container =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ && /$profile_path/ != */../* ]] || { echo 'hf-apply-hook: invalid host' >&2; exit 1; }
mapfile -t restart < <(jq -r '.apply_hook.restart[]' "$config")
"$here/hf-source-check.sh" "$1"
source_repo=$(git -C "$(dirname -- "$1")" rev-parse --show-toplevel 2>/dev/null || true)
installed_from=""
if [[ -n $source_repo ]]; then
  source_sha=$(git -C "$source_repo" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)
  main_sha=$(git -C "$source_repo" rev-parse --verify 'origin/main^{commit}' 2>/dev/null || true)
  if [[ $source_sha =~ ^[0-9a-f]{40,64}$ && $main_sha =~ ^[0-9a-f]{40,64}$ ]] && git -C "$source_repo" merge-base --is-ancestor "$source_sha" "$main_sha" 2>/dev/null; then
    source_path=$(realpath --relative-to="$source_repo" "$1" 2>/dev/null || true)
    case "$source_path" in ../*|..) source_path="" ;; esac
    if [[ -n $source_path ]]; then
      source_blob=$(git -C "$source_repo" hash-object "$1")
      commit_blob=$(git -C "$source_repo" rev-parse "$source_sha:$source_path" 2>/dev/null || true)
      [[ -z $commit_blob || $source_blob == "$commit_blob" ]] && installed_from=$source_sha
    fi
  fi
fi
! systemctl --user is-active --quiet "$unit" || { echo 'hf-apply-hook: release is active; hold' >&2; exit 1; }
tag=$2
scp -q "$1" "$host:$backup/$tag-patched.py"
if [[ -n $installed_from ]]; then scp -q "$here/register-release-drift-carried.sh" "$host:$backup/$tag-register-release-drift-carried.sh"; fi
scp -q "$3" "$host:$coord_root/COORD-$(date -u +%Y%m%d)-hotfix-$tag.md"
# Values are restricted to shell-safe characters before passing positional arguments over SSH.
ssh -o ConnectTimeout=8 "$host" "bash -s -- $tag ${installed_from:--} $backup $container $target $profiles $profile_path $registry" <<'REMOTE'
set -euo pipefail
tag=$1 revision=$2 backup=$3 container=$4 target=$5 profiles=$6 profile_path=$7 registry=$8
B=$backup/$tag-$(date -u +%Y%m%dT%H%MZ)
N=$backup/$tag-patched.py
R=$backup/$tag-register-release-drift-carried.sh
mkdir -p "$B/profiles"
docker exec "$container" cat "$target" > "$B/gateway-template.py"
for f in "$profiles"/*/"$profile_path"; do e=${f#"$profiles"/}; e=${e%%/*}; cp -p "$f" "$B/profiles/$e.py"; done
docker cp "$N" "$container:$target"
for f in "$profiles"/*/"$profile_path"; do cat "$N" > "$f"; done
if [[ $revision != - ]]; then
  installed_copy=$B/installed-from-main.py
  docker cp "$container:$target" "$installed_copy"
  bash "$R" "$registry" "$container" "$target" "$revision" "$installed_copy"
fi
echo "backup=$B"
docker exec "$container" md5sum "$target" | cut -c1-32
md5sum "$profiles"/*/"$profile_path" | cut -c1-32 | sort | uniq -c
REMOTE
(cd "$ZF_REPO_DIR" && "${restart[@]}")
HF_SHA=$installed_from bash "$here/hf-accept.sh"
