"""Resolve shared config data in target, pack, then engine order."""
import os
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from env_config import zf_env


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


def zf_host_ops_file(relative_path, fallback=None):
    engine_dir = Path(os.environ.get("ZF_ENGINE_DIR") or Path(__file__).resolve().parent.parent)
    agent_home = Path(os.environ.get("AGENT_HOME") or os.environ.get("ZF_HOME") or Path.home() / ".zenoforge")
    host_ops = Path(os.environ.get("ZF_HOST_OPS_DIR") or agent_home / "host-ops")
    candidate = host_ops / relative_path
    if candidate.is_file():
        return candidate
    return Path(fallback) if fallback is not None else engine_dir / relative_path.removeprefix("scripts/agent/")
