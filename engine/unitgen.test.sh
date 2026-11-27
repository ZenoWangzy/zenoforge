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

# A service without ExecStart is one clear error through the plist path: rc 2, no plist for it.
cat > "$tmp/no-exec.timer" <<'UNIT'
[Timer]
OnCalendar=*-*-* 01:00:00 UTC
UNIT
cat > "$tmp/no-exec.service" <<'UNIT'
[Service]
Environment=PATH=/usr/bin:/bin
UNIT
plist_bad="$tmp/plist-bad"
if output="$(HOME=/home/zf-golden TZ=CST-8 python3 "$dir/unitgen.py" plist --dir "$plist_bad" "$tmp/no-exec.timer" 2>&1)"; then
  echo "FAIL: missing ExecStart passed plist" >&2
  exit 1
else
  rc=$?
fi
[[ $rc == 2 ]] || { echo "FAIL: expected rc 2, got $rc: $output" >&2; exit 1; }
grep -Fq "no ExecStart in $tmp/no-exec.service" <<< "$output"
[[ ! -e "$plist_bad/zenoforge.no-exec.plist" ]] || { echo "FAIL: plist written for unit without ExecStart" >&2; exit 1; }

loop_dir="$tmp/loop"
mkdir -p "$loop_dir" "$tmp/bin"
clock_file="$tmp/clock"
events="$tmp/events"
timeout_log="$tmp/timeout.log"
start="$(python3 -c 'from datetime import datetime, timezone; print(int(datetime(2025, 1, 1, 23, 59, 59, tzinfo=timezone.utc).timestamp()))')"
printf 'TEST_VALUE=from-file\nFILE_VALUE=loaded\n' > "$loop_dir/env"
cat > "$tmp/bin/timeout" <<'TIMEOUT'
#!/usr/bin/env bash
printf '%s %s %s\n' "$1" "$2" "$3" >> "$TIMEOUT_LOG"
shift 3
exec "$@"
TIMEOUT
chmod +x "$tmp/bin/timeout"

make_record_service() {
  local name="$1" duration="$2"
  cat > "$loop_dir/$name.service" <<UNIT
[Service]
Environment=TEST_VALUE=from-unit
EnvironmentFile=$loop_dir/env
WorkingDirectory=$loop_dir
TimeoutStartSec=10s
ExecStart=/bin/sh -c 'printf "%s|%s|%s\\n" "\$TEST_VALUE" "\$FILE_VALUE" "\$1" >> "\$TEST_LOG"; exec sleep $duration' zf $name
UNIT
}

make_record_service calendar 0.02
make_record_service once 0.02
make_record_service repeat 0.02
make_record_service busy 0.5
cat > "$loop_dir/calendar.timer" <<'UNIT'
[Timer]
OnCalendar=*-*-* 00:00:00 UTC
UNIT
cat > "$loop_dir/once.timer" <<'UNIT'
[Timer]
OnActiveSec=2s
UNIT
cat > "$loop_dir/repeat.timer" <<'UNIT'
[Timer]
OnUnitActiveSec=3s
UNIT
cat > "$loop_dir/busy.timer" <<'UNIT'
[Timer]
OnUnitActiveSec=1s
UNIT

set_clock() {
  printf '%s\n' "$1" > "$clock_file.next"
  mv "$clock_file.next" "$clock_file"
}
wait_for_count() {
  local wanted="$1" deadline=$((SECONDS + 5)) count
  while (( SECONDS < deadline )); do
    if [[ -f "$events" ]]; then count="$(wc -l < "$events" | tr -d '[:space:]')"; else count=0; fi
    (( count >= wanted )) && return 0
    sleep 0.01
  done
  cat "$tmp/loop.out" >&2
  echo "FAIL: expected $wanted unit starts, got ${count:-0}" >&2
  exit 1
}

set_clock "$start"
PATH="$tmp/bin:$PATH" TEST_LOG="$events" TIMEOUT_LOG="$timeout_log" \
  python3 "$dir/unitgen.py" loop "$loop_dir" --clock-file "$clock_file" \
    --stop-at "$((start + 7))" --poll-interval 0.01 > "$tmp/loop.out" 2>&1 &
loop_pid=$!
cleanup_loop() {
  if kill -0 "$loop_pid" 2>/dev/null; then
    set_clock "$((start + 7))"
    wait "$loop_pid" || true
  fi
}
trap cleanup_loop EXIT
deadline=$((SECONDS + 5))
while ! grep -Fq 'unitgen loop started' "$tmp/loop.out" 2>/dev/null; do
  (( SECONDS < deadline )) || { cat "$tmp/loop.out" >&2; echo 'FAIL: unit loop did not start' >&2; exit 1; }
  sleep 0.01
done
set_clock "$((start + 1))"
wait_for_count 2
set_clock "$((start + 2))"
wait_for_count 3
sleep 0.6
set_clock "$((start + 3))"
wait_for_count 5
sleep 0.6
set_clock "$((start + 6))"
wait_for_count 7
set_clock "$((start + 7))"
wait "$loop_pid"
trap - EXIT
grep -Fxq 'from-file|loaded|calendar' "$events"
grep -Fxq 'from-file|loaded|once' "$events"
grep -Fxq 'from-file|loaded|repeat' "$events"
[[ "$(grep -Fc '|busy' "$events")" == 3 ]] || { echo 'FAIL: unit loop did not resume after the active process finished' >&2; exit 1; }
grep -Fq "unitgen loop starting calendar at $((start + 1))" "$tmp/loop.out"
grep -Fq "unitgen loop starting once at $((start + 2))" "$tmp/loop.out"
grep -Fq "unitgen loop starting repeat at $((start + 3))" "$tmp/loop.out"
grep -Fq "unitgen loop starting repeat at $((start + 6))" "$tmp/loop.out"
grep -Fq "unitgen loop skipped active busy at $((start + 2))" "$tmp/loop.out"
! grep -Fq "unitgen loop starting busy at $((start + 2))" "$tmp/loop.out"
[[ "$(wc -l < "$timeout_log" | tr -d '[:space:]')" == 7 ]] || { echo 'FAIL: timeout wrapper did not receive every launch' >&2; exit 1; }
grep -Fxq -- '-k 30 10' "$timeout_log"

live="$tmp/supervisor/autopi-live"
systemd_out="$tmp/install-systemd"
launchagents_out="$tmp/install-launchd"
loop_out="$tmp/install-loop"
if ZF_TIMERS=loop python3 "$dir/unitgen.py" install --live "$live" \
  --systemd-unit-dir "$loop_out/systemd" --launchagents-dir "$loop_out/launchagents"; then
  [[ ! -e "$loop_out/systemd" && ! -e "$loop_out/launchagents" ]] || { echo 'FAIL: loop install wrote host units' >&2; exit 1; }
else
  echo 'FAIL: loop install failed' >&2
  exit 1
fi
ZF_TIMERS=systemd python3 "$dir/unitgen.py" install --live "$live" --systemd-unit-dir "$systemd_out"
grep -Fxq "ExecStart=$live/loop.sh" "$systemd_out/zenoforge-autopilot-scheduler.service"
grep -Fxq "ExecStart=$live/bell-loop.sh" "$systemd_out/zenoforge-autopilot-bell.service"
! grep -Fq '@LIVE@' "$systemd_out/zenoforge-autopilot-scheduler.service"
! grep -Fq '@LIVE@' "$systemd_out/zenoforge-autopilot-bell.service"
[[ -z "$(find "$dir/systemd" -maxdepth 1 -type f -name '*.service.in' -print -quit)" ]] || { echo 'FAIL: templates entered the run-tick service glob' >&2; exit 1; }

cat > "$tmp/bin/launchctl" <<'LAUNCHCTL'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LAUNCHCTL_LOG"
LAUNCHCTL
chmod +x "$tmp/bin/launchctl"
PATH="$tmp/bin:$PATH" LAUNCHCTL_LOG="$tmp/launchctl.log" ZF_TIMERS=launchd \
  python3 "$dir/unitgen.py" install --live "$live" --launchagents-dir "$launchagents_out"
python3 - "$launchagents_out" "$live" <<'PY'
import plistlib
import sys
from pathlib import Path

directory = Path(sys.argv[1])
live = sys.argv[2]
for name, script in (
    ("zenoforge.zenoforge-autopilot-scheduler.plist", "loop.sh"),
    ("zenoforge.zenoforge-autopilot-bell.plist", "bell-loop.sh"),
):
    with (directory / name).open("rb") as source:
        plist = plistlib.load(source)
    assert plist["ProgramArguments"] == [f"{live}/{script}"]
    assert plist["KeepAlive"] is True
PY
PATH="$tmp/bin:$PATH" LAUNCHCTL_LOG="$tmp/launchctl.log" ZF_TIMERS=launchd \
  python3 "$dir/unitgen.py" install --live "$live" --launchagents-dir "$launchagents_out"
PATH="$tmp/bin:$PATH" LAUNCHCTL_LOG="$tmp/launchctl.log" ZF_TIMERS=launchd \
  python3 "$dir/unitgen.py" load --launchagents-dir "$launchagents_out"
python3 - "$tmp/launchctl.log" <<'PY'
import sys
from pathlib import Path

calls = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
assert len(calls) == 4
assert all(calls[index].startswith("bootout gui/") for index in (0, 2))
assert all(calls[index].startswith("bootstrap gui/") for index in (1, 3))
assert calls[0].removeprefix("bootout ") == calls[1].removeprefix("bootstrap ")
assert calls[2].removeprefix("bootout ") == calls[3].removeprefix("bootstrap ")
PY
PATH="$tmp/bin:$PATH" LAUNCHCTL_LOG="$tmp/launchctl.log" ZF_TIMERS=launchd \
  python3 "$dir/unitgen.py" load --launchagents-dir "$launchagents_out"
[[ "$(wc -l < "$tmp/launchctl.log" | tr -d '[:space:]')" == 4 ]] || { echo 'FAIL: unchanged units were loaded again' >&2; exit 1; }

if [[ "$(uname -s)" == Darwin ]]; then
  smoke_dir="$tmp/launchd-smoke"
  smoke_plists="$tmp/launchd-smoke-plists"
  touch_target="$tmp/launchd-touched"
  mkdir -p "$smoke_dir"
  cat > "$smoke_dir/touch-on-load.timer" <<'UNIT'
[Timer]
OnActiveSec=1s
UNIT
  cat > "$smoke_dir/touch-on-load.service" <<UNIT
[Service]
ExecStart=/usr/bin/touch $touch_target
UNIT
  HOME="$tmp" python3 "$dir/unitgen.py" plist --dir "$smoke_plists" "$smoke_dir"
  smoke_plist="$smoke_plists/zenoforge.touch-on-load.plist"
  smoke_domain="gui/$(id -u)"
  launchctl bootstrap "$smoke_domain" "$smoke_plist"
  launchd_smoke_cleanup() { launchctl bootout "$smoke_domain" "$smoke_plist" >/dev/null 2>&1 || true; }
  trap launchd_smoke_cleanup EXIT
  deadline=$((SECONDS + 10))
  while [[ ! -e "$touch_target" ]]; do
    (( SECONDS < deadline )) || { echo 'FAIL: launchd agent did not touch its file' >&2; exit 1; }
    sleep 0.1
  done
  launchd_smoke_cleanup
  trap - EXIT
fi
echo "PASS unitgen"
