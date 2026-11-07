#!/usr/bin/env bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/land-shared-append-test.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/repo"
agent_home="$tmp/home"
land_script_dir="$tmp/engine"
log="$agent_home/logs/shared-append-rebases.jsonl"

fail() {
  printf 'land-shared-append.test.sh: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$land_script_dir/mac-autopilot"
printf '{"footprint_mutex":{"shared_append":["reg.ts"]}}\n' > "$land_script_dir/mac-autopilot/config.template.json"
land_git_rebase() { git rebase -q "$@"; }
zf_config_file() { return 1; } # no target config: the lander falls back to the engine template
source "$script_dir/land-shared-append.sh"

git init -q -b main "$repo"
git -C "$repo" config user.name fixture
git -C "$repo" config user.email fixture@example.invalid
printf 'a\n' > "$repo/reg.ts"
printf 'x\n' > "$repo/other.ts"
git -C "$repo" add . && git -C "$repo" commit -q -m seed

# Branch edits the registry file; main moves on, so the landing must replay the branch.
branch_edit() { # file line
  git -C "$repo" checkout -q -B topic main
  printf '%s\n' "$2" >> "$repo/$1"
  git -C "$repo" commit -q -am "topic $1"
  git -C "$repo" checkout -q -B main main
}
main_edit() {
  git -C "$repo" checkout -q main
  printf '%s\n' "$2" >> "$repo/$1"
  git -C "$repo" commit -q -am "main $1"
  git -C "$repo" checkout -q topic
}

# Replay without conflict on the shared file: one row, no conflict files.
branch_edit reg.ts topic-line
git -C "$repo" checkout -q topic
main_edit other.ts main-other
(cd "$repo" && land_rebase_record_shared_append main) || fail 'clean replay must succeed'
[[ "$(wc -l < "$log")" == 1 ]] || fail 'clean replay on a shared file must write one row'
jq -e '.shared_files == ["reg.ts"] and .conflict_files == [] and .conflict == false' "$log" >/dev/null || fail 'clean row wrong'

# Replay with a conflict on the shared file: the rebase fails and the row names the file.
git -C "$repo" reset -q --hard main
branch_edit reg.ts topic-line-2
git -C "$repo" checkout -q topic
main_edit reg.ts main-line-2
if (cd "$repo" && land_rebase_record_shared_append main); then fail 'conflicting replay must fail'; fi
[[ "$(wc -l < "$log")" == 2 ]] || fail 'conflicting replay must write one more row'
tail -n 1 "$log" | jq -e '.conflict == true and .conflict_files == ["reg.ts"]' >/dev/null || fail 'conflict row wrong'
git -C "$repo" rebase --abort

# A branch that needs no replay, or touches no shared file, writes nothing.
git -C "$repo" checkout -q -B topic main
(cd "$repo" && land_rebase_record_shared_append main) || fail 'up-to-date rebase must succeed'
branch_edit other.ts topic-other
git -C "$repo" checkout -q topic
main_edit reg.ts main-reg-2
(cd "$repo" && land_rebase_record_shared_append main) || fail 'non-shared replay must succeed'
[[ "$(wc -l < "$log")" == 2 ]] || fail 'up-to-date or non-shared rebase must not write a row'
# The startup sync rebases first and leaves nothing to replay later, so it must record too.
grep -q 'land_rebase_record_shared_append "$land_main_base"' "$script_dir/land-direct-main-bootstrap.sh" || fail 'bootstrap startup sync does not record its rebase'
echo 'land-shared-append.test.sh: ok'
