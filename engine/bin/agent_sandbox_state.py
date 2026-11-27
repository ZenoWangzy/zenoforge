import os
import pathlib
import re
import json
import shutil
import tempfile
import tomllib
import uuid


SESSION_ID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", re.I)


def configure_zcode(path):
    target = pathlib.Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps({"features": {key: False for key in ("mcp", "plugins", "skills", "hooks", "memory")}}))


def prepare_codex_profile(command, host_env, stage):
    profile = ""
    for index, value in enumerate(command):
        if value in {"-p", "--profile"} and index + 1 < len(command):
            profile = command[index + 1]
            break
        if value.startswith("--profile="):
            profile = value.split("=", 1)[1]
            break
    if not profile:
        return
    home = pathlib.Path(host_env.get("HOME", str(pathlib.Path.home())))
    root = pathlib.Path(host_env.get("CODEX_HOME", home / ".codex"))
    config = root / "config.toml"
    if not config.is_file():
        return
    profiles = tomllib.loads(config.read_text()).get("profiles", {})
    selected = profiles.get(profile, {}) if isinstance(profiles, dict) else {}
    if not isinstance(selected, dict):
        return
    values = {key: selected[key] for key in ("model", "model_reasoning_effort", "service_tier")
              if isinstance(selected.get(key), str)}
    if values:
        destination = pathlib.Path(stage) / "codex-config.toml"
        destination.write_text(f"[profiles.{json.dumps(profile)}]\n" + "".join(f"{key} = {json.dumps(value)}\n" for key, value in values.items()))
        destination.chmod(0o400)


def _resume_id(command):
    for index, value in enumerate(command[:-1]):
        if value in {"resume", "--resume"} and SESSION_ID.fullmatch(command[index + 1]):
            return command[index + 1]
        if value.startswith("--resume=") and SESSION_ID.fullmatch(value.split("=", 1)[1]):
            return value.split("=", 1)[1]
    return ""


def _session_roots(provider, host_env):
    home = pathlib.Path(host_env.get("HOME", str(pathlib.Path.home()))).resolve()
    if provider == "codex":
        root = pathlib.Path(host_env.get("CODEX_HOME", home / ".codex")).resolve() / "sessions"
        return root, pathlib.Path("/tmp/worker/.codex/sessions"), "codex"
    root = pathlib.Path(host_env.get("CLAUDE_CONFIG_DIR", home / ".claude")).resolve() / "projects"
    return root, pathlib.Path("/tmp/worker/.claude/projects"), "claude"


def _existing(root, provider, session_id):
    if not session_id or not root.is_dir():
        return None
    if provider == "codex":
        candidates = root.glob(f"*/*/*/rollout-*-{session_id}.jsonl")
    else:
        candidates = root.glob(f"*/{session_id}.jsonl")
    return next((path for path in sorted(candidates) if path.is_file() and not path.is_symlink()), None)


def prepare(provider, command, host_env, repo, host_temp):
    if provider not in {"codex", "claude"}:
        return None
    root, target, kind = _session_roots(provider, host_env)
    store = pathlib.Path(host_temp) / "session-state"
    store.mkdir(mode=0o700)
    mapping = {}
    current = _existing(root, kind, _resume_id(command))
    if current is not None:
        relative = current.relative_to(root)
        staged = relative
        if kind == "claude":
            project = "-" + "/run/zf-agent/workspace".strip("/").replace("/", "-")
            staged = pathlib.Path(project) / current.name
        destination = store / staged
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(current, destination)
        destination.chmod(0o600)
        mapping[staged.as_posix()] = relative.as_posix()
    return {"root": root, "store": store, "target": target, "kind": kind, "repo": repo, "mapping": mapping}


def _valid_session(kind, relative):
    parts = relative.parts
    if kind == "codex":
        return (len(parts) == 4 and all(re.fullmatch(r"[0-9]{4}", value) for value in parts[:1])
                and all(re.fullmatch(r"[0-9]{2}", value) for value in parts[1:3])
                and re.fullmatch(r"rollout-[A-Za-z0-9._-]+-[0-9a-f-]{36}\.jsonl", parts[3], re.I))
    return len(parts) == 2 and re.fullmatch(r"-[A-Za-z0-9._-]+", parts[0]) and SESSION_ID.fullmatch(parts[1][:-6]) and parts[1].endswith(".jsonl")


def _host_relative(state, relative):
    existing = state["mapping"].get(relative.as_posix())
    if existing:
        return pathlib.Path(existing)
    if state["kind"] == "claude":
        project = "-" + state["repo"].strip("/").replace("/", "-")
        return pathlib.Path(project) / relative.name
    return relative


def restore(state):
    if state is None:
        return
    for source in state["store"].rglob("*.jsonl"):
        relative = source.relative_to(state["store"])
        if source.is_symlink() or not source.is_file() or not _valid_session(state["kind"], relative):
            continue
        destination = state["root"] / _host_relative(state, relative)
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        temporary = destination.with_name(destination.name + ".zf-" + uuid.uuid4().hex)
        try:
            shutil.copyfile(source, temporary)
            temporary.chmod(0o600)
            os.replace(temporary, destination)
        finally:
            temporary.unlink(missing_ok=True)
