#!/usr/bin/env python3
"""Small local fixtures: real flock/PID identity; no model, systemd, or network."""
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("admission", ROOT / "execution-admission.py")
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class ExecutionAdmission(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.home = Path(self.directory.name)
        self.env = dict(os.environ, AGENT_HOME=str(self.home))
        self.env.pop("ZF_EXECUTION_SLOT", None)
        self.env.pop("ZF_EXECUTION_PROC_ROOT", None)
        self.env.pop("LUNA_PRIORITY", None)
        self.env.pop("AGENT_EXECUTION_CPU_TARGET_PERCENT", None)
        self.children = []
        self.driver = self.home / "driver.py"
        self.driver.write_text(
            "import importlib.util,sys\n"
            f"s=importlib.util.spec_from_file_location('guard',{str(ROOT / 'execution-admission.py')!r})\n"
            "g=importlib.util.module_from_spec(s);s.loader.exec_module(g)\n"
            "g.occupied=lambda proc:set()\n"
            "g.resources=lambda *args:{'available_mb':9999999,'load1':0.0}\n"
            "try:sys.exit(g.admission(sys.argv[1],sys.argv[3:] if sys.argv[2:3]==['--'] else sys.argv[2:]))\n"
            "except (g.Deferred,OSError,ValueError,KeyError,StopIteration):sys.exit(75)\n"
        )
        self.capacity(8)

    def tearDown(self):
        for child in self.children:
            if child.poll() is None:
                child.terminate()
                child.wait(timeout=5)
        self.directory.cleanup()

    def capacity(self, value):
        (self.home / "capacity.env").write_text(f"AGENT_GLOBAL_EXECUTION_CAP={value}\n")

    def run_guard(self, mode, *command):
        return subprocess.run([sys.executable, str(self.driver), mode, *command], env=self.env, capture_output=True, text=True)

    def pause(self):
        (self.home / "PAUSE").write_text(json.dumps({"caller": "operator", "reason": "host pressure", "issue": "3765", "provider": "all", "model": "all", "timestamp": "2026-10-14T08:15:00Z"}))

    def test_cpu_counter_window_overrides_load_only_when_fresh(self):
        proc = self.home / "cpu-proc"
        (proc / "sys/kernel/random").mkdir(parents=True)
        (proc / "sys/kernel/random/boot_id").write_text("boot-a")
        (proc / "stat").write_text("cpu 100 0 0 100 0 0 0 0 99 0\ncpu0 1\n")
        (proc / "meminfo").write_text("MemAvailable: 9999999 kB\n")
        (proc / "loadavg").write_text("40 0 0 1/2 3\n")
        with patch.object(guard.time, "monotonic", return_value=100):
            first = guard.cpu_sample(self.home, proc)
        self.assertEqual(first["cpu_state"], "UNKNOWN")
        with self.assertRaises(guard.Deferred):
            guard.resources(proc, 6144, 12, first, 90)
        (proc / "stat").write_text("cpu 120 0 0 180 0 0 0 0 119 0\ncpu0 1\n")
        with patch.object(guard.time, "monotonic", return_value=105):
            sample = guard.cpu_sample(self.home, proc)
            approved = guard.resources(proc, 6144, 12, sample, 90)
        self.assertEqual(sample["cpu_percent"], 20)
        self.assertEqual(approved["cpu_decision"], "below-target")
        with patch.object(guard.time, "monotonic", return_value=121):
            stale = guard.cpu_sample(self.home, proc)
        self.assertEqual(stale["cpu_state"], "UNKNOWN")
        with self.assertRaises(guard.Deferred):
            guard.resources(proc, 6144, 12, stale, 90)

    def test_cpu_threshold_memory_and_wait_are_not_idle(self):
        proc = self.home / "cpu-resources"
        proc.mkdir()
        (proc / "meminfo").write_text("MemAvailable: 9999999 kB\n")
        (proc / "loadavg").write_text("40 0 0 1/2 3\n")
        with patch.object(guard.time, "monotonic", return_value=105):
            for percent, decision in ((89.99, "below-target"), (90, "hold"), (95, "hold"), (95.01, "overload")):
                cpu = dict(cpu_state="FRESH", cpu_percent=percent, cpu_sampled_monotonic=105)
                if percent < 90:
                    self.assertEqual(guard.resources(proc, 6144, 12, cpu, 90)["cpu_decision"], decision)
                else:
                    with self.assertRaises(guard.Deferred) as error:
                        guard.resources(proc, 6144, 12, cpu, 90)
                    self.assertEqual(error.exception.metrics["cpu_decision"], decision)
            (proc / "meminfo").write_text("MemAvailable: 1024 kB\n")
            with self.assertRaises(guard.Deferred):
                guard.resources(proc, 6144, 12, dict(cpu_state="FRESH", cpu_percent=1, cpu_sampled_monotonic=105), 90)

    def test_cpu_reset_boot_and_short_calls_cannot_renew_sample(self):
        proc = self.home / "cpu-proc"
        (proc / "sys/kernel/random").mkdir(parents=True)
        boot = proc / "sys/kernel/random/boot_id"
        boot.write_text("boot-a")
        def sample(now, counters):
            (proc / "stat").write_text("cpu " + counters + "\ncpu0 1\n")
            with patch.object(guard.time, "monotonic", return_value=now):
                return guard.cpu_sample(self.home, proc)
        self.assertEqual(sample(100, "100 0 0 100 0 0 0 0")["cpu_state"], "UNKNOWN")
        state = sample(105, "105 0 0 110 80 0 0 5 999 0")
        self.assertEqual(state["cpu_percent"], 5)
        self.assertEqual(state["cpu_iowait_percent"], 80)
        self.assertEqual(state["cpu_steal_percent"], 5)
        self.assertEqual(sample(106, "106 0 0 111 80 0 0 5"), state)
        self.assertEqual(sample(110, "1 0 0 1 0 0 0 0")["cpu_state"], "UNKNOWN")
        self.assertEqual(sample(115, "1 0 0 1 0 0 0 0")["cpu_state"], "UNKNOWN")
        boot.write_text("boot-b")
        self.assertEqual(sample(120, "2 0 0 9 0 0 0 0")["cpu_state"], "UNKNOWN")
        self.assertEqual(sample(119, "3 0 0 10 0 0 0 0")["cpu_state"], "UNKNOWN")
        (proc / "stat").unlink()
        with patch.object(guard.time, "monotonic", return_value=124):
            self.assertEqual(guard.cpu_sample(self.home, proc)["cpu_state"], "UNKNOWN")

    def test_cpu_configuration_is_opt_in_and_validated(self):
        with patch.dict(os.environ, clear=True):
            self.assertIsNone(guard.configuration(self.home)[3])
            for value in ("nan", "inf", "0", "96", "invalid"):
                (self.home / "capacity.env").write_text("AGENT_EXECUTION_CPU_TARGET_PERCENT=" + value)
                with self.assertRaises(guard.Deferred):
                    guard.configuration(self.home)
            (self.home / "capacity.env").write_text("AGENT_EXECUTION_CPU_TARGET_PERCENT=90")
            self.assertEqual(guard.configuration(self.home)[3], 90)

    def test_cpu_start_interval_shared_check_readonly_and_inherited_reuse(self):
        (self.home / "capacity.env").write_text("AGENT_GLOBAL_EXECUTION_CAP=16\nAGENT_EXECUTION_CPU_TARGET_PERCENT=90\n")
        # Existing fixture removes ambient load/census; real locks and lease inheritance remain.
        self.assertEqual(self.run_guard("check").returncode, 0)
        self.assertEqual(self.run_guard("check").returncode, 0)
        start = self.home / "locks/execution-cpu-start.json"
        self.assertFalse(start.exists(), "read-only checks cannot consume a start")
        release = self.home / "cpu-release"
        ready = self.home / "cpu-started"
        code = f"from pathlib import Path;import time;Path({str(ready)!r}).touch();r=Path({str(release)!r});\nwhile not r.exists():time.sleep(.01)"
        children = [subprocess.Popen([sys.executable, str(self.driver), "run", sys.executable, "-c", code], env=self.env) for _ in range(2)]
        self.children.extend(children)
        deadline = time.monotonic() + 5
        while not ready.exists() or not any(child.poll() is not None for child in children):
            self.assertLess(time.monotonic(), deadline)
            time.sleep(.01)
        self.assertEqual(sorted(child.returncode for child in children if child.poll() is not None), [75])
        self.assertEqual(self.run_guard("check").returncode, 75)
        state = json.loads((self.home / "locks/execution-cpu.json").read_text())
        self.assertEqual(state["cpu_state"], "UNKNOWN", "a start primes a post-start window")
        release.touch()
        self.assertEqual(sorted(child.wait(timeout=5) for child in children), [0, 75])
        record = json.loads(start.read_text())
        record["monotonic"] -= 5
        start.write_text(json.dumps(record))
        code = f"import subprocess,sys;assert subprocess.call([sys.executable,{str(self.driver)!r},'check'])==75;sys.exit(subprocess.call([sys.executable,{str(self.driver)!r},'run','sh','-c','exit 23']))"
        self.assertEqual(self.run_guard("run", sys.executable, "-c", code).returncode, 23,
                         "inherited work reuses the actual lease without a second CPU token")

    def test_cpu_interval_survives_stat_failure_and_recovery(self):
        (self.home / "capacity.env").write_text("AGENT_GLOBAL_EXECUTION_CAP=16\nAGENT_EXECUTION_CPU_TARGET_PERCENT=90\n")
        # Only the optional CPU stat read fails; boot identity and actual leases remain real.
        source = self.driver.read_text()
        self.driver.write_text(source.replace("try:sys.exit", """from pathlib import Path
import os
read=Path.read_text
def fixture_read(path,*args,**kwargs):
 if path==Path('/proc/stat') and os.environ.get('FIXTURE_STAT_FAILURE')=='1':raise FileNotFoundError('fixture stat')
 return read(path,*args,**kwargs)
Path.read_text=fixture_read
try:sys.exit"""))
        start = self.home / "locks/execution-cpu-start.json"
        for initially_unknown in (False, True):
            with self.subTest(initially_unknown=initially_unknown):
                start.unlink(missing_ok=True)
                self.env["FIXTURE_STAT_FAILURE"] = "1" if initially_unknown else "0"
                self.assertEqual(self.run_guard("run", "true").returncode, 0)
                record = json.loads(start.read_text())
                self.assertEqual(record["boot_id"], Path('/proc/sys/kernel/random/boot_id').read_text().strip())
                self.env["FIXTURE_STAT_FAILURE"] = "1"
                self.assertEqual(self.run_guard("run", "true").returncode, 75)
                self.env["FIXTURE_STAT_FAILURE"] = "0"
                self.assertEqual(self.run_guard("run", "true").returncode, 75)
                self.assertEqual(json.loads(start.read_text()), record)

    def test_cpu_interval_missing_corrupt_permission_and_real_boot_change(self):
        (self.home / "capacity.env").write_text("AGENT_GLOBAL_EXECUTION_CAP=16\nAGENT_EXECUTION_CPU_TARGET_PERCENT=90\n")
        self.assertEqual(self.run_guard("check").returncode, 0, "first missing token is allowed")
        start = self.home / "locks/execution-cpu-start.json"
        self.assertFalse(start.exists())
        boot = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
        for invalid in ('{', 'null', '[]', '{}', json.dumps(dict(boot_id=None, monotonic=0)),
                        json.dumps(dict(boot_id=boot, monotonic=float('nan'))),
                        json.dumps(dict(boot_id=boot, monotonic=-1))):
            with self.subTest(invalid=invalid):
                start.write_text(invalid)
                self.assertEqual(self.run_guard("run", "true").returncode, 75)
        start.write_text(json.dumps(dict(boot_id=boot, monotonic=time.monotonic()+10)))
        self.assertEqual(self.run_guard("check").returncode, 75, "future same-boot timestamp fails closed")
        start.write_text(json.dumps(dict(boot_id='00000000-0000-0000-0000-000000000001', monotonic=time.monotonic()+10)))
        self.assertEqual(self.run_guard("run", "true").returncode, 0, "confirmed different boot resets interval")
        self.assertEqual(json.loads(start.read_text())["boot_id"], boot)
        source = self.driver.read_text()
        self.driver.write_text(source.replace("try:sys.exit", f"""from pathlib import Path
read=Path.read_text
def fixture_read(path,*args,**kwargs):
 if path==Path({str(start)!r}):raise PermissionError('fixture token')
 return read(path,*args,**kwargs)
Path.read_text=fixture_read
try:sys.exit"""))
        self.assertEqual(self.run_guard("run", "true").returncode, 75)
        self.driver.write_text(source.replace("g.resources=lambda *args:{'available_mb':9999999,'load1':0.0}", "g.resources=lambda *args:{'available_mb':9999999,'load1':0.0}\nfrom pathlib import Path\nread=Path.read_text\ndef fixture_read(path,*args,**kwargs):\n if path==Path('/proc/sys/kernel/random/boot_id'):raise FileNotFoundError('fixture boot')\n return read(path,*args,**kwargs)\nPath.read_text=fixture_read"))
        start.unlink()
        self.assertEqual(self.run_guard("run", "true").returncode, 75, "unknown boot cannot waive the interval")

    def test_cpu_inherited_lease_high_load_memory_and_optout(self):
        proc = self.home / "inherited-resources"
        proc.mkdir()
        self.env.update(AGENT_EXECUTION_MAX_LOAD="12", AGENT_EXECUTION_MIN_MEM_MB="6144")
        self.env.pop("AGENT_EXECUTION_CPU_TARGET_PERCENT", None)
        self.driver.write_text(self.driver.read_text().replace(
            "g.resources=lambda *args:{'available_mb':9999999,'load1':0.0}",
            f"r=g.resources\ng.resources=lambda proc,*args:r(g.Path({str(proc)!r}),*args)\n"
            "g.cpu_sample=lambda *args,**kwargs:dict(cpu_state='UNKNOWN',cpu_percent=None,cpu_sampled_monotonic=g.time.monotonic())"))
        start = self.home / "locks/execution-cpu-start.json"
        for optin, memory, expected in ((True, 99999999, 23), (True, 1024, 75), (False, 99999999, 75)):
            with self.subTest(optin=optin, memory=memory):
                self.capacity(1)
                if optin:
                    with (self.home / "capacity.env").open("a") as handle:
                        handle.write("AGENT_EXECUTION_CPU_TARGET_PERCENT=90\n")
                start.unlink(missing_ok=True)
                (proc / "meminfo").write_text("MemAvailable: 99999999 kB\n")
                (proc / "loadavg").write_text("0 0 0 1/2 3\n")
                code = ("from pathlib import Path;import subprocess,sys;"
                        f"p=Path({str(start)!r});before=p.read_bytes() if p.exists() else None;"
                        f"Path({str(proc / 'loadavg')!r}).write_text('40 0 0 1/2 3\\n');"
                        f"Path({str(proc / 'meminfo')!r}).write_text('MemAvailable: {memory} kB\\n');"
                        f"status=subprocess.call([sys.executable,{str(self.driver)!r},'run','sh','-c','exit 23']);"
                        "assert (p.read_bytes() if p.exists() else None)==before;sys.exit(status)")
                result = self.run_guard("run", sys.executable, "-c", code)
                self.assertEqual(result.returncode, expected, result.stderr)

    def test_cpu_resources_cli_serializes_samples_without_consuming_slots(self):
        proc = self.home / "cpu-cli-proc"
        (proc / "sys/kernel/random").mkdir(parents=True)
        (proc / "sys/kernel/random/boot_id").write_text("boot-cli")
        (proc / "stat").write_text("cpu 100 0 0 100 0 0 0 0\ncpu0 1\n")
        (proc / "meminfo").write_text("MemAvailable: 9999999 kB\n")
        (proc / "loadavg").write_text("40 0 0 1/2 3\n")
        (self.home / "capacity.env").write_text("AGENT_EXECUTION_CPU_TARGET_PERCENT=90\n")
        env = dict(self.env, ZF_EXECUTION_PROC_ROOT=str(proc), AGENT_EXECUTION_MAX_LOAD="12")
        command = [sys.executable, str(ROOT / "execution-admission.py"), "resources"]
        first = subprocess.run(command, env=env, capture_output=True, text=True)
        self.assertEqual(first.returncode, 75, first.stderr)
        cache = self.home / "locks/execution-cpu.json"
        state = json.loads(cache.read_text()); state["cpu_sampled_monotonic"] -= 5
        cache.write_text(json.dumps(state))
        (proc / "stat").write_text("cpu 120 0 0 180 0 0 0 0\ncpu0 1\n")
        calls = [subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for _ in range(2)]
        outputs = [call.communicate(timeout=5) for call in calls]
        self.assertEqual([call.returncode for call in calls], [0, 0], outputs)
        samples = [json.loads(output[0]) for output in outputs]
        self.assertEqual([sample["cpu_percent"] for sample in samples], [20, 20])
        self.assertEqual(samples[0]["cpu_sampled_monotonic"], samples[1]["cpu_sampled_monotonic"])
        self.assertFalse((self.home / "locks/execution-cpu-start.json").exists())
        self.assertEqual(list((self.home / "locks").glob("execution-[0-9]*.lock")), [])

    def test_missing_mandatory_resource_still_defers(self):
        proc = self.home / "missing-proc"
        proc.mkdir()
        result = subprocess.run([sys.executable, str(ROOT / "execution-admission.py"), "check"],
                                env=dict(self.env, ZF_EXECUTION_PROC_ROOT=str(proc)), capture_output=True, text=True)
        self.assertEqual(result.returncode, 75)
        self.assertIn("FileNotFoundError", result.stderr)

    def test_dispatchers_use_shared_cpu_result_instead_of_old_load_gate(self):
        fake = self.home / "guard.py"
        marker = self.home / "resource-call"
        fake.write_text("import os,sys\nassert sys.argv[1:] == ['resources']\n"
                        f"open({str(marker)!r},'w').write('resources')\nsys.exit(int(os.environ['FIXTURE_CPU_STATUS']))\n")
        for script, begin, end in (
            ("night/dispatch.sh", 'if [ -n "${AGENT_EXECUTION_CPU_TARGET_PERCENT:-}" ]; then', '# 2026-09-23'),
            ("dispatch-codex.sh", '  if [ -n "${AGENT_EXECUTION_CPU_TARGET_PERCENT:-}" ]; then', '  [[ "$MAX_AGENTS"')):
            source = (ROOT / script).read_text()
            start = source.index(begin)
            block = source[start:source.index(end, start)]
            shell = (f'pipeline_execution_guard() {{ printf "%s" "{fake}"; }}\n'
                     'dispatch_load_exceeded() { return 0; }\n'
                     'load_1m=999; processors=1; LOAD_LIMIT_MULTIPLIER=1; TIER=general\n'
                     'LOADAVG_FILE=/proc/loadavg\n' + block)
            for status in (0, 75):
                result = subprocess.run(['bash', '-c', shell],
                    env=dict(self.env, AGENT_EXECUTION_CPU_TARGET_PERCENT='90', FIXTURE_CPU_STATUS=str(status)),
                    capture_output=True, text=True)
                self.assertEqual(result.returncode, status, (script, result.stderr))
                self.assertEqual(marker.read_text(), 'resources')
                marker.unlink()
            result = subprocess.run(['bash', '-c', shell],
                env=dict(self.env, AGENT_EXECUTION_CPU_TARGET_PERCENT='', FIXTURE_CPU_STATUS='0'),
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 1, (script, result.stderr))
            self.assertFalse(marker.exists())

    def test_pause_denies_all_work_without_clearing_marker(self):
        self.pause()
        marker = self.home / "never"
        result = self.run_guard("run", sys.executable, "-c", f"open({str(marker)!r},'w').write('bad')")
        self.assertEqual(result.returncode, 75)
        self.assertFalse(marker.exists())
        self.assertTrue((self.home / "PAUSE").exists())
        # Malformed markers retain native semantics; they do not fabricate a stop.
        (self.home / "PAUSE").write_text("{}")
        self.assertEqual(self.run_guard("check").returncode, 0)
        (self.home / "PAUSE").write_text("[]")
        self.assertEqual(self.run_guard("check").returncode, 0)

    def test_eight_competing_lanes_share_eight_slots(self):
        self.competing_lanes(8)

    def test_ten_competing_lanes_share_ten_slots(self):
        self.competing_lanes(10)

    def test_twelve_models_and_four_valid_execution_slots_share_sixteen(self):
        self.competing_lanes(16)

    def test_configuration_defaults_ten_and_accepts_sixteen(self):
        (self.home / 'capacity.env').unlink()
        with patch.dict(os.environ, clear=True):
            self.assertEqual(guard.configuration(self.home)[:2], (10, 6144))
            self.assertEqual(guard.configuration(self.home)[4:], (1024, 1))
            self.capacity(8)
            self.assertEqual(guard.configuration(self.home)[0], 8)
            self.capacity(10)
            self.assertEqual(guard.configuration(self.home)[0], 10)
            self.capacity(12)
            self.assertEqual(guard.configuration(self.home)[0], 12)
            self.capacity(13)
            self.assertEqual(guard.configuration(self.home)[0], 13)
            self.capacity(16)
            self.assertEqual(guard.configuration(self.home)[0], 16)
            self.capacity(17)
            with self.assertRaises(guard.Deferred):
                guard.configuration(self.home)

    def test_configuration_rejects_caps_outside_supported_range(self):
        with patch.dict(os.environ, clear=True):
            self.capacity(0)
            with self.assertRaises(guard.Deferred):
                guard.configuration(self.home)
            for key, value in (("AGENT_EXECUTION_MEM_PER_WORKER_MB", "0"),
                               ("AGENT_EXECUTION_LOAD_PER_WORKER", "nan")):
                with self.subTest(key=key):
                    (self.home / "capacity.env").write_text(f"{key}={value}\n")
                    with self.assertRaises(guard.Deferred):
                        guard.configuration(self.home)

    def test_dynamic_cap_follows_live_memory_and_load_readings(self):
        sample = lambda available, load1: {"available_mb": available, "load1": load1}
        # 16 ceiling, 2048 floor, 1536 MB and 2 load units per worker.
        for (available, load1, held), expected in (((8240, 2.0, 0), 4), ((8240, 2.0, 3), 7),
                                                   ((4000, 2.0, 0), 1), ((3000, 2.0, 0), 0),
                                                   ((9999999, 23.5, 0), 0), ((9999999, 20.0, 0), 2)):
            with self.subTest(available=available, load1=load1, held=held):
                self.assertEqual(guard.admission_cap(16, 2048, 24, 1536, 2, sample(available, load1), held), expected)
        # Missing or non-numeric readings admit nothing, never a guessed number.
        for missing in (None, {}, {"available_mb": None, "load1": None}, {"available_mb": "big", "load1": 0.0}):
            with self.subTest(missing=missing):
                self.assertEqual(guard.admission_cap(16, 2048, 24, 1536, 2, missing, 0), 0)
        self.assertEqual(guard.admission_cap(2, 2048, 24, 1536, 2, sample(9999999, 0.0), 9), 2, "ceiling still bounds")
        # CPU opt-in: a fresh below-target observation admits one incremental
        # worker whatever load1 says; a load fallback still uses load1 headroom.
        below_target = dict(sample(9999999, 23.5), cpu_decision="below-target")
        load_fallback = dict(sample(9999999, 23.5), cpu_decision="load-fallback")
        self.assertEqual(guard.admission_cap(16, 2048, 24, 1536, 2, below_target, 8), 9)
        self.assertEqual(guard.admission_cap(16, 2048, 24, 1536, 2, load_fallback, 8), 8)
        self.assertEqual(guard.admission_cap(9, 2048, 24, 1536, 2, below_target, 8), 9, "ceiling still bounds")

    def test_dynamic_cap_priority_classes(self):
        sample = {"available_mb": 9999999, "load1": 46.5}
        # hotfix/release ignore load/CPU headroom while memory and the ceiling
        # continue to bound their dynamic capacity.
        self.assertEqual(guard.admission_cap(16, 2048, 12, 1536, 2, sample, 8, "release"), 16)
        self.assertEqual(guard.admission_cap(16, 2048, 12, 1536, 2, sample, 8, "hotfix"), 16)
        self.assertEqual(guard.admission_cap(16, 2048, 12, 1536, 2, dict(sample, cpu_decision="below-target"), 8, "release"), 16)
        tight = {"available_mb": 3000, "load1": 0.0}
        self.assertEqual(guard.admission_cap(16, 2048, 12, 1536, 2, tight, 8, "release"), 8)
        # opt keeps load headroom against twice the configured maximum; ordinary
        # pipeline keeps the single maximum; a below-target CPU sample still
        # grants opt its single incremental worker.
        self.assertEqual(guard.admission_cap(16, 2048, 12, 1536, 2, {"available_mb": 9999999, "load1": 18}, 8, "opt"), 11)
        self.assertEqual(guard.admission_cap(16, 2048, 12, 1536, 2, sample, 8, "opt"), 8)
        self.assertEqual(guard.admission_cap(16, 2048, 12, 1536, 2, dict(sample, cpu_decision="below-target"), 8, "opt"), 9)
        self.assertEqual(guard.admission_cap(16, 2048, 12, 1536, 2, {"available_mb": 9999999, "load1": 18}, 8, ""), 8)
        self.assertEqual(guard.admission_cap(16, 2048, 12, 1536, 2, {"available_mb": 9999999, "load1": 18}, 8), 8)

    def guarded_check(self, **environment):
        return subprocess.run([sys.executable, str(self.driver), "check"],
                              env=dict(self.env, **environment), capture_output=True, text=True)

    def test_release_and_hotfix_pass_high_load_while_pipeline_and_opt_defer(self):
        proc = self.home / "priority-proc"
        proc.mkdir()
        self.env.update(AGENT_EXECUTION_MAX_LOAD="12", AGENT_EXECUTION_MIN_MEM_MB="6144",
                        AGENT_EXECUTION_CPU_TARGET_PERCENT="85", ZF_EXECUTION_PROC_ROOT=str(proc))
        self.driver.write_text(self.driver.read_text().replace(
            "g.resources=lambda *args:{'available_mb':9999999,'load1':0.0}",
            f"original_resources=g.resources\ng.resources=lambda proc,*args:original_resources(g.Path({str(proc)!r}),*args)"))
        (proc / "meminfo").write_text("MemAvailable: 99999999 kB\n")
        (proc / "loadavg").write_text("46.5 0 0 1/2 3\n")
        # 2026-10-29: load 46.5 over a maximum of 12 refused a release batch
        # while opt workers filled the box. Priority work keeps only the memory
        # floor; ordinary pipeline (unset or "normal") and opt at twice the
        # maximum still defer.
        self.assertEqual(self.guarded_check().returncode, 75)
        self.assertEqual(self.guarded_check(LUNA_PRIORITY="normal").returncode, 75)
        self.assertEqual(self.guarded_check(LUNA_PRIORITY="release").returncode, 0)
        self.assertEqual(self.guarded_check(LUNA_PRIORITY="hotfix").returncode, 0)
        self.assertEqual(self.guarded_check(LUNA_PRIORITY="opt").returncode, 75)
        # The mocked proc tree has no CPU stat or boot identity: priority work
        # does not enter the CPU sampler or its post-start observation gate.
        cpu_overload = {"cpu_state": "FRESH", "cpu_percent": 90.0,
                        "cpu_sampled_monotonic": guard.time.monotonic()}
        for priority in ("release", "hotfix"):
            with self.subTest(priority=priority):
                sample = guard.resources(proc, 6144, 12, cpu_overload, 85, priority)
                self.assertEqual(sample["load1"], 46.5)
                self.assertEqual(sample["cpu_decision"], "hold")
        (proc / "loadavg").write_text("0 0 0 1/2 3\n")
        with self.assertRaises(guard.Deferred):
            guard.resources(proc, 6144, 12, cpu_overload, 85)
        self.env.pop("AGENT_EXECUTION_CPU_TARGET_PERCENT")
        (proc / "loadavg").write_text("46.5 0 0 1/2 3\n")
        # opt keeps running between the maximum and twice it, where ordinary
        # pipeline is already deferred.
        (proc / "loadavg").write_text("18 0 0 1/2 3\n")
        self.assertEqual(self.guarded_check(LUNA_PRIORITY="opt").returncode, 0)
        self.assertEqual(self.guarded_check().returncode, 75)
        # The memory floor still refuses priority work.
        (proc / "meminfo").write_text("MemAvailable: 1024 kB\n")
        self.assertEqual(self.guarded_check(LUNA_PRIORITY="release").returncode, 75)

    def test_shim_marks_release_units_and_load_admits_only_them(self):
        called = self.home / "native-called"
        fake = self.home / "native"
        fake.write_text(f"#!/bin/sh\nprintf '%s\\n' \"$@\" > '{called}'\n")
        fake.chmod(0o755)
        proc = self.home / "shim-proc"
        proc.mkdir()
        (proc / "meminfo").write_text("MemAvailable: 99999999 kB\n")
        (proc / "loadavg").write_text("46.5 0 0 1/2 3\n")
        self.env.update(AGENT_EXECUTION_MAX_LOAD="12", AGENT_EXECUTION_MIN_MEM_MB="6144",
                        ZF_EXECUTION_PROC_ROOT=str(proc), ZF_SYSTEMD_RUN_REAL=str(fake))
        # The shim resolves its guard as ../execution-admission.py, so stage the
        # driver (occupied stubbed; resources on the fixture proc) beside a copy
        # of the real shim.
        self.driver.write_text(self.driver.read_text().replace(
            "g.resources=lambda *args:{'available_mb':9999999,'load1':0.0}",
            f"original_resources=g.resources\ng.resources=lambda proc,*args:original_resources(g.Path({str(proc)!r}),*args)"))
        harness = self.home / "admission-harness"
        (harness / "execution-shim").mkdir(parents=True)
        (harness / "execution-shim/systemd-run").write_text((ROOT / "execution-shim/systemd-run").read_text())
        (harness / "execution-shim/systemd-run").chmod(0o755)
        (harness / "execution-admission.py").write_text(self.driver.read_text())
        shim = str(harness / "execution-shim/systemd-run")
        result = subprocess.run([shim, "--user", "--unit=zf-release-batch", "--", "/bin/true"],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        launched = called.read_text().splitlines()
        self.assertIn("LUNA_PRIORITY=release", launched)
        self.assertLess(launched.index("LUNA_PRIORITY=release"), launched.index("run-unit"),
                        "the unit env must carry the priority into the in-unit run-unit stage")
        self.assertEqual(launched[launched.index("LUNA_PRIORITY=release") - 1], "-E")
        called.unlink()
        result = subprocess.run([shim, "--user", "--unit=zf-implement-1", "--", "/bin/true"],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 75, "ordinary units still defer at high load")
        self.assertFalse(called.exists())

    def test_hand_dispatch_resolves_priority_before_its_admission_gate(self):
        source = (ROOT / "night/dispatch.sh").read_text()
        start = source.index('source "$SCRIPT_DIR/dispatch-load-guard.sh"')
        end = source.index("pipeline_execution_admit || exit $?", start) + len("pipeline_execution_admit || exit $?")
        preflight = source[start:end]
        state = self.home / "hand-priority.json"
        state.write_text(json.dumps({"order": ["hotfix", "optimization", "general"],
                                     "roles": {"production": "hotfix"}, "sessions": {},
                                     "default": "general", "memory_floor_mb": {}}))
        for role, enqueue_priority, expected in (("production", "", "hotfix"),
                                                  ("work", "pipeline", "opt")):
            with self.subTest(role=role, enqueue_priority=enqueue_priority):
                result = subprocess.run(["bash", "-c",
                    f'SCRIPT_DIR="{ROOT}"\n'
                    'pipeline_execution_admit() { printf "priority=%s\\n" "$LUNA_PRIORITY"; return 75; }\n'
                    f'{preflight}\n'],
                    env=dict(self.env, HAND_PRIORITY_STATE=str(state), ROLE=role, NAME="fixture",
                             RESUME_NOTE="", ENQUEUE_PRIORITY=enqueue_priority),
                    capture_output=True, text=True)
                self.assertEqual(result.returncode, 75, result.stderr)
                self.assertEqual(result.stdout.strip(), f"priority={expected}")

    def test_dynamic_admission_counts_live_workers(self):
        proc = self.home / "dynamic-proc"
        proc.mkdir()
        (proc / "meminfo").write_text("MemAvailable: 8437760 kB\n")  # 8240 MB
        (proc / "loadavg").write_text("2 0 0 1/2 3\n")
        (self.home / "capacity.env").write_text(
            "AGENT_GLOBAL_EXECUTION_CAP=16\nAGENT_EXECUTION_MIN_MEM_MB=2048\nAGENT_EXECUTION_MAX_LOAD=24\n"
            "AGENT_EXECUTION_MEM_PER_WORKER_MB=1536\nAGENT_EXECUTION_LOAD_PER_WORKER=2\n")
        # The driver subprocess must read the fixture, not its fixed sample.
        self.driver.write_text(self.driver.read_text().replace(
            "g.resources=lambda *args:{'available_mb':9999999,'load1':0.0}",
            f"original_resources=g.resources\ng.resources=lambda proc,*args:original_resources(g.Path({str(proc)!r}),*args)"))
        def lane(name):
            ready = self.home / f"dynamic-{name}"
            personal = self.home / f"dynamic-{name}-release"
            code = ("from pathlib import Path\nimport time\n"
                    f"mem=Path({str(proc / 'meminfo')!r});ld=Path({str(proc / 'loadavg')!r})\n"
                    "def shift(kb,load):\n"
                    " cur=int(mem.read_text().split()[1]);mem.write_text(f'MemAvailable: {cur+kb} kB\\n')\n"
                    " l1=float(ld.read_text().split()[0]);ld.write_text(f'{l1+load} 0 0 1/2 3\\n')\n"
                    "shift(-1572864,2)\n"
                    f"Path({str(ready)!r}).touch()\n"
                    f"while not Path({str(personal)!r}).exists():time.sleep(0.01)\n"
                    "shift(1572864,-2)\n")
            child = subprocess.Popen([sys.executable, str(self.driver), "run", sys.executable, "-c", code], env=self.env)
            self.children.append(child)
            deadline = time.monotonic() + 5
            while not ready.exists():
                self.assertLess(time.monotonic(), deadline, f"lane {name} was not admitted")
                time.sleep(0.01)
            return personal
        releases = [lane(index) for index in range(4)]
        # The four memory slots are consumed: a fifth worker defers without a verdict.
        self.assertEqual(self.run_guard("run", "true").returncode, 75)
        # One worker exits and frees its share: the next admission passes again.
        releases[1].touch()
        self.children[1].wait(timeout=5)
        lane("fifth")
        for path in (releases[0], releases[2], releases[3], self.home / "dynamic-fifth-release"):
            path.touch()
        for child in self.children[4:]:
            child.wait(timeout=5)

    def test_isolated_test_home_skips_host_census_only_inside_test_root(self):
        test_root = self.home / "isolated"
        agent_home = test_root / "agent"
        outside_home = self.home / "outside"
        agent_home.mkdir(parents=True)
        outside_home.mkdir()
        settings = {
            "AGENT_HOME": str(agent_home),
            "AGENT_GLOBAL_EXECUTION_CAP": "1",
            "ZF_AGENT_TEST_MODE": "1",
            "ZF_AGENT_TEST_ROOT": str(test_root),
        }
        with patch.dict(os.environ, settings):
            with patch.object(guard, "resources", return_value={"available_mb": 9999999, "load1": 0.0}):
                with patch.object(guard, "occupied", side_effect=AssertionError("host census must be skipped")):
                    self.assertEqual(guard.admission("check", []), 0)

        settings["AGENT_HOME"] = str(outside_home)
        with patch.dict(os.environ, settings):
            with patch.object(guard, "resources"):
                with patch.object(guard, "occupied", return_value={"external-worker"}):
                    with self.assertRaises(guard.Deferred):
                        guard.admission("check", [])

    def competing_lanes(self, cap):
        # Pin the resource readings' contribution so only the ceiling bounds lanes.
        (self.home / "capacity.env").write_text(
            f"AGENT_GLOBAL_EXECUTION_CAP={cap}\nAGENT_EXECUTION_MIN_MEM_MB=1\nAGENT_EXECUTION_MAX_LOAD=999\n")
        lanes = (tuple(f"model-{index:02d}" for index in range(1, 13)) +
                 ("direct-main-transient", "worktree-cleanup-transient", "queue-service", "dispatch-allowance"))[:cap]
        release = self.home / "release"
        for lane in lanes:
            ready = self.home / lane
            code = f"import os,time;from pathlib import Path;p=Path({str(ready)!r});p.write_text(os.environ['RELEASE_TEST_JOBS']);r=Path({str(release)!r});\nwhile not r.exists():time.sleep(.01)"
            child = subprocess.Popen([sys.executable, str(self.driver), "run", sys.executable, "-c", code], env=self.env)
            self.children.append(child)
        deadline = time.monotonic() + 5
        while not all((self.home / lane).exists() for lane in lanes):
            self.assertLess(time.monotonic(), deadline, "fixture admission did not start")
            time.sleep(.01)
        self.assertEqual(self.run_guard("run", "true").returncode, 75)
        self.assertEqual({(self.home / lane).read_text() for lane in lanes}, {"1"})
        # A lowered cap still counts leases from slots above the new limit.
        self.capacity(1)
        self.assertEqual(self.run_guard("check").returncode, 75)
        release.touch()
        for child in self.children:
            self.assertEqual(child.wait(timeout=5), 0)
        self.assertEqual(self.run_guard("run", "true").returncode, 0)

    def test_nested_checks_reuse_owner_but_preserve_failure_and_child_bounds(self):
        self.capacity(1)
        code = f"import subprocess,sys,os;assert os.environ['VITEST_MAX_WORKERS']=='1';assert os.environ['RUN_CI_SUITES_JOBS']=='1';assert os.environ['IMPLEMENT_TEST_JOBS']=='1';assert subprocess.call([sys.executable,{str(self.driver)!r},'check'])==75;sys.exit(subprocess.call([sys.executable,{str(self.driver)!r},'run','sh','-c','exit 23']))"
        self.assertEqual(self.run_guard("run", sys.executable, "-c", code).returncode, 23)
        self.assertEqual(self.run_guard("check").returncode, 0)

    def test_guardian_forwards_term_and_waits_for_cleanup(self):
        ready = self.home / "signal-ready"
        receipt = self.home / "signal-cleanup"
        code = ("import signal,time;from pathlib import Path;"
                f"signal.signal(signal.SIGTERM,lambda *args:(Path({str(receipt)!r}).touch(),exit(143)));"
                f"Path({str(ready)!r}).touch();signal.pause()")
        child = subprocess.Popen([sys.executable, str(self.driver), "run", sys.executable, "-c", code], env=self.env)
        self.children.append(child)
        deadline = time.monotonic() + 5
        while not ready.exists():
            self.assertLess(time.monotonic(), deadline)
            time.sleep(.01)
        child.terminate()
        deadline = time.monotonic() + 5
        while not receipt.exists():
            self.assertLess(time.monotonic(), deadline, "worker did not finish signal cleanup")
            time.sleep(.01)
        # Keep cleanup prompt; use the metrics suite's 15s budget for both bounded writes.
        self.assertEqual(child.wait(timeout=15), 143)
        self.assertTrue(receipt.exists())
        self.assertEqual(self.run_guard("run", "true").returncode, 0)

    def test_held_unknown_or_reused_pid_fails_closed(self):
        locks = self.home / "locks"
        locks.mkdir()
        with (locks / "execution-0.lock").open("a+") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            self.assertEqual(self.run_guard("check").returncode, 75)
            (locks / "execution-0.json").write_text(json.dumps({"pid": os.getpid(), "start_ticks": "wrong"}))
            self.assertEqual(self.run_guard("check").returncode, 75)

    def test_resources_and_legacy_frozen_group_are_not_zero(self):
        proc = self.home / "proc"
        proc.mkdir()
        (proc / "meminfo").write_text("MemAvailable: 1024 kB\n")
        (proc / "loadavg").write_text("0.1 0 0 1/2 3\n")
        with self.assertRaises(guard.Deferred):
            guard.resources(proc, 6144, 12)
        (proc / "meminfo").write_text("MemAvailable: 9999999 kB\n")
        (proc / "loadavg").write_text("nan 0 0 1/2 3\n")
        with self.assertRaises(guard.Deferred):
            guard.resources(proc, 1, 12)
        self.assertTrue(guard.WORKER_UNIT.match("zf-implement-3437.service"))
        self.assertTrue(guard.WORKER_UNIT.match("zf-node-owner-episode-pipeline-ci.service"))
        self.assertFalse(guard.WORKER_UNIT.match("zf-codex-claude-bell.service"))
        # A frozen owner and its child count once, independently of a stale roster.
        for pid, group in ((111, "/app/zf-implement-3437.service"), (112, "/app/zf-implement-3437.service"), (113, "/app/zf-node-owner-ci.service"), (os.getpid(), "/non-systemd")):
            directory = proc / str(pid)
            directory.mkdir()
            fields = ["T", "1"] + ["0"] * 17 + ["1234"]
            (directory / "stat").write_text(f"{pid} (test process) " + " ".join(fields))
            (directory / "cgroup").write_text("0::" + group + "\n")
        self.assertEqual(guard.occupied(proc), {"/app/zf-implement-3437.service", "/app/zf-node-owner-ci.service"})

    def test_native_launcher_pause_refuses_before_systemd_and_nonworkers_pass(self):
        self.pause()
        fake = self.home / "native"
        called = self.home / "called"
        fake.write_text(f"#!/bin/sh\nprintf '%s\\n' \"$@\" > '{called}'\n")
        fake.chmod(0o755)
        env = dict(self.env, ZF_SYSTEMD_RUN_REAL=str(fake))
        shim = ROOT / "execution-shim/systemd-run"
        for unit in ("zf-implement-1", "zf-node-owner-x", "zf-hand-example"):
            result = subprocess.run([str(shim), "--user", "--unit", unit, "--", "true"], env=env, capture_output=True)
            self.assertEqual(result.returncode, 75)
            self.assertFalse(called.exists())
        result = subprocess.run([str(shim), "--user", "--unit=zenoforge-traffic-monitor", "--", "true"], env=env)
        self.assertEqual(result.returncode, 0)
        self.assertIn("zenoforge-traffic-monitor", called.read_text())

    def test_supervisor_pause_happens_before_snapshot_or_recovery(self):
        self.pause()
        result = subprocess.run(["bash", str(ROOT / "supervise-pipeline.sh")], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn("operator PAUSE", result.stderr)

    def test_idle_cleanup_launch_is_lightweight_and_unknown_cleanup_is_guarded(self):
        self.pause()
        called = self.home / "native-called"
        fake = self.home / "native"
        fake.write_text(f"#!/bin/sh\nprintf '%s\\n' \"$@\" > '{called}'\n")
        fake.chmod(0o755)
        command = ['bash', str(ROOT / 'worktree-lifecycle.sh'), 'watch', '/repo', '/tree', '123', '456']
        env = dict(self.env, ZF_SYSTEMD_RUN_REAL=str(fake))
        shim = str(ROOT / 'execution-shim/systemd-run')
        result = subprocess.run([shim, '--user', '--unit=zf-worktree-cleanup-123', '--', *command], env=env, capture_output=True)
        self.assertEqual(result.returncode, 0)
        self.assertNotIn('run-unit', called.read_text())
        called.unlink()
        command[2] = 'watch-cleanup'
        result = subprocess.run([shim, '--user', '--unit=zf-worktree-cleanup-123', '--', *command], env=env, capture_output=True)
        self.assertEqual(result.returncode, 75)
        self.assertFalse(called.exists())

    def test_idle_cleanup_census_keeps_old_guardian_and_unknown_phase(self):
        proc = self.home / 'proc'
        proc.mkdir()
        def process(pid, parent, group, command):
            directory = proc / str(pid)
            directory.mkdir()
            fields = ['T', str(parent)] + ['0'] * 17 + ['1234']
            (directory / 'stat').write_text(f'{pid} (fixture) ' + ' '.join(fields))
            (directory / 'cgroup').write_text('0::' + group + '\n')
            (directory / 'cmdline').write_bytes(b'\0'.join(arg.encode() for arg in command) + b'\0')
        command = ['bash', str(ROOT / 'worktree-lifecycle.sh'), 'watch', '/repo', '/tree', '123', '456']
        process(os.getpid(), 1, '/non-systemd', [])
        process(111, 1, '/zf-worktree-cleanup-idle.service', command)
        process(112, 111, '/zf-worktree-cleanup-idle.service', ['sleep', '10'])
        process(121, 1, '/zf-worktree-cleanup-old.service', ['python3', 'execution-admission.py'])
        process(122, 121, '/zf-worktree-cleanup-old.service', command)
        process(131, 1, '/zf-worktree-cleanup-heavy.service', [*command[:2], 'watch-cleanup', *command[3:]])
        process(141, 1, '/zf-implement-frozen.service', ['model'])
        self.assertEqual(guard.occupied(proc), {'/zf-worktree-cleanup-old.service', '/zf-worktree-cleanup-heavy.service', '/zf-implement-frozen.service'})
        all_groups = {'/zf-worktree-cleanup-idle.service', '/zf-worktree-cleanup-old.service',
                      '/zf-worktree-cleanup-heavy.service', '/zf-implement-frozen.service'}
        for error in (FileNotFoundError, ProcessLookupError):
            with patch.object(guard, "descendant", side_effect=error()):
                self.assertEqual(guard.occupied(proc), all_groups)
        with patch.object(guard, "descendant", side_effect=PermissionError()):
            with self.assertRaises(PermissionError):
                guard.occupied(proc)
        real_identity = guard.identity
        def vanished(pid, root):
            if str(pid) == "111":
                raise ProcessLookupError()
            return real_identity(pid, root)
        with patch.object(guard, "identity", side_effect=vanished):
            self.assertEqual(guard.occupied(proc), all_groups)

    def test_actual_watcher_terminal_cleanup_is_admitted_and_deferred_without_mutation(self):
        repo = self.home / 'repo'
        repo.mkdir()
        subprocess.run(['git', 'init', '-q', str(repo)], check=True)
        pipeline = repo / 'engine/issue-pipeline.sh'
        pipeline.parent.mkdir(parents=True)
        pipeline.write_text('#!/usr/bin/env bash\nexit 0\n')
        script = self.home / 'worktree-lifecycle.sh'
        source = (ROOT / 'worktree-lifecycle.sh').read_text()
        phase = 'watch_cleanup()' if 'watch_cleanup()' in source else 'watch()'
        start = source.index('  # A child the agent backgrounded', source.index(phase))
        end = source.index('\nmain() {', start)
        receipt = self.home / 'heavy'
        script.write_text(source[:start] + f'  printf "%s:%s" "${{RELEASE_TEST_JOBS:-unset}}" "${{NIGHT_TEST_JOBS:-unset}}" > "{receipt}"\n}}\n' + source[end:])
        (self.home / 'hand-completion-refill.sh').write_text((ROOT / 'hand-completion-refill.sh').read_text())
        resource_proc = self.home / 'resource-proc'
        resource_proc.mkdir()
        (resource_proc / 'meminfo').write_text('MemAvailable: 99999999 kB\n')
        (resource_proc / 'loadavg').write_text('0 0 0 1/2 3\n')
        driver = self.driver.read_text().replace("g.resources=lambda *args:{'available_mb':9999999,'load1':0.0}", f'original_resources=g.resources\ng.resources=lambda proc,*args:original_resources(g.Path({str(resource_proc)!r}),*args)')
        (self.home / 'execution-admission.py').write_text(driver)
        def invoke(mode, pid='999999999', ticks='1'):
            return subprocess.run(['bash', str(script), mode, str(repo), str(self.home / 'target'), pid, ticks], env=self.env, capture_output=True, text=True, timeout=10)
        self.pause()
        blocked = invoke('watch')
        self.assertEqual(blocked.returncode, 75, blocked.stdout + blocked.stderr)
        self.assertFalse(receipt.exists())
        (self.home / 'PAUSE').unlink()
        self.capacity(1)
        with (self.home / 'capacity.env').open('a') as handle:
            handle.write('AGENT_EXECUTION_MIN_MEM_MB=6144\nAGENT_EXECUTION_MAX_LOAD=12\n')
        locks = self.home / 'locks'
        locks.mkdir(exist_ok=True)
        with (locks / 'execution-0.lock').open('a+') as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            (locks / 'execution-0.json').write_text(json.dumps(guard.identity(os.getpid(), Path('/proc'))))
            self.assertEqual(invoke('watch-cleanup').returncode, 75)
            self.assertFalse(receipt.exists())
        self.assertEqual(invoke('watch-cleanup', str(os.getpid()), guard.identity(os.getpid(), Path('/proc'))['start_ticks']).returncode, 75)
        self.assertFalse(receipt.exists())
        (resource_proc / 'meminfo').write_text('MemAvailable: 6290432 kB\n')  # 6143 MB.
        self.assertEqual(invoke('watch').returncode, 75)
        self.assertFalse(receipt.exists())
        (resource_proc / 'meminfo').write_text('MemAvailable: 99999999 kB\n')
        (resource_proc / 'loadavg').write_text('12 0 0 1/2 3\n')
        self.assertEqual(invoke('watch').returncode, 75)
        self.assertFalse(receipt.exists())
        (resource_proc / 'loadavg').write_text('0 0 0 1/2 3\n')
        self.assertEqual(invoke('watch').returncode, 0)
        self.assertEqual(receipt.read_text(), '1:1')


if __name__ == "__main__":
    unittest.main()
