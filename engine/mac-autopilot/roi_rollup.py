#!/usr/bin/env python3
"""Worker cost and per-ticket ROI reports from the unit ledger.

`report` lists recent unit-loop worker units; `tickets` aggregates the same ledger
per ticket into lead time, stage wall time, tokens by model and stage, API-list cost,
the fleet/day/per-ticket output ratios and the waste share (RT-2)."""
import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path

import roi_ledger


PRICE_FILE = Path(__file__).resolve().parents[1] / "state" / "roi-prices.json"
DEFAULT_REPO = "example-maintainer/example-repo"


def _decimal(value):
    if isinstance(value, bool) or not isinstance(value, (int, float, str)):
        return None
    try:
        number = Decimal(str(value))
    except InvalidOperation:
        return None
    return number if number.is_finite() and number >= 0 else None


def _model_cost(model, prices):
    name = model.get("model")
    price = (prices.get("models") or {}).get(name) if isinstance(name, str) else None
    rates = price.get("per_million") if isinstance(price, dict) else None
    if not isinstance(rates, dict):
        return None
    input_tokens, cached, cache_write, output = (model.get(key) for key in ("input", "cached", "cache_write", "output"))
    if any(type(value) is not int or value < 0 for value in (input_tokens, cached, output)):
        return None
    input_rate, cached_rate, cache_write_rate, output_rate = (
        _decimal(rates.get(key)) for key in ("input", "cached", "cache_write", "output")
    )
    if input_rate is None or output_rate is None:
        return None
    if cached and cached_rate is None:
        return None
    if cache_write is None:
        if cache_write_rate is not None:
            return None
        cache_write = 0
    elif cache_write and cache_write_rate is None:
        return None
    if cache_write is None:
        cache_write = 0
    fresh_input = input_tokens - cached - cache_write
    if fresh_input < 0:
        return None
    total = Decimal(fresh_input) * input_rate + Decimal(output) * output_rate
    if cached:
        total += Decimal(cached) * cached_rate
    if cache_write:
        total += Decimal(cache_write) * cache_write_rate
    return total / Decimal(1_000_000)


def _sum_field(models, name):
    values = [model.get(name) for model in models]
    if not values or any(type(value) is not int or value < 0 for value in values):
        return None
    return sum(values)


def _row_cost(event, prices):
    costs = [_model_cost(model, prices) for model in event.get("models") or []]
    return sum(costs, Decimal(0)) if costs and all(value is not None for value in costs) else None


def _parse_ts(value):
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00")).astimezone(timezone.utc)
    except (AttributeError, ValueError):
        return None


def _efficiency_rows(home):
    rows = []
    metrics = Path(home) / "metrics"
    for path in sorted(list(metrics.glob("efficiency-*.jsonl")) + list(metrics.glob("efficiency-*.jsonl.gz"))):
        with roi_ledger._open_text(path) as source:
            for line in source:
                if not line.strip():
                    continue
                try:
                    value = json.loads(line)
                except ValueError:
                    continue
                if isinstance(value, dict):
                    rows.append(value)
    return rows


def _landings_and_closures(rows):
    """Every landing and closure the efficiency ledger records, window-independent."""
    landings, closures = {}, set()
    for row in rows:
        at = _parse_ts(row.get("ts"))
        if not at:
            continue
        kind = row.get("event_type")
        if kind == "merged" and isinstance(row.get("issue"), int):
            landing = {"at": at, "sha": row.get("sha"), "lane": "pr"}
        elif kind == "source-landed":
            issues = [value for value in row.get("owned_issues") or [] if isinstance(value, int) and value > 0]
            if not issues:
                continue
            landing = {"at": at, "sha": row.get("head") or row.get("source_sha"), "lane": "direct"}
        elif kind == "ticket-closed" and isinstance(row.get("issue"), int):
            closures.add(row["issue"])
            continue
        else:
            continue
        for issue in ([row["issue"]] if kind == "merged" else issues):
            if issue not in landings or at >= landings[issue]["at"]:
                landings[issue] = landing
    return landings, closures


def _reverted_shas(repo_root):
    """Reverted commit SHAs mapped to their newest revert time, as node_health delivery does."""
    try:
        result = subprocess.run(
            ["git", "-C", repo_root, "log", "--format=%H%x00%ct%x00%B%x1e", "--grep=This reverts commit"],
            capture_output=True, text=True, timeout=30)
        if result.returncode != 0:
            return {}
    except (OSError, subprocess.TimeoutExpired):
        return {}
    reverted = {}
    for record in result.stdout.split("\x1e"):
        _, separator, rest = record.partition("\x00")
        if not separator:
            continue
        stamp, separator, message = rest.partition("\x00")
        try:
            at = datetime.fromtimestamp(int(stamp.strip()), timezone.utc)
        except (ValueError, OverflowError, OSError):
            continue
        for sha in re.findall(r"This reverts commit ([0-9a-f]{40})", message):
            reverted[sha] = max(at, reverted.get(sha, at))
    return reverted


def _issue_created(repo, cutoff, timeout=30):
    """Issue creation times from two census calls, the node_health delivery join.

    Closed covers tickets the lander closed; open covers merged-PR tickets whose issue
    was never closed. Both states are needed: this repo has both in quantity."""
    from concurrent.futures import ThreadPoolExecutor
    searches = {"closed": f"closed:>={cutoff:%Y-%m-%d}", "open": f"created:>={cutoff:%Y-%m-%d}"}
    commands = [["gh", "issue", "list", "--repo", repo, "--state", state, "--search", search,
                 "--limit", "1000", "--json", "number,createdAt"]
                for state, search in searches.items()]

    def run(command):
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
            return json.loads(result.stdout or "null") if result.returncode == 0 else None
        except (OSError, subprocess.TimeoutExpired, ValueError):
            return None

    created = {}
    with ThreadPoolExecutor(max_workers=len(commands)) as pool:
        for rows in pool.map(run, commands):
            if not isinstance(rows, list):
                continue
            for row in rows:
                number, at = row.get("number"), _parse_ts(row.get("createdAt"))
                if isinstance(number, int) and at:
                    created[number] = at
    return created


def _unit_final_stages(home):
    """Issue number -> work-order final stage from the scheduler's units.json (read-only)."""
    supervisor = os.environ.get("MAC_AUTOPILOT_SUPERVISOR_DIR") or os.path.join(home, "checkout", ".scratch-supervisor")
    runtime = os.environ.get("MAC_AUTOPILOT_RUNTIME_DIR") or os.path.join(supervisor, "autopi")
    stages = {}
    try:
        with open(os.path.join(runtime, "units.json"), encoding="utf-8") as source:
            units = json.load(source).get("units") or []
    except (OSError, ValueError, AttributeError):
        return stages
    for unit in units:
        if isinstance(unit, dict) and isinstance(unit.get("issue"), int):
            stages[unit["issue"]] = unit.get("stage")
    return stages


class _Ticket:
    __slots__ = ("issue", "rows", "stages_s", "models")

    def __init__(self, issue):
        self.issue = issue
        self.rows = []
        self.stages_s = {}
        self.models = {}

    def add(self, event, share):
        self.rows.append(event)
        stage = (event.get("unit") or {}).get("stage") or "unknown"
        self.stages_s[stage] = self.stages_s.get(stage, 0.0) + float(share or 1.0) * event.get("wall_s", 0)
        for model in event.get("models") or []:
            name = model.get("model") or "unknown"
            bucket = self.models.setdefault((stage, name), {"input": [0, True], "output": [0, True],
                                                            "cached": [0, True], "reasoning": [0, True],
                                                            "tokens": [0, True], "rows": 0})
            bucket["rows"] += 1
            for field in bucket:
                if field == "rows":
                    continue
                value = model.get(field)
                if type(value) is int and value >= 0:
                    bucket[field][0] += value
                else:
                    bucket[field][1] = False

    def totals(self):
        priced = [event["_cost"] for event in self.rows if event["_cost"] is not None]
        tokens = [event["_tokens"] for event in self.rows]
        return {
            "units": len(self.rows),
            "cost_usd": sum(priced, Decimal(0)) if priced else None,
            "unpriced_units": sum(1 for event in self.rows if event["_cost"] is None),
            "tokens": sum(value for value in tokens if value is not None) if tokens and all(
                value is not None for value in tokens) else None,
            "wall_s": round(sum(self.stages_s.values()), 1),
            "stages_s": {stage: round(value, 1) for stage, value in sorted(self.stages_s.items())},
            "models": [{"stage": stage, "model": name, "rows": counts["rows"],
                        **{field: values[0] if values[1] else None for field, values in counts.items()
                           if field != "rows"}}
                       for (stage, name), counts in sorted(self.models.items())],
        }


def tickets_report(home, days=7, prices_path=None, repo=None, repo_root=None, now=None):
    """Per-ticket zero-to-landed cost plus fleet, day and per-ticket output ratios.

    Delivered means merged or direct-main landed (this deployment has no release gate for
    pipeline tickets). Waste is the cost of units on tickets closed unmerged or reverted.
    The issue createdAt census targets `repo`, else the ZF_REPO deployment repo, else the
    placeholder example repo."""
    repo = repo or os.environ.get("ZF_REPO") or DEFAULT_REPO
    now = now or datetime.now(timezone.utc)
    since = now - timedelta(days=days)
    if prices_path:
        prices = roi_ledger.load_prices(prices_path)
    else:
        prices = roi_ledger.load_prices(PRICE_FILE, os.path.join(home, "roi-prices.local.json"))

    events = [event for event in roi_ledger.read_events(home)
              if event.get("event_type") == "unit-end" and since <= _parse_ts(event["ts"]) <= now]
    for event in events:
        event["_cost"] = _row_cost(event, prices)
        event["_tokens"] = _sum_field(event.get("models") or [], "tokens")

    efficiency = _efficiency_rows(home)
    landings, closures = _landings_and_closures(efficiency)
    created = _issue_created(repo, since - timedelta(days=30))
    reverted = _reverted_shas(repo_root or os.path.join(home, "checkout"))
    unit_stages = _unit_final_stages(home)
    issueless = sum(1 for row in efficiency
                    if row.get("event_type") == "source-landed" and not row.get("owned_issues")
                    and since <= (_parse_ts(row.get("ts")) or now) <= now)

    tickets, overhead = {}, {"rows": 0, "cost_usd": Decimal(0), "priced": 0, "tokens": 0}
    for event in events:
        members = event.get("tickets") or []
        share = Decimal(1) / len(members) if members else None
        if members:
            for issue in members:
                tickets.setdefault(int(issue), _Ticket(int(issue))).add(event, share)
        else:
            overhead["rows"] += 1
            overhead["tokens"] += event["_tokens"] or 0
            if event["_cost"] is not None:
                overhead["priced"] += 1
                overhead["cost_usd"] += event["_cost"]

    known_cost = sum((event["_cost"] for event in events if event["_cost"] is not None), Decimal(0))
    total_tokens = sum(event["_tokens"] or 0 for event in events)

    # Landed tickets with no ledger rows still count as delivered, with unmeasured cost.
    for issue, landing in landings.items():
        if since <= landing["at"] <= now and issue not in tickets:
            tickets[issue] = _Ticket(issue)

    rows, waste_cost, in_flight_cost, delivered_rows = {}, Decimal(0), Decimal(0), []
    landed_earlier_cost = Decimal(0)
    waste_priced = 0
    for issue, ticket in sorted(tickets.items()):
        totals = ticket.totals()
        landing = landings.get(issue)
        if landing and landing["at"] <= now:
            outcome = "landed"
            if landing["sha"] and (at := reverted.get(landing["sha"])) and at >= landing["at"]:
                outcome = "reverted"
            created_at = created.get(issue)
            totals["landed_at"] = landing["at"].strftime("%Y-%m-%dT%H:%M:%SZ")
            totals["lane"] = landing["lane"]
            totals["lead_hours"] = round((landing["at"] - created_at).total_seconds() / 3600, 2) \
                if created_at and created_at <= landing["at"] else None
        elif issue in closures or unit_stages.get(issue) == "closed":
            outcome = "closed-unmerged"
        else:
            outcome = "in-flight"
        totals["outcome"] = outcome
        rows[issue] = totals
        if outcome == "landed" and since <= landing["at"] <= now:
            delivered_rows.append((issue, totals))
        if totals["cost_usd"] is None:
            continue
        if outcome in ("closed-unmerged", "reverted"):
            waste_cost += totals["cost_usd"]
            waste_priced += 1
        elif outcome == "in-flight":
            in_flight_cost += totals["cost_usd"]
        elif landing["at"] < since:
            landed_earlier_cost += totals["cost_usd"]

    delivered_rows.sort(key=lambda item: item[1]["landed_at"], reverse=True)
    leads = [totals["lead_hours"] for _, totals in delivered_rows if totals["lead_hours"] is not None]
    delivered_priced = [totals["cost_usd"] for _, totals in delivered_rows if totals["cost_usd"] is not None]
    delivered_cost = sum(delivered_priced, Decimal(0))
    delivered_token_rows = [totals["tokens"] for _, totals in delivered_rows if totals["tokens"] is not None]
    delivered_tokens = sum(delivered_token_rows)
    landed_by_day = {}
    for _, totals in delivered_rows:
        landed_by_day[totals["landed_at"][:10]] = landed_by_day.get(totals["landed_at"][:10], 0) + 1
    day_rows = []
    for day in sorted({event["ts"][:10] for event in events} | set(landed_by_day)):
        day_events = [event for event in events if event["ts"].startswith(day)]
        day_cost = sum((event["_cost"] for event in day_events if event["_cost"] is not None), Decimal(0))
        day_waste = sum((totals["cost_usd"] or 0 for issue, totals in rows.items()
                         if totals["outcome"] in ("closed-unmerged", "reverted")
                         and any(event["ts"].startswith(day) for event in tickets[issue].rows)), Decimal(0))
        day_rows.append({
            "day": day,
            "delivered": landed_by_day.get(day, 0),
            "units": len(day_events),
            "tokens": sum(event["_tokens"] or 0 for event in day_events),
            "cost_usd": day_cost,
            "waste_usd": day_waste,
            "waste_pct": round(float(day_waste / day_cost * 100), 2) if day_cost else None,
        })

    unpriced_rows = sum(1 for event in events if event["_cost"] is None)
    for event in events:
        del event["_cost"], event["_tokens"]

    return {
        "schema": "zf-ticket-roi-report/v1",
        "window": {"from": since.strftime("%Y-%m-%dT%H:%M:%SZ"), "to": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
                   "days": days, "timezone": "UTC"},
        "cost_basis": prices.get("cost_basis", "api_list"),
        "price_table_version": prices.get("version"),
        "scope": "pipeline unit-loop worker units (interactive sessions excluded)",
        "components_missing": ["traffic-bytes (per-unit sampler lands with RT-7)",
                               "ci-minutes (per-run ledger rows land with RT-4)"],
        "totals": {
            "unit_rows": len(events),
            "known_cost_usd": known_cost if events else None,
            "unpriced_rows": unpriced_rows,
            "tokens": total_tokens or None,
            "traffic_bytes": None,
            "ci_minutes": None,
            "delivered": len(delivered_rows),
            "delivered_with_units": sum(1 for _, totals in delivered_rows if totals["units"]),
            "in_flight": sum(1 for totals in rows.values() if totals["outcome"] == "in-flight"),
            "closed_unmerged": sum(1 for totals in rows.values() if totals["outcome"] == "closed-unmerged"),
            "reverted": sum(1 for totals in rows.values() if totals["outcome"] == "reverted"),
            "issueless_landings": issueless,
            "issue_created_available": bool(created),
        },
        "output_ratio": {
            "per_delivered_ticket": {
                "cost_usd": round(delivered_cost / len(delivered_priced), 6) if delivered_priced else None,
                "tokens": round(delivered_tokens / len(delivered_token_rows)) if delivered_token_rows else None,
                "lead_hours_avg": round(sum(leads) / len(leads), 2) if leads else None,
                "traffic_bytes": None,
                "note": "each average divides by the delivered tickets for which that quantity is known; "
                        "cost covers only units that ended in the window",
            },
            "waste_pct": round(float(waste_cost / known_cost * 100), 2)
                         if known_cost and waste_priced else None,
            "waste_usd": waste_cost if known_cost and (waste_priced
                         or not any(t["outcome"] in ("closed-unmerged", "reverted") for t in rows.values())) else None,
            "in_flight_usd": in_flight_cost if known_cost else None,
            "landed_before_window_usd": landed_earlier_cost if known_cost else None,
            "overhead_usd": overhead["cost_usd"] if overhead["priced"] else None,
            "overhead_rows": overhead["rows"],
            "reconciles": delivered_cost + waste_cost + in_flight_cost + landed_earlier_cost
                          + overhead["cost_usd"] == known_cost,
        },
        "tickets": [{"ticket": issue, **totals} for issue, totals in
                    sorted(rows.items(), key=lambda item: str(item[1].get("landed_at") or ""), reverse=True)],
        "by_day": day_rows,
    }


def report(home, days=1, prices_path=None, now=None):
    now = now or datetime.now(timezone.utc)
    since = now - timedelta(days=days)
    if prices_path:
        prices = roi_ledger.load_prices(prices_path)
    else:
        prices = roi_ledger.load_prices(PRICE_FILE, os.path.join(home, "roi-prices.local.json"))

    events = [event for event in roi_ledger.read_events(home)
              if event.get("event_type") == "unit-end"
              and since <= datetime.fromisoformat(event["ts"].replace("Z", "+00:00")).astimezone(timezone.utc) <= now]
    rows = []
    for event in events:
        models = event.get("models") or []
        costs = [_model_cost(model, prices) for model in models]
        cost = sum(costs, Decimal(0)) if costs and all(value is not None for value in costs) else None
        names = [model.get("model") or "unknown" for model in models]
        rows.append({
            "ts": event["ts"],
            "tickets": event.get("tickets") or [],
            "stage": (event.get("unit") or {}).get("stage"),
            "unit": (event.get("unit") or {}).get("key"),
            "model": ",".join(names) if names else "unknown",
            "input": _sum_field(models, "input"),
            "cached": _sum_field(models, "cached"),
            "cache_write": _sum_field(models, "cache_write"),
            "output": _sum_field(models, "output"),
            "reasoning": _sum_field(models, "reasoning"),
            "tokens": _sum_field(models, "tokens"),
            "cost_usd": cost,
        })
    rows.sort(key=lambda row: (row["ts"], row["unit"] or ""))
    priced = [row["cost_usd"] for row in rows if row["cost_usd"] is not None]
    report_data = {
        "schema": "zf-worker-cost-report/v1",
        "window": {"from": since.strftime("%Y-%m-%dT%H:%M:%SZ"), "to": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
                   "days": days, "timezone": "UTC"},
        "cost_basis": prices.get("cost_basis", "api_list"),
        "price_table_version": prices.get("version"),
        "worker_units": len(rows),
        "known_cost_subtotal_usd": sum(priced, Decimal(0)) if priced else None,
        "unpriced_units": sum(1 for row in rows if row["cost_usd"] is None),
        "units": rows,
    }
    return report_data


def _number(value):
    return f"{value:,}" if value is not None else "n/a"


def _money(value):
    return f"${value:.6f}" if value is not None else "n/a"


def _render(report_data):
    subtotal = report_data["known_cost_subtotal_usd"]
    subtotal_text = f"${subtotal:.6f}" if subtotal is not None else "n/a"
    print(f"Worker cost, last {report_data['window']['days']:g} d UTC | "
          f"{report_data['worker_units']} units | API list known subtotal {subtotal_text} | "
          f"unpriced {report_data['unpriced_units']}")
    print("ticket\tstage\tunit\tmodel\tinput\tcached\tcache-write\toutput\treasoning\ttokens\tcost-usd")
    for row in report_data["units"]:
        ticket = ",".join(f"#{value}" for value in row["tickets"]) or "-"
        cost = f"${row['cost_usd']:.6f}" if row["cost_usd"] is not None else "n/a"
        print("\t".join(str(value) for value in (
            ticket, row["stage"] or "-", row["unit"] or "-", row["model"],
            _number(row["input"]), _number(row["cached"]), _number(row["cache_write"]),
            _number(row["output"]), _number(row["reasoning"]), _number(row["tokens"]), cost,
        )))


def _render_tickets(data):
    totals, ratio = data["totals"], data["output_ratio"]
    print(f"Ticket ROI, last {data['window']['days']:g} d UTC | {data['scope']}")
    print(f"prices {data['price_table_version']} ({data['cost_basis']}) | missing components: "
          + "; ".join(part.split(" (")[0] for part in data["components_missing"]))
    print(f"delivered {totals['delivered']} ({totals['delivered_with_units']} with recorded units, "
          f"+{totals['issueless_landings']} issue-less landings not attributable) | "
          f"in flight {totals['in_flight']} | closed-unmerged {totals['closed_unmerged']} | "
          f"reverted {totals['reverted']} | overhead rows {ratio['overhead_rows']}")
    print(f"cost {_money(totals['known_cost_usd'])} known (unpriced rows {totals['unpriced_rows']}) | "
          f"tokens {_number(totals['tokens'])} | traffic n/a | ci-minutes n/a"
          + ("" if totals["issue_created_available"] else " | issue createdAt unavailable (gh census failed)"))
    per = ratio["per_delivered_ticket"]
    print(f"per delivered ticket: {_money(per['cost_usd'])} | "
          f"{_number(per['tokens'])} tokens | {per['lead_hours_avg'] if per['lead_hours_avg'] is not None else 'n/a'} h lead "
          f"| traffic n/a")
    print(f"waste {ratio['waste_pct'] if ratio['waste_pct'] is not None else 'n/a'}% "
          f"({_money(ratio['waste_usd'])}) | in flight {_money(ratio['in_flight_usd'])} | "
          f"overhead {_money(ratio['overhead_usd'])} | reconciles: {ratio['reconciles']}")
    print("ticket\toutcome\tlane\tlead-h\twall-min\tstage-wall-min\ttokens\tcost-usd\tmodels(stage)")
    for row in data["tickets"]:
        stage_wall = ",".join(f"{stage} {value / 60:.0f}" for stage, value in row["stages_s"].items()) or "-"
        models = ",".join(f"{entry['model']}:{entry['tokens']:,}" if entry["tokens"] is not None
                          else f"{entry['model']}:n/a"
                          for entry in row["models"]) or "-"
        cost = _money(row["cost_usd"]) if row["units"] else "n/a (no units recorded)"
        print("\t".join(str(value) for value in (
            f"#{row['ticket']}", row["outcome"], row.get("lane") or "-",
            row.get("lead_hours") if row.get("lead_hours") is not None else "n/a",
            round(row["wall_s"] / 60, 1) if row["units"] else "n/a",
            stage_wall, _number(row["tokens"]), cost, models,
        )))
    print("by day: " + " | ".join(
        f"{day['day']} delivered {day['delivered']}, cost {_money(day['cost_usd'])}, "
        f"waste {day['waste_pct'] if day['waste_pct'] is not None else 'n/a'}%"
        for day in data["by_day"]))


def _decimal_to_str(value):
    if isinstance(value, Decimal):
        return str(value)
    if isinstance(value, dict):
        return {key: _decimal_to_str(item) for key, item in value.items()}
    if isinstance(value, list):
        return [_decimal_to_str(item) for item in value]
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    report_parser = subparsers.add_parser("report", help="show recent worker token counts and API-list cost")
    report_parser.add_argument("--days", type=float, default=1)
    report_parser.add_argument("--home", default=os.environ.get("AGENT_HOME") or os.environ.get("ZF_HOME")
                               or os.path.expanduser("~/.zenoforge"))
    report_parser.add_argument("--prices", help="use this price table instead of the host default")
    report_parser.add_argument("--json", action="store_true")
    tickets_parser = subparsers.add_parser(
        "tickets", help="per-ticket zero-to-landed cost, output ratio and waste share")
    tickets_parser.add_argument("--days", type=float, default=7)
    tickets_parser.add_argument("--home", default=os.environ.get("AGENT_HOME") or os.environ.get("ZF_HOME")
                                or os.path.expanduser("~/.zenoforge"))
    tickets_parser.add_argument("--prices", help="use this price table instead of the host default")
    tickets_parser.add_argument("--repo", default=None,
                                help="GitHub repo for the issue-createdAt census (default: ZF_REPO, else the example repo)")
    tickets_parser.add_argument("--repo-root", default=None,
                                help="git checkout scanned for revert commits (default: <home>/checkout)")
    tickets_parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    if args.days <= 0:
        parser.error("--days must be positive")
    try:
        if args.command == "report":
            result = report(args.home, args.days, args.prices)
            if not result["worker_units"]:
                print("roi_rollup.py: no unit-loop worker rows in the requested window", file=sys.stderr)
                return 3
            if args.json:
                print(json.dumps(_decimal_to_str(result), indent=2, ensure_ascii=False))
            else:
                _render(result)
            return 0
        result = tickets_report(args.home, args.days, args.prices, args.repo, args.repo_root)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"roi_rollup.py: {error}", file=sys.stderr)
        return 1
    if not result["totals"]["unit_rows"]:
        print("roi_rollup.py: no unit-loop worker rows in the requested window", file=sys.stderr)
        return 3
    if args.json:
        print(json.dumps(_decimal_to_str(result), indent=2, ensure_ascii=False))
    else:
        _render_tickets(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
