import ctypes
import os
import platform
import re
import subprocess
import sys
import time
from pathlib import Path


class ProcBsdInfo(ctypes.Structure):
    _fields_ = [
        ("pbi_flags", ctypes.c_uint32),
        ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_uint32),
        ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32),
        ("pbi_uid", ctypes.c_uint32),
        ("pbi_gid", ctypes.c_uint32),
        ("pbi_ruid", ctypes.c_uint32),
        ("pbi_rgid", ctypes.c_uint32),
        ("pbi_svuid", ctypes.c_uint32),
        ("pbi_svgid", ctypes.c_uint32),
        ("rfu_1", ctypes.c_uint32),
        ("pbi_comm", ctypes.c_char * 16),
        ("pbi_name", ctypes.c_char * 32),
        ("pbi_nfiles", ctypes.c_uint32),
        ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32),
        ("e_tdev", ctypes.c_uint32),
        ("e_tpgid", ctypes.c_uint32),
        ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64),
        ("pbi_start_tvusec", ctypes.c_uint64),
    ]


def darwin_process_info(pid):
    info = ProcBsdInfo()
    reader = ctypes.CDLL("libproc.dylib").proc_pidinfo
    reader.argtypes = [
        ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int,
    ]
    reader.restype = ctypes.c_int
    size = ctypes.sizeof(info)
    if reader(pid, 3, 0, ctypes.byref(info), size) != size:
        raise ProcessLookupError(pid)
    return {
        "pid": info.pbi_pid,
        "ppid": info.pbi_ppid,
        "pgid": info.pbi_pgid,
        "start_id": info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec,
    }


def cpu_totals(stat_text):
    fields = stat_text.splitlines()[0].split()
    counters = [int(value) for value in fields[1:]]
    if fields[0] != "cpu" or len(counters) < 8:
        raise ValueError("invalid /proc/stat cpu row")
    busy = sum(counters[index] for index in (0, 1, 2, 5, 6, 7))
    idle = counters[3] + counters[4]
    return busy, idle


def command_output(command_runner, command):
    result = command_runner(command, capture_output=True, text=True, check=False)
    if result.returncode:
        raise RuntimeError(f"command failed: {command[0]}")
    return result.stdout


def memory_free_pct(command_runner):
    output = command_output(command_runner, ["memory_pressure"])
    match = re.search(r"System-wide memory free percentage: *([0-9]+([.][0-9]+)?)%", output)
    if match is None:
        raise ValueError("memory free percentage is missing")
    return float(match.group(1))


def mac_cpu_busy_pct(command_runner):
    output = command_output(command_runner, ["top", "-l", "2", "-n", "0", "-s", "1"])
    rows = re.findall(
        r"CPU usage: [0-9]+(?:[.][0-9]+)?% user, [0-9]+(?:[.][0-9]+)?% sys, ([0-9]+(?:[.][0-9]+)?)% idle",
        output,
    )
    if not rows:
        raise ValueError("CPU usage is missing")
    return int(100 - float(rows[-1]))


class HostInfo:
    def __init__(self, proc_root=None, system=None, command_runner=None, reader=None, sleeper=None):
        self.proc_root = Path("/proc") if proc_root is None else Path(proc_root)
        self.system = platform.system() if system is None else system
        self.command_runner = subprocess.run if command_runner is None else command_runner
        self.reader = Path.read_text if reader is None else reader
        self.sleeper = time.sleep if sleeper is None else sleeper

    def mem_avail_mb(self):
        if self.system == "Linux":
            for line in self.reader(self.proc_root / "meminfo").splitlines():
                if line.startswith("MemAvailable:"):
                    return int(line.split()[1]) // 1024
            raise ValueError("MemAvailable is missing")
        if self.system == "Darwin":
            total = int(command_output(self.command_runner, ["sysctl", "-n", "hw.memsize"]).strip())
            return int(total * memory_free_pct(self.command_runner) / 100 / (1024 * 1024))
        raise ValueError(f"unsupported platform: {self.system}")

    def load1(self):
        if self.system == "Linux":
            return float(self.reader(self.proc_root / "loadavg").split()[0])
        if self.system == "Darwin":
            return os.getloadavg()[0]
        raise ValueError(f"unsupported platform: {self.system}")

    def cpu_busy_pct(self):
        if self.system == "Linux":
            path = self.proc_root / "stat"
            first_busy, first_idle = cpu_totals(self.reader(path))
            self.sleeper(2)
            last_busy, last_idle = cpu_totals(self.reader(path))
            busy = last_busy - first_busy
            idle = last_idle - first_idle
            return 100 * busy // (busy + idle + 1)
        if self.system == "Darwin":
            return mac_cpu_busy_pct(self.command_runner)
        raise ValueError(f"unsupported platform: {self.system}")

    def mem_pressure_pct(self):
        if self.system == "Linux":
            rows = self.reader(self.proc_root / "pressure/memory").splitlines()
            full = next(row for row in rows if row.startswith("full "))
            return float(next(field[6:] for field in full.split() if field.startswith("avg60=")))
        if self.system == "Darwin":
            return 100.0 - memory_free_pct(self.command_runner)
        raise ValueError(f"unsupported platform: {self.system}")

    def ncpu(self):
        if self.system == "Linux" and hasattr(os, "sched_getaffinity"):
            return len(os.sched_getaffinity(0))
        if self.system in ("Linux", "Darwin"):
            return os.cpu_count() or 1
        raise ValueError(f"unsupported platform: {self.system}")

    def boot_id(self):
        if self.system == "Linux":
            return self.reader(self.proc_root / "sys/kernel/random/boot_id").strip()
        if self.system == "Darwin":
            return command_output(
                self.command_runner,
                ["sysctl", "-n", "kern.bootsessionuuid"],
            ).strip()
        raise ValueError(f"unsupported platform: {self.system}")

    def process_info(self, pid):
        if self.system != "Darwin":
            raise ValueError(f"unsupported platform: {self.system}")
        return darwin_process_info(pid)


def main(argv=None, proc_root=None, system=None, command_runner=None, reader=None, sleeper=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1:
        raise SystemExit("usage: hostinfo.py <subcommand>")
    host = HostInfo(proc_root, system, command_runner, reader, sleeper)
    commands = {
        "mem_avail_mb": host.mem_avail_mb,
        "load1": host.load1,
        "cpu_busy_pct": host.cpu_busy_pct,
        "mem_pressure_pct": host.mem_pressure_pct,
        "ncpu": host.ncpu,
        "boot_id": host.boot_id,
    }
    try:
        value = commands[argv[0]]()
    except KeyError as error:
        raise SystemExit(f"unknown subcommand: {argv[0]}") from error
    print(value)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
