#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d "$test_env_root/unitgen.XXXXXX")"

cat > "$tmp/unknown.service" <<'UNIT'
[Unit]
Description=parser fixture
UnknownDirective=yes
UNIT

parsed="$(python3 "$dir/unitgen.py" parse "$tmp/unknown.service")"
grep -Fq '"key": "UnknownDirective"' <<< "$parsed"
grep -Fq '"line": 3' <<< "$parsed"
if output="$(python3 "$dir/unitgen.py" check "$tmp/unknown.service" 2>&1)"; then
  echo "FAIL: unknown directive passed check" >&2
  exit 1
else
  rc=$?
fi
[[ $rc == 1 ]] || { echo "FAIL: expected rc 1, got $rc: $output" >&2; exit 1; }
grep -Fq "$tmp/unknown.service:3: unknown directive UnknownDirective" <<< "$output"
python3 "$dir/unitgen.py" check "$dir/systemd/"
echo "PASS unitgen"
