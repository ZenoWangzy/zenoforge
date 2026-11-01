#!/usr/bin/env python3
"""Assess bounded service log and container-state rows without raw samples."""

import hashlib
import json
import os
import re
import sys
import tempfile
import time
from collections import Counter
from datetime import datetime
from pathlib import Path

EMAIL = re.compile(r"(?i)\b[A-Z0-9._%+-]+@([A-Z0-9.-]+\.[A-Z]{2,})\b")
URL = re.compile(r"(?i)\b(?:https?|postgres(?:ql)?|mysql|mariadb|redis|mongodb(?:\+srv)?|amqp)://\S+")
SECRET_FIELD = re.compile(
    r"(?i)\b(authorization|api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret|token)\b\s*[:=]\s*(\"[^\"]*\"|'[^']*'|[^,\s}\]]+)"
)
BEARER = re.compile(r"(?i)\bBearer\s+\S+")
UUID = re.compile(r"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b")
TENANT_ID = re.compile(r"(?i)\b(?:t|tenant|member|shard|container)[-_][a-z0-9]{6,}\b")
KEYED_ID = re.compile(r"(?i)\b(trace|request|call|tenant|member|employee|user|session|conversation)[_-]?id[\"']?\s*([=:]+)\s*[\"']?[a-z0-9._:-]{4,}[\"']?")
LONG_ID = re.compile(r"(?<![A-Za-z0-9])[A-Za-z0-9_-]*\d[A-Za-z0-9_-]{3,}(?![A-Za-z0-9])")
NUMBER = re.compile(r"(?<![A-Za-z])\d+(?:\.\d+)?(?![A-Za-z])")
TIMESTAMP = re.compile(r"^(\d{4}-\d\d-\d\dT[^ ]+)\s+(.*)$")
ISO_TIMESTAMP = re.compile(r"\b\d{4}-\d\d-\d\d[T ]\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:?\d\d)?\b", re.I)
PLAIN_STATUS = re.compile(
    r"(?:HTTP/\d(?:\.\d)?[\" ]+|\bstatus(?:_code)?[\"']?\s*[=: ]\s*|\s)([1-5]\d\d)(?![\w.])", re.I
)
ACCESS_LINE = re.compile(r'"(?P<method>GET|POST|PUT|DELETE|PATCH|HEAD|OPTIONS) (?P<path>/[^ "?]*)[^\"]* HTTP/')
TRACE_ID = re.compile(r"(?i)^[a-f0-9]{32}$")
SAFE_REF = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")
ERROR_LEVEL = re.compile(r"\b(?:ERROR|FATAL|CRITICAL)\b", re.I)
STACK_TRACE = re.compile(
    r"Traceback \(most recent call last\):|^\s+File \"[^\"]+\", line \d+|^\s*at [^\r\n]+:\d+|\b[A-Za-z_][A-Za-z0-9_.]*(?:Error|Exception|Fault):",
    re.I | re.M,
)
CONSTRAINT = re.compile(r"\b([A-Za-z_][A-Za-z0-9_.-]{2,80}_(?:pkey|fkey|key|check|unique))\b", re.I)
EXCEPTION = re.compile(r"\b([A-Za-z_][A-Za-z0-9_.]{1,80}(?:Error|Exception|Fault))(?=[:\s]|$)")
SAFE_ERROR_PHRASE = re.compile(r"(?i)\b(quota|rate limit|invalid schema|foreign key|timeout|unauthorized|forbidden|not found|validation failed)\b")
def nested_value(value, keys):
    if isinstance(value, dict):
        for key in keys:
            if key in value and value[key] not in (None, ""):
                return value[key]
        for child in value.values():
            found = nested_value(child, keys)
            if found not in (None, ""):
                return found
    elif isinstance(value, list):
        for child in value:
            found = nested_value(child, keys)
            if found not in (None, ""):
                return found
    return None


def mask_text(value):
    value = str(value)
    value = URL.sub("[url]", value)
    value = EMAIL.sub(lambda match: "k***@" + match.group(1).lower(), value)
    value = BEARER.sub("Bearer [redacted]", value)
    value = SECRET_FIELD.sub(lambda match: match.group(1) + "=[redacted]", value)
    value = re.sub(r"(?i)\bsk-[A-Za-z0-9_-]{8,}", "[redacted]", value)
    return re.sub(r"\b[A-Za-z0-9_=-]{40,}\b", "[redacted]", value)


def normalize(value):
    value = mask_text(value)
    value = ISO_TIMESTAMP.sub("<timestamp>", value)
    value = UUID.sub("<uuid>", value)
    value = TENANT_ID.sub("<id>", value)
    value = KEYED_ID.sub(lambda match: match.group(1) + "_id<id>", value)
    value = LONG_ID.sub("<id>", value)
    value = NUMBER.sub("<n>", value)
    return " ".join(value.lower().split())


def monitor_settings(config):
    production = config.get("production", {}) if isinstance(config, dict) else {}
    names = production.get("container_names", {}) if isinstance(production, dict) else {}
    sources = production.get("log_sources", {}) if isinstance(production, dict) else {}
    rules = config.get("anomaly_rules", {}).get("production_logs", {}) if isinstance(config, dict) else {}
    return {
        "known_containers": set(rules.get("known_containers", names.get("production", []))),
        "container_prefix_labels": rules.get("container_prefix_labels", []),
        "request_id_fields": sources.get("request_id_fields", ["request_id", "requestId", "req_id", "reqId"]),
        "model_group_fields": sources.get("model_group_fields", ["model_group", "model_group_name", "routing_group", "requested_model", "model_name", "model"]),
        "model_gateway_container": rules.get("model_gateway_container", ""),
        "service_gateway_container": rules.get("service_gateway_container", ""),
        "model_gateway_request_paths": rules.get("model_gateway_request_paths", []),
        "model_gateway_label": rules.get("model_gateway_label", "model-service"),
        "service_gateway_label": rules.get("service_gateway_label", "service-gateway"),
        "model_zero_success_reason": rules.get("model_zero_success_reason", "model-group-zero-success"),
        "service_gateway_5xx_reason": rules.get("service_gateway_5xx_reason", "service-gateway-5xx"),
        "service_gateway_database_reason": rules.get("service_gateway_database_reason", "service-gateway-database-error"),
        "production_anomaly_reason": rules.get("production_anomaly_reason", "production-anomaly"),
        "ux_reason": rules.get("ux_reason", "service-ux"),
        "ux_signature_prefix": rules.get("ux_signature_prefix", "service-ux"),
        "ux_container": rules.get("ux_container", "service-ux"),
        "ux_service": rules.get("ux_service", "service-ux"),
        "ux_route": rules.get("ux_route", ""),
        "ux_detail_label": rules.get("ux_detail_label", "service-ux"),
        "ux_standards": rules.get("ux_standards", {}),
        "ux_remember_per_run": rules.get("ux_remember_per_run", 100),
        "summary_names": rules.get("summary_names", {}),
    }


def container_label(value, settings=None):
    settings = settings or monitor_settings({})
    name = str(value or "unknown").lstrip("/")
    if name in settings["known_containers"]:
        return name
    for rule in settings["container_prefix_labels"]:
        if isinstance(rule, dict) and isinstance(rule.get("prefix"), str) and name.startswith(rule["prefix"]):
            label = rule.get("label")
            if isinstance(label, str) and label:
                return label
    if EMAIL.search(name) or UUID.search(name) or TENANT_ID.search(name):
        return "container-<id>"
    return normalize(name)[:80].replace(" ", "_") or "unknown"


def safe_service(value, fallback):
    service = str(value or fallback or "unknown").strip().lower()
    service = EMAIL.sub("<id>", service)
    service = UUID.sub("<id>", service)
    service = TENANT_ID.sub("<id>", service)
    return re.sub(r"[^a-z0-9_.:-]+", "_", service)[:80] or "unknown"


def safe_route(value):
    route = str(value or "").split("?", 1)[0].split("#", 1)[0].strip()
    if not route.startswith("/"):
        return ""
    parts = route.split("/")
    dynamic_after = {"employees", "employee", "members", "member", "users", "user", "tenants", "tenant", "sessions", "session", "conversations", "conversation", "traces", "trace"}
    for index, part in enumerate(parts):
        if not part:
            continue
        if index > 0 and parts[index - 1].lower() in dynamic_after:
            parts[index] = "<id>"
        elif re.fullmatch(r"[:{][A-Za-z0-9_.-]+}?", part):
            parts[index] = "<id>"
        elif UUID.fullmatch(part) or re.fullmatch(r"\d+", part) or EMAIL.fullmatch(part):
            parts[index] = "<id>"
        elif re.search(r"\d", part) and len(part) >= 6:
            parts[index] = "<id>"
    return "/".join(parts)[:120]


def int_value(value):
    try:
        number = int(value)
        return number if 100 <= number <= 599 else None
    except (TypeError, ValueError):
        return None


def clean_trace_id(value):
    value = str(value or "").strip()
    if re.fullmatch(r"(?i)[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}", value):
        value = value.replace("-", "")
    return value.lower() if TRACE_ID.fullmatch(value) else ""


def parse_row(line, settings=None):
    settings = settings or monitor_settings({})
    container, payload = line.split("\t", 1)
    timestamp = "unknown"
    match = TIMESTAMP.match(payload)
    if match:
        timestamp, body = match.groups()
    else:
        body = payload
    try:
        obj = json.loads(body) if body.lstrip().startswith("{") else None
    except (json.JSONDecodeError, TypeError):
        obj = None
    if not isinstance(obj, (dict, list)):
        obj = {}
    status = int_value(nested_value(obj, (
        "response_status_code", "upstream_status", "status_code", "statusCode", "http_status", "response_status", "status"
    )))
    if status is None:
        match = PLAIN_STATUS.search(body)
        status = int_value(match.group(1)) if match else None
    method = str(nested_value(obj, ("method", "http_method")) or "").upper()
    route = safe_route(nested_value(obj, ("http_route", "route", "path", "url_path", "url")))
    access = ACCESS_LINE.search(body)
    if access:
        method = method or access.group("method")
        route = route or safe_route(access.group("path"))
    service = safe_service(nested_value(obj, ("service",)), container_label(container, settings))
    trace_id = clean_trace_id(nested_value(obj, ("trace_id", "traceId")))
    request_obj = nested_value(obj, ("req", "request"))
    request_id = str(nested_value(obj, settings["request_id_fields"]) or "")
    if not request_id and isinstance(request_obj, (dict, list)):
        request_id = str(nested_value(request_obj, ("id", "request_id", "requestId", "reqId")) or "")
    request_id = mask_text(request_id)
    if "[redacted]" in request_id or not SAFE_REF.fullmatch(request_id):
        request_id = ""
    if not trace_id:
        plain_trace = re.search(r"\btrace[_-]?id[\"']?\s*[=:]\s*[\"']?([a-fA-F0-9-]{32,36})", body, re.I)
        trace_id = clean_trace_id(plain_trace.group(1)) if plain_trace else ""
    if not request_id:
        plain_request = re.search(r"\b(?:request|call)[_-]?id[\"']?\s*[=:]\s*[\"']?([A-Za-z0-9._:-]{1,128})", body, re.I)
        request_id = plain_request.group(1) if plain_request else ""
    if not trace_id:
        trace_id = clean_trace_id(request_id)
    level = nested_value(obj, ("level", "severity", "levelname", "log_level"))
    error_obj = nested_value(obj, ("err", "error", "exception"))
    error_type = nested_value(error_obj, ("type", "name", "constructorName")) if isinstance(error_obj, (dict, list)) else ""
    structured_error = bool(re.search(r"(?:Error|Exception|Fault)$", str(error_type or ""), re.I))
    error_level = (
        str(level or "").upper() in {"ERROR", "FATAL", "CRITICAL", "50", "60"}
        or structured_error
        or ERROR_LEVEL.search(body) is not None
    )
    stack_trace = STACK_TRACE.search(body) is not None
    error = bool(error_level or stack_trace or (status is not None and status >= 500))
    code = nested_value(obj, ("error_code", "constraint_name", "constraint", "code", "sqlstate"))
    if not code:
        found = CONSTRAINT.search(body) or EXCEPTION.search(body)
        code = found.group(1) if found else ""
    if not code:
        phrase = SAFE_ERROR_PHRASE.search(body)
        code = phrase.group(1).lower().replace(" ", "-") if phrase else ""
    code = str(code or "").strip()
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.-]{1,80}|[1-5][0-9]{2}|[0-9A-Z]{5}", code, re.I):
        code = ""
    database_error = bool(
        re.search(r"DatabaseError$", str(error_type or ""), re.I)
        or re.fullmatch(r"[0-9A-Z]{5}", code, re.I)
    )
    return {
        "container_raw": container,
        "container": container_label(container, settings),
        "timestamp": timestamp,
        "body": body,
        "status": status,
        "method": method[:10],
        "route": route,
        "service": service,
        "trace_id": trace_id,
        "request_id": request_id if SAFE_REF.fullmatch(request_id) else "",
        "model_group": safe_service(nested_value(obj, settings["model_group_fields"]), "unknown"),
        "fallback": "fallback" in body.lower(),
        "timeout": bool(re.search(r"\b(?:timed?[ -]?out|deadline exceeded)\b", body, re.I)),
        "error_level": bool(error_level),
        "stack_trace": bool(stack_trace),
        "error": error,
        "database_error": database_error,
        "code": code.lower(),
    }


def timestamp_epoch(value):
    if not value or value == "unknown":
        return None
    try:
        text = str(value).replace("Z", "+00:00")
        return datetime.fromisoformat(text).timestamp()
    except ValueError:
        return None


def trace_route(event):
    route = event.get("route") or event.get("http_route") or event.get("path") or ""
    metadata = event.get("metadata_json")
    if isinstance(metadata, dict):
        route = route or metadata.get("http.route") or metadata.get("route") or metadata.get("path") or ""
    method_route = re.match(r"^(?:GET|POST|PUT|DELETE|PATCH|HEAD|OPTIONS)\s+(/\S+)$", str(route), re.I)
    if method_route:
        route = method_route.group(1)
    return safe_route(route)


def trace_service_matches(row, event):
    log_names = {row["service"], row["container"]}
    trace_names = {
        safe_service(event.get("service"), ""),
        safe_service(event.get("container") or event.get("container_name"), ""),
    }
    trace_names.discard("unknown")
    return any(a == b or (len(a) >= 5 and a in b) or (len(b) >= 5 and b in a) for a in log_names for b in trace_names)


def join_trace(row, trace_events):
    row_time = timestamp_epoch(row["timestamp"])
    if row_time is None or not row["route"]:
        return ""
    candidates = []
    for event in trace_events:
        trace_id = clean_trace_id(event.get("trace_id"))
        request_match = bool(row["request_id"] and event.get("request_id") == row["request_id"])
        route_match = trace_route(event) == row["route"]
        if not trace_id or not trace_service_matches(row, event) or not (route_match or request_match):
            continue
        event_time = timestamp_epoch(event.get("started_at") or event.get("ts"))
        if event_time is None or abs(row_time - event_time) > 120:
            continue
        candidates.append((abs(row_time - event_time), trace_id))
    return min(candidates)[1] if candidates else ""


def signature_for(row):
    if row["status"] == 429:
        error_kind = "quota"
    elif row["status"] == 400:
        error_kind = "bad-request"
    elif row["status"] is not None and row["status"] >= 500:
        error_kind = "http-5xx"
    elif row["stack_trace"]:
        error_kind = "stack-trace"
    else:
        error_kind = "error-level"
    route = " ".join(part for part in (row["method"], row["route"]) if part)
    signature = normalize("/".join((row["container"], error_kind, route, row["code"] or "error")))[:320]
    return signature, hashlib.sha256(signature.encode()).hexdigest()[:20]


def load_state(path):
    try:
        state = json.loads(path.read_text())
    except FileNotFoundError:
        return {"version": 2, "signatures": [], "containers": {}, "pending_alerts": [], "sampled_at_epoch": None}, None, False
    except (OSError, json.JSONDecodeError):
        return None, "signature state unreadable", False
    if not isinstance(state, dict) or not isinstance(state.get("signatures", []), list):
        return None, "signature state invalid", False
    legacy = state.get("version") != 2
    return {
        "version": 2,
        "signatures": state.get("signatures", []),
        "containers": state.get("containers", {}) if isinstance(state.get("containers", {}), dict) else {},
        "pending_alerts": state.get("pending_alerts", []) if isinstance(state.get("pending_alerts", []), list) else [],
        "sampled_at_epoch": state.get("sampled_at_epoch"),
    }, None, legacy


def write_state(path, state):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_path = tempfile.mkstemp(prefix=".prod-errors-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as file:
            json.dump(state, file, separators=(",", ":"), sort_keys=True)
            file.write("\n")
        os.chmod(temp_path, 0o600)
        os.replace(temp_path, path)
    finally:
        try:
            os.unlink(temp_path)
        except FileNotFoundError:
            pass


def ack_alerts(path, event_ids):
    state, error, _legacy = load_state(Path(path))
    if error:
        return False
    done = set(event_ids)
    state["pending_alerts"] = [alert for alert in state["pending_alerts"] if alert.get("event_id") not in done]
    write_state(Path(path), state)
    return True


def state_row(line, settings=None):
    settings = settings or monitor_settings({})
    fields = line.split("\t")
    if len(fields) != 7:
        raise ValueError("invalid container state row")
    name, restarts, oom, exit_code, finished, running = fields[1:]
    identity = hashlib.sha256(name.encode()).hexdigest()[:24]
    return identity, {
        "container": container_label(name, settings),
        "restarts": int(restarts),
        "oom": oom.lower() == "true",
        "exit_code": int(exit_code),
        "finished": finished,
        "running": running.lower() == "true",
    }


def ux_is_bad(turn, field, bug):
    value = turn.get(field)
    if bug is None:
        return value is True
    return isinstance(value, (int, float)) and not isinstance(value, bool) and value > bug


def ux_alerts(turns, previous_signatures, settings=None):
    settings = settings or monitor_settings({})
    """One alert per kind for turns not seen before. Every bad turn is remembered in state['signatures']
    (one key per kind+trace), so a turn that stays in the sliding window alerts once, not every minute."""
    alerts = []
    remembered = []
    for kind, rule in settings["ux_standards"].items():
        if not isinstance(rule, dict):
            continue
        field = rule.get("field")
        bug = rule.get("bug")
        if not isinstance(field, str):
            continue
        fresh = []
        for turn in turns:
            trace = clean_trace_id(turn.get("trace_id"))
            if not trace or not ux_is_bad(turn, field, bug):
                continue
            signature = f"{settings['ux_signature_prefix']}/{kind}/{trace}"
            key = hashlib.sha256(signature.encode()).hexdigest()[:20]
            if len(remembered) < settings["ux_remember_per_run"]:
                remembered.append({"key": key, "signature": signature, "last_count": 1})
            if key not in previous_signatures:
                fresh.append((trace, turn))
        if not fresh:
            continue
        kind_signature = f"{settings['ux_signature_prefix']}/{kind}"
        batch = hashlib.sha256("|".join(sorted(trace for trace, _ in fresh)).encode()).hexdigest()[:12]
        alerts.append({
            "key": hashlib.sha256(kind_signature.encode()).hexdigest()[:20], "signature": kind_signature, "count": len(fresh),
            "first": min(str(turn.get("started_at") or "unknown") for _, turn in fresh), "container": settings["ux_container"],
            "service": settings["ux_service"], "route": settings["ux_route"], "status": None, "code": kind,
            "trace_id": fresh[0][0], "sample_request_id": "", "request_id_seen": False,
            "deduplicated_lines": [
                f"trace={trace} first_visible_ms={turn.get('first_visible_ms')} silent_gap_ms={turn.get('silent_gap_ms')} "
                f"errored={turn.get('errored')} stuck={turn.get('stuck')}"
                for trace, turn in fresh[:20]
            ],
            "source": "ux", "reason": kind, "event_id": f"ux-{kind}-{batch}",
        })
    return alerts, remembered


def assess(raw, state_path, window="10m", min_requests=10, non_2xx_percent=20, now_epoch=None, config=None):
    settings = monitor_settings(config or {})
    lines = raw.splitlines()
    if not lines or lines[0] != "__PROD_ERRORS_OK__":
        reason = " ".join(mask_text("\n".join(lines[1:])).split())[:600] if lines and lines[0] == "__PROD_ERRORS_READ_FAILED__" else ""
        detail = "production log read failed" + (": " + reason if reason else "")
        return {"verdict": "UNKNOWN", "detail": detail, "alerts": [], "new_signatures": []}
    state, state_error, legacy_state = load_state(Path(state_path))
    if state_error:
        return {"verdict": "UNKNOWN", "detail": state_error, "alerts": [], "new_signatures": []}

    rows = []
    traces = []
    current_containers = {}
    incomplete = False
    container_state_ok = True
    trace_read_failed = False
    ux_turns = []
    ux_read_failed = False
    malformed = False
    for line in lines[1:]:
        if not line:
            continue
        if line.startswith("__PROD_ERRORS_READ_FAILED__") or line.startswith("__PROD_ERRORS_TRUNCATED__"):
            incomplete = True
            continue
        if line == "__CONTAINER_STATE_READ_FAILED__":
            incomplete = True
            container_state_ok = False
            continue
        if line == "__TRACE_READ_FAILED__":
            trace_read_failed = True
            continue
        if line == "__UX_READ_FAILED__":
            ux_read_failed = True
            continue
        if line.startswith("__UX__\t"):
            try:
                turn = json.loads(line.split("\t", 1)[1])
                if isinstance(turn, dict):
                    ux_turns.append(turn)
            except json.JSONDecodeError:
                ux_read_failed = True
            continue
        if line.startswith("__CONTAINER_STATE__\t"):
            identity, current = state_row(line, settings)
            current_containers[identity] = current
            continue
        if line.startswith("__TRACE__\t"):
            try:
                event = json.loads(line.split("\t", 1)[1])
                if isinstance(event, dict):
                    traces.append(event)
            except json.JSONDecodeError:
                trace_read_failed = True
            continue
        if "\t" not in line:
            malformed = True
            incomplete = True
            continue
        try:
            rows.append(parse_row(line, settings))
        except (ValueError, TypeError):
            malformed = True
            incomplete = True

    if malformed:
        return {"verdict": "UNKNOWN", "detail": "production log sample malformed", "alerts": [], "new_signatures": []}

    groups = {}
    outcome_keys = set()
    signatures = {}
    gateway_span_failed = 0
    gateway_statuses = Counter()
    gateway_5xx = 0
    gateway_database_errors = 0
    for row in rows:
        body = row["body"]
        status = row["status"]
        if settings["model_gateway_container"] and row["container_raw"].lstrip("/") == settings["model_gateway_container"]:
            access = ACCESS_LINE.search(body)
            if access and settings["model_gateway_request_paths"] and not access.group("path").endswith(tuple(settings["model_gateway_request_paths"])):
                continue
            if status is not None:
                outcome = "timeout" if row["timeout"] else "2xx" if 200 <= status < 300 else str(status) if status in (400, 429) else "5xx" if status >= 500 else "other_non2xx"
                group = groups.setdefault(row["model_group"], Counter())
                dedupe = (row["request_id"], outcome) if row["request_id"] else None
                if dedupe is None or dedupe not in outcome_keys:
                    group["requests"] += 1
                    group[outcome] += 1
                    if outcome not in ("2xx", "timeout"):
                        group["non2xx"] += 1
                    if outcome == "timeout":
                        group["non2xx"] += 1
                    if dedupe:
                        outcome_keys.add(dedupe)
            if row["fallback"]:
                groups.setdefault(row["model_group"], Counter())["fallbacks"] += 1
        if settings["service_gateway_container"] and row["container_raw"].lstrip("/") == settings["service_gateway_container"]:
            is_span_failed = "span_failed" in body.lower()
            if is_span_failed:
                gateway_span_failed += 1
                if status is not None:
                    gateway_statuses[str(status)] += 1
            if status is not None and status >= 500:
                gateway_5xx += 1
            if row["database_error"]:
                gateway_database_errors += 1
        if not row["error"]:
            continue
        if not row["trace_id"]:
            row["trace_id"] = join_trace(row, traces)
        signature, key = signature_for(row)
        current = signatures.setdefault(key, {
            "key": key, "signature": signature, "count": 0, "first": row["timestamp"],
            "container": row["container"], "service": row["service"], "route": row["route"],
            "status": row["status"], "code": row["code"], "trace_id": row["trace_id"],
            "sample_request_id": row["request_id"],
            "request_id_seen": False, "deduplicated_lines": [], "_line_keys": set(),
        })
        current["count"] += 1
        if row["timestamp"] != "unknown" and (current["first"] == "unknown" or row["timestamp"] < current["first"]):
            current["first"] = row["timestamp"]
        if not current["trace_id"] and row["trace_id"]:
            current["trace_id"] = row["trace_id"]
        current["request_id_seen"] = current["request_id_seen"] or bool(row["request_id"])
        if not current["sample_request_id"] and row["request_id"]:
            current["sample_request_id"] = row["request_id"]
        safe_line = " ".join(part for part in (
            f"service={row['service']}",
            f"route={row['method']} {row['route']}".strip(),
            f"status={row['status']}" if row["status"] is not None else "",
            f"code={row['code']}" if row["code"] else "",
            f"trace={row['trace_id']}" if row["trace_id"] else "trace=none",
            f"request_id={row['request_id']}" if row["request_id"] else "",
        ) if part)
        if safe_line not in current["_line_keys"]:
            current["_line_keys"].add(safe_line)
            if len(current["deduplicated_lines"]) < 20:
                current["deduplicated_lines"].append(safe_line)

    previous_signatures = {
        entry.get("key"): entry for entry in state["signatures"]
        if isinstance(entry, dict) and isinstance(entry.get("key"), str)
    }
    alerts = []
    for key, entry in signatures.items():
        previous = previous_signatures.get(key, {})
        previous_count = previous.get("last_count")
        reason = ""
        if legacy_state or key not in previous_signatures:
            reason = "first-seen"
        elif isinstance(previous_count, int) and entry["count"] >= max(3, previous_count * 2):
            reason = "rate-spike"
        if reason:
            alerts.append({
                **{k: v for k, v in entry.items() if not k.startswith("_")},
                "source": "log", "reason": reason,
                "event_id": f"{reason}-{entry['count']}-{entry['first']}",
            })

    now_epoch = float(now_epoch if now_epoch is not None else time.time())
    previous_containers = state["containers"]
    current_alerts = []
    if container_state_ok:
        for identity, current in current_containers.items():
            previous = previous_containers.get(identity)
            previous_restarts = previous.get("restarts", current["restarts"]) if previous else current["restarts"]
            restart_delta = max(0, current["restarts"] - previous_restarts)
            if restart_delta:
                current_alerts.append((identity, current, "container-restart", restart_delta, f"restart-{current['restarts']}"))
            finished_epoch = timestamp_epoch(current["finished"])
            previous_sample = state.get("sampled_at_epoch")
            oom_is_new = (previous and not previous.get("oom")) or (
                not previous and finished_epoch is not None and previous_sample is not None
                and finished_epoch > float(previous_sample))
            if current["oom"] and oom_is_new:
                current_alerts.append((identity, current, "container-oom", 1, f"oom-{current['finished']}"))
            if not current["running"] and current["exit_code"] != 0 and finished_epoch is not None and previous_sample is not None and finished_epoch > float(previous_sample):
                current_alerts.append((identity, current, "container-nonzero-exit", 1, f"exit-{current['finished']}"))
        for identity, current, kind, count, event_id in current_alerts:
            signature = f"{current['container']}/{kind}"
            key = hashlib.sha256(signature.encode()).hexdigest()[:20]
            alerts.append({
                "key": key, "signature": signature, "count": count,
                "first": current["finished"] if current["finished"] != "0001-01-01T00:00:00Z" else "unknown",
                "container": current["container"], "service": current["container"],
                "route": "", "status": current["exit_code"] if kind == "container-nonzero-exit" else None,
                "code": kind, "trace_id": "", "request_id_seen": False,
                "deduplicated_lines": [f"container={current['container']} {kind} restarts={current['restarts']} exit={current['exit_code']} oom={str(current['oom']).lower()}"],
                "source": "container", "reason": kind, "event_id": event_id,
            })

    ux_found, ux_remembered = ux_alerts(ux_turns, previous_signatures, settings)
    alerts.extend(ux_found)

    updated_signatures = []
    for key, previous in previous_signatures.items():
        updated_signatures.append({
            "key": key, "signature": previous.get("signature", ""),
            "last_count": signatures[key]["count"] if key in signatures else 0,
        })
    for key, entry in signatures.items():
        if key not in previous_signatures:
            updated_signatures.append({"key": key, "signature": entry["signature"], "last_count": entry["count"]})
        else:
            for item in updated_signatures:
                if item["key"] == key:
                    item["last_count"] = entry["count"]
                    break
    updated_signatures.extend(entry for entry in ux_remembered if entry["key"] not in previous_signatures)
    state["signatures"] = updated_signatures[-512:]
    if container_state_ok:
        state["containers"] = current_containers
        state["sampled_at_epoch"] = now_epoch

    total_requests = sum(group["requests"] for group in groups.values())
    total_non2xx = sum(group["non2xx"] for group in groups.values())
    ratio = (total_non2xx * 100 / total_requests) if total_requests else 0
    bad_ratio = total_requests >= min_requests and ratio >= non_2xx_percent
    no_success_groups = sorted(name for name, group in groups.items() if name != "unknown" and group["requests"] and not group["2xx"])
    detected_alerts = alerts.copy()
    pending = {alert.get("event_id"): alert for alert in state["pending_alerts"] if isinstance(alert, dict) and alert.get("event_id")}
    for alert in detected_alerts:
        pending[alert["event_id"]] = alert
    state["pending_alerts"] = list(pending.values())[-512:]
    visible_alerts = list(pending.values())
    new_error = any(alert["reason"] in {"first-seen", "rate-spike"} for alert in detected_alerts)
    reasons = []
    if bad_ratio:
        reasons.append("non2xx-ratio")
    if no_success_groups:
        reasons.append(settings["model_zero_success_reason"])
    if gateway_5xx:
        reasons.append(settings["service_gateway_5xx_reason"])
    if gateway_database_errors:
        reasons.append(settings["service_gateway_database_reason"])
    if new_error or current_alerts:
        reasons.append(settings["production_anomaly_reason"])
    if ux_found:
        reasons.append(settings["ux_reason"])
    verdict = "BROKEN" if reasons else ("UNKNOWN" if incomplete or not container_state_ok else "OK")
    statuses = ",".join(f"{code}:{count}" for code, count in sorted(gateway_statuses.items(), key=lambda item: int(item[0]))) or "none"
    group_summary = " ; ".join(
        f"{name}{{2xx={group['2xx']},429={group['429']},400={group['400']},5xx={group['5xx']},other={group['other_non2xx']},timeouts={group['timeout']},fallbacks={group['fallbacks']},requests={group['requests']}}}"
        for name, group in sorted(groups.items())
    ) or "none"
    signature_count = sum(entry["count"] for entry in signatures.values())
    summary_names = settings["summary_names"]
    model_gateway_label = summary_names.get("model_gateway", settings["model_gateway_label"])
    gateway_label = summary_names.get("service_gateway", settings["service_gateway_label"])
    ux_label = summary_names.get("ux", settings["ux_detail_label"])
    ux_turns_label = summary_names.get("ux_turns", settings["ux_detail_label"])
    detail = (
        f"window={window} reasons={','.join(reasons) or 'none'} log-errors={signature_count} alerts={len(alerts)} "
        f"containers={len(current_containers)} {model_gateway_label} requests={total_requests} non2xx={total_non2xx} ratio={ratio:.0f}% groups={group_summary} "
        f"{gateway_label} span_failed={gateway_span_failed} statuses={statuses} 5xx={gateway_5xx} database-errors={gateway_database_errors} "
        f"coverage={'partial' if incomplete or not container_state_ok else 'complete'} "
        f"trace-join={'unavailable' if trace_read_failed else 'available'} "
        f"{ux_turns_label}-turns={len(ux_turns)} {ux_label}={'unavailable' if ux_read_failed else 'available'}"
    )
    try:
        write_state(Path(state_path), state)
    except (OSError, UnicodeError):
        return {"verdict": "UNKNOWN", "detail": "signature state write failed; " + detail, "alerts": [], "new_signatures": []}
    visible_alerts = [{k: v for k, v in alert.items() if not k.startswith("_")} for alert in visible_alerts]
    new_signatures = [alert for alert in detected_alerts if alert["reason"] == "first-seen"]
    return {"verdict": verdict, "detail": detail, "alerts": visible_alerts, "new_signatures": new_signatures}


def main():
    if len(sys.argv) >= 4 and sys.argv[1] == "--ack":
        if not ack_alerts(sys.argv[2], sys.argv[3:]):
            return 1
        return 0
    config_path = None
    arguments = sys.argv[1:]
    if len(arguments) >= 2 and arguments[0] == "--config":
        config_path, *arguments = arguments[1:]
    if len(arguments) != 4:
        print(json.dumps({"verdict": "UNKNOWN", "detail": "invalid monitor configuration", "alerts": [], "new_signatures": []}))
        return 2
    try:
        config = json.loads(Path(config_path).read_text()) if config_path else {}
        state_path, window, min_requests, ratio = arguments
        result = assess(sys.stdin.read(), state_path, window, int(min_requests), int(ratio), config=config)
    except (OSError, ValueError, TypeError, UnicodeError):
        result = {"verdict": "UNKNOWN", "detail": "monitor assessment failed", "alerts": [], "new_signatures": []}
    print(json.dumps(result, separators=(",", ":"), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
