#!/usr/bin/env python3
"""Parse systemd unit directives and check portability coverage."""

import argparse
import json
import sys
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("parse", "check"):
        sub = commands.add_parser(command)
        sub.add_argument("paths", nargs="+", type=Path)
    args = parser.parse_args()
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
