#!/usr/bin/env bash
# repair_check_rows keeps the rows gh prints when it exits nonzero for a failed check, and fails on empty gh output.
set -euo pipefail
d=$(cd "$(dirname "$0")" && pwd); t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
eval "$(sed -n '/^repair_check_rows() {/,/^}/p' "$d/merge-lane.sh")"
HERE=$(cd "$d/.." && pwd); jqf() { jq "$@"; }; tick_pr_check_census() { return 1; }
cat > "$t/gh" <<'STUB'
#!/usr/bin/env bash
[[ -n ${ROWS-} ]] && printf '%s\n' "$ROWS"; exit 8
STUB
chmod +x "$t/gh"; export PATH="$t:$PATH"
out=$(ROWS='[{"name":"Test suite","bucket":"fail","link":"https://example.invalid/actions/runs/1/job/42"}]' repair_check_rows 7) || true
grep -q 'Test suite' <<<"$out" || { echo "FAIL: failed-check rows dropped: $out"; exit 1; }
if ROWS='' repair_check_rows 7 >/dev/null; then echo 'FAIL: empty gh output must fail'; exit 1; fi
echo ok
