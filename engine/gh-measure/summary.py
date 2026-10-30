#!/usr/bin/env python3
"""Summarize gh-measure rows: where the pipeline's GitHub calls come from, how often they fail, how long they take."""
import sys
from collections import defaultdict
from datetime import datetime


def p50(values):
    values = sorted(values)
    return values[len(values) // 2] if values else 0


def spikes(path, now=None):
    """Call sites with >=50% failures in the last hour whose prior 24 h failure rate was below 5%."""
    now = now or datetime.now().astimezone().timestamp()
    recent, prior = defaultdict(lambda: [0, 0]), defaultdict(lambda: [0, 0])
    for line in open(path, encoding="utf-8", errors="replace"):
        f = line.rstrip("\n").split("\t")
        if len(f) != 7 or not f[5].lstrip("-").isdigit():
            continue
        try:
            age = now - datetime.fromisoformat(f[0].replace("Z", "+00:00")).timestamp()
        except ValueError:
            continue
        if not 0 <= age < 25 * 3600:
            continue
        bucket = recent if age < 3600 else prior
        bucket[(f[2], f[3], f[4])][0] += 1
        bucket[(f[2], f[3], f[4])][1] += f[5] != "0"
    for site, (calls, bad) in sorted(recent.items()):
        p_calls, p_bad = prior[site]
        if 2 * bad >= calls and (p_calls == 0 or 20 * p_bad < p_calls):
            print(" ".join(x for x in site if x), f"{100 * bad // calls}%", sep="\t")
    return 0


def main(path, top=25):
    rows = []
    for line in open(path, encoding="utf-8", errors="replace"):
        f = line.rstrip("\n").split("\t")
        if len(f) == 7 and f[5].lstrip("-").isdigit() and f[6].lstrip("-").isdigit():
            rows.append((f[0], f[1], f[2], f[3], f[4], int(f[5]), int(f[6])))
    if not rows:
        print("no rows")
        return 1
    first, last = (datetime.fromisoformat(r.replace("Z", "+00:00")) for r in (rows[0][0], rows[-1][0]))
    hours = max((last - first).total_seconds() / 3600, 1 / 60)
    fails = sum(1 for r in rows if r[5] != 0)
    print(f"{len(rows)} gh calls over {hours:.1f} h = {len(rows) / hours:.0f}/h; "
          f"failed {fails} ({100 * fails / len(rows):.1f}%); gh wall time {sum(r[6] for r in rows) / 3600000:.2f} h")
    for title, key in (("by unit", lambda r: r[1]), ("by call site", lambda r: (r[2], r[3], r[4]))):
        groups = defaultdict(list)
        for r in rows:
            groups[key(r)].append(r)
        print(f"\n{title}: calls/h  fail%  p50ms  total_min  key")
        for k, g in sorted(groups.items(), key=lambda kv: -len(kv[1]))[:top]:
            bad = sum(1 for r in g if r[5] != 0)
            label = k if isinstance(k, str) else " ".join(x for x in k if x)
            print(f"  {len(g) / hours:8.1f}  {100 * bad / len(g):5.1f}  {p50([r[6] for r in g]):5d}  "
                  f"{sum(r[6] for r in g) / 60000:9.1f}  {label}")
    return 0


if __name__ == "__main__":
    if sys.argv[1] == "spikes":
        sys.exit(spikes(sys.argv[2], float(sys.argv[3]) if len(sys.argv) > 3 else None))
    sys.exit(main(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 25))
