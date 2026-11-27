#!/usr/bin/env python3
import errno
import fcntl
import fnmatch
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import uuid
from pathlib import Path


def units_root():
    return Path(os.environ.get("AGENT_HOME", Path.home() / ".zenoforge-agent")) / "run" / "units"


def unit_key(name):
    for suffix in (".service", ".scope", ".timer"):
        if name.endswith(suffix):
            name = name[:-len(suffix)]
            break
    if not name or name in {".", ".."} or "/" in name or "\\" in name:
        raise ValueError("invalid unit name")
    return name


def active(name):
    try:
        fd = os.open(units_root() / unit_key(name) / "lock", os.O_RDWR)
    except FileNotFoundError:
        return False
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
        except OSError as error:
            if error.errno in {errno.EACCES, errno.EAGAIN}:
                return True
            raise
        fcntl.flock(fd, fcntl.LOCK_UN)
        return False
    finally:
        os.close(fd)


def read_record(directory):
    try:
        return json.loads((directory / "meta.json").read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def write_record(path, record):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(record, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def unit_file(name):
    key = unit_key(name)
    suffix = next((item for item in (".service", ".scope", ".timer") if name.endswith(item)), ".service")
    filename = key + suffix
    configured = Path(os.environ.get("ZF_SYSTEMD_UNIT_DIR", Path.home() / ".config" / "systemd" / "user"))
    for root in (configured, Path(__file__).resolve().parent.parent / "systemd"):
        path = root / filename
        if path.is_file():
            return path
    return None


def description(name, record):
    if record.get("Description"):
        return str(record["Description"])
    path = unit_file(name)
    section = ""
    if path:
        for raw in path.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if line.startswith("[") and line.endswith("]"):
                section = line[1:-1]
            elif section == "Unit" and line.startswith("Description="):
                return line.partition("=")[2]
    return ""


def display_name(name, record):
    if name.endswith((".service", ".scope", ".timer")):
        return name
    return name + "." + record.get("UnitType", "service")


def runtime_seconds(value):
    if not value:
        return None
    for suffix, multiplier in (("ms", .001), ("min", 60), ("h", 3600), ("s", 1)):
        if value.endswith(suffix):
            return float(value[:-len(suffix)]) * multiplier
    return float(value)


def status_code(value):
    return value if value >= 0 else min(255, 128 - value)


def parse_run_args(arguments):
    values = {"collect": False, "scope": False, "wait": False, "pipe": False, "properties": {}, "environment": {}}
    index = 0
    while index < len(arguments):
        arg = arguments[index]
        index += 1
        if arg == "--":
            return values, arguments[index:]
        if arg in {"--collect", "--scope", "--wait", "--pipe"}:
            values[arg[2:]] = True
        elif arg in {"--quiet", "--user"}:
            pass
        elif arg == "--unit":
            values["unit"] = arguments[index]
            index += 1
        elif arg.startswith("--unit="):
            values["unit"] = arg.split("=", 1)[1]
        elif arg in {"-p", "--property"}:
            item = arguments[index]
            index += 1
            key, _, value = item.partition("=")
            values["properties"][key] = value
        elif arg.startswith("--property="):
            key, _, value = arg.split("=", 1)[1].partition("=")
            values["properties"][key] = value
        elif arg == "-E":
            key, value = arguments[index].split("=", 1)
            values["environment"][key] = value
            index += 1
        elif arg.startswith("-E") and "=" in arg[2:]:
            key, value = arg[2:].split("=", 1)
            values["environment"][key] = value
        elif arg.startswith(("--slice=", "--description=")):
            pass
        else:
            raise ValueError("unsupported systemd-run option: " + arg)
    raise ValueError("systemd-run requires a command after --")


def start_unit(arguments):
    values, command = parse_run_args(arguments)
    if not command:
        raise ValueError("systemd-run requires a command after --")
    unit = values.get("unit", "run-" + uuid.uuid4().hex)
    if values["scope"] and not unit.endswith(".scope"):
        unit += ".scope"
    key = unit_key(unit)
    directory = units_root() / key
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(directory, 0o700)
    lock_fd = os.open(directory / "lock", os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as error:
        os.close(lock_fd)
        if error.errno in {errno.EACCES, errno.EAGAIN}:
            return 1
        raise
    properties = values["properties"]
    record = {
        "Unit": key, "UnitType": "scope" if values["scope"] else "service",
        "InvocationID": uuid.uuid4().hex, "MainPID": 0, "pgid": 0,
        "MonitorPID": 0, "ActiveState": "active", "SubState": "running",
        "Result": "success", "ExecMainCode": "exited", "ExecMainStatus": 0,
        "ActiveEnterTimestamp": time.strftime("%a %Y-%m-%d %H:%M:%S UTC", time.gmtime()),
        "LastTriggerUSec": "", "Properties": properties,
    }
    record_path = directory / "meta.json"
    write_record(record_path, record)
    config = {
        "command": command, "collect": values["collect"], "wait": values["wait"],
        "pipe": values["pipe"], "runtime": properties.get("RuntimeMaxSec"),
        "cwd": properties.get("WorkingDirectory"), "environment": values["environment"],
    }
    if values["scope"]:
        try:
            process = subprocess.Popen(
                command, cwd=config["cwd"], env={**os.environ, **config["environment"]},
                start_new_session=True, pass_fds=(lock_fd,),
            )
        except OSError as error:
            os.close(lock_fd)
            print(str(error), file=sys.stderr)
            return 1
        record.update(MainPID=process.pid, pgid=process.pid)
        write_record(record_path, record)
        result = process.wait()
        finish_record(record_path, result)
        os.close(lock_fd)
        if values["collect"]:
            collect_unit(directory)
        return status_code(result)
    config_path = directory / "config.json"
    write_record(config_path, config)
    try:
        monitor = subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "_monitor", str(directory), str(lock_fd)],
            pass_fds=(lock_fd,), start_new_session=True, stdin=subprocess.DEVNULL,
            stdout=None if values["wait"] and values["pipe"] else subprocess.DEVNULL,
            stderr=None if values["wait"] and values["pipe"] else subprocess.DEVNULL,
        )
    except OSError as error:
        os.close(lock_fd)
        print(str(error), file=sys.stderr)
        return 1
    os.close(lock_fd)
    for _ in range(500):
        current = read_record(directory)
        if current.get("MainPID") or current.get("StartupError"):
            break
        if monitor.poll() is not None:
            break
        time.sleep(.01)
    if values["collect"] and not directory.exists() and monitor.poll() is not None:
        return status_code(monitor.wait()) if values["wait"] else 0
    if current.get("StartupError") or not current.get("MainPID"):
        print(current.get("StartupError", "unit failed to start"), file=sys.stderr)
        return 1
    return status_code(monitor.wait()) if values["wait"] else 0


def finish_record(path, result, timed_out=False):
    record = read_record(path.parent)
    record.update(
        ExecMainCode="killed" if result < 0 else "exited",
        ExecMainStatus=status_code(result),
        Result="timeout" if timed_out else ("signal" if result < 0 else ("success" if result == 0 else "exit-code")),
        ActiveState="inactive", SubState="dead",
    )
    write_record(path, record)


def monitor_unit(directory, lock_fd):
    record_path = directory / "meta.json"
    output = None
    config = {}
    result = 1
    try:
        config = json.loads((directory / "config.json").read_text(encoding="utf-8"))
        record = read_record(directory)
        record["MonitorPID"] = os.getpid()
        write_record(record_path, record)
        log_path = Path(os.environ.get("AGENT_HOME", Path.home() / ".zenoforge-agent")) / "logs" / "units" / (directory.name + ".log")
        log_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        output = open(log_path, "ab", buffering=0)
        try:
            process = subprocess.Popen(
                config["command"], cwd=config["cwd"],
                env={**os.environ, **config["environment"]}, start_new_session=True,
                pass_fds=(lock_fd,),
                stdout=None if config["wait"] and config["pipe"] else output,
                stderr=None if config["wait"] and config["pipe"] else subprocess.STDOUT,
            )
        except OSError as error:
            record = read_record(directory)
            record.update(StartupError=str(error), ActiveState="inactive", SubState="dead")
            write_record(record_path, record)
            return 1
        record = read_record(directory)
        record.update(MainPID=process.pid, pgid=process.pid)
        write_record(record_path, record)
        timed_out = False
        try:
            result = process.wait(timeout=runtime_seconds(config["runtime"]))
        except subprocess.TimeoutExpired:
            timed_out = True
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                result = process.wait(timeout=float(os.environ.get("ZF_STOP_GRACE_SEC", "30")))
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                result = process.wait()
        finish_record(record_path, result, timed_out)
    except (OSError, ValueError, KeyError) as error:
        record = read_record(directory)
        record.update(StartupError=str(error), ActiveState="inactive", SubState="dead")
        write_record(record_path, record)
    finally:
        if output is not None:
            output.close()
        try:
            os.close(lock_fd)
        except OSError:
            pass
    if config.get("collect"):
        collect_unit(directory)
    return status_code(result)


def collect_unit(directory):
    lock = directory / "lock"
    while directory.is_dir():
        try:
            fd = os.open(lock, os.O_RDWR)
        except FileNotFoundError:
            return
        try:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError as error:
                if error.errno not in {errno.EACCES, errno.EAGAIN}:
                    raise
                time.sleep(.05)
                continue
            for path in directory.iterdir():
                path.unlink()
            directory.rmdir()
            return
        finally:
            os.close(fd)


def journalctl(arguments):
    if "-k" in arguments:
        return 1
    unit = count = since = pattern = None
    output = "cat"
    index = 0
    while index < len(arguments):
        arg = arguments[index]
        index += 1
        if arg in {"-u", "--unit", "-n", "--lines", "--since", "-o", "--output", "--grep"}:
            value = arguments[index]
            index += 1
            if arg in {"-u", "--unit"}:
                unit = value
            elif arg in {"-n", "--lines"}:
                count = int(value)
            elif arg == "--since":
                since = value
            elif arg in {"-o", "--output"}:
                output = value
            else:
                pattern = value
        elif arg.startswith("--unit="):
            unit = arg.split("=", 1)[1]
        elif arg.startswith(("--lines=", "-n")):
            count = int(arg.split("=", 1)[1] if "=" in arg else arg[2:])
        elif arg.startswith("--since="):
            since = arg.split("=", 1)[1]
        elif arg.startswith("--output="):
            output = arg.split("=", 1)[1]
        elif arg.startswith("--grep="):
            pattern = arg.split("=", 1)[1]
    if unit is None:
        return 1
    path = Path(os.environ.get("AGENT_HOME", Path.home() / ".zenoforge-agent")) / "logs" / "units" / (unit_key(unit) + ".log")
    if not path.is_file():
        return 0
    modified = path.stat().st_mtime
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    if since and modified < float(since[1:] if since.startswith("@") else since):
        lines = []
    if pattern is not None:
        try:
            expression = re.compile(pattern)
        except re.error as error:
            print(str(error), file=sys.stderr)
            return 2
        lines = [line for line in lines if expression.search(line)]
    if count is not None:
        lines = [] if count == 0 else lines[-count:]
    if output not in {"cat", "short-unix"}:
        return 2
    for line in lines:
        print(f"{modified:.6f} {line}" if output == "short-unix" else line)
    return 0


def timer_mode():
    return os.environ.get("ZF_TIMERS", "launchd" if sys.platform == "darwin" else "systemd")


def unitgen(command):
    path = Path(__file__).resolve().parent.parent / "unitgen.py"
    try:
        return subprocess.run([sys.executable, str(path), command], check=False).returncode
    except OSError as error:
        print(str(error), file=sys.stderr)
        return 2


def reload_timers():
    if timer_mode() != "launchd":
        return 0
    result = unitgen("plist")
    return result if result else unitgen("load")


def launchctl_call(arguments):
    try:
        return subprocess.run(["launchctl", *arguments], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False).returncode
    except OSError as error:
        print(str(error), file=sys.stderr)
        return 2


def systemctl(arguments):
    args = [arg for arg in arguments if arg not in {"--user", "--system"}]
    if not args:
        return 1
    verb, rest = args[0], args[1:]
    units = [arg for arg in rest if not arg.startswith("-")]
    unit = units[-1] if units else None
    if verb == "is-active":
        value = active(unit) if unit else False
        if "--quiet" not in rest:
            print("active" if value else "inactive")
        return 0 if value else (1 if not unit else 3)
    if verb == "show":
        properties, unit = [], None
        value_only = "--value" in rest
        index = 0
        while index < len(rest):
            arg = rest[index]
            index += 1
            if arg in {"-p", "--property"}:
                properties.append(rest[index])
                index += 1
            elif arg.startswith("--property="):
                properties.append(arg.split("=", 1)[1])
            elif arg.startswith("-p") and arg != "-p":
                properties.append(arg[2:])
            elif arg == "--value" or arg.startswith("-"):
                continue
            else:
                unit = arg
        if not unit:
            return 1
        record = read_record(units_root() / unit_key(unit))
        running = active(unit)
        values = {
            "ActiveState": "active" if running else "inactive",
            "SubState": "running" if running else "dead",
            "MainPID": record.get("MainPID", 0),
            "InvocationID": record.get("InvocationID", ""),
            "Result": record.get("Result", ""),
            "ExecMainCode": record.get("ExecMainCode", ""),
            "ExecMainStatus": record.get("ExecMainStatus", 0),
            "ActiveEnterTimestamp": record.get("ActiveEnterTimestamp", ""),
            "LastTriggerUSec": record.get("LastTriggerUSec", ""),
            "LoadState": "loaded" if record else "not-found",
        }
        properties = properties or list(values)
        for name in properties:
            value = str(values.get(name, ""))
            print(value if value_only else name + "=" + value)
        return 0
    if verb == "list-units":
        pattern = next((arg for arg in reversed(rest) if not arg.startswith("-")), "*")
        state = next((arg.split("=", 1)[1] for arg in rest if arg.startswith("--state=")), "active")
        root, rows = units_root(), []
        if root.is_dir():
            for directory in root.iterdir():
                if not directory.is_dir() or not active(directory.name):
                    continue
                record = read_record(directory)
                name = display_name(record.get("Unit", directory.name), record)
                if state != "all" and record.get("ActiveState", "active") != state:
                    continue
                if fnmatch.fnmatchcase(name, pattern):
                    rows.append(f"{name} loaded active running {description(name, record)}".rstrip())
        print("\n".join(sorted(rows))) if rows else None
        return 0
    if verb == "status":
        if not unit:
            return 1
        record = read_record(units_root() / unit_key(unit))
        running = active(unit)
        name = display_name(unit_key(unit), record)
        print(f"{'●' if running else '○'} {name} - {description(name, record)}")
        print("     Loaded: loaded" if record or unit_file(name) else "     Loaded: not-found")
        print(f"     Active: {'active (running)' if running else 'inactive (dead)'}")
        return 0
    if verb == "cat":
        path = unit_file(unit) if unit else None
        if path is None:
            return 1
        try:
            display = path.resolve().relative_to(Path.cwd().resolve()).as_posix()
        except ValueError:
            display = str(path)
        print(f"# {display}")
        contents = path.read_text(encoding="utf-8")
        sys.stdout.write(contents)
        if contents and not contents.endswith("\n"):
            sys.stdout.write("\n")
        return 0
    if verb == "list-timers":
        print("NEXT                        LEFT          LAST                        PASSED       UNIT")
        return 0
    if verb == "daemon-reload":
        return reload_timers()
    if verb == "is-enabled":
        enabled = launchctl_call(["print", f"gui/{os.getuid()}/zenoforge.{unit_key(unit)}"]) == 0 if timer_mode() == "launchd" and unit else unit_file(unit) is not None if unit else False
        print("enabled" if enabled else "disabled")
        return 0 if enabled else 1
    if verb == "enable":
        return reload_timers() if timer_mode() == "launchd" and unit else 0
    if verb == "stop":
        for name in units:
            record = read_record(units_root() / unit_key(name))
            group = int(record.get("pgid") or record.get("MainPID", 0))
            if group:
                try:
                    os.killpg(group, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            deadline = time.monotonic() + float(os.environ.get("ZF_STOP_GRACE_SEC", "30"))
            while active(name) and time.monotonic() < deadline:
                time.sleep(.05)
            if active(name) and group:
                try:
                    os.killpg(group, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            deadline = time.monotonic() + 5
            while active(name) and time.monotonic() < deadline:
                time.sleep(.05)
            if active(name):
                return 1
        return 0
    if verb in {"start", "restart"}:
        if timer_mode() == "launchd" and unit and unit.endswith(".timer"):
            args = ["kickstart"] + (["-k"] if verb == "restart" else [])
            return launchctl_call([*args, f"gui/{os.getuid()}/zenoforge.{unit_key(unit)}"])
        return 0
    if verb == "reset-failed":
        root = units_root()
        if root.is_dir():
            for directory in root.iterdir():
                if directory.is_dir() and not active(directory.name):
                    shutil.rmtree(directory)
        return 0
    return 0


def main():
    if len(sys.argv) < 2:
        return 2
    command, args = sys.argv[1], sys.argv[2:]
    try:
        if command == "_monitor":
            return monitor_unit(Path(args[0]), int(args[1]))
        if command == "systemd-run":
            return start_unit(args)
        if command == "systemctl":
            return systemctl(args)
        if command == "journalctl":
            return journalctl(args)
        return 2
    except (OSError, ValueError, IndexError, KeyError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
