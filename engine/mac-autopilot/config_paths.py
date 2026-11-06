"""Resolve shared config data in target, pack, then engine order."""
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from env_config import zf_env

INCIDENT_GUARDS = "state/incident-guards.json"
MECHANISM_REGISTRY = "state/mechanism-registry.json"
MECHANISM_REQUIRED_FIELDS = ("id", "desc", "supervisor", "silence_hours", "events")


def zf_config_file(relative_path):
    path = Path(relative_path)
    if path.is_absolute() or ".." in path.parts:
        raise ValueError("config path must be relative and cannot contain a .. segment")

    engine_dir = Path(os.environ.get("ZF_ENGINE_DIR") or Path(__file__).resolve().parent.parent)
    repo_dir = Path(zf_env("REPO_DIR") or engine_dir.parent)
    if "ZF_CONFIG_ROOT" in os.environ:
        configured_root = os.environ["ZF_CONFIG_ROOT"]
        config_root = Path(configured_root) if configured_root else None
    else:
        config_root = repo_dir / ".zenoforge"
    pack_dir = Path(os.environ["ZF_PACK_DIR"]) if os.environ.get("ZF_PACK_DIR") else None

    candidates = [
        config_root / path if config_root else None,
        pack_dir / path if pack_dir else None,
        engine_dir / path,
    ]
    for candidate in candidates:
        if candidate is not None and candidate.is_file():
            return candidate
    return None


def zf_mechanism_registry(overlay=None):
    """The engine registry with the resolved overlay merged over it by id, field by field.

    An overlay holds only what it overrides, so an engine edit to anything else stays live.
    """
    engine_dir = Path(os.environ.get("ZF_ENGINE_DIR") or Path(__file__).resolve().parent.parent)
    engine_path = engine_dir / MECHANISM_REGISTRY
    overlay_path = Path(overlay) if overlay else zf_config_file(MECHANISM_REGISTRY)
    try:
        doc = json.loads(engine_path.read_text(encoding="utf-8")) if engine_path.is_file() else {"mechanisms": []}
        rows = {row["id"]: row for row in doc["mechanisms"]}
    except (OSError, ValueError, KeyError, TypeError):
        return None
    if overlay_path is not None and overlay_path != engine_path:
        overlaid = dict(rows)
        try:
            for row in json.loads(overlay_path.read_text(encoding="utf-8"))["mechanisms"]:
                merged = {**overlaid.get(row.get("id"), {}), **row}
                # A partial row whose id left the engine has nothing to merge over and would break the scorecard.
                if all(merged.get(field) for field in MECHANISM_REQUIRED_FIELDS):
                    overlaid[merged["id"]] = merged
            rows = overlaid
        except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
            # All or nothing. Engine rows still report; no rows at all would read as no data and raise nothing.
            print(f"mechanism registry overlay {overlay_path} ignored: {error!r}", file=sys.stderr)
    return {**doc, "mechanisms": list(rows.values())} if rows else None


def zf_incident_guards(target=None):
    """The target's incident records, then engine records under an id the target lacks.

    For reports, so a lesson the target never copied is still seen. Validators, writers and the
    lesson_id join in generate-lesson-enforcers keep the target file: engine lesson ids mean other rules there.
    """
    engine_dir = Path(os.environ.get("ZF_ENGINE_DIR") or Path(__file__).resolve().parent.parent)
    engine_path = engine_dir / INCIDENT_GUARDS
    target_path = Path(target) if target else zf_config_file(INCIDENT_GUARDS)
    if target_path is None:
        return None
    doc = json.loads(target_path.read_text(encoding="utf-8"))
    if target_path == engine_path or not engine_path.is_file():
        return doc
    try:
        seen = {row.get("id") for row in doc["incidents"]}
        engine_rows = json.loads(engine_path.read_text(encoding="utf-8"))["incidents"]
        return {**doc, "incidents": doc["incidents"] + [row for row in engine_rows if row.get("id") not in seen]}
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        print(f"engine incident records ignored: {error!r}", file=sys.stderr)
        return doc


def zf_host_ops_file(relative_path, fallback=None):
    engine_dir = Path(os.environ.get("ZF_ENGINE_DIR") or Path(__file__).resolve().parent.parent)
    agent_home = Path(os.environ.get("AGENT_HOME") or os.environ.get("ZF_HOME") or Path.home() / ".zenoforge")
    host_ops = Path(os.environ.get("ZF_HOST_OPS_DIR") or agent_home / "host-ops")
    built_alias = relative_path.startswith("engine/")
    compare_built = built_alias or relative_path.startswith("scripts/agent/")
    host_ops_relative = f"scripts/agent/{relative_path.removeprefix('engine/')}" if built_alias else relative_path
    candidate = host_ops / host_ops_relative
    if fallback is not None:
        fallback_path = Path(fallback)
    elif built_alias:
        fallback_path = engine_dir / relative_path.removeprefix("engine/")
    else:
        fallback_path = engine_dir / relative_path.removeprefix("scripts/agent/")
    if candidate.is_file():
        # A copy that differs from the built file is stale: returning it would hide a landed fix.
        if not compare_built or not fallback_path.is_file() or candidate.read_bytes() == fallback_path.read_bytes():
            return candidate
    return fallback_path


if __name__ == "__main__":
    # Bash readers pass the file they resolved, so they get the merge the python readers use.
    merged = zf_incident_guards(sys.argv[2]) if sys.argv[1] == "--incident-guards" else zf_mechanism_registry(sys.argv[1])
    if merged is None:
        sys.exit(1)
    json.dump(merged, sys.stdout, ensure_ascii=False)
