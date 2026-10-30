#!/usr/bin/env python3
"""Actual guardian/flock/sink boundaries; serial fake workers, no model or systemd."""
import datetime
from contextlib import redirect_stderr
import fcntl
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("guard", ROOT / "execution-admission.py")
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class AdmissionMetrics(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        self.env = dict(os.environ, AGENT_HOME=str(self.home), PRIVATE_SENTINEL="never-persist-this")
        self.env.pop("ZF_EXECUTION_SLOT", None)
        self.env.pop("ZF_EXECUTION_PROC_ROOT", None)
        self.env.pop("LUNA_PRIORITY", None)
        (self.home / "capacity.env").write_text("AGENT_GLOBAL_EXECUTION_CAP=1\nAGENT_EXECUTION_MIN_MEM_MB=6144\nAGENT_EXECUTION_MAX_LOAD=12\n")
        self.proc = self.home / "resource-proc"
        self.proc.mkdir()
        self.resources(12288, .5)
        self.driver = self.home / "driver.py"
        self.driver.write_text(
            "import importlib.util,sys,fcntl\nfrom pathlib import Path\n"
            f"s=importlib.util.spec_from_file_location('guard',{str(ROOT / 'execution-admission.py')!r})\n"
            "g=importlib.util.module_from_spec(s);s.loader.exec_module(g)\n"
            "g.occupied=lambda proc:set()\noriginal_resources=g.resources\n"
            f"g.resources=lambda proc,*args:original_resources(Path({str(self.proc)!r}),*args)\n"
            "original_append=g.AttemptMetrics.append\n"
            "def append(self,event,*args):\n"
            "  gate=self.home/'locks/execution-admission.lock'\n"
            "  if gate.exists():\n"
            "    with gate.open('r') as f:fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\n"
            "  if event=='execution-release':\n"
            "    with (self.home/'locks/execution-0.lock').open('r') as f:fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\n"
            "  original_append(self,event,*args)\n"
            "g.AttemptMetrics.append=append\n"
            # The sink sources the whole lib.sh under a 2 s bound (about 1 s on a 12-core dev host); a 4-vCPU runner needs longer, so only the sink bound is lifted here.
            "sink_run=g.subprocess.run\n"
            "def run(cmd,**kw):\n"
            "  if cmd[0]=='timeout':cmd=[*cmd[:3],'10s',*cmd[4:]];kw['timeout']=14\n"
            "  return sink_run(cmd,**kw)\n"
            "g.subprocess.run=run\n"
            "try:sys.exit(g.admission(sys.argv[1],sys.argv[2:]))\n"
            "except (g.Deferred,OSError,ValueError,KeyError,StopIteration,IndexError):sys.exit(75)\n"
        )

    def tearDown(self):
        self.tmp.cleanup()

    def resources(self, available, load):
        (self.proc / "meminfo").write_text(f"MemAvailable: {available * 1024} kB\n")
        (self.proc / "loadavg").write_text(f"{load} 0 0 1/2 3\n")

    def invoke(self, mode="run", *command, env=None):
        return subprocess.run([sys.executable, str(self.driver), mode, *command],
                              env=env or self.env, capture_output=True, text=True, timeout=60)

    def rows(self):
        month = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m")
        path = self.home / "metrics" / f"efficiency-{month}.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def held_slot(self):
        locks = self.home / "locks"
        locks.mkdir(exist_ok=True)
        (locks / "execution-0.json").write_text(json.dumps(guard.identity(os.getpid(), Path("/proc"))))
        f = (locks / "execution-0.lock").open("a+")
        fcntl.flock(f, fcntl.LOCK_EX)
        return f

    def test_multiple_actual_attempts_admit_release_and_private_projection(self):
        self.assertEqual(self.invoke("run", sys.executable, "-c", "pass", "PRIVATE_SENTINEL").returncode, 0)
        self.assertEqual(self.invoke("run-unit", sys.executable, "-c", "raise SystemExit(7)").returncode, 7)
        rows = self.rows()
        self.assertEqual([r["event_type"] for r in rows], ["execution-admission", "execution-release"] * 2)
        self.assertEqual([r["status"] for r in rows], [0, 0, 0, 7])
        self.assertEqual(len({r["attempt_id"] for r in rows}), 2)
        self.assertEqual(len({r["event_id"] for r in rows}), 4)
        self.assertEqual(rows[0]["attempt_id"], rows[1]["attempt_id"])
        self.assertTrue(all(r["pid"] > 0 and r["start_ticks"] and r["boot_id"] and r["producer_hostname"] for r in rows))
        self.assertTrue(all(r["available_mb"] == 12288 and r["load1"] == .5 for r in rows))
        self.assertEqual(rows[0]["resource_sampled_at"], rows[1]["resource_sampled_at"])
        self.assertEqual(rows[0]["occupancy_sampled_at"], rows[1]["occupancy_sampled_at"])
        self.assertLessEqual(rows[0]["resource_sampled_at"], rows[0]["ts"])
        self.assertTrue(rows[1]["lease_released"])
        self.assertNotIn("PRIVATE_SENTINEL", json.dumps(rows))
        self.assertNotIn("never-persist-this", json.dumps(rows))
        self.assertFalse(any(k in rows[0] for k in ("argv", "env", "command", "prompt")))

    def test_actual_resource_and_capacity_75_keep_unknown_occupancy_honest(self):
        marker = self.home / "never"
        command = (sys.executable, "-c", f"open({str(marker)!r},'w').close()")
        self.resources(6143, .5)
        self.assertEqual(self.invoke("run", *command).returncode, 75)
        self.resources(12288, 12)
        self.assertEqual(self.invoke("run-unit", *command).returncode, 75)
        self.resources(12288, .5)
        with self.held_slot():
            self.assertEqual(self.invoke("run", *command).returncode, 75)
        rows = self.rows()
        self.assertEqual([r["reason"] for r in rows], ["resource-floor", "resource-floor", "capacity"])
        self.assertEqual([r["occupied"] for r in rows], [None, None, 1])
        self.assertTrue(all(r["outcome"] == "defer" and r["status"] == 75 and not r["lease_released"] for r in rows))
        self.assertEqual(len({r["attempt_id"] for r in rows}), 3)
        self.assertFalse(marker.exists())

    def test_no_readiness_events_and_actual_inherited_run_is_not_lease_release(self):
        self.assertEqual(self.invoke("check").returncode, 0)
        self.assertEqual(self.invoke("status").returncode, 0)
        self.assertEqual(self.invoke("inherited").returncode, 1)
        self.assertEqual(self.rows(), [])
        env = dict(self.env, ZF_EXECUTION_SLOT="0")
        with self.held_slot():
            self.assertEqual(self.invoke("inherited", env=env).returncode, 0)
            self.assertEqual(self.rows(), [])
            self.assertEqual(self.invoke("run", sys.executable, "-c", "pass", env=env).returncode, 0)
            self.assertEqual(self.invoke("run", "/nonexistent/PRIVATE_SENTINEL", env=env).returncode, 75)
        rows = self.rows()
        self.assertEqual([r["event_type"] for r in rows], ["execution-admission", "execution-admission", "execution-error"])
        self.assertTrue(all(r["lease_kind"] == "inherited" and not r["lease_released"] for r in rows))
        self.assertIsNone(rows[0]["execution_started"])
        self.assertEqual(rows[-1]["status"], 75)
        self.assertNotIn("PRIVATE_SENTINEL", json.dumps(rows))

    def test_priority_class_is_recorded_on_admission_events(self):
        self.assertEqual(self.invoke("run", sys.executable, "-c", "pass",
                                     env=dict(self.env, LUNA_PRIORITY="release")).returncode, 0)
        self.assertEqual([row["priority"] for row in self.rows()], ["release", "release"])

    def test_sink_lock_failure_preserves_actual_worker_status_and_release(self):
        directory = self.home / "metrics"
        directory.mkdir(mode=0o700)
        month = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m")
        with (directory / f"efficiency-{month}.jsonl.lock").open("a+") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            result = self.invoke("run", sys.executable, "-c", "raise SystemExit(7)")
        self.assertEqual(result.returncode, 7)
        self.assertIn("execution metrics: append failed", result.stderr)
        self.assertEqual(self.rows(), [])
        self.assertEqual(self.invoke("run", sys.executable, "-c", "pass").returncode, 0)
        self.assertEqual(len(self.rows()), 2)

    def test_launch_failure_is_defer_then_actual_reservation_release(self):
        self.assertEqual(self.invoke("run", "/nonexistent/PRIVATE_SENTINEL").returncode, 75)
        rows = self.rows()
        self.assertEqual([r["event_type"] for r in rows], ["execution-admission", "execution-release"])
        self.assertEqual(rows[0]["outcome"], "defer")
        self.assertTrue(all(r["status"] == 75 for r in rows))
        self.assertTrue(rows[-1]["lease_released"])
        self.assertNotIn("PRIVATE_SENTINEL", json.dumps(rows))

    def test_telemetry_initialization_fault_does_not_change_execution(self):
        errors = io.StringIO()
        original_resources = guard.resources
        with patch.dict(os.environ, self.env, clear=True), redirect_stderr(errors):
            with patch.object(guard, "AttemptMetrics", side_effect=RuntimeError("PRIVATE_SENTINEL")):
                with patch.object(guard, "occupied", return_value=set()):
                    with patch.object(guard, "resources", side_effect=lambda proc, *args: original_resources(self.proc, *args)):
                        self.assertEqual(guard.admission("run", [sys.executable, "-c", "raise SystemExit(7)"]), 7)
        self.assertIn("execution metrics: initialization failed", errors.getvalue())
        self.assertNotIn("PRIVATE_SENTINEL", errors.getvalue())
        self.assertEqual(self.rows(), [])


if __name__ == "__main__":
    unittest.main()
