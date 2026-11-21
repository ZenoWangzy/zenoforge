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
# #1339: a command whose argument holds a newline must still record exactly one line, with the newline as the two characters \n.
pass_arg=$'one\ntwo'
before="$(wc -l < "$receipts")"
rc=0; (cd "$tmp" && bash "$SCRIPT_DIR/../tools/test-receipt.sh" true "$pass_arg") || rc=$?
check 'a passing multiline command adds exactly one receipt line' "$((before + 1))" "$(wc -l < "$receipts")"
check 'the record is rc 0, a TAB, then the command with the newline as \n' $'0\ttrue one\\ntwo' "$(tail -n 1 "$receipts")"
# Review of the #1339 writer: the backslash must be escaped first, or a real newline and a literal backslash-n in
# the command collapse to the same record text; TAB, carriage return and a trailing newline also need cases.
real_nl_arg=$'a\nb'
literal_bs_arg='a\nb'
rc=0; (cd "$tmp" && bash "$SCRIPT_DIR/../tools/test-receipt.sh" true "$real_nl_arg") || rc=$?
rc2=0; (cd "$tmp" && bash "$SCRIPT_DIR/../tools/test-receipt.sh" true "$literal_bs_arg") || rc2=$?
check 'a real newline and a literal backslash-n record as two different lines' \
  $'0\ttrue a\\nb\n0\ttrue a\\\\nb' "$(tail -n 2 "$receipts")"
check 'both collision runs return 0' '0 0' "$rc $rc2"
tab_arg=$'a\tb'
before="$(wc -l < "$receipts")"
rc=0; (cd "$tmp" && bash "$SCRIPT_DIR/../tools/test-receipt.sh" true "$tab_arg") || rc=$?
check 'a TAB in the command adds one receipt line and returns 0' "0 $((before + 1))" "$rc $(wc -l < "$receipts")"
check 'the record holds one TAB, the separator, and the argument TAB as the two characters \t' $'0\ttrue a\\tb' "$(tail -n 1 "$receipts")"
cr_arg=$'a\rb'
before="$(wc -l < "$receipts")"
rc=0; (cd "$tmp" && bash "$SCRIPT_DIR/../tools/test-receipt.sh" true "$cr_arg") || rc=$?
check 'a carriage return adds one receipt line and returns 0' "0 $((before + 1))" "$rc $(wc -l < "$receipts")"
check 'the record holds no carriage return, only the two characters \r' $'0\ttrue a\\rb' "$(tail -n 1 "$receipts")"
trailing_nl_arg=$'x\n'
before="$(wc -l < "$receipts")"
rc=0; (cd "$tmp" && bash "$SCRIPT_DIR/../tools/test-receipt.sh" true "$trailing_nl_arg") || rc=$?
check 'a trailing newline adds exactly one receipt line and returns 0' "0 $((before + 1))" "$rc $(wc -l < "$receipts")"
check 'the record ends with the argument and its newline as the two characters \n' $'0\ttrue x\\n' "$(tail -n 1 "$receipts")"
fail_arg=$'three\nfour'
before="$(wc -l < "$receipts")"
rc=0; (cd "$tmp" && bash "$SCRIPT_DIR/../tools/test-receipt.sh" false "$fail_arg") || rc=$?
check 'a failing multiline command returns 1 and records exactly rc 1, a TAB, then the command with the newline as \n' \
  $'1 1\tfalse three\\nfour' "$rc $(tail -n 1 "$receipts")"
check 'a failing multiline command adds exactly one receipt line' "$((before + 1))" "$(wc -l < "$receipts")"
last_line="$(tail -n 1 "$receipts")"
check 'the failing record starts with its exit code and a TAB' yes "$([[ $last_line == 1$'\t'* ]] && echo yes || echo no)"
(( failures == 0 )) && echo 'test-receipt-dirty.test.sh: pass' || { echo "test-receipt-dirty.test.sh: $failures failed"; exit 1; }
