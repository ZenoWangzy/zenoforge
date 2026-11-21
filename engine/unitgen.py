#!/usr/bin/env python3
"""Parse systemd unit directives and check portability coverage."""

import argparse
import json
import os
import plistlib
import re
import shlex
import sys
from datetime import datetime
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
    return status


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("parse", "check"):
        sub = commands.add_parser(command)
        sub.add_argument("paths", nargs="+", type=Path)
    plist = commands.add_parser("plist")
    plist.add_argument("paths", nargs="*", type=Path, default=[SYSTEMD_DIR])
    plist.add_argument("--dir", type=Path, default=Path.home() / "Library" / "LaunchAgents")
    args = parser.parse_args()
    if args.command == "plist":
        return render_plists(args.paths, args.dir)
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
