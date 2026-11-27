#!/usr/bin/env python3
"""Parse systemd unit directives and check portability coverage."""

import argparse
import json
import os
import plistlib
import re
import shlex
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path


# Directive names and mappings from docs/design/PORTABILITY.md section 6.2.
DIRECTIVE_TABLE = {
    "ExecStart": "ProgramArguments",
    "WorkingDirectory": "WorkingDirectory",
    "Environment": "EnvironmentVariables",
    "EnvironmentFile": "EnvironmentVariables",
    "Description": "informational",
    "StandardOutput": "StandardOutPath",
    "StandardError": "StandardErrorPath",
    "OnActiveSec": "StartInterval and RunAtLoad",
    "OnUnitActiveSec": "StartInterval",
    "OnBootSec": "RunAtLoad",
    "OnCalendar": "StartCalendarInterval",
    "Persistent": "no mapping needed",
    "TimeoutStartSec": "timeout wrapper",
    "RandomizedDelaySec": "dropped",
    "AccuracySec": "dropped",
    "After": "dropped",
    "Type": "job without KeepAlive",
    "Nice": "Nice",
    "CPUWeight": "no direct equivalent",
    "IOWeight": "no direct equivalent",
    "IOSchedulingClass": "no direct equivalent",
    "WantedBy": "n/a",
}
SECTIONS = {"Unit", "Service", "Timer", "Install"}
SYSTEMD_DIR = Path(__file__).resolve().parent / "systemd"
DURATION = re.compile(r"(\d+)(s|sec|min|m|h|hour)?")
DURATION_SECONDS = {None: 1, "s": 1, "sec": 1, "m": 60, "min": 60, "h": 3600, "hour": 3600}
CALENDAR = re.compile(r"\*-\*-\* (\d\d)(?:/(\d+))?:(\d\d):00 UTC")


def unit_files(paths):
    for path in paths:
        if path.is_dir():
            yield from sorted((*path.glob("*.service"), *path.glob("*.timer")))
        else:
            yield path


def parse(path):
    sections = {}
    section = None
    for line_no, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith(("#", ";")):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            if section in SECTIONS:
                sections.setdefault(section, [])
            continue
        if section not in SECTIONS or "=" not in line:
            continue
        key, value = line.split("=", 1)
        sections[section].append({"key": key.strip(), "value": value.strip(), "line": line_no})
    return sections


def seconds(value):
    match = DURATION.fullmatch(value)
    if not match:
        raise ValueError(f"unsupported duration {value!r}")
    return int(match[1]) * DURATION_SECONDS[match[2]]


def calendar_entries(value, offset_minutes):
    # only "*-*-* HH[/step]:MM:00 UTC" (the shipped form); wider OnCalendar shapes come with zenoforge#1010 (PT-7c)
    match = CALENDAR.fullmatch(value)
    if not match:
        raise ValueError(f"unsupported OnCalendar {value!r}")
    hour, step, minute = int(match[1]), match[2], int(match[3])
    entries = []
    for utc_hour in range(hour, 24, int(step)) if step else [hour]:
        local = (utc_hour * 60 + minute + offset_minutes) % 1440
        entries.append({"Hour": local // 60, "Minute": local % 60})
    return entries


def read_env_file(path):
    env = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        # no escapes or multi-line values; systemd env-file quoting comes with zenoforge#1011 (PT-7d)
        env[key.strip()] = value.strip().strip("\"'")
    return env


def timer_plist(timer, home, offset_minutes):
    def expand(text):
        return text.replace("%h", home)

    def values(sections, key):
        return [expand(d["value"]) for ds in sections.values() for d in ds if d["key"] == key]

    service_path = timer.with_suffix(".service")
    service = parse(service_path)
    schedule = parse(timer)
    env = {}
    for item in values(service, "Environment"):
        key, _, value = item.partition("=")
        env[key] = value
    for item in values(service, "EnvironmentFile"):
        path = Path(item.lstrip("-"))
        if path.exists():
            env.update(read_env_file(path))
        elif not item.startswith("-"):
            raise FileNotFoundError(f"EnvironmentFile {path} is missing")
    # systemd ExecStart prefixes: - @ : + ! (":" turns off $ expansion, which launchd never does)
    exec_starts = values(service, "ExecStart")
    if not exec_starts:
        raise ValueError(f"no ExecStart in {service_path}")
    args = shlex.split(exec_starts[-1].lstrip("-@:+!"))
    if values(service, "TimeoutStartSec"):
        timeout = seconds(values(service, "TimeoutStartSec")[-1])
        args = ["timeout", "-k", "30", str(timeout), *args]
    plist = {
        "Label": f"zenoforge.{timer.stem}",
        "ProgramArguments": args,
        "EnvironmentVariables": env,
        "SoftResourceLimits": {"NumberOfFiles": 8192},
    }
    if values(service, "WorkingDirectory"):
        plist["WorkingDirectory"] = values(service, "WorkingDirectory")[-1]
    if values(service, "Nice"):
        plist["Nice"] = int(values(service, "Nice")[-1])
    journal = values(service, "StandardOutput") + values(service, "StandardError")
    if journal:
        if set(journal) != {"journal"}:
            raise ValueError(f"only StandardOutput=journal is mapped, got {journal}")
        log = f"{env.get('AGENT_HOME', home + '/.zenoforge')}/logs/units/{timer.stem}.log"
        plist["StandardOutPath"] = plist["StandardErrorPath"] = log
    if values(schedule, "OnUnitActiveSec"):
        plist["StartInterval"] = seconds(values(schedule, "OnUnitActiveSec")[-1])
    if values(schedule, "OnActiveSec") or values(schedule, "OnBootSec"):
        plist["RunAtLoad"] = True
    calendars = values(schedule, "OnCalendar")
    if calendars:
        plist["StartCalendarInterval"] = [
            entry for value in calendars for entry in calendar_entries(value, offset_minutes)
        ]
    return plist


def render_plists(paths, out_dir):
    # launchd has no UTC: OnCalendar is shifted by the offset in force when this runs (PORTABILITY.md 6.2)
    offset = datetime.now().astimezone().utcoffset()
    offset_minutes = int(offset.total_seconds() // 60)
    home = os.path.expanduser("~")
    out_dir.mkdir(parents=True, exist_ok=True)
    status = 0
    for timer in (path for path in unit_files(paths) if path.suffix == ".timer"):
        try:
            data = plistlib.dumps(timer_plist(timer, home, offset_minutes), sort_keys=True)
        except (OSError, ValueError) as error:
            print(f"{timer}: {error}", file=sys.stderr)
            status = 2
            continue
        target = out_dir / f"zenoforge.{timer.stem}.plist"
        if target.exists() and target.read_bytes() == data:
            continue
        target.write_bytes(data)
        remember_changed(out_dir, target.name)
    return status


def remember_changed(directory, name):
    marker = directory / ".unitgen.changed"
    names = set(marker.read_text(encoding="utf-8").splitlines()) if marker.exists() else set()
    names.add(name)
    marker.write_text("".join(f"{item}\n" for item in sorted(names)), encoding="utf-8")


def write_if_changed(directory, name, data, loadable=False):
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / name
    if target.exists() and target.read_bytes() == data:
        return False
    target.write_bytes(data)
    if loadable:
        remember_changed(directory, name)
    return True


def next_calendar(value, after):
    entries = calendar_entries(value, 0)
    current = datetime.fromtimestamp(after, timezone.utc)
    for offset in range(3):
        day = current.date() + timedelta(days=offset)
        for entry in entries:
            candidate = datetime(
                day.year, day.month, day.day, entry["Hour"], entry["Minute"], tzinfo=timezone.utc
            ).timestamp()
            if candidate > after:
                return candidate
    raise ValueError(f"no next OnCalendar occurrence for {value!r}")


def loop_schedule(timer, home, start):
    schedule = parse(timer).get("Timer", [])
    service = timer_plist(timer, home, 0)
    events = []
    for directive in schedule:
        key = directive["key"]
        value = directive["value"]
        if key == "OnActiveSec":
            events.append({"kind": "once", "due": start + seconds(value)})
        elif key == "OnUnitActiveSec":
            interval = seconds(value)
            events.append({"kind": "interval", "due": start + interval, "interval": interval})
        elif key == "OnCalendar":
            events.append({"kind": "calendar", "due": next_calendar(value, start), "value": value})
    if not events:
        raise ValueError(f"no supported timer schedule in {timer}")
    return {
        "name": timer.stem,
        "events": events,
        "argv": service["ProgramArguments"],
        "environment": service.get("EnvironmentVariables", {}),
        "cwd": service.get("WorkingDirectory"),
    }


def read_clock(clock_file):
    if clock_file is None:
        return time.time()
    return float(clock_file.read_text(encoding="utf-8").strip())


def run_loop(paths, clock_file=None, stop_at=None, poll_interval=1):
    if poll_interval <= 0:
        print("unitgen loop: poll interval must be positive", file=sys.stderr)
        return 2
    try:
        now = read_clock(clock_file)
        schedules = [
            loop_schedule(timer, os.path.expanduser("~"), now)
            for timer in unit_files(paths)
            if timer.suffix == ".timer"
        ]
    except (OSError, ValueError) as error:
        print(f"unitgen loop: {error}", file=sys.stderr)
        return 2
    active = {}
    print("unitgen loop started", flush=True)
    while True:
        try:
            now = read_clock(clock_file)
        except (OSError, ValueError) as error:
            print(f"unitgen loop: {error}", file=sys.stderr)
            return 2
        for name, process in list(active.items()):
            result = process.poll()
            if result is not None:
                del active[name]
                print(f"unitgen loop finished {name} rc={result}", flush=True)
        for schedule in schedules:
            due = [event for event in schedule["events"] if event["due"] <= now]
            if not due:
                continue
            name = schedule["name"]
            if name in active:
                print(f"unitgen loop skipped active {name} at {int(now)}", flush=True)
            else:
                environment = os.environ.copy()
                environment.update(schedule["environment"])
                try:
                    process = subprocess.Popen(
                        schedule["argv"], env=environment, cwd=schedule["cwd"]
                    )
                except OSError as error:
                    print(f"unitgen loop: {name}: {error}", file=sys.stderr)
                    return 2
                active[name] = process
                print(f"unitgen loop starting {name} at {int(now)}", flush=True)
            for event in due:
                if event["kind"] == "once":
                    schedule["events"].remove(event)
                elif event["kind"] == "interval":
                    event["due"] = now + event["interval"]
                else:
                    event["due"] = next_calendar(event["value"], now)
        if stop_at is not None and now >= stop_at:
            for process in active.values():
                if process.poll() is None:
                    process.terminate()
            for process in active.values():
                process.wait()
            return 0
        time.sleep(poll_interval)


def timer_mode():
    return os.environ.get("ZF_TIMERS", "launchd" if sys.platform == "darwin" else "systemd")


def live_directory(value):
    if value is not None:
        return str(value)
    supervisor = os.environ.get("MAC_AUTOPILOT_SUPERVISOR_DIR")
    if supervisor:
        return str(Path(supervisor) / "autopi-live")
    root = Path(os.environ.get("MAC_AUTOPILOT_ROOT", SYSTEMD_DIR.parent.parent))
    return str(root / ".scratch-supervisor" / "autopi-live")


def template_files(template_dir):
    return sorted(template_dir.glob("*.service.in"))


def service_plist(template, live):
    directives = parse(template).get("Service", [])
    starts = [directive["value"] for directive in directives if directive["key"] == "ExecStart"]
    if not starts:
        raise ValueError(f"no ExecStart in {template}")
    name = template.name.removesuffix(".service.in")
    return {
        "Label": f"zenoforge.{name.removesuffix('.service')}",
        "ProgramArguments": shlex.split(starts[-1].replace("@LIVE@", live)),
        "EnvironmentVariables": {"PATH": os.environ.get("PATH", "")},
        "KeepAlive": True,
        "SoftResourceLimits": {"NumberOfFiles": 8192},
    }


def install_units(mode, templates, systemd_dir, launchagents_dir, live):
    if mode == "loop":
        return 0
    if mode not in {"systemd", "launchd"}:
        print(f"unitgen install: unsupported ZF_TIMERS={mode}", file=sys.stderr)
        return 2
    try:
        files = template_files(templates)
        if not files:
            raise FileNotFoundError(f"no service templates in {templates}")
        for template in files:
            if mode == "systemd":
                target_name = template.name.removesuffix(".in")
                data = template.read_text(encoding="utf-8").replace("@LIVE@", live).encode()
                write_if_changed(systemd_dir, target_name, data)
            else:
                target_name = f"zenoforge.{template.name.removesuffix('.service.in')}.plist"
                data = plistlib.dumps(service_plist(template, live), sort_keys=True)
                write_if_changed(launchagents_dir, target_name, data, loadable=True)
    except (OSError, ValueError) as error:
        print(f"unitgen install: {error}", file=sys.stderr)
        return 2
    return 0


def load_launchagents(directory, uid):
    marker = directory / ".unitgen.changed"
    if not marker.exists():
        return 0
    domain = f"gui/{uid}"
    for name in marker.read_text(encoding="utf-8").splitlines():
        target = directory / name
        if not target.is_file():
            print(f"unitgen load: missing plist {target}", file=sys.stderr)
            return 2
        try:
            subprocess.run(
                ["launchctl", "bootout", domain, str(target)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
            result = subprocess.run(
                ["launchctl", "bootstrap", domain, str(target)], check=False
            )
        except OSError as error:
            print(f"unitgen load: {error}", file=sys.stderr)
            return 2
        if result.returncode != 0:
            print(f"unitgen load: launchctl bootstrap failed for {target}", file=sys.stderr)
            return 2
    marker.unlink()
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("parse", "check"):
        sub = commands.add_parser(command)
        sub.add_argument("paths", nargs="+", type=Path)
    plist = commands.add_parser("plist")
    plist.add_argument("paths", nargs="*", type=Path, default=[SYSTEMD_DIR])
    plist.add_argument("--dir", type=Path, default=Path.home() / "Library" / "LaunchAgents")
    loop = commands.add_parser("loop")
    loop.add_argument("paths", nargs="*", type=Path, default=[SYSTEMD_DIR])
    loop.add_argument("--clock-file", type=Path)
    loop.add_argument("--stop-at", type=float)
    loop.add_argument("--poll-interval", type=float, default=1)
    install = commands.add_parser("install")
    install.add_argument("--templates", type=Path, default=SYSTEMD_DIR / "templates")
    install.add_argument(
        "--systemd-unit-dir", type=Path, default=Path.home() / ".config" / "systemd" / "user"
    )
    install.add_argument(
        "--launchagents-dir", type=Path, default=Path.home() / "Library" / "LaunchAgents"
    )
    install.add_argument("--live", type=Path)
    load = commands.add_parser("load")
    load.add_argument(
        "--launchagents-dir", type=Path, default=Path.home() / "Library" / "LaunchAgents"
    )
    load.add_argument("--uid", type=int, default=os.getuid())
    args = parser.parse_args()
    if args.command == "plist":
        return render_plists(args.paths, args.dir)
    if args.command == "loop":
        return run_loop(args.paths, args.clock_file, args.stop_at, args.poll_interval)
    if args.command == "install":
        return install_units(
            timer_mode(),
            args.templates,
            args.systemd_unit_dir,
            args.launchagents_dir,
            live_directory(args.live),
        )
    if args.command == "load":
        if timer_mode() == "launchd":
            return load_launchagents(args.launchagents_dir, args.uid)
        return 0
    status = 0
    for path in unit_files(args.paths):
        try:
            sections = parse(path)
        except OSError as error:
            print(f"{path}: {error}", file=sys.stderr)
            status = 2
            continue
        if args.command == "parse":
            print(json.dumps({"file": str(path), "sections": sections}, sort_keys=True))
            continue
        for directives in sections.values():
            for directive in directives:
                if directive["key"] not in DIRECTIVE_TABLE:
                    print(
                        f"{path}:{directive['line']}: unknown directive {directive['key']}",
                        file=sys.stderr,
                    )
                    if status == 0:
                        status = 1
    return status


if __name__ == "__main__":
    raise SystemExit(main())
