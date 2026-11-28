import datetime
import fcntl
import importlib.util
import json
import math
import os
import time
from pathlib import Path

hostinfo_spec = importlib.util.spec_from_file_location("hostinfo", Path(__file__).with_name("hostinfo.py"))
hostinfo = importlib.util.module_from_spec(hostinfo_spec)
hostinfo_spec.loader.exec_module(hostinfo)


def memory_full_avg60(proc, platform=None):
    try:
        if platform and platform.system != "Linux":
            return platform.host.mem_pressure_pct()
        line = next(row for row in (proc / "pressure/memory").read_text().splitlines() if row.startswith("full "))
        return float(line.split("avg60=")[1].split()[0])
    except (OSError, RuntimeError, StopIteration, IndexError, ValueError):
        return None


def resources(proc, memory, load, cpu=None, target=None, priority="", admitted=False, platform=None,
              memory_pressure=None, memory_limit=10, opt_load_factor=4 / 3, deferred=RuntimeError):
    fixture = os.environ.get("AGENT_DISPATCH_MEMINFO_FILE")
    if platform and platform.system != "Linux" and not fixture:
        available = platform.host.mem_avail_mb()
    else:
        source = Path(fixture) if fixture else proc / "meminfo"
        fields = dict(line.split(":", 1) for line in source.read_text().splitlines() if ":" in line)
        available = int(fields["MemAvailable"].split()[0]) // 1024
    priority_bypass = priority in ("hotfix", "release")
    if load is None:
        current_load = None
    elif platform and platform.system != "Linux":
        current_load = platform.host.load1()
    else:
        current_load = float((proc / "loadavg").read_text().split()[0])
    sampled_at = datetime.datetime.now(datetime.timezone.utc).isoformat()
    result = {"available_mb": available, "load1": current_load if current_load is not None and math.isfinite(current_load) else None,
              "resource_sampled_at": sampled_at}
    pressure = (memory_pressure or memory_full_avg60)(proc, platform)
    if pressure is not None:
        result["memory_full_avg60"] = pressure
    fresh = (target is not None and cpu and cpu.get("cpu_state") == "FRESH"
             and 0 <= time.monotonic() - cpu["cpu_sampled_monotonic"] <= 15)
    if target is not None:
        result.update(cpu or {"cpu_state": "UNKNOWN", "cpu_percent": None})
        if not fresh:
            result.update(cpu_state="UNKNOWN", cpu_percent=None)
        result["cpu_decision"] = ("overload" if fresh and cpu["cpu_percent"] > 95 else
                                  "hold" if fresh and cpu["cpu_percent"] >= target else
                                  "below-target" if fresh else "load-fallback")
    load_limit = None if priority_bypass else (load * opt_load_factor if priority == "opt" and load is not None else load)
    if available < memory or (load_limit is not None and not fresh and (not math.isfinite(current_load) or current_load >= load_limit)):
        raise deferred(f"resource floor: available_mb={available} load={current_load}", **result)
    if not priority_bypass and not admitted and pressure is not None and pressure >= memory_limit:
        raise deferred(f"resource floor: memory_full_avg60={pressure}", **result)
    if priority not in ("hotfix", "release") and fresh and cpu["cpu_percent"] >= target:
        raise deferred(f"CPU admission: percent={cpu['cpu_percent']:.2f} target={target:g}", **result)
    return result


class Platform:
    def __init__(self, proc=None, system=None, host=None, identity_reader=None, occupied_reader=None,
                 cpu_sampler=None, resource_sampler=None, worker_unit=None, deferred=RuntimeError):
        override = os.environ.get("ZF_EXECUTION_PROC_ROOT")
        self.proc = Path(override or proc or "/proc")
        if override:
            self.system = "Linux"
            self.host = hostinfo.HostInfo(proc_root=self.proc, system="Linux")
        else:
            self.host = host or hostinfo.HostInfo(proc_root=self.proc, system=system)
            self.system = system or self.host.system
        self.identity_reader = identity_reader
        self.occupied_reader = occupied_reader
        self.cpu_sampler = cpu_sampler
        self.resource_sampler = resource_sampler
        self.worker_unit = worker_unit
        self.deferred = deferred

    def identity(self, pid):
        if self.system == "Linux":
            return self.identity_reader(pid, self.proc)
        return self.host.process_info(pid)

    def occupied(self, home):
        if self.system == "Linux":
            return self.occupied_reader(self.proc)
        root = (home or Path(os.environ.get("AGENT_HOME", str(Path.home() / ".zenoforge")))) / "run" / "units"
        workers = {}
        try:
            for path in root.iterdir():
                if not self.worker_unit.match(path.name) or path.name == os.environ.get("ZF_PIPELINE_UNIT"):
                    continue
                try:
                    with (path / "lock").open("r") as handle:
                        fcntl.flock(handle, fcntl.LOCK_SH | fcntl.LOCK_NB)
                except BlockingIOError:
                    pass
                except FileNotFoundError:
                    continue
                else:
                    continue
                try:
                    pgid = json.loads((path / "meta.json").read_text()).get("pgid")
                    if isinstance(pgid, bool) or not isinstance(pgid, int) or pgid < 1:
                        pgid = None
                except (OSError, ValueError, TypeError, AttributeError):
                    pgid = None
                workers[path.name] = pgid
        except FileNotFoundError:
            return workers
        except OSError as exc:
            raise self.deferred("execution unit ledger unreadable") from exc
        return workers

    def cpu_sample(self, home, reset=False):
        if self.system == "Linux":
            return self.cpu_sampler(home, self.proc, reset)
        now = time.monotonic()
        try:
            value = self.host.cpu_busy_pct()
            valid = isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and 0 <= value <= 100
            return {"cpu_state": "FRESH" if valid else "UNKNOWN", "cpu_percent": value if valid else None,
                    "cpu_sampled_monotonic": now}
        except (OSError, RuntimeError, ValueError, TypeError, IndexError):
            return {"cpu_state": "UNKNOWN", "cpu_percent": None, "cpu_sampled_monotonic": now}

    def resources(self, memory, load, cpu=None, target=None, priority="", admitted=False):
        if self.system == "Linux":
            return self.resource_sampler(self.proc, memory, load, cpu, target, priority, admitted)
        try:
            return self.resource_sampler(self.proc, memory, load, cpu, target, priority, admitted, self)
        except (OSError, RuntimeError, ValueError) as exc:
            raise self.deferred("resource floor: host sample unavailable") from exc

    def ncpu(self):
        return self.host.ncpu()

    def boot_id(self):
        return self.host.boot_id()
