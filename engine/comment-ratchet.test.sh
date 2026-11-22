#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

fail() { printf 'comment-ratchet.test.sh: %s\n' "$*" >&2; exit 1; }

real=$(node "$MODEL_POLICY_TEST_REPO/tools/comment-ratchet.mjs" 2>&1) || fail "current tree fails: $real"
[[ $real == 'comment-ratchet ok' ]] || fail "current tree did not report success: $real"

repo="$test_env_root/comment-ratchet"
mkdir -p "$repo/tools" "$repo/engine"
cp "$MODEL_POLICY_TEST_REPO/tools/comment-ratchet.mjs" "$repo/tools/"
git init -q -b main "$repo"
git -C "$repo" config user.name test
git -C "$repo" config user.email test@example.com
cd "$repo"
ratchet() { node tools/comment-ratchet.mjs "$@" 2>&1; }

printf 'cat <<EOF\n# not a comment\nEOF\n' > engine/heredoc.sh
printf '# one\necho one\n' > engine/a.sh
printf '1\tengine/a.sh\n' > tools/comment-baseline.txt
rc=0; out=$(ratchet) || rc=$?
[[ $rc == 0 && $out == 'comment-ratchet ok' ]] || fail "a heredoc # line or a file at its baseline was refused: $out"

printf '# two\n' >> engine/a.sh
rc=0; out=$(ratchet) || rc=$?
[[ $rc == 1 && $out == *'FAIL engine/a.sh has 2 comments, its baseline in tools/comment-baseline.txt is 1'*'remove the comment; put a decision in docs/adr and a shortcut in an issue'* ]] || fail "a grown file passed or its message lacks file, count, baseline or both actions: $out"

printf '# new\n' > engine/b.sh
rc=0; out=$(ratchet) || rc=$?
[[ $rc == 1 && $out == *'FAIL engine/b.sh has 1 comments, its baseline in tools/comment-baseline.txt is 0'* ]] || fail "a new file with a comment passed: $out"
rm engine/b.sh

rc=0; out=$(ratchet --tighten) || rc=$?
[[ $rc == 1 && $out == *'a count grew, nothing tightened'* ]] || fail "--tighten accepted a grown count: $out"
[[ "$(cat tools/comment-baseline.txt)" == $'1\tengine/a.sh' ]] || fail '--tighten changed the baseline after growth'

rm engine/a.sh tools/comment-baseline.txt
printf '# one\necho one\n' > engine/a.sh
ratchet --tighten >/dev/null || fail 'tightening with no baseline file failed'
grep -qP '^1\tengine/a.sh$' tools/comment-baseline.txt || fail "first tighten did not create the baseline: $(cat tools/comment-baseline.txt)"

git add -A && git commit -qm base
printf 'echo one\n' > engine/a.sh
git commit -qam 'comment-only deletion'
rc=0; out=$(ratchet --proof HEAD~1) || rc=$?
[[ $rc == 0 && $out == 'comment-only: ok' ]] || fail "a comment-only deletion failed --proof: $out"

printf 'echo one\necho three\n' > engine/a.sh
git commit -qam 'code change'
rc=0; out=$(ratchet --proof HEAD~2) || rc=$?
[[ $rc == 1 && $out == *'engine/a.sh'* ]] || fail "a code change passed --proof: $out"

printf '# new\n' > engine/c.sh
git add -A && git commit -qm 'comment-only addition'
rc=0; out=$(ratchet --changed HEAD~1) || rc=$?
[[ $rc == 1 && $out == *'FAIL engine/c.sh'* && $out != *'engine/a.sh'* ]] || fail "--changed did not check only the changed file: rc=$rc $out"

node_bin=$(command -v node)
rc=0; out=$(env PATH=/usr/bin:/bin "$node_bin" tools/comment-ratchet.mjs 2>&1) || rc=$?
[[ $rc == 2 && $out == *'shfmt is not installed'* ]] || fail "a missing shfmt was not refused with rc 2 and a message: rc=$rc $out"
