#!/usr/bin/env bash
# Every ZCode launch must strip GH_TOKEN and GITHUB_TOKEN, so a new launch file has to join this list. merge-pr.sh runs this on an export, so no git here.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
want='engine/bin/zc engine/eval/stage-call.sh engine/lib.d/model-calls.sh engine/mac-autopilot/scheduler.d/worker-command.sh engine/night/dispatch.sh'
got="$(cd "$root" && grep -rlE '(^|[ (=])zcode -p |/bin/zcode"' engine --exclude='*.test.*' --exclude='*.md' --exclude-dir=node_modules | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
[[ "$got" == "$want" ]] || { echo "not ok - the known ZCode launch set (expected [$want], got [$got])"; exit 1; }
echo 'ok - the known ZCode launch set'
