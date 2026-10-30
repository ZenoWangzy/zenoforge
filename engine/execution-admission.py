#!/usr/bin/env python3
"""One execution budget across pipeline lanes; OS locks survive exec/freeze."""
import datetime
from contextlib import ExitStack
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
import uuid


WORKER_UNIT = re.compile(r"^zf-(?:implement-|triage-|recut-|advisor-|web-advisor-provider-|release-|node-owner-|hand-|land-direct-main-|merge-|worktree-cleanup-|maintenance-|gitnexus-)")


def append_scheduler_event(home, message):
    runtime = os.environ.get("MAC_AUTOPILOT_RUNTIME_DIR")
    if not runtime:
        root = Path(os.environ.get("MAC_AUTOPILOT_ROOT", str(home / "checkout")))
        supervisor = Path(os.environ.get("MAC_AUTOPILOT_SUPERVISOR_DIR", str(root / ".scratch-supervisor")))
        runtime = str(supervisor / "autopi")
    path = Path(runtime) / "scheduler.log"
    path.parent.mkdir(parents=True, exist_ok=True)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        os.write(fd, f"[{stamp}] {message}\n".encode())
    finally:
        os.close(fd)


def record_test_violation(command_name, reason):
    command_names = {"node", "pnpm", "bash", "sh", "python", "python3"}
    reasons = {"test-file", "node-test", "pnpm-test"}
    if command_name not in command_names or reason not in reasons:
        raise ValueError("invalid non-product test violation")
    unit = os.environ.get("ZF_PIPELINE_UNIT", "unknown")
    if not re.fullmatch(r"[A-Za-z0-9_.:#-]{1,128}", unit):
        unit = "unknown"
    home = Path(os.environ.get("AGENT_HOME") or os.environ.get("ZF_HOME")
                or Path.home() / ".zenoforge")
    append_scheduler_event(
        home,
        f"event=non-product-test-violation unit={unit} command={command_name} reason={reason}",
    )


def log_admission_decision(home, fields, outcome, reason):
    def value(key):
        field = fields.get(key)
        return "unknown" if field is None else str(field)

    message = (
        f"execution admission decision mode={value('kind')} outcome={outcome} "
        f"MemAvailable_mb={value('available_mb')} load1={value('load1')} "
        f"ceiling={value('ceiling')} held={value('occupied')} "
        f"decision_cap={value('cap')} reason={reason}"
    )
    try:
        append_scheduler_event(home, message)
    except OSError:
        print("execution admission event log: append failed", file=sys.stderr)


class Deferred(Exception):
    def __init__(self, message, **metrics):
        super().__init__(message)
        self.metrics = metrics


class AttemptMetrics:
    """One real RUN decision; never observes check/status/inherited readiness."""
    def __init__(self, mode, home):
        self.home = home
        self.attempt_id = uuid.uuid4().hex
        self.decided = False
        self.released = False
        self.status = None
        self.fields = dict(kind=mode, ceiling=None, cap=None, occupied=None, available_mb=None,
                           load1=None, resource_sampled_at=None, occupancy_sampled_at=None,
                           pid=os.getpid(), start_ticks=None, boot_id=None,
                           producer_hostname=None, source_sha=None, source_blob=None,
                           lease_kind=None, execution_started=None, owner=None, ticket=None,
                           priority=None)
        priority = priority_class()
        if priority:
            self.fields["priority"] = priority
        for key, env_key, pattern in (("owner", "ZF_AGENT_NAME", r"[A-Za-z0-9_.-]{1,128}"),
                                       ("ticket", "ZF_LAND_QUEUE_TICKET", r"[0-9]{20}")):
            value = os.environ.get(env_key, "")
            if re.fullmatch(pattern, value):
                self.fields[key] = value
        try:
            self.fields["start_ticks"] = identity(os.getpid(), Path("/proc"))["start_ticks"]
            self.fields["boot_id"] = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
            # Same kernel hostname identity as existing testcontainers-local leases;
            # never trust an inherited HOSTNAME environment value for attribution.
            host = os.uname().nodename
            if re.fullmatch(r"[A-Za-z0-9_.-]{1,253}", host):
                self.fields["producer_hostname"] = host
            source = Path(__file__).read_bytes()
            self.fields["source_blob"] = hashlib.sha1(b"blob " + str(len(source)).encode() + b"\0" + source).hexdigest()
        except (OSError, ValueError, KeyError, StopIteration, IndexError):
            pass  # Missing provenance remains unknown, never a guessed zero.
        try:
            version = subprocess.run(
                ["git", "-C", str(Path(__file__).resolve().parents[1]), "rev-parse",
                 "HEAD", "HEAD:engine/execution-admission.py"],
                capture_output=True, text=True, timeout=1)
            head, blob = version.stdout.split()
            if (version.returncode == 0 and re.fullmatch(r"[0-9a-f]{40}", head)
                    and blob == self.fields["source_blob"]):
                self.fields["source_sha"] = head
        except (OSError, ValueError, subprocess.SubprocessError):
            pass  # Dirty/unversioned source is still identified by its actual blob.

    def append(self, event, outcome, status, reason):
        try:
            row = dict(self.fields, schema_version=1, record_type="event", event_type=event,
                       ts=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                       event_id=f"{self.attempt_id}:{event}", attempt_id=self.attempt_id,
                       outcome=outcome, status=status, reason=reason,
                       status_scope=("guard-return" if event == "execution-release" else
                                     "exec-launch" if event == "execution-error" else "admission-decision"),
                       lease_released=event == "execution-release")
            # Existing sink owns permissions/flock/append. GNU timeout also bounds
            # its descendants; no admission-gate lock is held at these call sites.
            result = subprocess.run(
                ["timeout", "--signal=TERM", "--kill-after=1s", "2s", "bash", "-c",
                 'source "$1" 2>/dev/null || exit 1; efficiency_metrics_append_rows "$(cat)"',
                 "execution-metrics", str(Path(__file__).with_name("lib.sh"))],
                input=json.dumps(row, allow_nan=False) + "\n", text=True,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=4)
            if result.returncode:
                print("execution metrics: append failed", file=sys.stderr)
        except Exception:
            print("execution metrics: append failed", file=sys.stderr)
        if event == "execution-admission":
            log_admission_decision(self.home, self.fields, outcome, reason)

    def decision(self, outcome, reason):
        if not self.decided:
            self.decided = True
            self.append("execution-admission", outcome, 0 if outcome == "admit" else 75, reason)

    def error(self, error):
        self.fields.update(getattr(error, "metrics", {}))
        reasons = {"operator PAUSE": "operator-pause", "resource floor:": "resource-floor",
                   "global execution cap:": "capacity", "CPU admission:": "cpu-admission", "invalid global execution capacity": "invalid-configuration",
                   "execution lease": "lease-identity"}
        reason = next((value for key, value in reasons.items() if str(error).startswith(key)), type(error).__name__)
        if self.decided:
            # Only inherited exec can fail after approval without an owned guardian.
            # This is not a second decision or a claim that its parent's lease ended.
            self.append("execution-error", "failed", 75, reason)
        else:
            self.decision("defer", reason)


def identity(pid, proc):
    fields = (proc / str(pid) / "stat").read_text().rsplit(")", 1)[1].split()
    cgroup = (proc / str(pid) / "cgroup").read_text().splitlines()
    unified = next(line.split(":", 2)[2] for line in cgroup if line.startswith("0::"))
    return {"pid": int(pid), "start_ticks": fields[19], "ppid": int(fields[1]), "cgroup": unified}


def descendant(pid, owner, proc):
    while pid > 1:
        caller = identity(pid, proc)
        if caller["pid"] == owner["pid"]:
            return caller["start_ticks"] == owner["start_ticks"]
        if caller["ppid"] == pid:
            break
        pid = caller["ppid"]
    return False


def configuration(home):
    values = dict(os.environ)
    keys = {"AGENT_GLOBAL_EXECUTION_CAP", "AGENT_EXECUTION_MIN_MEM_MB", "AGENT_EXECUTION_MAX_LOAD",
            "AGENT_EXECUTION_CPU_TARGET_PERCENT", "AGENT_EXECUTION_MEM_PER_WORKER_MB", "AGENT_EXECUTION_LOAD_PER_WORKER"}
    capacity = home / "capacity.env"
    if capacity.exists():
        for line in capacity.read_text().splitlines():
            key, sep, value = line.removeprefix("export ").partition("=")
            if sep and key in keys:
                values[key] = value.strip().strip("\"'")
    try:
        cap = int(values.get("AGENT_GLOBAL_EXECUTION_CAP", "10"))
        memory = int(values.get("AGENT_EXECUTION_MIN_MEM_MB", "6144"))
        processors = len(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else (os.cpu_count() or 1)
        load = float(values.get("AGENT_EXECUTION_MAX_LOAD", str(processors)))
        target_text = values.get("AGENT_EXECUTION_CPU_TARGET_PERCENT", "")
        target = float(target_text) if target_text else None
        per_worker = int(values.get("AGENT_EXECUTION_MEM_PER_WORKER_MB", "1024"))
        load_per_worker = int(values.get("AGENT_EXECUTION_LOAD_PER_WORKER", "1"))
        if target is not None and (not math.isfinite(target) or not 1 <= target <= 95):
            raise ValueError()
        if not 1 <= cap <= 16 or memory < 1 or not math.isfinite(load) or load <= 0 or per_worker < 1 or load_per_worker < 1:
            raise ValueError()
    except ValueError as exc:
        raise Deferred("invalid global execution capacity") from exc
    return cap, memory, load, target, per_worker, load_per_worker


def admission_cap(ceiling, memory_floor, max_load, per_worker, load_per_worker, sample, held, priority=""):
    """Live admission count replaces the static cap: each held worker already
    consumed its share, so the cap is the held count plus whatever headroom the
    current memory and load sample still shows, never above the ceiling."""
    available = sample.get("available_mb") if isinstance(sample, dict) else None
    load1 = sample.get("load1") if isinstance(sample, dict) else None
    mem_more = max(0, (available - memory_floor) // per_worker) if isinstance(available, int) else 0
    if priority in ("hotfix", "release"):
        # Load headroom must not cap priority work at cap=held (the same veto
        # resources() skips); memory headroom still applies within the ceiling.
        return max(0, min(ceiling, held + mem_more))
    if isinstance(sample, dict) and sample.get("cpu_decision") == "below-target":
        # CPU opt-in: a fresh below-target observation replaces the load1
        # headroom with one incremental worker per observation window, the same
        # admission the post-start interval already throttles; load1 must not
        # reintroduce the veto the CPU sample was opted in to replace.
        cpu_more = 1
    else:
        # opt keeps headroom until twice the configured maximum, where ordinary
        # pipeline is already deferred (#4621 tier order at the gate).
        headroom = max_load * 2 if priority == "opt" else max_load
        cpu_more = (max(0, int(headroom - load1) // load_per_worker)
                    if isinstance(load1, (int, float)) and not isinstance(load1, bool) and math.isfinite(load1) else 0)
    return max(0, min(ceiling, held + min(mem_more, cpu_more)))


def isolated_test_home(home, proc):
    root = os.environ.get("ZF_AGENT_TEST_ROOT", "")
    if proc != Path("/proc") or os.environ.get("ZF_AGENT_TEST_MODE") != "1" or not root or not Path(root).is_dir():
        return False
    try:
        home.resolve().relative_to(Path(root).resolve())
        return True
    except (OSError, RuntimeError, ValueError):
        return False


def paused(home):
    path = home / "PAUSE"
    if not path.exists():
        return False
    try:
        data = json.loads(path.read_text())
        if not isinstance(data, dict):
            return False
        required = ("reason", "issue", "provider", "model", "timestamp")
        if data.get("caller") != "operator" or not all(isinstance(data.get(k), str) and data[k] for k in required):
            return False
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", data["timestamp"]):
            return False
        datetime.datetime.strptime(data["timestamp"], "%Y-%m-%dT%H:%M:%SZ")
        return True
    except (ValueError, TypeError, KeyError):
        return False


def inherited(home, proc):
    slot = os.environ.get("ZF_EXECUTION_SLOT", "")
    if not slot.isdecimal():
        return False
    try:
        owner = json.loads((home / "locks" / f"execution-{slot}.json").read_text())
        current = identity(owner["pid"], proc)
        if current["start_ticks"] != owner["start_ticks"]:
            return False
        with (home / "locks" / f"execution-{slot}.lock").open("r") as handle:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return False  # A stale JSON receipt is not a held execution lease.
            except BlockingIOError:
                pass
        if identity(os.getpid(), proc)["cgroup"] != current["cgroup"]:
            return False
        # An unrelated supervisor in /non-systemd must not borrow another lease.
        return descendant(os.getpid(), current, proc)
    except (OSError, ValueError, KeyError, StopIteration, IndexError):
        pass
    return False


def cpu_sample(home, proc, reset=False):
    """Caller holds execution-admission.lock. No sleeping or second sampler."""
    path = home / "locks" / "execution-cpu.json"
    now = time.monotonic()
    unknown = {"cpu_state": "UNKNOWN", "cpu_percent": None, "cpu_sampled_monotonic": now}
    try:
        previous = json.loads(path.read_text())
        if not isinstance(previous, dict):
            previous = {}
    except (OSError, ValueError):
        previous = {}
    try:
        lines = (proc / "stat").read_text().splitlines()
        values = lines[0].split()
        counters = [int(value) for value in values[1:9]]
        if values[0] != "cpu" or len(counters) != 8 or min(counters) < 0:
            raise ValueError()
        topology = [line.split()[0] for line in lines if re.match(r"cpu[0-9]+ ", line)]
        topology.append(sorted(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else os.cpu_count())
        boot = (proc / "sys/kernel/random/boot_id").read_text().strip()
        if not boot:
            raise ValueError()
        state = dict(unknown, counters=counters, boot_id=boot, topology=topology)
        elapsed = now - previous.get("cpu_sampled_monotonic", now)
        old = previous.get("counters", [])
        valid = (previous.get("boot_id") == boot and previous.get("topology") == topology
                 and len(old) == 8 and 0 <= elapsed <= 15
                 and previous.get("cpu_state") in ("UNKNOWN", "FRESH")
                 and (previous["cpu_state"] != "FRESH" or
                      (isinstance(previous.get("cpu_percent"), (int, float))
                       and math.isfinite(previous["cpu_percent"]) and 0 <= previous["cpu_percent"] <= 100))
                 and all(isinstance(value, int) and current >= value for current, value in zip(counters, old)))
        if valid and not reset and elapsed < 5:
            return previous  # Concurrent check/run calls reuse the original timestamp.
        if valid and not reset:
            delta = [current - value for current, value in zip(counters, old)]
            total = sum(delta)
            if total > 0:
                # guest/guest_nice are already in user/nice; report wait/steal separately.
                state.update(cpu_state="FRESH", cpu_percent=100 * sum(delta[i] for i in (0, 1, 2, 5, 6)) / total,
                             cpu_iowait_percent=100 * delta[4] / total,
                             cpu_steal_percent=100 * delta[7] / total)
    except (OSError, ValueError, TypeError, IndexError):
        state = unknown  # An unreadable/reset sample must not extend an earlier approval.
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(f".{os.getpid()}.tmp")
    temporary.write_text(json.dumps(state, allow_nan=False) + "\n")
    temporary.replace(path)
    return state


def priority_class():
    """LUNA_PRIORITY tiers (#4621): hotfix > opt > ordinary pipeline; release
    joins hotfix at the gate so a release batch never queues behind pipeline
    load (2026-10-29: load 46.5 against a maximum of 12 refused a release)."""
    value = os.environ.get("LUNA_PRIORITY", "")
    return value if value in ("hotfix", "opt", "release") else ""


def resources(proc, memory, load, cpu=None, target=None, priority=""):
    fields = dict(line.split(":", 1) for line in (proc / "meminfo").read_text().splitlines() if ":" in line)
    available = int(fields["MemAvailable"].split()[0]) // 1024
    # Inherited CPU-mode leases can skip load sampling; priority work still
    # samples load for telemetry while ignoring its admission veto.
    priority_bypass = priority in ("hotfix", "release")
    current_load = float((proc / "loadavg").read_text().split()[0]) if load is not None else None
    sampled_at = datetime.datetime.now(datetime.timezone.utc).isoformat()
    result = {"available_mb": available, "load1": current_load if current_load is not None and math.isfinite(current_load) else None,
              "resource_sampled_at": sampled_at}
    fresh = (target is not None and cpu and cpu.get("cpu_state") == "FRESH"
             and 0 <= time.monotonic() - cpu["cpu_sampled_monotonic"] <= 15)
    if target is not None:
        result.update(cpu or {"cpu_state": "UNKNOWN", "cpu_percent": None})
        if not fresh:
            result.update(cpu_state="UNKNOWN", cpu_percent=None)
        result["cpu_decision"] = ("overload" if fresh and cpu["cpu_percent"] > 95 else
                                  "hold" if fresh and cpu["cpu_percent"] >= target else
                                  "below-target" if fresh else "load-fallback")
    # hotfix/release keep only the memory floor; opt yields once pipeline is
    # already deferred and load still exceeds twice the configured maximum.
    load_limit = None if priority_bypass else (load * 2 if priority == "opt" and load is not None else load)
    if available < memory or (load_limit is not None and not fresh and (not math.isfinite(current_load) or current_load >= load_limit)):
        raise Deferred(f"resource floor: available_mb={available} load={current_load}", **result)
    if priority not in ("hotfix", "release") and fresh and cpu["cpu_percent"] >= target:
        raise Deferred(f"CPU admission: percent={cpu['cpu_percent']:.2f} target={target:g}", **result)
    return result


def lifecycle_wait_command(command):
    return (len(command) == 7 and Path(command[0]).name in ("bash", "sh")
            and Path(command[1]).resolve() == Path(__file__).with_name("worktree-lifecycle.sh").resolve()
            and command[2] == "watch" and command[5].isdecimal() and int(command[5]) > 0
            and command[6].isdecimal())


def occupied(proc):
    """Count native execution groups, including frozen."""
    workers = set()
    cleanup_processes = {}
    wait_roots = {}
    for path in proc.iterdir():
        if not path.name.isdecimal():
            continue
        try:
            info = identity(path.name, proc)
            if WORKER_UNIT.match(Path(info["cgroup"]).name):
                workers.add(info["cgroup"])
                if Path(info["cgroup"]).name.startswith("zf-worktree-cleanup-"):
                    cleanup_processes.setdefault(info["cgroup"], []).append(info)
                    args = [os.fsdecode(arg) for arg in (path / "cmdline").read_bytes().split(b"\0") if arg]
                    if lifecycle_wait_command(args):
                        wait_roots.setdefault(info["cgroup"], []).append(info)
        except (FileNotFoundError, ProcessLookupError):
            continue  # A process can exit during the bounded snapshot.
    own = identity(os.getpid(), proc)
    workers.discard(own["cgroup"])
    for group, roots in wait_roots.items():
        try:
            if all(any(descendant(child["pid"], root, proc) for root in roots) for child in cleanup_processes[group]):
                workers.discard(group)  # Only positively established idle watcher subtrees.
        except (FileNotFoundError, ProcessLookupError):
            pass  # A vanished member cannot prove the already-counted group idle.
    return workers


def bound_children():
    for name in ("RELEASE_TEST_JOBS", "RUN_CI_SUITES_JOBS", "NIGHT_TEST_JOBS", "IMPLEMENT_TEST_JOBS", "VITEST_MAX_WORKERS", "VITEST_MAX_FORKS", "VITEST_MAX_THREADS", "CARGO_BUILD_JOBS", "npm_config_workspace_concurrency", "OMP_NUM_THREADS"):
        os.environ[name] = "1"
    os.environ["MAKEFLAGS"] = "-j1"


def admission(mode, command):
    home = Path(os.environ.get("AGENT_HOME", str(Path.home() / ".zenoforge")))
    attempt = None
    if mode in ("run", "run-unit"):
        try:
            attempt = AttemptMetrics(mode, home)
        except Exception:
            print("execution metrics: initialization failed", file=sys.stderr)
    try:
        status = admission_inner(mode, command, attempt)
        if attempt:
            attempt.status = status
        return status
    except (Deferred, OSError, ValueError, KeyError, StopIteration, IndexError) as error:
        if attempt:
            attempt.status = 75
            attempt.error(error)
        raise
    finally:
        if attempt and attempt.released:
            attempt.append("execution-release", "released", attempt.status, "guardian-lease-closed")


def admission_inner(mode, command, attempt=None):
    home = Path(os.environ.get("AGENT_HOME", str(Path.home() / ".zenoforge")))
    proc = Path(os.environ.get("ZF_EXECUTION_PROC_ROOT", "/proc"))
    priority = priority_class()
    if mode == "waiting":
        return 0 if lifecycle_wait_command(command) else 1
    if mode == "paused":
        return 0 if paused(home) else 1
    cap, memory, load, target, per_worker, load_per_worker = configuration(home)
    ceiling = cap
    if attempt:
        attempt.fields["ceiling"] = ceiling
        attempt.fields["cap"] = cap
    if mode == "status":
        print(json.dumps({"source": str(Path(__file__).resolve()), "cap_ceiling": cap, "paused": paused(home), "worker_cgroups": sorted(occupied(proc))}))
        return 0
    if paused(home):
        raise Deferred("operator PAUSE")
    cpu_target = None if priority in ("hotfix", "release") else target
    if mode not in ("check", "resources") and inherited(home, proc):
        # This is the same admitted worker, not a new start. Keep live memory and
        # PAUSE/identity checks; CPU opt-in must not reintroduce the old load veto.
        sample = resources(proc, memory, None if target is not None else load, None, None, priority)
        if attempt:
            attempt.fields.update(sample or {}, lease_kind="inherited")
        if mode in ("run", "run-unit"):
            bound_children()
            if attempt:
                attempt.decision("admit", "inherited-resources-approved")
            os.execvpe(command[0], command, os.environ)
        return 0
    if mode == "inherited":
        return 1
    locks = home / "locks"
    locks.mkdir(parents=True, exist_ok=True)
    with (locks / "execution-admission.lock").open("a+") as gate, ExitStack() as lease_handles:
        fcntl.flock(gate, fcntl.LOCK_EX)
        if paused(home):
            raise Deferred("operator PAUSE")
        cpu = cpu_sample(home, proc) if cpu_target is not None else None
        try:
            sample = resources(proc, memory, load, cpu, cpu_target, priority)
        except Deferred as error:
            if mode == "check":
                fields = dict(kind=mode, ceiling=ceiling, cap=ceiling, occupied=None)
                fields.update(error.metrics)
                reason = "cpu-admission" if str(error).startswith("CPU admission:") else "resource-floor"
                log_admission_decision(home, fields, "defer", reason)
            raise
        if mode == "resources":
            print(json.dumps(sample))
            return 0
        if attempt:
            attempt.fields.update(sample or {})
        start_path = locks / "execution-cpu-start.json"
        if cpu_target is not None:
            # CPU counters can be unreadable independently of the boot identity.
            # UNKNOWN sampling must never cancel a previously consumed interval.
            try:
                boot_id = str(uuid.UUID((proc / "sys/kernel/random/boot_id").read_text().strip()))
            except (OSError, ValueError, AttributeError) as exc:
                raise Deferred("CPU admission: boot identity unreadable") from exc
            try:
                started = json.loads(start_path.read_text())
                if not isinstance(started, dict):
                    raise ValueError("invalid start record")
            except FileNotFoundError:
                started = None
            except (OSError, ValueError) as exc:
                raise Deferred("CPU admission: start interval state unreadable") from exc
            if started is not None:
                try:
                    previous_boot = str(uuid.UUID(started["boot_id"]))
                    stamp = started["monotonic"]
                    if isinstance(stamp, bool) or not isinstance(stamp, (int, float)) or not math.isfinite(stamp) or stamp < 0:
                        raise ValueError("invalid start timestamp")
                except (ValueError, TypeError, KeyError, AttributeError) as exc:
                    raise Deferred("CPU admission: start interval state unreadable") from exc
                age = time.monotonic() - started["monotonic"]
                if previous_boot == boot_id and age < 5:
                    raise Deferred("CPU admission: waiting for post-start observation", **(sample or {}))
        # Isolated test runs must not consume or be blocked by unrelated host workers.
        groups = set() if isolated_test_home(home, proc) else occupied(proc)
        held = []
        candidates = []
        # Scan old slots too when an operator lowers the cap; never lose occupancy.
        files = set(locks.glob("execution-*.lock")) - {locks / "execution-admission.lock"}
        files.update(locks / f"execution-{i}.lock" for i in range(ceiling))
        for path in sorted(files):
            slot = path.stem.removeprefix("execution-")
            if not slot.isdecimal():
                continue
            handle = lease_handles.enter_context(path.open("a+"))
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                candidates.append((int(slot), handle))
            except BlockingIOError:
                handle.close()
                held.append(int(slot))
                try:
                    owner = json.loads(path.with_suffix(".json").read_text())
                    live = identity(owner["pid"], proc)
                    if live["start_ticks"] != owner["start_ticks"]:
                        raise Deferred("execution lease PID identity changed")
                    groups.discard(live["cgroup"])
                except (OSError, ValueError, KeyError, StopIteration, IndexError) as exc:
                    raise Deferred("execution lease identity unreadable") from exc
        total = len(held) + len(groups)
        decision_cap = admission_cap(ceiling, memory, load, per_worker, load_per_worker, sample, total, priority)
        if attempt:
            attempt.fields["cap"] = decision_cap
            attempt.fields["occupied"] = total
            attempt.fields["occupancy_sampled_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        if mode == "check":
            log_admission_decision(
                home,
                dict(kind=mode, available_mb=sample.get("available_mb"), load1=sample.get("load1"),
                     ceiling=ceiling, occupied=total, cap=decision_cap),
                "defer" if total >= decision_cap else "admit", "capacity-check")
        if total >= decision_cap:
            raise Deferred(f"global execution cap: active={total} cap={decision_cap}")
        if mode == "check":
            return 0
        slot, handle = next((i, h) for i, h in candidates if i < decision_cap)
        record = identity(os.getpid(), proc)
        destination = locks / f"execution-{slot}.json"
        temporary = destination.with_suffix(f".{os.getpid()}.tmp")
        temporary.write_text(json.dumps(record) + "\n")
        temporary.chmod(0o600)
        temporary.replace(destination)
        # Guardian holds the slot until synchronous worker cleanup finishes.
        fd = fcntl.fcntl(handle.fileno(), fcntl.F_DUPFD, 64)
        os.set_inheritable(fd, True)
        if attempt:
            attempt.fields["lease_kind"] = "owned"
        os.environ["ZF_EXECUTION_SLOT"] = str(slot)
        if cpu_target is not None:
            # Only a newly acquired lease consumes the interval. Prime counters at
            # that grant so the next launch cannot reuse a pre-start CPU window.
            baseline = cpu_sample(home, proc, reset=True)
            temporary = start_path.with_suffix(f".{os.getpid()}.tmp")
            temporary.write_text(json.dumps({"boot_id": boot_id,
                                             "monotonic": baseline["cpu_sampled_monotonic"]}) + "\n")
            temporary.replace(start_path)
        bound_children()
    # Preserve the worker shell's PGID=PID stop contract. Keep GNU setsid waiting
    # for its child so a scope cannot outlive its execution lease.
    try:
        if paused(home):
            raise Deferred("operator PAUSE")
        if mode == "run-unit" and Path(command[0]).name == "setsid" and not any(arg in ("-w", "--wait") for arg in command[1:]):
            command = [command[0], "--wait", *command[1:]]
        child = subprocess.Popen(command, env=os.environ, start_new_session=(mode == "run-unit"))
        def forward(signum, _frame):
            if child.poll() is None:
                child.send_signal(signum)
        previous = {sig: signal.signal(sig, forward) for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)}
        try:
            if attempt:
                attempt.fields["execution_started"] = True
                attempt.decision("admit", "capacity-and-resources-approved")
            status = child.wait()
        finally:
            for sig, handler in previous.items():
                signal.signal(sig, handler)
        return status if status >= 0 else 128 - status
    finally:
        # The guardian's duplicate is the last owned lease handle after ExitStack.
        # Observe release only after child cleanup and actual kernel-lock close.
        os.close(fd)
        if attempt:
            attempt.released = True


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "check"
    command = sys.argv[2:]
    if command[:1] == ["--"]:
        command = command[1:]
    if mode == "record-test-violation":
        if len(command) != 2:
            sys.exit(64)
        try:
            record_test_violation(*command)
        except (OSError, ValueError) as error:
            print(f"execution metrics: could not record non-product test violation: {type(error).__name__}", file=sys.stderr)
            sys.exit(1)
        sys.exit(0)
    if mode not in ("check", "run", "run-unit", "inherited", "status", "paused", "waiting", "resources") or (mode in ("run", "run-unit") and not command):
        sys.exit(64)
    try:
        sys.exit(admission(mode, command))
    except (Deferred, OSError, ValueError, KeyError, StopIteration, IndexError) as error:
        # Never log command argv, environment contents, or credential-bearing files.
        detail = str(error) if isinstance(error, Deferred) else type(error).__name__
        print(f"execution admission deferred: {detail}", file=sys.stderr)
        sys.exit(75)
