"""Attribute the host's process creation rate to live process roots."""
import json, os, re, time
from pathlib import Path

USER_MANAGER = re.compile(r"user@[^/]+\.service\Z")


def _cgroup(raw):
    for line in raw.splitlines():
        try:
            _, _, path = line.split(":", 2)
        except ValueError:
            continue
        parts = [part for part in path.strip("/").split("/") if part]
        manager_at = next((i for i, part in enumerate(parts) if USER_MANAGER.fullmatch(part)), None)
        units = parts[manager_at + 1:] if manager_at is not None else parts
        unit = next((part for part in reversed(units) if part.endswith(".service")), None)
        if manager_at is not None or unit is not None:
            manager = parts[manager_at] if manager_at is not None else None
            return manager, unit
    return None, None


def _processes(proc_root):
    processes, pids = {}, set()
    for entry in os.scandir(proc_root):
        if not entry.name.isdigit():
            continue
        pid = int(entry.name)
        pids.add(pid)
        try:
            raw = Path(entry.path, "stat").read_text()
            end = raw.rfind(")")
            start = raw.find("(")
            if start < 0 or end <= start:
                continue
            fields = raw[end + 2:].split()
            if len(fields) < 2:
                continue
            comm = raw[start + 1:end]
            manager, unit = _cgroup(Path(entry.path, "cgroup").read_text())
            processes[pid] = {"ppid": int(fields[1]), "comm": comm, "manager": manager, "unit": unit}
        except (OSError, IndexError, ValueError):
            continue
    return processes, pids


def _root(pid, processes):
    root, seen = pid, set()
    process = processes[pid]
    scope = process["manager"] or process["unit"]
    cursor = pid
    while scope and cursor not in seen:
        seen.add(cursor)
        parent_pid = processes[cursor]["ppid"]
        parent = processes.get(parent_pid)
        if not parent or parent["comm"] == "systemd":
            break
        parent_scope = parent["manager"] or parent["unit"]
        if parent_scope != scope:
            break
        root = cursor = parent_pid
    return root


def sample(node_health_path, now=None):
    """Return the highest attributed root rate, its detail, and the rate used for status."""
    proc_root = os.environ.get("NODE_HEALTH_PROC_ROOT", "/proc")
    try:
        with open(os.path.join(proc_root, "stat")) as stats:
            total = next(int(line.split()[1]) for line in stats if line.startswith("processes "))
        processes, pids = _processes(proc_root)
    except (OSError, StopIteration, ValueError):
        return None, "", None

    sampled_at = time.time() if now is None else float(now)
    state_path = Path(os.path.abspath(node_health_path)).parent / "node-health-fork-rate-state.json"
    try:
        previous = json.loads(state_path.read_text())
        previous_at = float(previous["sampled_at"])
        previous_total = int(previous["processes"])
        previous_pids = set(map(int, previous["pids"]))
    except (OSError, KeyError, TypeError, ValueError):
        previous_at = previous_total = None
        previous_pids = set()

    temporary = None
    try:
        state_path.parent.mkdir(parents=True, exist_ok=True)
        temporary = state_path.with_name(state_path.name + f".{os.getpid()}.tmp")
        temporary.write_text(json.dumps({"sampled_at": sampled_at, "processes": total, "pids": sorted(pids)}))
        os.replace(temporary, state_path)
    except OSError:
        return None, "", None
    finally:
        if temporary is not None:
            try:
                temporary.unlink()
            except OSError:
                pass
    if previous_at is None:
        return None, "", None
    elapsed, delta = sampled_at - previous_at, total - previous_total
    if not 10 < elapsed <= 600 or delta < 0:
        return None, "", None
    if delta == 0:
        return 0.0, "", 0.0

    roots = {}
    for pid in pids - previous_pids:
        process = processes.get(pid)
        if process is None:
            continue
        root_pid = _root(pid, processes)
        root = processes[root_pid]
        unit = root["unit"] or process["unit"]
        key = (unit, root_pid) if unit else ("non-systemd",)
        group = roots.setdefault(key, {"count": 0, "unit": unit or "non-systemd", "roots": {}})
        group["count"] += 1
        label = (root["comm"], root_pid)
        group["roots"][label] = group["roots"].get(label, 0) + 1
    total_rate = delta / elapsed
    attributed = sum(group["count"] for group in roots.values())
    unattributed = max(0, delta - attributed)
    unattributed_rate = unattributed / elapsed
    rates = []
    for group in roots.values():
        comm, pid = min(group["roots"], key=lambda label: (-group["roots"][label], label[1]))
        rate = group["count"] / elapsed
        rates.append((rate, group["unit"], comm, pid))
    rates.sort(key=lambda row: (-row[0], row[1], row[3]))
    details = [f"{unit} ({comm}, {pid}): {rate:.1f}/s" for rate, unit, comm, pid in rates if rate > 20]
    details += [f"total_rate: {total_rate:.1f}/s", f"unattributed: {unattributed_rate:.1f}/s ({unattributed / delta:.0%})"]
    return rates[0][0] if rates else 0.0, "; ".join(details), max(rates[0][0] if rates else 0.0, unattributed_rate)
