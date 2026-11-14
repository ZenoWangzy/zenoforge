#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
trap 'rm -rf -- "$test_env_root"' EXIT
t="$test_env_root/dropped-refs"
mkdir -p "$t/base/engine/mac-autopilot" "$t/new/engine/mac-autopilot"
engine_sha=0123456789abcdef0123456789abcdef01234567
printf 'zenoforge_sha=%s\n' "$engine_sha" > "$t/new/BUILD-INFO"
echo 'echo watch' > "$t/base/engine/mac-autopilot/zombie-watch.sh"
printf '%s\n' '#!/usr/bin/env bash' 'HERE=$(dirname "$0")' 'bash "$HERE/zombie-watch.sh"' > "$t/base/engine/mac-autopilot/zombie-loop.sh"
cp "$t/base/engine/mac-autopilot/zombie-loop.sh" "$t/new/engine/mac-autopilot/zombie-loop.sh"
run() { python3 -I "$here/dropped-file-refs-check.py" "$t/base" "$t/new" "$@"; }
rc=0; out=$(run 2>&1) || rc=$?
[[ $rc == 1 ]] && grep -q 'zombie-watch.sh.*zombie-loop.sh:3' <<<"$out" || { echo "FAIL: dropped referenced file passed: $out"; exit 1; }
printf 'mac-autopilot/zombie-watch.sh\tretired on purpose\t%s\n' "$engine_sha" > "$t/intended.tsv"
out=$(run "$t/intended.tsv" 2>&1) || { echo "FAIL: intended drop: $out"; exit 1; }
printf 'mac-autopilot/zombie-watch.sh\tstale retirement\t%s\n' "${engine_sha%?}f" > "$t/stale.tsv"
rc=0; out=$(run "$t/stale.tsv" 2>&1) || rc=$?
[[ $rc == 1 ]] && grep -Fq "intended-changes: ignoring stale row mac-autopilot/zombie-watch.sh (sha ${engine_sha%?}f, new engine $engine_sha)" <<<"$out" \
  && grep -q 'DROPPED but still referenced' <<<"$out" || { echo "FAIL: stale row approved dropped file: $out"; exit 1; }
cp "$t/base/engine/mac-autopilot/zombie-watch.sh" "$t/new/engine/mac-autopilot/"
out=$(run 2>&1) && grep -q 'OK (0 dropped' <<<"$out" || { echo "FAIL: restored file: $out"; exit 1; }
rm "$t/new/engine/mac-autopilot/zombie-watch.sh"
sed -i '3d' "$t/new/engine/mac-autopilot/zombie-loop.sh"
out=$(run 2>&1) && grep -q 'OK (1 dropped' <<<"$out" || { echo "FAIL: unreferenced drop: $out"; exit 1; }
# A consumer the build ships beside the engine (an injected skill tree) references the dropped file: must fail too,
# and an intended-change row must still approve it (2026-11-03: the advisor skill lost cdp-page-registry.cjs this way).
mkdir -p "$t/new/.agents/skills/web-advisor-provider"
printf '%s\n' '#!/usr/bin/env node' "require(zfHostOpsFile('engine/mac-autopilot/zombie-watch.sh'))" > "$t/new/.agents/skills/web-advisor-provider/ask.cjs"
rc=0; out=$(run 2>&1) || rc=$?
[[ $rc == 1 ]] && grep -q 'zombie-watch.sh.*.agents/skills/web-advisor-provider/ask.cjs:2' <<<"$out" || { echo "FAIL: consumer-referenced drop passed: $out"; exit 1; }
out=$(run "$t/intended.tsv" 2>&1) || { echo "FAIL: intended drop still flagged for consumer: $out"; exit 1; }
rm -rf -- "$t/new/.agents"
out=$(run 2>&1) && grep -q 'OK (1 dropped' <<<"$out" || { echo "FAIL: unreferenced drop after consumer removed: $out"; exit 1; }
# 2026-11-14 ENGINE-CONVERGE-FAIL: the version dir links the checkout's top level, and gitnexus's temp index dir
# (.gitnexus-next.*) was gone by open(); a dangling link (script-named or not) must not crash the check.
ln -s "$t/gone/.gitnexus-next.h1zEIc" "$t/new/.gitnexus-next.h1zEIc"
ln -s "$t/gone/release.sh" "$t/new/release.sh"
out=$(run 2>&1) && grep -q 'OK (1 dropped' <<<"$out" || { echo "FAIL: dangling link: $out"; exit 1; }
echo "dropped-file-refs-check.test.sh: PASS"
