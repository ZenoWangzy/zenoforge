#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
trap 'rm -rf -- "$test_env_root"' EXIT
t="$test_env_root/dropped-refs"
mkdir -p "$t/base/engine/mac-autopilot" "$t/new/engine/mac-autopilot"
echo 'echo watch' > "$t/base/engine/mac-autopilot/zombie-watch.sh"
printf '%s\n' '#!/usr/bin/env bash' 'HERE=$(dirname "$0")' 'bash "$HERE/zombie-watch.sh"' > "$t/base/engine/mac-autopilot/zombie-loop.sh"
cp "$t/base/engine/mac-autopilot/zombie-loop.sh" "$t/new/engine/mac-autopilot/zombie-loop.sh"
run() { python3 -I "$here/dropped-file-refs-check.py" "$t/base" "$t/new" "$@"; }
rc=0; out=$(run 2>&1) || rc=$?
[[ $rc == 1 ]] && grep -q 'zombie-watch.sh.*zombie-loop.sh:3' <<<"$out" || { echo "FAIL: dropped referenced file passed: $out"; exit 1; }
printf 'mac-autopilot/zombie-watch.sh\tretired on purpose\n' > "$t/intended.tsv"
out=$(run "$t/intended.tsv" 2>&1) || { echo "FAIL: intended drop: $out"; exit 1; }
cp "$t/base/engine/mac-autopilot/zombie-watch.sh" "$t/new/engine/mac-autopilot/"
out=$(run 2>&1) && grep -q 'OK (0 dropped' <<<"$out" || { echo "FAIL: restored file: $out"; exit 1; }
rm "$t/new/engine/mac-autopilot/zombie-watch.sh"
sed -i '3d' "$t/new/engine/mac-autopilot/zombie-loop.sh"
out=$(run 2>&1) && grep -q 'OK (1 dropped' <<<"$out" || { echo "FAIL: unreferenced drop: $out"; exit 1; }
echo "dropped-file-refs-check.test.sh: PASS"
