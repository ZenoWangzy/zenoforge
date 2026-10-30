#!/usr/bin/env python3
"""Run the real timer repair block against an isolated fake user manager."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SOURCE = Path(os.environ.get('RUN_TICK_SOURCE', str(Path(__file__).with_name('run-tick.sh'))))


class TimerRepair(unittest.TestCase):
    def repair(self, agent, maintenance='disabled', off='observe', inactive=True):
        source = SOURCE.read_text()
        start = source.index('  if [ ! -r "$timer_list" ]; then')
        end = source.index('  done <"$timer_list"', start) + len('  done <"$timer_list"')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root/'timers').write_text(
                'zenoforge-agent.timer - agent-alert\n'
                'zenoforge-maintenance.timer CONTROL maintenance-alert\n'
            )
            script = '''set -euo pipefail
declare -A active=()
systemctl() {
  local timer="${!#}" state=disabled
  case "$timer" in
    zenoforge-agent.timer) state="$AGENT_STATE" ;;
    zenoforge-maintenance.timer) state="$MAINTENANCE_STATE" ;;
  esac
  case " $* " in
    *" is-enabled "*)
      [[ " $* " == *" --quiet "* ]] || printf '%s\\n' "$state"
      [[ "$state" == enabled ]] ;;
    *" is-active "*) [[ "$INACTIVE" == 0 || "${active[$timer]:-0}" == 1 ]] ;;
    *" enable --now "*|*" start "*) printf '%s\\n' "$*" >> "$CALLS"; active[$timer]=1 ;;
    *) return 2 ;;
  esac
}
timeout() { shift; "$@"; }
gh() { printf '%s' "$OFF_MODE"; }
refuse() { exit 99; }
append_supervisor_event() { printf 'alert\\n' >> "$CALLS"; }
timer_list="$ROOT/timers"; AGENT_HOME="$ROOT"; UNIT_PREFIX=zenoforge; timer_gh_timeout_sec=1; timer_repo=test/repo
run() {
''' + source[start:end] + '\n}\nrun\n'
            env = {
                **os.environ,
                'ROOT': str(root),
                'CALLS': str(root/'calls'),
                'AGENT_STATE': agent,
                'MAINTENANCE_STATE': maintenance,
                'OFF_MODE': off,
                'INACTIVE': str(int(inactive)),
            }
            subprocess.run(['bash', '-c', script], env=env, capture_output=True, text=True, timeout=5, check=True)
            return (root/'calls').read_text().splitlines() if (root/'calls').exists() else []

    def test_disabled_dependencies_are_enabled(self):
        self.assertEqual(self.repair('disabled'), [
            '--user enable --now zenoforge-agent.timer',
            '--user enable --now zenoforge-maintenance.timer',
        ])

    def test_enabled_inactive_dependencies_are_started(self):
        self.assertEqual(self.repair('enabled', 'enabled'), [
            '--user start zenoforge-agent.timer',
            '--user start zenoforge-maintenance.timer',
        ])

    def test_explicit_dependency_off_is_preserved(self):
        self.assertEqual(self.repair('disabled', 'disabled', off='off'), [
            '--user enable --now zenoforge-agent.timer',
        ])


if __name__ == '__main__':
    unittest.main()
