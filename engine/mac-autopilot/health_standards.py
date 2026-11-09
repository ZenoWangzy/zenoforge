"""Load measured node-health bounds and apply them with sample-aware statuses."""
import json, math, os, re, sys
from pathlib import Path

from config_paths import zf_config_file


def resolve(criteria):
    resolved = dict(criteria)
    minimums = {mid: 10 for mid in resolved if re.search(r"_p(?:50|90|95)(?:_|$)", mid)}
    bases, invalid, unknown = {}, set(), set()
    default = Path(__file__).with_name("health-standards.json")
    target = zf_config_file("mac-autopilot/health-standards.json")
    paths = [default] if default.is_file() else []
    target = Path(target) if target else None
    if target and target.resolve() != default.resolve() and (target.exists() or target.is_symlink()): paths.append(target)
    for path in paths:
        try:
            doc = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            invalid.update(resolved); print(f"health standards unusable file={path.name}: {exc}; all metrics STANDARD-INVALID", file=sys.stderr); continue
        if not isinstance(doc, dict):
            invalid.update(resolved); print(f"health standards invalid file={path.name}: expected an object; all metrics STANDARD-INVALID", file=sys.stderr); continue
        for mid, entry in doc.items():
            if mid not in resolved:
                if mid not in unknown: print(f"health standard ignored metric={mid}: unknown metric id", file=sys.stderr); unknown.add(mid)
                continue
            valid = isinstance(entry, dict)
            basis = entry.get("basis") if valid else None
            healthy, unhealthy = (entry.get(k) for k in ("healthy", "unhealthy")) if valid else (None, None)
            node, desc, _, _, higher = resolved[mid]
            valid = valid and isinstance(basis, str) and len(basis.strip()) >= 20
            valid = valid and all(isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) for v in (healthy, unhealthy))
            valid = valid and (unhealthy <= healthy if higher else healthy <= unhealthy)
            if valid and "min_n" in entry: valid = type(entry["min_n"]) is int and entry["min_n"] > 0
            if not valid: invalid.add(mid); print(f"health standard invalid metric={mid}: basis or bounds are invalid; keeping default", file=sys.stderr); continue
            resolved[mid] = (node, desc, healthy, unhealthy, higher); bases[mid] = basis.strip()
            if "min_n" in entry: minimums[mid] = entry["min_n"]
            invalid.discard(mid)
    return resolved, minimums, bases, invalid


def score(metrics, criteria, sample_counts, minimums, invalid_standards, status_of, no_data_status, not_applicable):
    rows = []
    for mid, (node, desc, healthy, unhealthy, higher) in criteria.items():
        v = metrics.get(mid)
        status = "STANDARD-INVALID" if mid in invalid_standards else no_data_status(mid, v) or ("N/A" if v is None and mid in not_applicable else status_of(v, healthy, unhealthy, higher))
        if status != "STANDARD-INVALID" and v is not None and mid in minimums and (n := sample_counts.get(mid)) is not None and n < minimums[mid]: status = "LOW-N"
        rows.append((node, mid, desc, v, healthy, unhealthy, higher, status))
    return rows


def _append_hourly_alert(path, hour, key, line):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    seen = open(path, errors="ignore").read() if os.path.exists(path) else ""
    stamp = f"[{hour}"
    if stamp in seen and key in seen.split(stamp, 1)[1]: return
    with open(path, "a") as out: out.write(line)


def write_health_alerts(runtime, agent_home, rows, now, display_value, doc_reference):
    alertable = [r for r in rows if r[7] in ("UNHEALTHY", "STANDARD-INVALID")]
    invalid = [r for r in alertable if r[7] == "STANDARD-INVALID"]
    path = os.path.join(runtime, "alerts", "node-health.md"); hour = f"{now:%Y-%m-%dT%H}"
    for node, mid, desc, v, healthy, unhealthy, higher, status in alertable:
        marker = "NODE-STANDARD-INVALID" if status == "STANDARD-INVALID" else "NODE-UNHEALTHY"
        detail = "status=STANDARD-INVALID" if status == "STANDARD-INVALID" else f"unhealthy-bound={unhealthy}"
        line = f"[{now:%Y-%m-%dT%H:%M:%SZ}] {marker} metric={mid} node={node} value={display_value(v)} {detail} ({desc}; see {doc_reference()})\n"
        _append_hourly_alert(path, hour, f"{marker} metric={mid} ", line)
    if invalid:
        line = f"[{now:%Y-%m-%dT%H:%M:%SZ}] NODE-STANDARD-INVALID metrics={len(invalid)} (see node-health scorecard)\n"
        _append_hourly_alert(os.path.join(agent_home, "logs", "head-watch.alerts"), hour, "NODE-STANDARD-INVALID ", line)
