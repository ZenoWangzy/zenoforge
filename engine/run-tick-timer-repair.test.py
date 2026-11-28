#!/usr/bin/env python3
"""Run the real timer repair block against an isolated fake user manager."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SOURCE = Path(os.environ.get('RUN_TICK_SOURCE', str(Path(__file__).with_name('run-tick.sh'))))


class TimerRepair(unittest.TestCase):
    def repair(self, agent, maintenance='disabled', off='observe', inactive=True, pause=None, local_timer=False, coordination='on'):
        source = SOURCE.read_text()
        start = source.index('  if [ ! -r "$timer_list" ]; then')
        end_marker = '  done < <(cat "$timer_list" "$local_timer_list" 2>/dev/null || true)'
        end = source.index(end_marker, start) + len(end_marker)
        pause_line = '  local PAUSE_FILE="$AGENT_HOME/PAUSE"\n'
        assert pause_line in source
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root/'timers').write_text(
                'zenoforge-agent.timer - agent-alert\n'
                'zenoforge-maintenance.timer CONTROL maintenance-alert\n'
            )
            if pause is not None:
                (root/'PAUSE').write_text(pause)
            if local_timer:
                (root/'timers.local.list').write_text('zenoforge-renewd.timer - renewd-alert\n')
            script = '''set -euo pipefail
declare -A active=()
systemctl() {
  local timer="${!#}" state=disabled
  case "$timer" in
    zenoforge-agent.timer) state="$AGENT_STATE" ;;
    zenoforge-maintenance.timer) state="$MAINTENANCE_STATE" ;;
    zenoforge-renewd.timer) state="$RENEWD_STATE" ;;
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
gh_timeout() { local timeout_value="$1"; shift; timeout "$timeout_value" gh "$@"; }
gh() { printf '%s' "$OFF_MODE"; }
refuse() { exit 99; }
append_supervisor_event() { printf 'alert\\n' >> "$CALLS"; }
timer_list="$ROOT/timers"; AGENT_HOME="$ROOT"; local_timer_list="$AGENT_HOME/timers.local.list"; ZF_COORD="$COORDINATION"; UNIT_PREFIX=zenoforge; timer_gh_timeout_sec=1; timer_repo=test/repo
run() {
''' + pause_line + source[start:end] + '\n}\nrun\n'
            env = {
                **os.environ,
                'ROOT': str(root),
                'CALLS': str(root/'calls'),
                'AGENT_STATE': agent,
                'MAINTENANCE_STATE': maintenance,
                'RENEWD_STATE': 'disabled',
                'OFF_MODE': off,
                'INACTIVE': str(int(inactive)),
                'COORDINATION': coordination,
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

    def test_pause_resume_naming_a_timer_leaves_it_stopped(self):
        pause = json.dumps({'resume': 'rm PAUSE; systemctl --user start zenoforge-agent.timer other.timer'})
        self.assertEqual(self.repair('enabled', 'enabled', pause=pause), [
            '--user start zenoforge-maintenance.timer',
        ])

    def test_pause_resume_not_naming_a_timer_repairs_it(self):
        pause = json.dumps({'resume': 'systemctl --user start zenoforge-agent.timer.bak other.timer'})
        self.assertEqual(self.repair('enabled', 'enabled', pause=pause), [
            '--user start zenoforge-agent.timer',
            '--user start zenoforge-maintenance.timer',
        ])

    def test_plain_text_pause_does_not_stop_repair(self):
        self.assertEqual(self.repair('enabled', 'enabled', pause='zenoforge-agent.timer'), [
            '--user start zenoforge-agent.timer',
            '--user start zenoforge-maintenance.timer',
        ])

    def test_local_coordination_timer_is_repaired_only_when_listed(self):
        expected = [
            '--user start zenoforge-agent.timer',
            '--user start zenoforge-maintenance.timer',
        ]
        self.assertEqual(self.repair('enabled', 'enabled'), expected)
        self.assertEqual(self.repair('enabled', 'enabled', local_timer=True), [
            *expected,
            '--user enable --now zenoforge-renewd.timer',
        ])

    def test_local_coordination_timer_is_not_repaired_when_coordination_is_off(self):
        self.assertEqual(self.repair('enabled', 'enabled', local_timer=True, coordination='off'), [
            '--user start zenoforge-agent.timer',
            '--user start zenoforge-maintenance.timer',
        ])


if __name__ == '__main__':
    unittest.main()
