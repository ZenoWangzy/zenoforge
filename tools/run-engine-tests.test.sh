#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091 # test-env.sh is repo-relative
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/engine/test-env.sh"

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
tmp="$TMPDIR/run-engine-tests"
mkdir -p "$tmp/tools" "$tmp/engine"
cp "$here/run-engine-tests.sh" "$tmp/tools/run-engine-tests.sh"
printf 'engine/base.test.sh\tbase reason\n' >"$tmp/tools/quarantine.txt"
printf 'engine/darwin-a.test.sh\tdarwin reason\nengine/shared.test.sh\tdarwin reason\n' >"$tmp/tools/quarantine-darwin.txt"
printf 'engine/shared.test.sh\twsl reason\nengine/wsl.test.sh\twsl reason\n' >"$tmp/tools/quarantine-wsl.txt"
: >"$tmp/tools/quarantine-empty.txt"
printf '%s\n' \
  engine/base.test.sh \
  engine/darwin-a.test.sh \
  engine/shared.test.sh \
  engine/wsl.test.sh \
  engine/ok.test.sh >"$tmp/suites.txt"
printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/engine/test-bootstrap-check.sh"
printf '#!/usr/bin/env bash\necho fixture passed\n' >"$tmp/engine/ok.test.sh"

output=$(cd "$tmp" && ZF_SUITES_FILE="$tmp/suites.txt" ZF_QUARANTINE_SETS='darwin wsl empty' bash tools/run-engine-tests.sh 0 1 2>&1) || {
  printf '%s\n' "$output" >&2
  exit 1
}
for line in \
  'QUARANTINE darwin: 2' \
  'QUARANTINE wsl: 2' \
  'QUARANTINE empty: 0' \
  'shard 0/1: 1 passed, 0 failed, 4 quarantined'; do
  grep -Fqx -- "$line" <<<"$output" || { printf 'missing output line: %s\n%s\n' "$line" "$output" >&2; exit 1; }
done
