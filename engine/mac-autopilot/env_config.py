"""Resolve a public engine setting through the product's optional env prefix."""

import json
import os
import re
from pathlib import Path

_ENV_NAME = re.compile(r"^[A-Z][A-Z0-9_]*$")
_ENGINE_DIR = Path(__file__).resolve().parents[1]


def _env_prefix():
    configured_root = os.environ.get("ZF_CONFIG_ROOT")
    if configured_root is not None:
        config_file = Path(configured_root) / "config.json" if configured_root else None
    else:
        repo_root = Path(os.environ.get("ZF_REPO_DIR") or _ENGINE_DIR.parent)
        config_file = repo_root / ".zenoforge" / "config.json"

    if config_file is None or not config_file.is_file():
        return ""
    with config_file.open(encoding="utf-8") as stream:
        config = json.load(stream)
    prefix = config.get("env_prefix") if isinstance(config, dict) else None
    return prefix if isinstance(prefix, str) else ""


def zf_env(name, default=None):
    """Return PREFIX+name, then ZF_name, then default, preserving present empty values."""
    if not isinstance(name, str) or not _ENV_NAME.fullmatch(name):
        raise ValueError("environment name must be an uppercase suffix")

    prefix = _env_prefix()
    if prefix:
        deployment_name = f"{prefix}{name}"
        if deployment_name in os.environ:
            return os.environ[deployment_name]
    public_name = f"ZF_{name}"
    if public_name in os.environ:
        return os.environ[public_name]
    return default
