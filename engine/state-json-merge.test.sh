#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
MERGE_DRIVER="$SCRIPT_DIR/git-merge-state-json.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$*"; }

cat >"$tmp/base.json" <<'JSON'
{
  "incidents": [
    {
      "id" : "base",
      "date":"2026-09-01",
      "what_happened" : "keep exact bytes"
    }
  ],
  "version": 1
}
JSON
cat >"$tmp/main.json" <<'JSON'
{
  "incidents": [
    {
      "id" : "base",
      "date":"2026-09-01",
      "what_happened" : "keep exact bytes"
    },
    {
      "id": "main-entry",
      "date": "2026-09-28",
      "detail": "main whitespace stays"
    }
  ],
  "version": 1
}
JSON
cat >"$tmp/branch.json" <<'JSON'
{
  "incidents": [
    {
      "id" : "base",
      "date":"2026-09-01",
      "what_happened" : "keep exact bytes"
    },
    {
      "id" : "branch-entry",
      "date" : "2026-09-28",
      "detail" : "branch whitespace stays"
    }
  ],
  "version": 1
}
JSON

bash "$MERGE_DRIVER" "$tmp/base.json" "$tmp/main.json" "$tmp/branch.json" \
  || fail 'disjoint append-only additions merge'
jq -e '.incidents | map(.id) == ["base","main-entry","branch-entry"]' "$tmp/main.json" >/dev/null \
  || fail 'both additions survive in main-then-branch order'
grep -Fq '      "id" : "base",' "$tmp/main.json" \
  || fail 'untouched entry retains exact indentation and spacing'
grep -Fq '      "what_happened" : "keep exact bytes"' "$tmp/main.json" \
  || fail 'untouched entry retains exact member bytes'
grep -Fq '      "id" : "branch-entry",' "$tmp/main.json" \
  || fail 'merged branch entry retains its exact member bytes'
grep -Fq '      "detail" : "branch whitespace stays"' "$tmp/main.json" \
  || fail 'merged branch entry retains its original formatting'
pass 'append merge preserves untouched and replayed entry bytes'

cat >"$tmp/base.json" <<'JSON'
{
  "landed_shas": {
    "stable-package" : "sha-stable"
  },
  "stalled_after_seconds": 21600
}
JSON
cat >"$tmp/main.json" <<'JSON'
{
  "landed_shas": {
    "stable-package" : "sha-stable",
    "main-package" : "sha-main"
  },
  "stalled_after_seconds": 21600
}
JSON
cat >"$tmp/branch.json" <<'JSON'
{
  "landed_shas": {
    "stable-package" : "sha-stable",
    "branch-package" : "sha-branch"
  },
  "stalled_after_seconds": 21600
}
JSON
bash "$MERGE_DRIVER" "$tmp/base.json" "$tmp/main.json" "$tmp/branch.json" \
  || fail 'independent work-plan map entries merge'
jq -e '.landed_shas == {"stable-package":"sha-stable","main-package":"sha-main","branch-package":"sha-branch"}' \
  "$tmp/main.json" >/dev/null || fail 'independent landed SHA entries both survive'
grep -Fq '    "stable-package" : "sha-stable"' "$tmp/main.json" \
  || fail 'untouched landed SHA property keeps exact formatting'
grep -Fq '    "branch-package" : "sha-branch"' "$tmp/main.json" \
  || fail 'merged landed SHA property keeps original formatting'
pass 'work-plan map merge preserves untouched and replayed property bytes'

cat >"$tmp/base.json" <<'JSON'
{
  "nullable" : null,
  "stable": 1
}
JSON
cp "$tmp/base.json" "$tmp/main.json"
cp "$tmp/base.json" "$tmp/branch.json"
bash "$MERGE_DRIVER" "$tmp/base.json" "$tmp/main.json" "$tmp/branch.json" \
  || fail 'unchanged null-valued properties survive merge'
jq -e 'has("nullable") and .nullable == null' "$tmp/main.json" >/dev/null \
  || fail 'top-level null must not be mistaken for a removed key'
grep -Fq '  "nullable" : null,' "$tmp/main.json" \
  || fail 'unchanged null-valued property keeps exact formatting'
pass 'unchanged null-valued properties survive byte-preserving merge'

cat >"$tmp/base.json" <<'JSON'
{"rulings":[{"id":"keep","value":1},{"id":"feature-added","value":2}]}
JSON
cat >"$tmp/main.json" <<'JSON'
{"rulings":[{"id":"keep","value":1},{"id":"feature-added","value":2},{"id":"main-added","value":3}]}
JSON
cat >"$tmp/branch.json" <<'JSON'
{"rulings":[{"id":"keep","value":1}]}
JSON
bash "$MERGE_DRIVER" "$tmp/base.json" "$tmp/main.json" "$tmp/branch.json" \
  || fail 'revert and independent main append merge'
jq -e '.rulings | map(.id) == ["keep","main-added"]' "$tmp/main.json" >/dev/null \
  || fail 'revert removes feature-added id without dropping main addition'
pass 'revert removes only replayed feature ids'

cat >"$tmp/base.json" <<'JSON'
{"incidents":[{"id":"same","value":1}]}
JSON
cat >"$tmp/main.json" <<'JSON'
{"incidents":[{"id":"same","value":2}]}
JSON
cat >"$tmp/branch.json" <<'JSON'
{"incidents":[{"id":"same","value":3}]}
JSON
if bash "$MERGE_DRIVER" "$tmp/base.json" "$tmp/main.json" "$tmp/branch.json" 2>/dev/null; then
  fail 'divergent edits to the same id must conflict'
fi
pass 'divergent same-id edits fail closed'
