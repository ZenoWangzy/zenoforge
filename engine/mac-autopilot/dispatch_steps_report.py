import argparse
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path
import re


DETAIL_LINE = re.compile(r"^\[(?P<stamp>[^\]]+)\]\s+dispatch detail steps refill=(?P<refill>true|false)(?:\s+(?P<steps>.*))?$")
STEP_VALUE = re.compile(r"(?P<name>[A-Za-z0-9_-]+)=(?P<seconds>\d+(?:\.\d+)?)s/(?P<count>\d+)")
MILLISECOND = Decimal("0.001")
TENTH = Decimal("0.1")


def parse_utc(value):
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise argparse.ArgumentTypeError(f"invalid UTC ISO time: {value}") from error
    if parsed.tzinfo is None or parsed.utcoffset() != timedelta(0):
        raise argparse.ArgumentTypeError(f"time must be UTC: {value}")
    return parsed.astimezone(timezone.utc)


def parse_step_line(line, since, refill):
    if "dispatch detail steps" not in line:
        return None, False
    match = DETAIL_LINE.fullmatch(line.rstrip("\r\n"))
    if match is None:
        return None, True
    try:
        stamp = parse_utc(match.group("stamp"))
    except argparse.ArgumentTypeError:
        return None, True
    if since is not None and stamp < since:
        return None, False
    if refill is not None and match.group("refill") != refill:
        return None, False
    steps = {}
    tokens = (match.group("steps") or "").split()
    if not tokens:
        return None, True
    for token in tokens:
        value = STEP_VALUE.fullmatch(token)
        if value is None or int(value.group("count")) < 1:
            return None, True
        name = value.group("name")
        if name in steps:
            return None, True
        steps[name] = Decimal(value.group("seconds"))
    return steps, False


def nearest_rank(values, percentile):
    ordered = sorted(values)
    rank = (percentile * len(ordered) + 99) // 100
    return ordered[rank - 1]


def format_seconds(value):
    return f"{value.quantize(MILLISECOND, rounding=ROUND_HALF_UP):.3f}s"


def format_share(value, total):
    if total == 0:
        return "0.0%"
    share = (value * 100 / total).quantize(TENTH, rounding=ROUND_HALF_UP)
    return f"{share:.1f}%"


def report(log_paths, since, refill):
    pass_totals = []
    step_samples = defaultdict(list)
    unparsed_lines = 0
    for log_path in log_paths:
        try:
            with log_path.open(encoding="utf-8", errors="replace") as log_file:
                for line in log_file:
                    steps, unparsed = parse_step_line(line, since, refill)
                    if unparsed:
                        unparsed_lines += 1
                    if steps is None:
                        continue
                    pass_totals.append(sum(steps.values(), Decimal(0)))
                    for name, seconds in steps.items():
                        step_samples[name].append(seconds)
        except OSError as error:
            raise OSError(f"{log_path}: {error}") from error

    lines = [f"passes\t{len(pass_totals)}"]
    if pass_totals:
        lines.append(f"pass_total_p50\t{format_seconds(nearest_rank(pass_totals, 50))}")
        lines.append(f"pass_total_p90\t{format_seconds(nearest_rank(pass_totals, 90))}")
    else:
        lines.extend(["pass_total_p50\t-", "pass_total_p90\t-"])
    lines.append("step\tpasses\ttotal\tshare\tp50\tp90")
    rows = [
        (name, samples, sum(samples, Decimal(0)))
        for name, samples in step_samples.items()
    ]
    all_step_seconds = sum((total for _, _, total in rows), Decimal(0))
    rows.sort(key=lambda row: (-row[2], row[0]))
    for name, samples, total in rows:
        lines.append(
            "\t".join(
                [
                    name,
                    str(len(samples)),
                    format_seconds(total),
                    format_share(total, all_step_seconds),
                    format_seconds(nearest_rank(samples, 50)),
                    format_seconds(nearest_rank(samples, 90)),
                ]
            )
        )
    lines.append(f"unparsed_lines\t{unparsed_lines}")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("logs", nargs="+", type=Path)
    parser.add_argument("--since", type=parse_utc)
    parser.add_argument("--refill", choices=("true", "false"))
    args = parser.parse_args()
    try:
        output = report(args.logs, args.since, args.refill)
    except OSError as error:
        parser.error(str(error))
    print(output)


if __name__ == "__main__":
    main()
