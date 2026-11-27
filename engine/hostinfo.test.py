import contextlib
import importlib.util
import io
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("hostinfo", ROOT / "hostinfo.py")
HOSTINFO = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HOSTINFO)


class HostInfo(unittest.TestCase):
    def capture(self, name, proc_root, system, **dependencies):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            HOSTINFO.main([name], proc_root=proc_root, system=system, **dependencies)
        return output.getvalue().strip()

    def fake_runner(self, outputs):
        calls = []

        def run(command, **kwargs):
            calls.append(tuple(command))
            return subprocess.CompletedProcess(command, 0, outputs[tuple(command)], "")

        return run, calls

    def test_linux_subcommands_read_current_host_values(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "meminfo").write_text("MemTotal: 8192 kB\nMemAvailable: 1536000 kB\n")
            (root / "loadavg").write_text("0.125 0.50 1.00 2/10 999\n")
            pressure = root / "pressure"
            pressure.mkdir()
            (pressure / "memory").write_text(
                "some avg10=0 avg60=30 avg300=0 total=1\n"
                "full avg10=0.00 avg60=9.99 avg300=0 total=1\n"
            )
            boot = root / "sys/kernel/random"
            boot.mkdir(parents=True)
            (boot / "boot_id").write_text("a80b80c5-8b0a-4d6a-b279-3612f5c03ef2\n")
            samples = iter((
                "cpu 100 10 20 300 10 5 5 0 0 0\n",
                "cpu 130 10 30 360 20 7 8 2 0 0\n",
            ))
            reader = lambda path: next(samples) if path.name == "stat" else path.read_text()
            expected = {
                "mem_avail_mb": "1500",
                "load1": "0.125",
                "cpu_busy_pct": "39",
                "mem_pressure_pct": "9.99",
                "ncpu": "4",
                "boot_id": "a80b80c5-8b0a-4d6a-b279-3612f5c03ef2",
            }
            with patch.object(HOSTINFO.os, "sched_getaffinity", return_value=set(range(4)), create=True):
                for name, value in expected.items():
                    self.assertEqual(
                        self.capture(name, root, "Linux", reader=reader, sleeper=lambda _: None),
                        value,
                    )

    def test_linux_ncpu_uses_one_when_cpu_count_is_unavailable(self):
        with patch.object(HOSTINFO, "os", SimpleNamespace(cpu_count=lambda: None)):
            self.assertEqual(self.capture("ncpu", Path("."), "Linux"), "1")

    def test_macos_subcommands_use_os_reads_and_fake_commands(self):
        outputs = {
            ("sysctl", "-n", "hw.memsize"): "8589934592\n",
            ("memory_pressure",): "System-wide memory free percentage: 75%\n",
            ("top", "-l", "2", "-n", "0", "-s", "1"): (
                "CPU usage: 5.0% user, 3.0% sys, 92.0% idle\n"
                "CPU usage: 20.0% user, 10.0% sys, 70.0% idle\n"
            ),
            ("sysctl", "-n", "kern.bootsessionuuid"): "a80b80c5-8b0a-4d6a-b279-3612f5c03ef2\n",
        }
        runner, calls = self.fake_runner(outputs)
        expected = {
            "mem_avail_mb": "6144",
            "load1": "0.875",
            "cpu_busy_pct": "30",
            "mem_pressure_pct": "25.0",
            "ncpu": "8",
            "boot_id": "a80b80c5-8b0a-4d6a-b279-3612f5c03ef2",
        }
        with patch.object(HOSTINFO.os, "getloadavg", return_value=(0.875, 1.0, 2.0)), \
             patch.object(HOSTINFO.os, "cpu_count", return_value=8):
            for name, value in expected.items():
                self.assertEqual(
                    self.capture(name, Path("."), "Darwin", command_runner=runner),
                    value,
                )
        self.assertEqual(calls, [
            ("sysctl", "-n", "hw.memsize"),
            ("memory_pressure",),
            ("top", "-l", "2", "-n", "0", "-s", "1"),
            ("memory_pressure",),
            ("sysctl", "-n", "kern.bootsessionuuid"),
        ])


if __name__ == "__main__":
    unittest.main()
