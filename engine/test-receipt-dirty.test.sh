#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# tools/test-receipt.sh files a receipt under HEAD, so it must refuse while tracked files differ from HEAD (11-13 #1113).
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp" "$test_env_root"' EXIT
failures=0
check() { # description expected actual
  if [[ "$2" == "$3" ]]; then printf 'ok - %s\n' "$1"; else printf 'not ok - %s (expected [%s], got [%s])\n' "$1" "$2" "$3"; failures=$((failures + 1)); fi
}
git -C "$tmp" init -q && git -C "$tmp" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf 'a\n' > "$tmp/f" && git -C "$tmp" add f && git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m f
receipts="$tmp/.git/zf-test-receipts/$(git -C "$tmp" rev-parse HEAD)"
rc=0; (cd "$tmp" && bash "$SCRIPT_DIR/../tools/test-receipt.sh" true) || rc=$?
check 'a clean tree records the receipt' '0 1' "$rc $(wc -l < "$receipts" 2>/dev/null || echo 0)"
printf 'b\n' > "$tmp/f"
rc=0; out="$(cd "$tmp" && bash "$SCRIPT_DIR/../tools/test-receipt.sh" true 2>&1)" || rc=$?
check 'a tracked change refuses with rc 2' 2 "$rc"
check 'the refusal names the cause' yes "$([[ $out == *'tracked files differ from HEAD'* ]] && echo yes || echo no)"
check 'no receipt line is added for the dirty run' 1 "$(wc -l < "$receipts")"
git -C "$tmp" checkout -q -- f && printf 'x\n' > "$tmp/untracked"
rc=0; (cd "$tmp" && bash "$SCRIPT_DIR/../tools/test-receipt.sh" true) || rc=$?
check 'an untracked file alone does not refuse' 0 "$rc"
(( failures == 0 )) && echo 'test-receipt-dirty.test.sh: pass' || { echo "test-receipt-dirty.test.sh: $failures failed"; exit 1; }
