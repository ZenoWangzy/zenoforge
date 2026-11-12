#!/usr/bin/env bash
# Structure and public-safety checks for docs/design/AGENT-SCALE-PRINCIPLES.md and its AGENTS.md pointer (issue #1039).
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
doc="$repo/docs/design/AGENT-SCALE-PRINCIPLES.md"
fail() { printf 'agent-scale-principles-doc.test.sh: %s\n' "$*" >&2; exit 1; }

[[ -f "$doc" ]] || fail "missing $doc"
for heading in '^## Summary$' '^## Principles$' '^## Checklist' '^## Cases$' '^## How to add a case$'; do
  grep -qE "$heading" "$doc" || fail "missing section matching $heading"
done
[[ "$(grep -cE '^#### [0-9]+\. ' "$doc")" == 16 ]] || fail "expected 16 principles"
[[ "$(grep -cE '^[0-9]+\. ' "$doc")" == 11 ]] || fail "expected 11 checklist questions"
[[ "$(grep -cE '^\| 2026-11-12 ' "$doc")" == 5 ]] || fail "expected 5 audit rows in the case table"

pointers="$(grep -c 'docs/design/AGENT-SCALE-PRINCIPLES.md' "$repo/AGENTS.md" || true)"
[[ "$pointers" == 1 ]] || fail "AGENTS.md must hold exactly one pointer line, found $pointers"

leaks="$(grep -nE '/home/|~/\.zenoforge|~/\.vecta|\.vecta-agent|vecta|gerald|mypc' "$doc" || true)"
[[ -z "$leaks" ]] || fail "private path or name in the public doc:"$'\n'"$leaks"

echo 'agent-scale-principles-doc.test.sh: all assertions passed'
