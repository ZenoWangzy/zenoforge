#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

fail() { printf 'suppression-ratchet.test.sh: %s\n' "$*" >&2; exit 1; }

ratchet="$MODEL_POLICY_TEST_REPO/tools/suppression-ratchet.mjs"
rc=0
real=$(HOME="$test_host_home" node "$ratchet" 2>&1) || rc=$?
[[ $rc == 0 && $real == 'suppression-ratchet ok' ]] || fail "current tree did not pass: rc=$rc $real"

repo="$test_env_root/suppression-ratchet"
mkdir -p "$repo/tools" "$repo/engine" "$repo/docs/adr"
cp "$MODEL_POLICY_TEST_REPO/tools/suppression-ratchet.mjs" "$repo/tools/"
cp "$MODEL_POLICY_TEST_REPO/tools/source-comments.mjs" "$repo/tools/"
printf '%s\n' '1	engine/a.py	noqa: F401' '1	engine/a.py	type: ignore[assignment]' '1	engine/a.sh	shellcheck disable=SC2086' '1	engine/a.ts	@ts-expect-error' '1	engine/a.ts	@ts-ignore' '1	engine/a.ts	eslint-disable no-alert' > "$repo/tools/suppression-baseline.txt"
printf '[]\n' > "$repo/tools/suppression-exceptions.json"
git init -q -b main "$repo"
git -C "$repo" config user.name test
git -C "$repo" config user.email test@example.com
cd "$repo"
run() { HOME="$test_host_home" node tools/suppression-ratchet.mjs "$@" 2>&1; }
fails() { if run "$@" > out.txt 2>&1; then return 1; fi; cat out.txt; }

printf '%s\n' '# shellcheck disable=SC2086' > engine/a.sh
cat > engine/a.ts <<'EOF'
/* eslint-disable no-alert */
// @ts-expect-error fixture
const first: string = 1;
// @ts-ignore fixture
const second: string = 2;
EOF
cat > engine/a.py <<'EOF'
from pathlib import Path # noqa: F401
value = 'x' # type: ignore[assignment]
EOF
[[ "$(run)" == 'suppression-ratchet ok' ]] || fail 'the baseline directive was refused'
git add -A && git commit -qm baseline
printf '%s\n' '1	engine/new.sh	shellcheck disable=SC2048' >> tools/suppression-baseline.txt
git add tools/suppression-baseline.txt && git commit -qm 'baseline growth'
out=$(fails --changed HEAD~1) || fail 'a directly raised baseline passed'
[[ $out == *'a baseline may only shrink'* ]] || fail "a raised baseline did not name the shrink-only rule: $out"
git show HEAD~1:tools/suppression-baseline.txt > tools/suppression-baseline.txt

printf '%s\n' '# shellcheck disable=SC2086' '# shellcheck disable=SC2086' > engine/a.sh
out=$(fails) || fail 'a new suppression directive passed'
[[ $out == *'FAIL engine/a.sh:2'*'shellcheck disable=SC2086'*'fix the finding'*'record the exception in an ADR'*'suppression-exceptions.json'* ]] || fail "the failure did not name its location and both remedies: $out"

mkdir -p docs/adr
cat > docs/adr/0001-test.md <<'EOF'
# Test ADR
<!-- adr-header v1 -->
> **Decision:** A test fixture has a valid ADR reference.
EOF
cat > tools/suppression-exceptions.json <<'EOF'
[{"file":"engine/a.sh","line":2,"directive":"shellcheck disable=SC2086","adr":"docs/adr/0001-test.md"}]
EOF
[[ "$(run)" == 'suppression-ratchet ok' ]] || fail 'an ADR-backed exception was refused'

cat > tools/suppression-exceptions.json <<'EOF'
[{"file":"engine/a.sh","line":2,"directive":"shellcheck disable=SC2086"}]
EOF
out=$(fails) || fail 'an exception without an ADR reference passed'
[[ $out == *'exception 1 must name an ADR'* ]] || fail "the missing ADR was not named: $out"

cat > tools/suppression-exceptions.json <<'EOF'
[{"file":"engine/a.sh","line":2,"directive":"shellcheck disable=SC2086","adr":"docs/adr/0002-missing.md"}]
EOF
out=$(fails) || fail 'an exception with a missing ADR passed'
[[ $out == *'ADR does not exist'* ]] || fail "the missing ADR file was not refused: $out"

printf '[]\n' > tools/suppression-exceptions.json
rm engine/a.ts engine/a.py
printf 'echo x\n' > engine/a.sh
out=$(run --tighten) || fail "the baseline did not shrink: $out"
rows=$(awk '!/^#/ && NF { n++ } END { print n+0 }' tools/suppression-baseline.txt)
[[ $rows == 0 ]] || fail "tightening retained a removed directive: $(cat tools/suppression-baseline.txt)"

printf '%s\n' '# shellcheck disable=SC2086' > engine/a.sh
out=$(fails --tighten) || fail 'tightening raised the baseline'
[[ $out == *'suppression-ratchet: a directive was added'* ]] || fail "baseline growth was not refused: $out"
