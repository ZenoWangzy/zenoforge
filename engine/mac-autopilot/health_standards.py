"""Load measured node-health bounds and apply them with sample-aware statuses."""
import json, math, re, sys
from pathlib import Path

from config_paths import zf_config_file


def resolve(criteria):
    resolved = dict(criteria)
    minimums = {mid: 10 for mid in resolved if re.search(r"_p(?:50|90|95)(?:_|$)", mid)}
    bases, invalid, unknown = {}, set(), set()
    default = Path(__file__).with_name("health-standards.json")
    target = zf_config_file("mac-autopilot/health-standards.json")
    paths = [default] if default.is_file() else []
    if target and Path(target).resolve() != default.resolve():
        paths.append(Path(target))
    for path in paths:
        try:
            doc = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc: print(f"health standards unreadable file={path.name}: {exc}", file=sys.stderr); continue
        if not isinstance(doc, dict): print(f"health standards invalid file={path.name}: expected an object", file=sys.stderr); continue
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
