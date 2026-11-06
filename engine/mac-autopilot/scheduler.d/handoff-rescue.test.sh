#!/usr/bin/env bash
# A handoff past a clone holding work moves that work to rescued/ refs. Any refusal must leave the clone exactly as it was.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/../.." && pwd -P)"
fixture="$test_env_root/handoff-rescue"
mkdir -p "$fixture/repo" "$fixture/supervisor/autopi/alerts" "$fixture/bin"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor" MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
export REQUIRED_PR_CHECKS_FILE="$engine_dir/mac-autopilot/required-pr-checks.json"
cp "$engine_dir/mac-autopilot/config.template.json" "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
printf '%s\n' '{"units":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/units.json"
printf '%s\n' '{"workers":[]}' > "$MAC_AUTOPILOT_RUNTIME_DIR/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

fail() { echo "handoff-rescue.test.sh: $*" >&2; exit 1; }
SCHEDULER_AGENT_LIB="$fixture/lib.sh"
printf '%s\n' 'state_merge() { [[ -z "${STATE_MERGE_FAILS:-}" ]] || return 1; printf "%s %s\n" "$1" "$2" >> "'"$fixture"'/state-merges"; }' > "$SCHEDULER_AGENT_LIB"
printf '#!/usr/bin/env bash\n[[ ! -e "%s/leak" ]]\n' "$fixture" > "$fixture/bin/gitleaks"; chmod +x "$fixture/bin/gitleaks"
export PATH="$fixture/bin:$PATH"
comments="$fixture/comments"; : > "$comments"
gh() { [[ "$1 $2" == "issue comment" ]] && printf '%s\n' "$*" >> "$comments"; }

origin="$fixture/origin.git"
new_clone() { # fresh remote and clone with a clean pushed main
  rm -rf "$origin" "$fixture/wt" "$fixture/state-merges"
  git init -q --bare "$origin"
  git init -q "$fixture/wt"
  git -C "$fixture/wt" config user.name t; git -C "$fixture/wt" config user.email t@example.com
  printf 'ignored.log\n' > "$fixture/wt/.gitignore"; printf 'one\n' > "$fixture/wt/a.txt"
  git -C "$fixture/wt" add -A; git -C "$fixture/wt" commit -qm base
  git -C "$fixture/wt" remote add origin "$origin"
  git -C "$fixture/wt" push -q origin HEAD:refs/heads/main
  git -C "$fixture/wt" fetch -q origin
  wt="$fixture/wt"
}
snapshot() { git -C "$wt" rev-parse HEAD; git -C "$wt" status --porcelain=v1 --untracked-files=all; git -C "$wt" stash list --format=%H; git -C "$wt" diff --cached --name-only; }
remote_rescues() { git --git-dir="$origin" for-each-ref --format='%(refname:short) %(objectname)' refs/heads/rescued/; }
refused_intact() { # what-it-is why-pattern
  local before after
  before="$(snapshot)"
  if rescue_handoff_clone 70 "$wt"; then fail "$1: expected a refusal"; fi
  after="$(snapshot)"
  [[ "$after" == "$before" ]] || fail "$1: the clone changed"
  [[ "$RESCUE_REFUSED" == *"$2"* ]] || fail "$1: said '$RESCUE_REFUSED'"
  [[ ! -s "$fixture/state-merges" ]] || fail "$1: a start ref was recorded"
}

# Dirty files, an untracked file, an ignored file, a stash and an unpushed commit all reach the remote or stay put.
new_clone
printf 'stashed\n' >> "$wt/a.txt"; git -C "$wt" stash -q; stash_sha="$(git -C "$wt" rev-parse stash@{0})"
printf 'local\n' > "$wt/b.txt"; git -C "$wt" add b.txt; git -C "$wt" commit -qm unpushed; unpushed="$(git -C "$wt" rev-parse HEAD)"
printf 'dirty\n' >> "$wt/a.txt"; printf 'new\n' > "$wt/c.txt"; printf 'keep me local\n' > "$wt/ignored.log"
rescue_handoff_clone 70 "$wt" || fail "rescue refused: $RESCUE_REFUSED"
[[ "$RESCUE_START_REF" == "rescued/agent-issue-70-$RESCUE_START_SHA" ]] || fail "wrong start ref $RESCUE_START_REF"
remote_rescues | grep -q "^$RESCUE_START_REF $RESCUE_START_SHA$" || fail "the rescue ref is not on the remote"
remote_rescues | grep -q "^rescued/stash-of-70-$stash_sha $stash_sha$" || fail "the stash is not on the remote"
[[ "$(git --git-dir="$origin" show "$RESCUE_START_SHA:c.txt")" == new && "$(git --git-dir="$origin" show "$RESCUE_START_SHA:a.txt")" == $'one\ndirty' ]] || fail "dirty work missing from the rescue commit"
git --git-dir="$origin" merge-base --is-ancestor "$unpushed" "$RESCUE_START_SHA" || fail "the unpushed commit is not in the rescue"
if git --git-dir="$origin" cat-file -e "$RESCUE_START_SHA:ignored.log" 2>/dev/null; then fail ".gitignore was not respected"; fi
[[ -e "$wt/ignored.log" ]] || fail "the ignored file left the clone"
if reason="$(worktree_cleanup_block_reason "$wt")"; then fail "the rescued clone still blocks: $reason"; fi
grep -q "\.scheduler_handoff.start_ref = \"$RESCUE_START_REF\"" "$fixture/state-merges" || fail "the start ref was not recorded"
grep -q "$RESCUE_START_REF" "$comments" && grep -q "stash-of-70-$stash_sha" "$comments" || fail "the issue does not name the refs"

# Only a stash on a pushed head: nothing to resume from, and the stash still reaches the remote.
new_clone
printf 'stashed\n' >> "$wt/a.txt"; git -C "$wt" stash -q
rescue_handoff_clone 70 "$wt" || fail "stash-only rescue refused: $RESCUE_REFUSED"
[[ -z "$RESCUE_START_REF" && "$(remote_rescues | wc -l)" == 1 ]] || fail "a stash alone must not create a start ref"
if worktree_cleanup_block_reason "$wt" >/dev/null; then fail "the stash still blocks"; fi

# A failed push leaves everything where it was.
new_clone
printf 'dirty\n' >> "$wt/a.txt"; printf 'new\n' > "$wt/c.txt"; git -C "$wt" stash -q -u; printf 'dirty2\n' >> "$wt/a.txt"
git -C "$wt" remote set-url origin "$fixture/missing.git"
refused_intact "a failed push" "push failed"

# A push the remote did not keep: the read-back decides, not the exit code.
new_clone
printf 'dirty\n' >> "$wt/a.txt"
real_git="$(command -v git)"
printf '#!/usr/bin/env bash\n[[ "${3:-}" != ls-remote ]] || { echo "0000000000000000000000000000000000000001 refs/heads/x"; exit 0; }\nexec "%s" "$@"\n' "$real_git" > "$fixture/bin/git"; chmod +x "$fixture/bin/git"
refused_intact "a read-back mismatch" "push failed"
rm -f "$fixture/bin/git"; hash -r

# The repo's pre-push hook is honoured.
new_clone
mkdir -p "$wt/scripts/hooks"; printf '#!/usr/bin/env bash\nexit 1\n' > "$wt/scripts/hooks/pre-push"; chmod +x "$wt/scripts/hooks/pre-push"
refused_intact "a pre-push refusal" "push failed"
[[ -z "$(remote_rescues)" ]] || fail "a hook refusal still pushed"

# The secret scan decides before anything leaves.
new_clone
printf 'dirty\n' >> "$wt/a.txt"; touch "$fixture/leak"
refused_intact "a secret scan refusal" "secret scan"
rm -f "$fixture/leak"; [[ -z "$(remote_rescues)" ]] || fail "a scan refusal still pushed"

# Size bounds keep large work for someone to read.
new_clone
for i in $(seq 1 51); do printf 'x\n' > "$wt/f$i.txt"; done
refused_intact "too many files" "more than 50"
new_clone
head -c 6000000 /dev/zero > "$wt/big.bin"
refused_intact "a large binary" "file over"
[[ -z "$(remote_rescues)" ]] || fail "a size refusal still pushed"

# A start ref that cannot be recorded would strand the work, so the clone stays.
new_clone
printf 'dirty\n' >> "$wt/a.txt"
STATE_MERGE_FAILS=1 refused_intact "an unrecorded start ref" "could not record"

# A conflicted merge is not a state to snapshot.
new_clone
git -C "$wt" checkout -q -b side; printf 'side\n' > "$wt/a.txt"; git -C "$wt" commit -qam side; git -C "$wt" checkout -q -
printf 'other\n' > "$wt/a.txt"; git -C "$wt" commit -qam other
git -C "$wt" merge -q side >/dev/null 2>&1 || true
if rescue_handoff_clone 70 "$wt"; then fail "a merge in progress was rescued"; fi
[[ "$RESCUE_REFUSED" == "merge in progress" ]] || fail "said '$RESCUE_REFUSED'"

echo "handoff-rescue.test.sh: all assertions passed"
