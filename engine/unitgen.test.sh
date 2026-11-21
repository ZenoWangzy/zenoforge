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

# plist: goldens are rendered with a fixed HOME and a fixed UTC+8 zone (POSIX TZ, no tzdata needed).
render_plists() { HOME=/home/zf-golden TZ=CST-8 python3 "$dir/unitgen.py" plist --dir "$1"; }
golden="$dir/unitgen.golden"
plist_out="$tmp/plist"
render_plists "$plist_out"
[[ "$(ls "$golden" | wc -l)" == "$(ls "$dir"/systemd/*.timer | wc -l)" ]] || { echo "FAIL: golden count differs from timers" >&2; exit 1; }
for want in "$golden"/*.plist; do
  got="$plist_out/$(basename "$want")"
  if ! cmp -s "$want" "$got"; then
    diff -u "$want" "$got" >&2 || true
    echo "FAIL: $(basename "$want") differs from golden" >&2
    exit 1
  fi
done
[[ "$(ls "$plist_out" | wc -l)" == "$(ls "$golden" | wc -l)" ]] || { echo "FAIL: extra plist written" >&2; exit 1; }
# 01:00 UTC is 09:00 at UTC+8; the UTC OnCalendar case must shift.
grep -Fq '<integer>9</integer>' "$plist_out/zenoforge.zenoforge-daily-perf-report.plist"

# Unchanged input writes nothing: an old mtime survives a second run.
stamp="$plist_out/zenoforge.zenoforge-supervisor.plist"
touch -d '2001-01-01 00:00:00 UTC' "$stamp"
render_plists "$plist_out"
[[ "$(stat -c %Y "$stamp")" == 978307200 ]] || { echo "FAIL: unchanged plist was rewritten" >&2; exit 1; }
echo "PASS unitgen"
