#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

fail() { printf 'comment-ratchet.test.sh: %s\n' "$*" >&2; exit 1; }

rc=0; real=$(HOME="$test_host_home" node "$MODEL_POLICY_TEST_REPO/tools/comment-ratchet.mjs" 2>&1) || rc=$?
if [[ $rc == 2 && $real == *'is not installed'* && -z ${CI:-} ]]; then
  printf 'SKIP comment-ratchet.test.sh: %s\n' "${real//$'\n'/; }"; exit 0
fi
(( rc == 0 )) || fail "current tree fails: $real"
unexpected="$(grep -Ev '^(NOTE .*: run node tools/comment-ratchet\.mjs --tighten\.|comment-ratchet ok)$' <<< "$real" || true)"
[[ -z "$unexpected" && "$(grep -xc 'comment-ratchet ok' <<< "$real")" == 1 ]] || fail "current tree reported unexpected output: $real"

repo="$test_env_root/comment-ratchet"
mkdir -p "$repo/tools" "$repo/engine"
[[ ! -d "$MODEL_POLICY_TEST_REPO/node_modules" ]] || ln -s "$MODEL_POLICY_TEST_REPO/node_modules" "$repo/node_modules"
cp "$MODEL_POLICY_TEST_REPO/tools/comment-ratchet.mjs" "$repo/tools/"
cp "$MODEL_POLICY_TEST_REPO/tools/source-comments.mjs" "$repo/tools/"
git init -q -b main "$repo"
git -C "$repo" config user.name test
git -C "$repo" config user.email test@example.com
cd "$repo"
ratchet() { HOME="$test_host_home" node tools/comment-ratchet.mjs "$@" 2>&1; }

printf 'cat <<EOF\n# not a comment\nEOF\n' > engine/heredoc.sh
printf '# one\necho one\n' > engine/a.sh
printf '# shellcheck disable=SC2086\necho suppressed\n' > engine/suppressed.sh
printf '%s\n' '// @ts-expect-error fixture' '// @ts-ignore fixture' '/* eslint-disable no-alert */' > engine/suppressed.mjs
printf '%s\n' 'from pathlib import Path # noqa: E402' 'value = 1 # type: ignore[assignment]' > engine/suppressed.py
printf '1\tengine/a.sh\n' > tools/comment-baseline.txt
rc=0; out=$(ratchet) || rc=$?
[[ $rc == 0 && $out == 'comment-ratchet ok' ]] || fail "a heredoc # line or a file at its baseline was refused: $out"

printf '# two\n' >> engine/a.sh
rc=0; out=$(ratchet) || rc=$?
[[ $rc == 1 && $out == *'REFUSAL found="engine/a.sh has 2 comments'*'alternative='*'documented_in=docs/enforced-rules.md'* ]] || fail "a grown file passed or its refusal lacks finding, alternative or documentation: $out"

printf '# new\n' > engine/b.sh
rc=0; out=$(ratchet) || rc=$?
[[ $rc == 1 && $out == *'REFUSAL found="engine/b.sh has 1 comments'*'alternative='*'documented_in=docs/enforced-rules.md'* ]] || fail "a new file with a comment passed or its refusal lacks guidance: $out"
rm engine/b.sh

rc=0; out=$(ratchet --tighten) || rc=$?
[[ $rc == 1 && $out == *'REFUSAL found="a count above baseline"'*'alternative="remove the added comment before tightening"'*'documented_in=docs/enforced-rules.md'* ]] || fail "--tighten accepted a grown count or its refusal omitted guidance: $out"
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
[[ $rc == 1 && $out == *'REFUSAL found="engine/c.sh has 1 comments'* && $out != *'engine/a.sh'* ]] || fail "--changed did not check only the changed file: rc=$rc $out"

node_bin=$(command -v node)
rc=0; out=$(env PATH=/usr/bin:/bin "$node_bin" tools/comment-ratchet.mjs 2>&1) || rc=$?
[[ $rc == 2 && $out == *'shfmt is not installed'* ]] || fail "a missing shfmt was not refused with rc 2 and a message: rc=$rc $out"
