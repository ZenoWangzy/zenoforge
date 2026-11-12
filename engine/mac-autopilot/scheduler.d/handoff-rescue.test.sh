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
printf '%s\n' 'supervisor_inbox_append_once() { printf "%s\n" "$2" >> "'"$fixture"'/inbox"; }' >> "$SCHEDULER_AGENT_LIB"
say() { printf '%s\n' "$*" >> "$fixture/say.log"; }
WT_ROOT="$fixture/wtroot"; mkdir -p "$WT_ROOT"
real_gitleaks="$(command -v gitleaks || true)"
# The stub reads the same text a real scan would, so these cases prove what reaches the scanner.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/scans"\nif [[ "$1" == stdin ]] && grep -q AKIAFAKE; then exit 3; fi\n[[ ! -e "%s/leak" ]] || exit 3\n[[ ! -e "%s/scan-broken" ]]\n' "$fixture" "$fixture" "$fixture" > "$fixture/bin/gitleaks"; chmod +x "$fixture/bin/gitleaks"
mkdir -p "$ROOT/scripts/hooks"; printf '#!/usr/bin/env bash\n[[ ! -e "%s/hook-refuses" ]]\n' "$fixture" > "$ROOT/scripts/hooks/pre-push"; chmod +x "$ROOT/scripts/hooks/pre-push"
export PATH="$fixture/bin:$PATH"
comments="$fixture/comments"; : > "$comments"
pr_comments="$fixture/pr-comments"; : > "$pr_comments"
gh() {
  case "${1:-} ${2:-}" in
    "issue comment") printf '%s\n' "$*" >> "$comments" ;;
    "pr comment") printf '%s\n' "$(jq -cn --arg pr "${3:-}" --arg body "${5:-}" '{pr:$pr,body:$body}')" >> "$pr_comments" ;;
    *) return 0 ;;
  esac
}

origin="$fixture/origin.git"
new_clone() { # fresh remote and clone with a clean pushed main
  rm -rf "$origin" "$fixture/wt" "$fixture/state-merges" "$fixture/supervisor/autopi/rescue-refused-70"
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
snapshot() {
  git -C "$wt" for-each-ref; git -C "$wt" status --porcelain=v1 --untracked-files=all; git -C "$wt" stash list --format=%H
  git -C "$wt" diff --cached --name-only; tar -C "$wt" --exclude=.git -cf - . | sha256sum
}
remote_rescues() { git --git-dir="$origin" for-each-ref --format='%(refname:short) %(objectname)' refs/heads/rescued/; }
refused_intact() { # what-it-is why-pattern
  local before after
  before="$(snapshot)"
  if rescue_handoff_clone 70 "$wt"; then fail "$1: expected a refusal"; fi
  after="$(snapshot)"
  [[ "$after" == "$before" ]] || fail "$1: the clone changed: $(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after"))"
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

# A failed push leaves everything where it was, at either push.
new_clone
printf 'dirty\n' >> "$wt/a.txt"; printf 'new\n' > "$wt/c.txt"; git -C "$wt" rm -q .gitignore; git -C "$wt" stash -q -u; printf 'dirty2\n' >> "$wt/a.txt"
git -C "$wt" remote set-url origin "$fixture/missing.git"
refused_intact "a failed stash push" "stash push failed"
new_clone
printf 'dirty\n' >> "$wt/a.txt"
git -C "$wt" remote set-url origin "$fixture/missing.git"
refused_intact "a failed commit push" "rescue push failed"

# An active hand/ worktree belongs to the handoff, not the old clone's unpushed branches.
new_clone
base_sha="$(git -C "$wt" rev-parse HEAD)"
git -C "$wt" checkout -q -b agent/issue-70
printf 'unpublished old clone work\n' > "$wt/prior.txt"
git -C "$wt" add prior.txt; git -C "$wt" commit -qm 'unpublished old clone work'
git -C "$wt" worktree add -q -b hand/issue-70 "$fixture/hand-70" "$base_sha"
printf 'active handoff work\n' > "$fixture/hand-70/handoff.txt"
git -C "$fixture/hand-70" add handoff.txt; git -C "$fixture/hand-70" commit -qm 'active handoff work'
handoff_sha="$(git -C "$fixture/hand-70" rev-parse HEAD)"
git -C "$wt" remote set-url origin "$fixture/missing.git"
refused_intact "an active handoff worktree" "rescue push failed"
if preserve_refused_clone 70 issue-70 "$wt"; then fail "the active hand/ branch caused the old clone to be moved aside"; fi
[[ -d "$wt" && "$(git -C "$fixture/hand-70" rev-parse HEAD)" == "$handoff_sha" \
  && "$(cat "$fixture/hand-70/handoff.txt")" == 'active handoff work' ]] || fail "the active handoff worktree changed"

# Deletes, renames, modes and symlinks all reach the rescue commit, and the clone ends clean.
new_clone
git -C "$wt" config core.fileMode true; printf 'two\n' > "$wt/b.txt"; printf 'x\n' > "$wt/d.txt"; git -C "$wt" add -A; git -C "$wt" commit -qm more; git -C "$wt" push -q origin HEAD:refs/heads/main; git -C "$wt" fetch -q origin
git -C "$wt" mv b.txt renamed.txt; rm "$wt/d.txt"; ln -s a.txt "$wt/link"; chmod +x "$wt/a.txt"
rescue_handoff_clone 70 "$wt" || fail "mixed changes refused: $RESCUE_REFUSED"
tree="$(git --git-dir="$origin" ls-tree -r "$RESCUE_START_SHA")"
grep -q 'renamed.txt' <<<"$tree" && ! grep -qE '\s(b|d)\.txt$' <<<"$tree" && grep -q '^120000.*link' <<<"$tree" && grep -q '^100755.*a.txt' <<<"$tree" || fail "the rescue lost a change"
[[ -z "$(git -C "$wt" status --porcelain=v1)" ]] || fail "the clone is not clean after the rescue"

# A detached HEAD is rescued like a branch.
new_clone
git -C "$wt" checkout -q --detach; printf 'dirty\n' >> "$wt/a.txt"
rescue_handoff_clone 70 "$wt" || fail "detached HEAD refused: $RESCUE_REFUSED"

# A push the remote did not keep: the read-back decides, not the exit code.
new_clone
printf 'dirty\n' >> "$wt/a.txt"
real_git="$(command -v git)"
# Plays newer git, which also moves the tracking ref on a push by URL.
printf '#!/usr/bin/env bash\n[[ "${3:-}" != ls-remote ]] || { echo "0000000000000000000000000000000000000001 refs/heads/x"; exit 0; }\nif [[ "${5:-}" == push ]]; then "%s" "$@" || exit; exec "%s" -C "$2" update-ref "refs/remotes/origin/${8#*:refs/heads/}" "${8%%%%:*}"; fi\nexec "%s" "$@"\n' "$real_git" "$real_git" "$real_git" > "$fixture/bin/git"; chmod +x "$fixture/bin/git"
refused_intact "a read-back mismatch" "push failed"
sed -i '/ls-remote/d' "$fixture/bin/git"
new_clone
printf 'dirty\n' >> "$wt/a.txt"
STATE_MERGE_FAILS=1 refused_intact "a push proved but not recorded" "could not record"
rm -f "$fixture/bin/git"; hash -r

# The repo's pre-push hook is honoured.
new_clone
printf 'dirty\n' >> "$wt/a.txt"; touch "$fixture/hook-refuses"
refused_intact "a pre-push refusal" "push failed"
rm -f "$fixture/hook-refuses"
[[ -z "$(remote_rescues)" ]] || fail "a hook refusal still pushed"

# The secret scan decides before anything leaves, and it sees stashes.
new_clone
printf 'dirty\n' >> "$wt/a.txt"; touch "$fixture/leak"
refused_intact "a secret scan refusal" "found a leak"
rm -f "$fixture/leak"; [[ -z "$(remote_rescues)" ]] || fail "a scan refusal still pushed"
: > "$fixture/scans"
if rescue_handoff_clone 70 "$wt"; then fail "a leak must not be retried"; fi
[[ "$RESCUE_REFUSED" == *"earlier pass"* && ! -s "$fixture/scans" ]] || fail "an unchanged clone was scanned again ($RESCUE_REFUSED)"
new_clone
printf 'key=AKIAFAKE\n' >> "$wt/a.txt"; git -C "$wt" stash -q
refused_intact "a secret in a stash's worktree edits" "found a leak"
new_clone
printf 'key=AKIAFAKE\n' > "$wt/new.txt"
refused_intact "a secret in an untracked file, with no stash" "found a leak"
new_clone
printf 'key=AKIAFAKE\n' >> "$wt/a.txt"
refused_intact "a secret in a dirty file" "found a leak"
new_clone
printf 'key=AKIAFAKE\n' > "$wt/b.txt"; git -C "$wt" add b.txt; git -C "$wt" commit -qm unpushed
refused_intact "a secret in an unpushed commit" "found a leak"
new_clone
git -C "$wt" checkout -q -b side; printf 'side\n' > "$wt/a.txt"; git -C "$wt" commit -qam side; git -C "$wt" checkout -q -
printf 'other\n' > "$wt/a.txt"; git -C "$wt" commit -qam other; git -C "$wt" merge -q side >/dev/null 2>&1 || true
printf 'key=AKIAFAKE\n' > "$wt/a.txt"; git -C "$wt" add a.txt; git -C "$wt" commit -qm 'hand resolution'
git -C "$wt" branch -qD side
refused_intact "a secret in a hand-resolved merge" "found a leak"
# A real scanner, where one is installed: its own exit codes are part of this contract.
if [[ -n "$real_gitleaks" ]]; then
  new_clone
  printf 'aws_secret_access_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYzz91kQp7Xc"\n' > "$wt/new.txt"; git -C "$wt" add new.txt; git -C "$wt" commit -qm unpushed
  rc=0; PATH="$(dirname -- "$real_gitleaks"):$PATH" rescue_secret_scan "$wt" "$(git -C "$wt" rev-parse HEAD)" || rc=$?
  [[ "$rc" == 3 ]] || fail "the real scanner returned $rc on a commit with no stash"
fi
# A scan that could not read its input is not a clean scan.
new_clone
printf 'dirty\n' >> "$wt/a.txt"
rc=0; rescue_secret_scan "$wt" 0000000000000000000000000000000000000001 || rc=$?
[[ "$rc" == 1 ]] || fail "a scan of a bad revision returned $rc"
new_clone
printf 'dirty\n' >> "$wt/a.txt"; touch "$fixture/scan-broken"
refused_intact "a broken scanner" "could not run"
rm -f "$fixture/scan-broken"

# Size bounds keep large work for someone to read.
new_clone
for i in $(seq 1 51); do printf 'x\n' > "$wt/f$i.txt"; done
refused_intact "too many files" "more than 50"
new_clone
head -c 6000000 /dev/urandom > "$wt/big.bin"
refused_intact "a large binary" "file over"
git -C "$wt" add big.bin
refused_intact "a large binary staged only" "file over"
git -C "$wt" stash -q
refused_intact "a large binary in a stash" "file over"
new_clone
head -c 6000000 /dev/urandom > "$wt/big.bin"; git -C "$wt" add big.bin; git -C "$wt" commit -qm big
refused_intact "a large binary in an unpushed commit" "file over"
[[ -z "$(remote_rescues)" ]] || fail "a size refusal still pushed"

# A start ref that cannot be recorded would strand the work, so the clone stays.
new_clone
printf 'dirty\n' >> "$wt/a.txt"
STATE_MERGE_FAILS=1 refused_intact "an unrecorded start ref" "could not record"

# The private index sees only the worktree, so these would be lost without a word.
new_clone
printf 'staged\n' > "$wt/a.txt"; git -C "$wt" add a.txt; printf 'one\n' > "$wt/a.txt"
git -C "$wt" diff --quiet --cached && fail "fixture: nothing staged"
refused_intact "a staged version later reverted" "staged content differs"
new_clone
printf 'edit\n' >> "$wt/a.txt"; git -C "$wt" update-index --assume-unchanged a.txt
refused_intact "an assume-unchanged edit" "assume-unchanged"

# Live clones are sparse: their absent files must survive in the rescue commit, and they are no reason to refuse.
new_clone
mkdir -p "$wt/hidden"; printf 'kept\n' > "$wt/hidden/x.txt"; git -C "$wt" add -A; git -C "$wt" commit -qm hidden; git -C "$wt" push -q origin HEAD:refs/heads/main; git -C "$wt" fetch -q origin
git -C "$wt" sparse-checkout set --no-cone '/*' '!/hidden/'
[[ ! -e "$wt/hidden/x.txt" ]] || fail "fixture: the sparse file is still on disk"
printf 'dirty\n' >> "$wt/a.txt"
rescue_handoff_clone 70 "$wt" || fail "a sparse clone was refused: $RESCUE_REFUSED"
[[ "$(git --git-dir="$origin" show "$RESCUE_START_SHA:hidden/x.txt")" == kept ]] || fail "the rescue commit deleted a sparse clone's absent file"
[[ -z "$(git -C "$wt" status --porcelain=v1)" && ! -e "$wt/hidden/x.txt" ]] || fail "the sparse clone is not clean after the rescue"
new_clone
mkdir -p "$wt/hidden"; printf 'kept\n' > "$wt/hidden/x.txt"; git -C "$wt" add -A; git -C "$wt" commit -qm hidden; git -C "$wt" push -q origin HEAD:refs/heads/main; git -C "$wt" fetch -q origin
git -C "$wt" update-index --skip-worktree hidden/x.txt; printf 'edit\n' >> "$wt/hidden/x.txt"
refused_intact "a skip-worktree edit" "skip-worktree edit"
flagged_clone() { # a pushed file, flagged with $1, plus a dirty file so a rescue would commit
  new_clone
  mkdir -p "$wt/hidden"; printf 'kept\n' > "$wt/hidden/x.txt"; git -C "$wt" add -A; git -C "$wt" commit -qm hidden; git -C "$wt" push -q origin HEAD:refs/heads/main; git -C "$wt" fetch -q origin
  git -C "$wt" update-index "$1" hidden/x.txt; printf 'dirty\n' >> "$wt/a.txt"
}
flagged_clone --skip-worktree; rm "$wt/hidden/x.txt"; ln -s /nonexistent "$wt/hidden/x.txt"
refused_intact "a flagged file swapped for a dangling symlink" "skip-worktree edit"
flagged_clone --skip-worktree; chmod +x "$wt/hidden/x.txt"
refused_intact "a mode change on a flagged file" "skip-worktree edit"
flagged_clone --assume-unchanged; rm "$wt/hidden/x.txt"
refused_intact "an assume-unchanged file deleted on purpose" "assume-unchanged"
# Names are not pathspecs: ":x" would compare x, and "*" would match the dirty file.
new_clone
printf 'one\n' > "$wt/:x.txt"; git -C "$wt" add -A; git -C "$wt" commit -qm colon; git -C "$wt" push -q origin HEAD:refs/heads/main; git -C "$wt" fetch -q origin
git -C "$wt" update-index --assume-unchanged ":x.txt"; printf 'edit\n' >> "$wt/:x.txt"; printf 'dirty\n' >> "$wt/a.txt"
refused_intact "an edit under a name that looks like pathspec magic" "assume-unchanged"
new_clone
printf 'one\n' > "$wt/*"; git -C "$wt" add -A; git -C "$wt" commit -qm glob; git -C "$wt" push -q origin HEAD:refs/heads/main; git -C "$wt" fetch -q origin
git -C "$wt" update-index --assume-unchanged "*"; printf 'dirty\n' >> "$wt/a.txt"
rescue_handoff_clone 70 "$wt" || fail "a clean flagged file named * was refused: $RESCUE_REFUSED"
# A real sparse clone: git drops the flag on a file that shows up on disk, and add -A will not stage it.
flagged_clone --no-skip-worktree; git -C "$wt" sparse-checkout set --no-cone '/*' '!/hidden/'
mkdir -p "$wt/hidden"; printf 'edit\n' > "$wt/hidden/x.txt"
refused_intact "an edit outside the sparse patterns" "leaves out"
[[ -z "$(remote_rescues)" ]] || fail "a clone that cannot be rescued still pushed a ref"
new_clone
printf 'one\n' > "$wt/é.txt"; git -C "$wt" add -A; git -C "$wt" commit -qm named; git -C "$wt" push -q origin HEAD:refs/heads/main; git -C "$wt" fetch -q origin
git -C "$wt" update-index --skip-worktree "é.txt"; printf 'edit\n' >> "$wt/é.txt"
refused_intact "a skip-worktree edit under a quoted name" "skip-worktree edit"

# A nested repo would travel as a bare gitlink and its files would be left to deletion.
new_clone
git init -q "$wt/nested"; git -C "$wt/nested" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m nested
refused_intact "a nested repository" "nested repository"

# A stash made with --all carries ignored files.
new_clone
printf 'local\n' > "$wt/ignored.log"; git -C "$wt" stash -q -a
refused_intact "ignored files in a stash" "ignored files"

# Commits on another local branch would be lost with the clone.
new_clone
git -C "$wt" checkout -q -b other; printf 'other\n' > "$wt/o.txt"; git -C "$wt" add o.txt; git -C "$wt" commit -qm other; git -C "$wt" checkout -q -
printf 'stashed\n' >> "$wt/a.txt"; git -C "$wt" stash -q; stash_sha="$(git -C "$wt" rev-parse stash@{0})"
rescue_handoff_clone 70 "$wt" || fail "another branch's commits were refused: $RESCUE_REFUSED"
remote_rescues | grep -q "^rescued/wt-[^ ]*-other " || fail "the unpushed branch did not reach the remote"
remote_rescues | grep -q "^rescued/stash-of-70-$stash_sha $stash_sha$" || fail "the stash did not reach the remote"
saved=("$WT_ROOT"/wt-wt.preserved-*); [[ ${#saved[@]} == 1 && -d "${saved[0]}" && ! -e "${saved[0]}/push-pending" ]] || fail "expected one pushed local copy, got ${saved[*]}"
grep -q '^Subject: \[PATCH.*other' "${saved[0]}"/unpushed-1/*.patch || fail "the unpushed commit was not kept as a patch"
[[ -z "$(git -C "$wt" stash list)" ]] || fail "the stash was not cleared"
[[ "$(cat "$fixture/say.log")" == "handoff rescue unit=wt stash/unpushed saved ${saved[0]}" ]] || fail "the log line is wrong: $(cat "$fixture/say.log")"
rm -rf "${saved[0]}" "$fixture/say.log"

# A conflicted merge is not a state to snapshot.
new_clone
git -C "$wt" checkout -q -b side; printf 'side\n' > "$wt/a.txt"; git -C "$wt" commit -qam side; git -C "$wt" checkout -q -
printf 'other\n' > "$wt/a.txt"; git -C "$wt" commit -qam other
git -C "$wt" merge -q side >/dev/null 2>&1 || true
if rescue_handoff_clone 70 "$wt"; then fail "a merge in progress was rescued"; fi
[[ "$RESCUE_REFUSED" == "MERGE_HEAD with unmerged paths" ]] || fail "said '$RESCUE_REFUSED'"

# A clone the secret scan refused is set aside, so its handoff goes on; nothing else is moved.
aside_clone() { # fresh clone at the unit's path under WT_ROOT, logs emptied
  new_clone; rm -rf "$WT_ROOT"/wt-issue-70*; mv "$fixture/wt" "$WT_ROOT/wt-issue-70"; wt="$WT_ROOT/wt-issue-70"
  rm -f "$fixture/inbox" "$fixture/say.log" "$comments" "$fixture/scans"; : > "$comments"
}
assert_refused_clone_aside() { # issue id content marker -> the intake caller can continue with a private, retained clone
  local n="$1" id="$2" marker="$3" handoff_continued=0 out
  local -a aside
  if preserve_refused_clone "$n" "$id" "$wt"; then handoff_continued=1; else fail "the refused clone was not set aside"; fi
  [[ "$handoff_continued" == 1 && ! -e "$wt" ]] || fail "the handoff stayed blocked by the refused clone"
  aside=("$WT_ROOT"/wt-"$id".preserved-*)
  [[ ${#aside[@]} == 1 && -d "${aside[0]}" ]] || fail "expected one preserved dir, got ${aside[*]}"
  [[ "${aside[0]##*.preserved-}" =~ ^[0-9]{8}T[0-9]{4}Z$ ]] || fail "bad stamp in ${aside[0]}"
  [[ "$(stat -c %a "${aside[0]}")" == 700 ]] || fail "the preserved dir is not mode 700"
  [[ "$(cat "$fixture/inbox")" == "handoff-preserved-clone-aside unit=$id path=${aside[0]}" ]] || fail "the inbox line is wrong"
  [[ -z "$(remote_rescues)" && ! -e "$fixture/supervisor/autopi/rescue-refused-$n" ]] || fail "the clone was pushed or its refusal marker stayed"
  [[ ! -e "$fixture/scans" ]] || fail "the preserved clone was scanned"
  # The cleanup walk names wt-$id exactly; the suffixed preserved path is left to seven-day expiry.
  [[ "${aside[0]}" != "$WT_ROOT/wt-$id" && -d "${aside[0]}" ]] || fail "the cleanup path includes the preserved clone"
  for out in "$fixture/say.log" "$fixture/inbox" "$comments" "$fixture/scans" "$fixture/state-merges"; do
    [[ ! -e "$out" ]] || ! grep -Fq "$marker" "$out" || fail "preserved content reached $out"
  done
}
aside_clone
printf 'key=AKIAFAKE\n' >> "$wt/a.txt"; git -C "$wt" stash -q
if rescue_handoff_clone 70 "$wt"; then fail "a leak was rescued"; fi
[[ -d "$wt" ]] || fail "rescue_handoff_clone itself must leave the clone"
preserve_refused_clone 70 issue-70 "$wt" || fail "a scan refusal was not set aside"
[[ ! -e "$wt" ]] || fail "the clone is still in place"
aside=("$WT_ROOT"/wt-issue-70.preserved-*); [[ ${#aside[@]} == 1 && -d "${aside[0]}" ]] || fail "expected one preserved dir, got ${aside[*]}"
[[ "${aside[0]##*.preserved-}" =~ ^[0-9]{8}T[0-9]{4}Z$ ]] || fail "bad stamp in ${aside[0]}"
[[ "$(stat -c %a "${aside[0]}")" == 700 ]] || fail "the preserved dir is mode $(stat -c %a "${aside[0]}")"
[[ -n "$(git -C "${aside[0]}" stash list)" ]] || fail "the stash left the preserved clone"
[[ -z "$(remote_rescues)" && ! -e "$fixture/supervisor/autopi/rescue-refused-70" ]] || fail "something was pushed, or the marker stayed"
[[ "$(wc -l < "$fixture/say.log")" == 1 && "$(cat "$fixture/inbox")" == "handoff-preserved-clone-aside unit=issue-70 path=${aside[0]}" ]] || fail "log or inbox line is wrong"
# The clone is gone, so the next pass finds nothing to rescue or hold.
[[ -z "$(worktree_cleanup_block_reason "$wt" 2>/dev/null)" ]] || fail "the handoff would still wait"
for out in "$fixture/say.log" "$fixture/inbox" "$comments" "$fixture/scans" "$fixture/state-merges"; do
  [[ ! -e "$out" ]] || ! grep -q 'AKIAFAKE\|key=' "$out" || fail "stash content reached $out"
done
# A stash with ignored data and unpushed commits both stay in the moved clone, and the handoff can continue.
aside_clone
stash_content='preserved-stash-fixture-content'
printf '%s\n' "$stash_content" > "$wt/ignored.log"
git -C "$wt" stash -q --all
stash_sha="$(git -C "$wt" rev-parse stash@{0})"
[[ "$(worktree_cleanup_block_reason "$wt")" == "Git stash exists" ]] || fail "the stash did not block cleanup"
if rescue_handoff_clone 70 "$wt"; then fail "ignored files in a stash were rescued"; fi
[[ "$RESCUE_REFUSED" == "stash holds ignored files" ]] || fail "said '$RESCUE_REFUSED' for ignored stash data"
assert_refused_clone_aside 70 issue-70 "$stash_content"
aside=("$WT_ROOT"/wt-issue-70.preserved-*)
[[ "$(git -C "${aside[0]}" rev-parse stash@{0})" == "$stash_sha" ]] || fail "the stash changed in the preserved clone"
[[ "$(git -C "${aside[0]}" show "$stash_sha^3:ignored.log")" == "$stash_content" ]] || fail "ignored stash data left the preserved clone"

aside_clone
branch_content='preserved-unpushed-branch-fixture-content'
trigger_content='preserved-uncommitted-trigger-fixture-content'
git -C "$wt" checkout -q -b other
printf '%s\n' "$branch_content" > "$wt/branch-work.txt"
git -C "$wt" add branch-work.txt; git -C "$wt" commit -qm 'synthetic unpushed branch work'
branch_sha="$(git -C "$wt" rev-parse HEAD)"
git -C "$wt" checkout -q -
printf '%s\n' "$trigger_content" > "$wt/work-in-progress.txt"
[[ "$(worktree_cleanup_block_reason "$wt")" == "uncommitted changes" ]] || fail "the uncommitted work did not block cleanup"
rescue_handoff_clone 70 "$wt" || fail "unpushed branch work was refused: $RESCUE_REFUSED"
saved=("$WT_ROOT"/wt-issue-70.preserved-*); [[ ${#saved[@]} == 1 && -d "${saved[0]}" ]] || fail "expected one saved dir, got ${saved[*]}"
grep -rqF "$branch_content" "${saved[0]}" || fail "the unpushed branch patch was not saved"
git --git-dir="$origin" for-each-ref --format='%(refname)' refs/heads/rescued/ | grep -q "^refs/heads/rescued/issue-70-[^ ]*-other$" || fail "the unpushed branch did not reach the remote"
[[ "$(cat "$fixture/say.log")" == "handoff rescue unit=issue-70 stash/unpushed saved ${saved[0]}" ]] || fail "the log line is wrong"
[[ "$(git --git-dir="$origin" show "$RESCUE_START_SHA:work-in-progress.txt")" == "$trigger_content" ]] || fail "the uncommitted trigger was not handed on"
for out in "$fixture/say.log" "$fixture/inbox" "$comments" "$fixture/scans" "$fixture/state-merges"; do
  [[ ! -e "$out" ]] || ! grep -Fq "$trigger_content" "$out" || fail "uncommitted content reached $out"
done

# The active handoff owns hand/* refs; rescue another local branch without publishing that worktree.
new_clone
base_sha="$(git -C "$wt" rev-parse HEAD)"
git -C "$wt" checkout -q -b other; printf 'other\n' > "$wt/o.txt"; git -C "$wt" add o.txt; git -C "$wt" commit -qm other
other_sha="$(git -C "$wt" rev-parse HEAD)"; git -C "$wt" checkout -q -
git -C "$wt" worktree add -q -b hand/issue-70 "$fixture/hand-unpublished-70" "$base_sha"
printf 'active handoff work\n' > "$fixture/hand-unpublished-70/handoff.txt"
git -C "$fixture/hand-unpublished-70" add handoff.txt; git -C "$fixture/hand-unpublished-70" commit -qm 'active handoff work'
hand_sha="$(git -C "$fixture/hand-unpublished-70" rev-parse HEAD)"
rescue_handoff_clone 70 "$wt" || fail "other branch rescue blocked by active hand work: $RESCUE_REFUSED"
remote_rescues | grep -q "^rescued/wt-[^ ]*-other $other_sha$" || fail "the unrelated branch was not rescued"
if remote_rescues | grep -q -- '-hand/'; then fail "the active hand branch was pushed as rescue work"; fi
if git --git-dir="$origin" cat-file -e "$hand_sha" 2>/dev/null; then fail "the active hand commit reached the remote"; fi
[[ "$(git -C "$fixture/hand-unpublished-70" rev-parse HEAD)" == "$hand_sha" \
  && "$(cat "$fixture/hand-unpublished-70/handoff.txt")" == 'active handoff work' ]] || fail "the active handoff worktree changed"

# The marker of an earlier pass counts as the scan's refusal too.
aside_clone
printf 'dirty\n' >> "$wt/a.txt"; touch "$fixture/leak"
rescue_handoff_clone 70 "$wt" && fail "a leak was rescued"; rm -f "$fixture/leak"
rescue_handoff_clone 70 "$wt" && fail "a leak was retried"
[[ "$RESCUE_REFUSED" == *"earlier pass"* ]] || fail "said '$RESCUE_REFUSED'"
preserve_refused_clone 70 issue-70 "$wt" || fail "the earlier-pass refusal was not set aside"
[[ ! -e "$wt" && ! -e "$fixture/supervisor/autopi/rescue-refused-70" ]] || fail "marker or clone left"
# A scan that did not run stays in place; it is not treated as a content finding.
aside_clone
printf 'dirty\n' >> "$wt/a.txt"; touch "$fixture/scan-broken"
rescue_handoff_clone 70 "$wt" && fail "a broken scan was rescued"; rm -f "$fixture/scan-broken"
[[ "$RESCUE_REFUSED" == *"could not run"* ]] || fail "said '$RESCUE_REFUSED'"
if preserve_refused_clone 70 issue-70 "$wt"; then fail "a scan that did not run was set aside"; fi
[[ -d "$wt" ]] || fail "a scan that did not run moved the clone"

# A merge left open by a dead owner. Clean and older than a tick: diffs saved, merge aborted, handoff goes on.
finished_merge() { # open a clean merge of side (staged b.txt) with one unstaged edit to a.txt
  git -C "$wt" checkout -q -b side; printf 'side\n' > "$wt/b.txt"; git -C "$wt" add b.txt; git -C "$wt" commit -qm side; git -C "$wt" checkout -q -
  git -C "$wt" merge -q --no-commit --no-ff side || fail "could not open the finished merge"
  git -C "$wt" branch -q -D side; printf 'unstaged\n' >> "$wt/a.txt"
}
rm -f "$A/merge-head-once"
aside_clone
printf 'local\n' > "$wt/c.txt"; git -C "$wt" add c.txt; git -C "$wt" commit -qm local; local_sha="$(git -C "$wt" rev-parse HEAD)"
finished_merge; gitdir="$(git -C "$wt" rev-parse --absolute-git-dir)"
touch -d '10 minutes ago' "$gitdir/MERGE_HEAD"; merge_sha="$(git -C "$wt" rev-parse MERGE_HEAD)"
# Record the remote's rescued refs at the moment of the abort: the unpushed commit must already be there.
git() { if [[ "$*" == *"merge --abort"* ]]; then command git --git-dir="$origin" for-each-ref --format='%(objectname)' refs/heads/rescued/ > "$fixture/abort-refs"; fi; command git "$@"; }
rescue_handoff_clone 70 "$wt" || fail "a finished merge was not aborted: $RESCUE_REFUSED"
unset -f git
grep -qx "$local_sha" "$fixture/abort-refs" || fail "the unpushed commit was not on the remote before the abort"
[[ -n "$(remote_rescues | grep "^rescued/issue-70-[^ ]* $local_sha$")" ]] || fail "no rescued ref for the unpushed commit"
[[ ! -e "$gitdir/MERGE_HEAD" ]] || fail "MERGE_HEAD survived the abort"
saved=("$WT_ROOT"/wt-issue-70.preserved-*); [[ ${#saved[@]} == 1 && -d "${saved[0]}" ]] || fail "expected one saved dir, got ${saved[*]}"
[[ ! -e "${saved[0]}/push-pending" ]] || fail "the pushed copy is still marked pending"
[[ "$(stat -c %a "${saved[0]}")" == 700 && "$(cat "${saved[0]}/MERGE_HEAD")" == "$merge_sha" ]] || fail "the saved dir or MERGE_HEAD sha is wrong"
grep -q '^+side$' "${saved[0]}/staged.patch" && grep -q '^+unstaged$' "${saved[0]}/unstaged.patch" || fail "the staged or unstaged diff was not saved"
[[ "$(cat "$fixture/say.log")" == "handoff rescue unit=issue-70 merge aborted: saved ${saved[0]}" ]] || fail "the log line is wrong: $(cat "$fixture/say.log")"
# reset --merge keeps the unstaged edit, so the normal handoff rescues it; the staged merge itself is only in the saved diff.
[[ -z "$(git -C "$wt" status --porcelain=v1)" && -n "$RESCUE_START_REF" ]] || fail "the clone was not left clean for the handoff"
[[ "$(git --git-dir="$origin" show "$RESCUE_START_SHA:a.txt")" == $'one\nunstaged' ]] || fail "the unstaged edit was not handed on"

# A push the remote refuses: the merge and the stash stay where they are, the local copy is kept past expiry.
rm -f "$A/rescue-push-failed.once"
aside_clone
printf 'local\n' > "$wt/c.txt"; git -C "$wt" add c.txt; git -C "$wt" commit -qm local
finished_merge; gitdir="$(git -C "$wt" rev-parse --absolute-git-dir)"; touch -d '10 minutes ago' "$gitdir/MERGE_HEAD"
touch "$fixture/hook-refuses"
refused_intact "a merge whose push was refused" "rescue push failed"
[[ -e "$gitdir/MERGE_HEAD" ]] || fail "the merge was aborted after a failed push"
kept=("$WT_ROOT"/wt-issue-70.preserved-*); [[ ${#kept[@]} == 1 && -e "${kept[0]}/push-pending" ]] || fail "the failed push left no pending local copy"
[[ "$(cat "$fixture/say.log")" == "handoff rescue unit=issue-70 push failed: kept ${kept[0]}; owner=head" ]] || fail "the push-failed line is wrong: $(cat "$fixture/say.log")"
[[ "$(cat "$fixture/inbox")" == "rescue-push-failed unit=issue-70 path=${kept[0]}" ]] || fail "the supervisor inbox line is wrong: $(cat "$fixture/inbox")"
# A second tick with the same push still refused: no repeat of the log line or the inbox entry.
rescue_handoff_clone 70 "$wt" && fail "the second tick's push did not refuse"
[[ "$(wc -l < "$fixture/say.log")" == 1 && "$(wc -l < "$fixture/inbox")" == 1 ]] || fail "the second tick repeated the push-failed line or the inbox entry"
rm -f "$fixture/hook-refuses"
NOW_EPOCH=$(( $(date +%s) + 8 * 86400 )) expire_preserved_clones
[[ -d "${kept[0]}" ]] || fail "a copy whose push failed was expired"
aside_clone
printf 'local\n' > "$wt/c.txt"; git -C "$wt" add c.txt; git -C "$wt" commit -qm local
git -C "$wt" checkout -q -b other; printf 'other\n' > "$wt/o.txt"; git -C "$wt" add o.txt; git -C "$wt" commit -qm other; git -C "$wt" checkout -q -
printf 'stashed\n' >> "$wt/a.txt"; git -C "$wt" stash -q
touch "$fixture/hook-refuses"
refused_intact "an unpushed branch whose push was refused" "rescue push failed"
rm -f "$fixture/hook-refuses"
[[ -n "$(git -C "$wt" stash list)" ]] || fail "the stash was cleared after a failed push"
[[ -z "$(remote_rescues)" ]] || fail "a ref reached the remote after a refused push"

# Unmerged paths: left alone, one log line per MERGE_HEAD naming the owner.
aside_clone
git -C "$wt" checkout -q -b side; printf 'side\n' > "$wt/a.txt"; git -C "$wt" commit -qam side; git -C "$wt" checkout -q -
printf 'other\n' > "$wt/a.txt"; git -C "$wt" commit -qam other
git -C "$wt" merge -q side >/dev/null 2>&1 || true
gitdir="$(git -C "$wt" rev-parse --absolute-git-dir)"; touch -d '10 minutes ago' "$gitdir/MERGE_HEAD"
refused_intact "a merge with unmerged paths" "MERGE_HEAD with unmerged paths"
rescue_handoff_clone 70 "$wt" && fail "a merge with unmerged paths was rescued"
[[ "$(cat "$fixture/say.log")" == "handoff rescue unit=issue-70 MERGE_HEAD with unmerged paths; owner=head" ]] || fail "the owner line is wrong: $(cat "$fixture/say.log")"
[[ -e "$gitdir/MERGE_HEAD" ]] || fail "the unmerged merge was touched"
saved=("$WT_ROOT"/wt-issue-70.preserved-*); [[ ! -e "${saved[0]}" ]] || fail "an unmerged merge was saved"

# A finished merge younger than a tick is left for its owner to finish.
aside_clone
finished_merge; gitdir="$(git -C "$wt" rev-parse --absolute-git-dir)"
refused_intact "a fresh finished merge" "MERGE_HEAD in progress"
[[ -e "$gitdir/MERGE_HEAD" && ! -s "$fixture/say.log" ]] || fail "a fresh merge was touched or logged"
saved=("$WT_ROOT"/wt-issue-70.preserved-*); [[ ! -e "${saved[0]}" ]] || fail "a fresh merge was saved"

# Expiry: 7 days after the stamp, that exact name pattern only.
rm -rf "$WT_ROOT"/*; : > "$fixture/say.log"
stamp() { date -u -d "$1 ago" +%Y%m%dT%H%MZ; }
stamp_8_days="$(stamp '8 days')"
stamp_6_days="$(stamp '6 days')"
stamp_9_days="$(stamp '9 days')"
mkdir -p "$WT_ROOT/wt-a.preserved-$stamp_8_days/sub" "$WT_ROOT/wt-b.preserved-$stamp_6_days" "$WT_ROOT/wt-c.preserved-soon" "$WT_ROOT/wt-d" "$fixture/outside"
chmod 500 "$WT_ROOT/wt-a.preserved-$stamp_8_days/sub"
ln -s "$fixture/outside" "$WT_ROOT/wt-e.preserved-$stamp_9_days"
touch "$fixture/outside/keep"; touch -d '30 days ago' "$WT_ROOT/wt-d"
expire_preserved_clones
[[ ! -e "$WT_ROOT/wt-a.preserved-$stamp_8_days" ]] || fail "the 8-day-old dir was kept"
[[ -d "$WT_ROOT/wt-b.preserved-$stamp_6_days" && -d "$WT_ROOT/wt-c.preserved-soon" && -d "$WT_ROOT/wt-d" ]] || fail "a young or non-matching dir was removed"
[[ -L "$WT_ROOT/wt-e.preserved-$stamp_9_days" && -e "$fixture/outside/keep" ]] || fail "a symlink was followed"
[[ "$(wc -l < "$fixture/say.log")" == 1 ]] || fail "expected one log line per removed dir"

# A RULE after a failed handoff check returns to repair, where the worker clone
# resumes from the integrated rescue commit instead of checking the old PR head.
new_clone
handoff_pr_head="$(git -C "$wt" rev-parse HEAD)"
git -C "$wt" checkout -q -b agent/issue-72 "$handoff_pr_head"
git -C "$wt" push -q origin HEAD:refs/heads/agent/issue-72
printf 'rescued line one\nrescued line two\n' > "$wt/rescued.txt"
git -C "$wt" add rescued.txt; git -C "$wt" commit -qm 'preserved handoff history'
handoff_integrated="$(git -C "$wt" rev-parse HEAD)"
handoff_ref72="rescued/agent-issue-72-$handoff_integrated"
git -C "$wt" push -q origin "HEAD:refs/heads/$handoff_ref72"
git -C "$wt" push -q origin "$handoff_pr_head:refs/heads/agent/issue-71"
handoff_ref71="rescued/agent-issue-71-$handoff_integrated"
git -C "$wt" push -q origin "$handoff_integrated:refs/heads/$handoff_ref71"
for id in 71 72; do
  branch="agent/issue-$id"
  git clone -q "$origin" "$WT_ROOT/wt-issue-$id"
  git -C "$WT_ROOT/wt-issue-$id" checkout -q -b "$branch" "refs/remotes/origin/$branch"
done

command jq -n --arg head "$handoff_pr_head" --arg integrated "$handoff_integrated" --arg ref "$handoff_ref72" '{units:[{
  id:"issue-72",pr:712,branch:"agent/issue-72",stage:"review-pending",history:[],
  handoff_integration_sha:$integrated,handoff_original_pr_head:$head,handoff_delivery_verified_sha:null,
  handoff_start_ref:$ref,handoff_start_applied:true}]}' > "$UNITS"
if verify_handoff_delivery issue-72 712 agent/issue-72 "$handoff_pr_head"; then fail 'the first missing-history check did not escalate'; fi
[[ "$(jq -r '.units[0].stage' "$UNITS")" == supervisor-review ]] || fail 'the first missing-history check did not keep its escalation'
printf 'REASON: retry delivery of the preserved handoff\nEVIDENCE: fixture rescue ref\nVERDICT: RULE\n' > "$fixture/cap-report.md"
supervisor_apply_cap_verdict issue-72 "$fixture/cap-report.md" RULE
[[ "$(jq -r '.units[0].stage' "$UNITS")" == repair-pending ]] || fail 'RULE returned an undelivered handoff to review instead of repair'
resume_handoff_integration issue-72 "$WT_ROOT/wt-issue-72"
[[ "$(git -C "$WT_ROOT/wt-issue-72" rev-parse HEAD)" == "$handoff_integrated" ]] || fail 'the ruled repair clone did not start from the integrated rescue commit'

# The same candidate with no write-start since the first failure falls back once,
# preserves rescue visibility in history/logs, and comments the dropped diffstat on the PR.
: > "$pr_comments"; : > "$fixture/say.log"
command jq -n --arg head "$handoff_pr_head" --arg integrated "$handoff_integrated" --arg ref "$handoff_ref71" '{units:[{
  id:"issue-71",pr:711,branch:"agent/issue-71",stage:"review-pending",history:[],
  handoff_integration_sha:$integrated,handoff_original_pr_head:$head,handoff_delivery_verified_sha:null,
  handoff_start_ref:$ref,handoff_start_applied:true}]}' > "$UNITS"
if verify_handoff_delivery issue-71 711 agent/issue-71 "$handoff_pr_head"; then fail 'the first missing-history check did not escalate'; fi
[[ "$(jq -r '[.units[0].history[] | select(.stage=="supervisor-escalated")] | length' "$UNITS")" == 1 ]] || fail 'the first handoff-history failure must keep today’s escalation'
verify_handoff_delivery issue-71 711 agent/issue-71 "$handoff_pr_head" || fail 'the repeated unchanged candidate did not fall back'
jq -e --arg integrated "$handoff_integrated" --arg ref "$handoff_ref71" '
  .units[0].handoff_integration_sha == null
  and ([.units[0].history[] | select(.stage=="handoff-history-dropped" and (.result|contains($integrated)) and (.result|contains($ref)))] | length)==1
  and ([.units[0].history[] | select(.stage=="supervisor-escalated")] | length)==1' "$UNITS" >/dev/null \
  || fail 'the unchanged second failure did not drop history once without another escalation'
grep -F "$handoff_integrated" "$fixture/say.log" | grep -F "$handoff_ref71" >/dev/null || fail 'the fallback log did not name the integrated SHA and rescue ref'
jq -s -e --arg integrated "$handoff_integrated" --arg ref "$handoff_ref71" '
  length==1 and .[0].pr=="711" and (.[0].body|contains("rescued.txt | 2 ++"))
  and (.[0].body|contains($integrated)) and (.[0].body|contains($ref))' "$pr_comments" >/dev/null \
  || fail "the PR did not receive exactly one comment carrying the dropped rescue diffstat ($(cat "$pr_comments"))"

echo "handoff-rescue.test.sh: all assertions passed"
