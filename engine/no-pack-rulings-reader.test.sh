#!/usr/bin/env bash
# Guard (591): no engine or tools code reads the pack's rulings copy. The engine reads VectA's vendored
# state/rulings.json through the pin; a reader of the pack copy (~/.vecta-agent/pack) drifts silently.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
cd "$MODEL_POLICY_TEST_REPO" # ls-files must run in this repo, not the test cwd

pack_read='\.vecta-agent/pack|AGENT_HOME}\?/pack/|"pack", "scripts"'
fail=0
while IFS= read -r f; do
  case "$f" in
    engine/no-pack-rulings-reader.test.sh) continue ;;
    *.test.*|*/test-*.sh|test-*.sh|*fixture*/*) continue ;;
    *.sh|*.mjs|*.js|*.cjs|*.py|*.ts) ;;
    *) continue ;;
  esac
  if hits=$(grep -n -e '\.vecta-agent/pack' -e 'AGENT_HOME}\?/pack/' -e '"pack", "scripts"' -- "$f"); then
    printf 'FAIL %s reads the pack rulings copy (pattern: %s)\n%s\n' "$f" "$pack_read" "$hits" >&2
    fail=1
  fi
done < <(git ls-files engine tools)

(( fail )) && exit 1
echo 'no-pack-rulings-reader ok'
