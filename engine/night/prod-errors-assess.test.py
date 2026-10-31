#!/usr/bin/env python3
import importlib.util
import json
import tempfile
from pathlib import Path

module_path = Path(__file__).with_name("prod-errors-assess.py")
spec = importlib.util.spec_from_file_location("monitor_assess", module_path)
monitor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(monitor)


def settings():
    return {
        "production": {
            "container_names": {"production": ["model-service", "gateway-service"]},
            "log_sources": {
                "request_id_fields": ["request_id", "requestId"],
                "model_group_fields": ["model_group", "model"],
            },
        },
        "anomaly_rules": {
            "production_logs": {
                "known_containers": ["model-service", "gateway-service"],
                "container_prefix_labels": [{"prefix": "worker-", "label": "worker-<id>"}],
                "model_gateway_container": "model-service",
                "service_gateway_container": "gateway-service",
                "model_gateway_request_paths": ["/chat/completions", "/responses"],
                "model_gateway_label": "configured-model-backend",
                "service_gateway_label": "configured-service-gateway",
                "model_zero_success_reason": "configured-zero-success",
                "service_gateway_5xx_reason": "configured-gateway-5xx",
                "service_gateway_database_reason": "configured-gateway-database-error",
                "production_anomaly_reason": "configured-production-anomaly",
                "ux_reason": "configured-ux",
                "ux_signature_prefix": "configured-ux",
                "ux_container": "configured-ux-container",
                "ux_service": "configured-ux-service",
                "ux_route": "configured.route",
                "ux_detail_label": "configured-ux",
                "ux_standards": {
                    "slow-start": {"field": "first_visible_ms", "bug": 1000},
                    "failed-turn": {"field": "errored", "bug": None},
                },
                "ux_remember_per_run": 10,
                "summary_names": {
                    "model_gateway": "configured-model",
                    "service_gateway": "configured-gateway",
                    "ux": "configured-ux",
                },
            },
        },
    }


def row(container, fields, minute="01"):
    timestamp = f"2026-10-11T12:{minute}:00Z"
    return f"{container}\t{timestamp} {json.dumps(fields, separators=(',', ':'))}"


def assess(raw, state, config=None):
    return monitor.assess(raw, state, now_epoch=1791720060, config=config or settings())


def test_masks_credentials_and_private_identifiers():
    raw = "\n".join([
        "__PROD_ERRORS_OK__",
        row("service-api", {
            "service": "api", "method": "DELETE", "path": "/users/12345678-1234-4234-8234-123456789abc",
            "status_code": 500, "request_id": "request-1234",
            "message": "constraint_key prompt=PRIVATE-TEXT Authorization: Bearer PRIVATE-TOKEN",
        }),
    ])
    with tempfile.TemporaryDirectory() as directory:
        state = Path(directory) / "seen.json"
        result = assess(raw, state)
    assert result["verdict"] == "BROKEN", result
    alert = result["alerts"][0]
    assert alert["route"] == "/users/<id>" and alert["sample_request_id"] == "request-1234", alert
    encoded = json.dumps(result)
    assert "PRIVATE-TEXT" not in encoded and "PRIVATE-TOKEN" not in encoded and "Bearer" not in encoded
    print("ok - alert masking keeps identifiers and credentials out of evidence")


def test_gateway_counters_and_configured_labels():
    raw = "\n".join([
        "__PROD_ERRORS_OK__",
        row("model-service", {"model_group": "group-a", "request_id": "request-a", "status": 503}),
        row("gateway-service", {
            "level": 50, "request_id": "request-b", "path": "/resource",
            "status_code": 500, "error": {"type": "DatabaseError", "code": "40P01"},
        }),
    ])
    with tempfile.TemporaryDirectory() as directory:
        state = Path(directory) / "seen.json"
        result = assess(raw, state)
        assert result["verdict"] == "BROKEN", result
        assert "configured-gateway-5xx" in result["detail"], result
        assert "configured-gateway-database-error" in result["detail"], result
        assert "configured-model requests=1" in result["detail"], result
        alert = result["alerts"][0]
        assert alert["container"] == "gateway-service" and alert["request_id_seen"], alert
        assert monitor.ack_alerts(state, [alert["event_id"]])
        repeated = assess(raw, state)
        assert repeated["verdict"] == "BROKEN" and not repeated["alerts"], repeated
    print("ok - configured service roles drive counters, labels, and deduplication")


def test_configured_ux_rules_and_container_aliases():
    raw = "\n".join([
        "__PROD_ERRORS_OK__",
        "__CONTAINER_STATE__\tworker-abcdef12\t1\tfalse\t0\t2026-10-11T12:00:00Z\ttrue",
        "__UX__\t" + json.dumps({
            "trace_id": "0123456789abcdef0123456789abcdef", "started_at": "2026-10-11T12:00:00Z",
            "first_visible_ms": 1500, "errored": False,
        }),
    ])
    with tempfile.TemporaryDirectory() as directory:
        state = Path(directory) / "seen.json"
        result = assess(raw, state)
        state_data = json.loads(state.read_text())
    assert result["verdict"] == "BROKEN", result
    ux = next(alert for alert in result["alerts"] if alert["source"] == "ux")
    assert ux["container"] == "configured-ux-container", ux
    assert ux["service"] == "configured-ux-service" and ux["route"] == "configured.route", ux
    assert any(item["container"] == "worker-<id>" for item in state_data["containers"].values()), state_data
    print("ok - configured UX thresholds and container aliases are applied")


def test_config_override_drives_assessment_values():
    target = settings()
    pack = settings()
    target["anomaly_rules"]["production_logs"]["service_gateway_5xx_reason"] = "target-rule"
    pack["anomaly_rules"]["production_logs"]["service_gateway_5xx_reason"] = "pack-rule"
    raw = "__PROD_ERRORS_OK__\n" + row("gateway-service", {"status_code": 503})
    with tempfile.TemporaryDirectory() as directory:
        state = Path(directory) / "seen.json"
        result = assess(raw, state, target)
    assert "target-rule" in result["detail"] and "pack-rule" not in result["detail"], result
    print("ok - target configuration values override retained pack settings")


def test_rate_spike_and_state_acknowledgement():
    raw = "__PROD_ERRORS_OK__\n" + row("service-api", {
        "service": "api", "path": "/items", "status_code": 500, "constraint": "items_owner_id_fkey",
    })
    with tempfile.TemporaryDirectory() as directory:
        state = Path(directory) / "seen.json"
        first = assess(raw, state)
        assert len(first["alerts"]) == 1, first
        assert monitor.ack_alerts(state, [first["alerts"][0]["event_id"]])
        burst = assess("\n".join(["__PROD_ERRORS_OK__"] + [row("service-api", {
            "service": "api", "path": "/items", "status_code": 500, "constraint": "items_owner_id_fkey",
        }, f"{minute:02d}") for minute in range(1, 4)]), state)
    assert len(burst["alerts"]) == 1 and burst["alerts"][0]["reason"] == "rate-spike", burst
    print("ok - repeated signatures produce one rate-spike alert")


if __name__ == "__main__":
    test_masks_credentials_and_private_identifiers()
    test_gateway_counters_and_configured_labels()
    test_configured_ux_rules_and_container_aliases()
    test_config_override_drives_assessment_values()
    test_rate_spike_and_state_acknowledgement()
