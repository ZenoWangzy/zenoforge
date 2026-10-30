#!/usr/bin/env python3
"""Exercise the real dispatch PID loop against guardian/CLI snapshots."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = Path(os.environ.get("DISPATCH_SOURCE", str(Path(__file__).with_name("dispatch.sh"))))


class ZcodePid(unittest.TestCase):
    def select(self, rows, worktree="/fixture/work", name="fixture"):
        source = SOURCE.read_text()
        start = source.index('  for _ in $(seq 1 "${ZF_ZCODE_PID_WAIT_SECONDS:-20}"); do')
        end = source.index('\n  done', start) + len('\n  done')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for pid in (100, 200):
                (root / str(pid)).mkdir()
                (root / str(pid) / "environ").write_bytes(
                    f"ZF_REPO_DIR={worktree}\0ZF_AGENT_NAME={name}\0".encode())
            body = source[start:end].replace('/proc/', str(root) + '/')
            script = '''set -euo pipefail
WT=/fixture/work; NAME=fixture; WORKTREE_ROOT=/fixture; pid=""
ZF_ZCODE_PID_WAIT_SECONDS=1
ps() { printf '%s\\n' "$ROWS"; }
hand_zcode_agents() { printf '100\\tfixture\\n'; }
sleep() { :; }
''' + body + '\nprintf "%s" "$pid"\n'
            result = subprocess.run(['bash', '-c', script], env={**os.environ, 'ROWS': rows},
                                    text=True, capture_output=True, timeout=5, check=True)
            return result.stdout

    def test_original_cli_argv_rejects_embedded_guardian_command(self):
        rows = '100 python3 execution-admission.py run -- zcode -p prompt --cwd /fixture/work\n200 /bin/zcode -p prompt --cwd /fixture/work'
        self.assertEqual(self.select(rows), '200')

    def test_retitled_cli_is_selected_before_environment_deduplication(self):
        rows = '100 python3 execution-admission.py run -- zcode -p prompt --cwd /fixture/work\n200 zcode-cli'
        self.assertEqual(self.select(rows), '200')

    def test_guardian_without_cli_cannot_own_roster(self):
        self.assertEqual(self.select('100 python3 execution-admission.py run -- zcode -p prompt --cwd /fixture/work'), '')

    def test_node_cli_script_before_retitle(self):
        rows = '100 python3 execution-admission.py run -- node /lib/zcode/cli.bundle.cjs -p prompt --cwd /fixture/work\n200 /bin/node /lib/zcode/cli.bundle.cjs -p prompt --cwd /fixture/work'
        self.assertEqual(self.select(rows), '200')

    def test_retitled_cli_requires_worktree_and_name(self):
        self.assertEqual(self.select('200 zcode-cli', worktree='/fixture/other'), '')
        self.assertEqual(self.select('200 zcode-cli', name='other'), '')


class LauncherExit(unittest.TestCase):
    def missing_pid(self, status, provider='codex', error='none', running=False):
        source = SOURCE.read_text()
        start = source.index('\nif [ -z "$pid" ]; then', source.index('sleep 2'))
        end = source.index('\n[[ "$pid" =~', start)
        budget_trap = next(line.strip() for line in source.splitlines()
                           if line.strip().startswith("trap 'if [ \"$HAND_BUDGET_HANDED_OFF\""))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = r'''set -euo pipefail
pid=""; NAME=fixture; WT=/fixture; LOG="$FIXTURE_ROOT/log"
HAND_BUDGET_ID=fixture; HAND_BUDGET_HANDED_OFF=0
BRIEF=brief; ROLE=work; REPORT=report; ATTEMPT=0; PROVIDER_RETRY=0; PROVIDER_EPISODE=episode
HAND_WORKTREE_RECORDS=""; REPO_DIR=/fixture
codex_budget_release() { echo released >> "$FIXTURE_ROOT/released"; }
codex_config_parse_error() { [ "$ERROR" = config ]; }
codex_config_error_detail() { echo fixture-config; }
record_codex_config_fault() { :; }
model_call_missing_agent_binary() { [ "$ERROR" = binary ]; }
record_codex_runtime_fault() { :; }
codex_session_error_kind() { if [ "$ERROR" = provider ]; then echo provider-kind; fi; }
codex_session_error_output() { cat "$LOG"; }
hand_provider_recover() { echo recovered; return 73; }
# Deceptive admission text must never turn a genuine exit1 into75.
echo 'execution admission deferred: global execution cap: active=10 cap=10' > "$LOG"
if [ "$RUNNING" = 1 ]; then /bin/sleep .3 &
else (exit "$CHILD_STATUS") &
fi
launcher_pid=$!
/bin/sleep .05
''' + budget_trap + source[start:end]
            result = subprocess.run(['bash', '-c', script], env={**os.environ,
                'FIXTURE_ROOT': str(root), 'PROVIDER': provider, 'CHILD_STATUS': str(status),
                'ERROR': error, 'RUNNING': str(int(running))}, text=True, capture_output=True, timeout=4)
            self.assertEqual((root / 'released').read_text().strip(), 'released')
            return result

    def test_guard75_propagates_for_both_providers(self):
        for provider in ('codex', 'zcode'):
            with self.subTest(provider=provider):
                result = self.missing_pid(75, provider)
                self.assertEqual(result.returncode, 75, result.stderr)
                self.assertNotIn('active=10', result.stderr)

    def test_genuine1_is_not_log_classified_as75(self):
        self.assertEqual(self.missing_pid(1).returncode, 1)

    def test_live_launcher_timeout_stays1(self):
        self.assertEqual(self.missing_pid(75, running=True).returncode, 1)

    def test_specific_fault_and_provider_recovery_keep_precedence(self):
        for error, expected in [('config', 1), ('binary', 1), ('provider', 73)]:
            with self.subTest(error=error):
                self.assertEqual(self.missing_pid(75, error=error).returncode, expected)


if __name__ == '__main__':
    unittest.main()
