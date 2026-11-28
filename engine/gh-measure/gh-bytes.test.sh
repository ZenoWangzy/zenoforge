#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
t="$(mktemp -d)"
trap 'rm -rf -- "$t" "$test_env_root"' EXIT

cat > "$t/calls.tsv" <<'EOF'
2026-11-28T09:00:00Z	u	worker.sh	api	repos/o/r/issues/N/comments	0	5	other	miss	200
2026-11-28T09:05:00Z	u	worker.sh	api	repos/o/r/pulls/N	0	5	other	miss	300
2026-11-28T09:10:00Z	u	worker.sh	api	repos/o/r/issues/N/comments	0	5	other	hit	50
2026-11-27T09:00:00Z	u	worker.sh	api	repos/o/r/issues/N/comments	0	5	other	miss	999
EOF

actual="$(python3 "$dir/summary.py" "$t/calls.tsv" --bytes-by-endpoint --day 2026-11-28)"
expected=$'endpoint\tcalls\tmiss_bytes\thit_bytes\nrepos/o/r/pulls/N\t1\t300\t0\nrepos/o/r/issues/N/comments\t2\t200\t50'
if [[ "$actual" != "$expected" ]]; then
  printf 'expected:\n%s\nactual:\n%s\n' "$expected" "$actual" >&2
  exit 1
fi
echo 'gh-bytes.test.sh: PASS'
