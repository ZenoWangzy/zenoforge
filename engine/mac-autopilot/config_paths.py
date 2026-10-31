"""Resolve shared config data in target, pack, then engine order."""
import os
from pathlib import Path


def zf_config_file(relative_path):
    path = Path(relative_path)
    if path.is_absolute() or ".." in path.parts:
        raise ValueError("config path must be relative and cannot contain a .. segment")

    engine_dir = Path(os.environ.get("ZF_ENGINE_DIR") or Path(__file__).resolve().parent.parent)
    repo_dir = Path(os.environ.get("ZF_REPO_DIR") or engine_dir.parent)
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
