#!/usr/bin/env python3
"""Ship one Luna or ZCode worktree to an SSH worker and mirror its run files locally."""
import fcntl
import fnmatch
import io
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid

RUNTIME_FILES = (
    "bin/luna",
    "bin/luna-capacity.sh",
    "bin/zc",
    "config.sh",
    "lib.d/codex-mcp.sh",
    "lib.d/worker-remote-handoff.sh",
    "lib.d/worker-output-cap.sh",
    "thread-budget.sh", "task-state.mjs",
)
SENSITIVE_DIRS = (".codex", ".ssh", ".aws", ".azure", ".config", ".docker", ".gnupg", ".kube")
SENSITIVE_NAMES = (
    ".env*", ".npmrc*", ".netrc", ".pypirc", ".git-credentials", "auth.json", "credentials*",
    "id_rsa*", "id_ed25519*", "token.json", "access_token*", "refresh_token*", "client_secret*",
    "service-account*", "service_account*", "*.pem", "*.key", "*.p12", "*.pfx",
)
STOP_REQUESTED = False
# One zcode login prompt per host: a pass is cached 15 min (a prompt costs quota); a failure 300 s (bin/worker's bound).
LOGIN_PROMPT, LOGIN_OK_SECONDS, LOGIN_FAIL_SECONDS = "Reply with exactly: ok", 900, 300


def setting_seconds(name, default):
    try:
        value = float(os.environ.get(name, default))
    except ValueError:
        raise ValueError(f"{name} must be a number") from None
    if value <= 0:
        raise ValueError(f"{name} must be greater than zero")
    return value


def setting_int(name, default, minimum, maximum):
    try:
        value = int(os.environ.get(name, default))
    except ValueError:
        raise ValueError(f"{name} must be an integer") from None
    if not minimum <= value <= maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return value


def setting_float(name, default, minimum, maximum):
    try:
        value = float(os.environ.get(name, default))
    except ValueError:
        raise ValueError(f"{name} must be a number") from None
    if not minimum <= value <= maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return value


def ssh_args(host):
    if not valid_ssh_alias(host):
        raise ValueError("worker host must be an SSH alias")
    connect_timeout = connect_timeout_seconds()
    return ["ssh", "-o", "BatchMode=yes", "-o", f"ConnectTimeout={connect_timeout}", host]


def valid_ssh_alias(host):
    return bool(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", host))


def remote_call(host, command, timeout=None, **kwargs):
    return subprocess.run(
        [*ssh_args(host), command],
        timeout=timeout or connect_timeout_seconds() + 10,
        **kwargs,
    )


def connect_timeout_seconds():
    try:
        value = int(os.environ.get("ZF_WORKER_SSH_CONNECT_TIMEOUT", "15"))
    except ValueError:
        raise ValueError("ZF_WORKER_SSH_CONNECT_TIMEOUT must be an integer") from None
    if not 1 <= value <= 120:
        raise ValueError("ZF_WORKER_SSH_CONNECT_TIMEOUT must be between 1 and 120")
    return value


def remote_said(text):
    text = text.decode(errors="replace") if isinstance(text, bytes) else text
    return "".join(f": {line[:200]}" for line in (text or "").strip().splitlines()[-1:])


def remote_probe_command(root):
    code = r'''import json, os, pathlib, re, subprocess, sys
root = pathlib.Path(sys.argv[1]); writable = root.is_dir() and os.access(root, os.W_OK | os.X_OK)
proc = pathlib.Path(os.environ.get("ZF_WORKER_REMOTE_PROC_ROOT", "/proc"))
path = root
while not path.exists() and path != path.parent:
    path = path.parent
load5 = float((proc / "loadavg").read_text().split()[1])
cores = len(re.findall(r"^processor\s*:", (proc / "cpuinfo").read_text(), re.M))
uid = os.geteuid()
status = proc / "self" / "status"
if status.is_file():
    match = re.search(r"^Uid:\s+\d+\s+(\d+)", status.read_text(), re.M)
    if match:
        uid = int(match.group(1))
mem = int(re.search(r"^MemAvailable:\s+(\d+)", (proc / "meminfo").read_text(), re.M).group(1)) // 1024
match = re.search(r"^some\s+[^\n]*\bavg60=([0-9.]+)", (proc / "pressure/cpu").read_text(), re.M)
if not match:
    raise RuntimeError("CPU PSI some avg60 is unavailable")
disk_pct = int(subprocess.check_output(["df", "-P", str(path)], text=True).splitlines()[-1].split()[-2].rstrip("%"))
print(json.dumps({"load5": load5, "cores": cores, "uid": uid, "memavailable_mb": mem,
                  "disk_percent": disk_pct, "cpu_psi_some_avg60": float(match.group(1)), "root_writable": writable}))
'''
    return f"python3 -c {shlex.quote(code)} {shlex.quote(root)}"


BACKEND_CHECKS = {
    # The cheap first step: luna's `codex login status` is the login check itself; zc's --version then probe_zc_login.
    "luna": ("codex", 'PATH="$PATH:$HOME/.local/bin" codex login status'),
    "zc": ("zcode", "timeout 10 zcode --version"),
}


def validate_backend(backend):
    if backend not in BACKEND_CHECKS:
        raise ValueError("backend must be luna or zc")
    return backend


def run_login_probe(host):
    # `zcode --version` returns 0 with no login (zcode 0.17.1 has no login-status command), so one prompt proves the
    # credential: bin/zc's flags and NODE_USE_ENV_PROXY, zcode from PATH like the remote run; the temp --cwd is removed.
    command = (f'd=$(mktemp -d) || exit 1; NODE_USE_ENV_PROXY=1 timeout 60 zcode --prompt {shlex.quote(LOGIN_PROMPT)} '
               f'--cwd "$d" --mode "${{ZC_MODE:-yolo}}" --output-format stream-json --no-color; rc=$?; rm -rf -- "$d"; exit $rc')
    try:
        result = remote_call(host, command, capture_output=True, text=True,
                             timeout=60 + connect_timeout_seconds() + 15)
    except (OSError, subprocess.SubprocessError) as error:
        return f"ssh:{type(error).__name__}"
    if result.returncode:
        return f"rc={result.returncode}"
    if '"turn.failed"' in result.stdout:
        return "turn.failed"
    return "ok" if '"turn.completed"' in result.stdout else "no turn.completed"


def cached_login_detail(cache):
    try:
        stamp, detail = cache.read_text().split(None, 1)
        lifetime = LOGIN_OK_SECONDS if detail.strip() == "ok" else LOGIN_FAIL_SECONDS
        return detail.strip() if time.time() - int(stamp) <= lifetime else None
    except (OSError, ValueError):
        return None


def probe_zc_login(host):
    # One prompt per host per window; the cache sits under the scratch root beside bin/worker's zc-runnable facts.
    scratch = Path(os.environ.get("WORKER_SCRATCH_ROOT", str(Path.home() / ".zenoforge/scratch")))
    cache = scratch / "tmp" / "zc-login" / host
    detail = cached_login_detail(cache)
    if detail is None:
        detail = run_login_probe(host)
        cache.parent.mkdir(parents=True, exist_ok=True)
        cache.write_text(f"{int(time.time())} {detail}\n")
    return None if detail == "ok" else f"zcode login probe failed ({detail})"


def probe_backend(host, backend):
    name, check = BACKEND_CHECKS[validate_backend(backend)]
    try:
        result = remote_call(host, f"{check} >/dev/null 2>&1", timeout=connect_timeout_seconds() + 15)
    except (OSError, subprocess.SubprocessError) as error:
        return f"{backend} backend check unavailable ({type(error).__name__})"
    if result.returncode == 0:
        # The cheap check proves only the binary: a zcode host is usable when one real prompt proves its login.
        return None if backend == "luna" else probe_zc_login(host)
    if result.returncode == 127:
        return f"{backend} backend unusable: {name} not found on the remote host"
    return f"{backend} backend unusable: {check} returned rc={result.returncode}"


def probe(host, root=None, backend="luna"):
    root = root or os.environ.get("ZF_WORKER_REMOTE_ROOT", "/srv/zf-workers")
    validate_backend(backend)
    try:
        result = remote_call(host, remote_probe_command(root), capture_output=True, text=True)
    except (OSError, subprocess.SubprocessError) as error:
        return None, f"ssh unavailable ({type(error).__name__})"
    if result.returncode:
        return None, f"ssh failed (rc={result.returncode})"
    try:
        metrics = json.loads(result.stdout)
        metrics["load5"] = float(metrics["load5"])
        metrics["cores"] = int(metrics["cores"])
        metrics["uid"] = int(metrics["uid"])
        metrics["memavailable_mb"] = int(metrics["memavailable_mb"])
        metrics["disk_percent"] = int(metrics["disk_percent"])
        metrics["cpu_psi_some_avg60"] = float(metrics["cpu_psi_some_avg60"])
    except (ValueError, KeyError, TypeError):
        return None, "remote capacity metrics were unreadable"
    min_mem_mb = setting_int("ZF_WORKER_REMOTE_MIN_MEM_MB", "8192", 1, 1048576)
    max_disk_percent = setting_int("ZF_WORKER_REMOTE_MAX_DISK_PERCENT", "95", 1, 100)
    max_cpu_psi = setting_int("ZF_WORKER_REMOTE_MAX_CPU_PSI", "60", 1, 100)
    max_load_per_core = setting_float("ZF_WORKER_REMOTE_MAX_LOAD_PER_CORE", "1.0", 0.1, 100)
    reasons = [] if metrics["root_writable"] else [f"remote root {root} is missing or not writable"]
    if metrics["uid"] == 0: reasons.append("remote user is root")
    if metrics["load5"] > metrics["cores"] * max_load_per_core:
        reasons.append(f"load5 {metrics['load5']:g} is above {metrics['cores']} cores x {max_load_per_core:g}")
    if metrics["memavailable_mb"] < min_mem_mb: reasons.append(f"MemAvailable {metrics['memavailable_mb']} MB is below {min_mem_mb} MB")
    if metrics["disk_percent"] > max_disk_percent: reasons.append(f"disk use {metrics['disk_percent']}% is above {max_disk_percent}%")
    if metrics["cpu_psi_some_avg60"] > max_cpu_psi:
        reasons.append(f"CPU PSI some avg60 {metrics['cpu_psi_some_avg60']:g} is above {max_cpu_psi}")
    if not reasons:
        backend_reason = probe_backend(host, backend)
        if backend_reason:
            reasons.append(backend_reason)
    metrics["reason"] = "; ".join(reasons)
    return metrics, metrics["reason"]


def format_metrics(host, metrics):
    return (f"{host}: load5={metrics['load5']:g}, MemAvailable={metrics['memavailable_mb']} MB, "
            f"disk={metrics['disk_percent']}%, CPU PSI some avg60={metrics['cpu_psi_some_avg60']:g}")


def command_probe(host, backend="luna"):
    metrics, reason = probe(host, backend=backend)
    if metrics is None or reason:
        print(f"worker-host: {host} refused: {reason}", file=sys.stderr)
        return 1
    print(f"worker-host: admitted {format_metrics(host, metrics)}", file=sys.stderr)
    return 0


def command_choose(backend="luna"):
    validate_backend(backend)
    preferred = os.environ.get("ZF_WORKER_HOST", "").strip()
    if preferred == "local":
        print("local")
        return 0
    if os.environ.get("LUNA_PRIORITY") == "hotfix" and not preferred:
        print("local")
        return 0
    hosts = ([preferred] if preferred else []) + os.environ.get("ZF_WORKER_HOSTS", "").split()
    seen = set()
    for host in hosts:
        if host in seen:
            continue
        seen.add(host)
        if not valid_ssh_alias(host):
            print(f"worker-host: skipping invalid SSH alias {host!r}", file=sys.stderr)
            continue
        metrics, reason = probe(host, backend=backend)
        if metrics is not None and not reason:
            print(f"worker-host: selected {format_metrics(host, metrics)}", file=sys.stderr)
            print(host)
            return 0
        print(f"worker-host: skipping {host}: {reason}", file=sys.stderr)
    if preferred:
        print(f"worker-host: no remote candidate admitted; falling back to local", file=sys.stderr)
    print("local")
    return 0


def validate_key(key):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,119}", key) or key in {".", ".."}:
        raise ValueError("worker key contains characters unsafe for a remote directory")


def scope_name(key):
    validate_key(key)
    suffix = __import__("hashlib").sha256(key.encode()).hexdigest()[:8]
    safe = re.sub(r"[^A-Za-z0-9_-]", "-", key)[:100]
    return f"zf-remote-{safe}-{suffix}"


def safe_source_path(raw, root):
    path = PurePosixPath(raw)
    if path.is_absolute() or not path.parts or any(part in {"", ".", "..", ".git", "node_modules", *SENSITIVE_DIRS}
                                                  for part in path.parts):
        return None
    name = path.name.lower()
    if any(fnmatch.fnmatchcase(name, pattern) for pattern in SENSITIVE_NAMES):
        return None
    source = root.joinpath(*path.parts)
    try:
        resolved = source.resolve(strict=True)
        resolved.relative_to(root)
    except (OSError, ValueError):
        return None
    if source.is_symlink() or not source.is_file():
        return None
    return source


def safe_origin(raw):
    if not raw:
        return ""
    if "://" in raw:
        from urllib.parse import urlsplit, urlunsplit
        parsed = urlsplit(raw)
        if not parsed.hostname:
            raise ValueError("repository origin is not a valid URL")
        netloc = parsed.hostname + (f":{parsed.port}" if parsed.port else "")
        return urlunsplit((parsed.scheme, netloc, parsed.path, "", ""))
    if ":" in raw and "@" in raw.split(":", 1)[0]:
        authority, path = raw.split(":", 1)
        return f"git@{authority.rsplit('@', 1)[-1]}:{path}"
    return raw


def sensitive_pathspecs():
    directories = [f":(exclude)**/{name}/**" for name in SENSITIVE_DIRS]
    files = [f":(exclude)**/{pattern}" for pattern in SENSITIVE_NAMES]
    return [*directories, *files]


def git_output(cwd, *args, allow_failure=False, failure=None):
    result = subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True)
    if result.returncode and not allow_failure:
        raise RuntimeError(failure or "git operation failed: " + " ".join(args[:2]))
    return result


def repository_info(cwd):
    top = Path(git_output(cwd, "rev-parse", "--show-toplevel").stdout.strip()).resolve()
    current = Path(cwd).resolve()
    relative = current.relative_to(top).as_posix()
    branch = git_output(top, "branch", "--show-current").stdout.strip()
    if not branch or not re.fullmatch(r"[A-Za-z0-9._/-]+", branch) or ".." in branch.split("/"):
        raise ValueError("remote workers require a named Git branch")
    origin = git_output(top, "remote", "get-url", "origin", allow_failure=True)
    origin_url = safe_origin(origin.stdout.strip()) if origin.returncode == 0 else ""
    head = git_output(top, "rev-parse", "HEAD").stdout.strip()
    base_branch = ""
    if origin_url:
        candidates = [branch]
        remote_head = git_output(top, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD", allow_failure=True)
        if remote_head.returncode == 0 and remote_head.stdout.strip().startswith("origin/"):
            candidates.append(remote_head.stdout.strip().split("/", 1)[1])
        candidates.extend(("main", "master"))
        for candidate in dict.fromkeys(candidates):
            ref = git_output(top, "show-ref", "--verify", "--quiet", f"refs/remotes/origin/{candidate}", allow_failure=True)
            if ref.returncode == 0:
                base_branch = candidate
                break
    base_ref = f"refs/remotes/origin/{base_branch}" if base_branch else ""
    return top, relative, branch, origin_url, head, base_branch, base_ref


def make_payload(top, cwd, prompt, schema, key, target, archive_path, backend="luna"):
    _, relative, branch, origin, head, base_branch, base_ref = repository_info(cwd)
    engine = Path(__file__).resolve().parent.parent
    temp = archive_path.parent
    bundle = temp / "snapshot.bundle"
    patch = temp / "worktree.patch"
    bundle.write_bytes(b"")
    if base_ref:
        is_ahead = git_output(top, "merge-base", "--is-ancestor", base_ref, "HEAD", allow_failure=True)
        if is_ahead.returncode == 0:
            count = int(git_output(top, "rev-list", "--count", f"{base_ref}..HEAD").stdout.strip())
            if count:
                subprocess.run(["git", "-C", str(top), "bundle", "create", str(bundle), "HEAD", f"^{base_ref}"],
                               check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        else:
            is_behind = git_output(top, "merge-base", "--is-ancestor", "HEAD", base_ref, allow_failure=True)
            if is_behind.returncode != 0:
                raise RuntimeError("local branch and origin base have diverged")
    else:
        subprocess.run(["git", "-C", str(top), "bundle", "create", str(bundle), "HEAD"],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    with patch.open("wb") as stream:
        subprocess.run(["git", "-C", str(top), "diff", "--binary", "HEAD", "--", ".", *sensitive_pathspecs()],
                       check=True, stdout=stream, stderr=subprocess.PIPE)
    manifest = {
        "key": key,
        "backend": validate_backend(backend),
        "branch": branch,
        "base_branch": base_branch or branch,
        "origin": origin,
        "head": head,
        "cwd": relative,
        "target": target,
        "memory_max": os.environ.get("ZF_WORKER_REMOTE_MEMORY_MAX", "8G"),
        "cpu_weight": os.environ.get("ZF_WORKER_REMOTE_CPU_WEIGHT", "20"),
        "model": os.environ.get("CODEX_MODEL", "gpt-6-luna"),
        "effort": os.environ.get("CODEX_EFFORT", "max"),
        "search": bool(os.environ.get("CODEX_SEARCH")),
        "priority": os.environ.get("LUNA_PRIORITY", "normal"),
        "output_cap_kb": os.environ.get("WORKER_OUTPUT_CAP_KB", "64"),
        "scope": scope_name(key),
    }
    if not re.fullmatch(r"[1-9][0-9]*(?:[KMGTP]i?B?)?", manifest["memory_max"], re.I):
        raise ValueError("ZF_WORKER_REMOTE_MEMORY_MAX must be a systemd size such as 8G")
    if not manifest["cpu_weight"].isdigit() or not 1 <= int(manifest["cpu_weight"]) <= 10000:
        raise ValueError("ZF_WORKER_REMOTE_CPU_WEIGHT must be an integer from 1 to 10000")
    job_file = temp / "job.json"
    job_file.write_text(json.dumps(manifest))
    file_list = subprocess.check_output(["git", "-C", str(top), "ls-files", "--others", "--exclude-standard", "-z"])
    untracked = []
    for raw in file_list.split(b"\0"):
        if not raw:
            continue
        source = safe_source_path(os.fsdecode(raw), top)
        if source is not None:
            untracked.append((source, os.fsdecode(raw)))
    with tarfile.open(archive_path, "w") as archive:
        archive.add(bundle, arcname="snapshot.bundle")
        archive.add(patch, arcname="worktree.patch")
        archive.add(job_file, arcname="job.json")
        archive.add(Path(prompt).resolve(strict=True), arcname="prompt.md")
        if schema:
            archive.add(Path(schema).resolve(strict=True), arcname="schema.json")
        archive.add(Path(__file__).resolve(), arcname="worker-remote.py")
        for relative_file in RUNTIME_FILES:
            source = engine / relative_file
            archive.add(source, arcname="runtime/engine/" + relative_file)
        for source in sorted((engine / "bin/install-guard").iterdir()):
            if source.is_file():
                archive.add(source, arcname="runtime/engine/bin/install-guard/" + source.name)
        for source, name in untracked:
            archive.add(source, arcname="untracked/" + name, recursive=False)
    return manifest


def remote_prepare(staging, target):
    staging, target = Path(staging), Path(target)
    job = json.loads((staging / "job.json").read_text())
    key, branch, base_branch, origin = job["key"], job["branch"], job["base_branch"], job["origin"]
    validate_key(key)
    target.parent.mkdir(parents=True, exist_ok=True)
    fresh = not (target / ".git").exists()
    if origin:
        mirror_root = target.parent / ".mirrors"
        mirror_root.mkdir(parents=True, exist_ok=True)
        digest = __import__("hashlib").sha256(origin.encode()).hexdigest()
        mirror = mirror_root / f"{digest}.git"
        with (mirror_root / f"{digest}.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            if mirror.exists():
                git_output(mirror, "fetch", "--quiet", "--prune", "origin")
            else:
                with tempfile.TemporaryDirectory(dir=mirror_root) as temporary:
                    seed = Path(temporary) / "origin.git"
                    subprocess.run(["git", "clone", "--quiet", "--mirror", origin, str(seed)],
                                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                    seed.rename(mirror)
    if fresh:
        if origin:
            git_output(target.parent, "clone", "--quiet", "--single-branch", "--branch", base_branch,
                       str(mirror), str(target))
            git_output(target, "remote", "set-url", "origin", origin)
        else:
            target.mkdir(parents=True, exist_ok=True)
            git_output(target, "init", "-q")
    dirty = bool(git_output(target, "status", "--porcelain").stdout.strip()) if not fresh else False
    current_branch = git_output(target, "branch", "--show-current", allow_failure=True).stdout.strip()
    if dirty and current_branch != branch:
        raise RuntimeError("remote worktree is dirty on a different branch")
    if not dirty:
        if origin:
            git_output(target, "fetch", "--quiet", "origin", base_branch)
            if branch != base_branch:
                git_output(target, "fetch", "--quiet", "origin", f"{branch}:refs/remotes/origin/{branch}", allow_failure=True)
        bundle, input_ref = staging / "snapshot.bundle", "refs/remotes/zf/worker-input"
        if bundle.stat().st_size:
            git_output(target, "fetch", "--quiet", str(bundle), f"+HEAD:{input_ref}")
        if current_branch != branch:
            if origin:
                requested_ref = git_output(target, "show-ref", "--verify", "--quiet",
                                           f"refs/remotes/origin/{branch}", allow_failure=True)
                base_ref = (f"refs/remotes/origin/{branch}" if requested_ref.returncode == 0
                            else f"refs/remotes/origin/{base_branch}")
            elif bundle.stat().st_size:
                base_ref = input_ref
            else:
                raise RuntimeError("remote branch has no base commit")
            git_output(target, "checkout", "-B", branch, base_ref)
        elif origin and git_output(target, "show-ref", "--verify", "--quiet",
                                   f"refs/remotes/origin/{branch}", allow_failure=True).returncode == 0:
            git_output(target, "merge", "--ff-only", f"refs/remotes/origin/{branch}", failure="remote branch has diverged")
        if bundle.stat().st_size:
            git_output(target, "merge", "--ff-only", input_ref, failure="local branch and remote branch have diverged")
        if (staging / "worktree.patch").stat().st_size:
            git_output(target, "apply", "--3way", str(staging / "worktree.patch"))
        for raw in (staging / "untracked").glob("**/*"):
            if not raw.is_file() or raw.is_symlink():
                continue
            relative = raw.relative_to(staging / "untracked")
            if safe_source_path(relative.as_posix(), staging / "untracked") is None:
                continue
            dest = target / relative
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(raw, dest)
    return 0


def remote_run(staging):
    staging = Path(staging)
    job = json.loads((staging / "job.json").read_text())
    target = Path(job["target"])
    cwd = target / job["cwd"]
    runtime = staging / "runtime/engine"
    gitdir_text = git_output(target, "rev-parse", "--absolute-git-dir").stdout.strip()
    scratch = Path(gitdir_text) / "zf-worker-scratch"
    out = scratch / "luna" / job["key"]
    out.mkdir(parents=True, exist_ok=True)
    for name in ("events.jsonl", "last.md", "rc", "codex.pid", "stderr.log", "remote.scope"):
        try:
            (out / name).unlink()
        except FileNotFoundError:
            pass
    env = os.environ.copy()
    env["PATH"] = os.pathsep.join(filter(None, (env.get("PATH"), str(Path.home() / ".local" / "bin"))))
    if shutil.which("codex", path=env["PATH"]) is None:
        if npm := shutil.which("npm"):
            prefix = subprocess.run([npm, "prefix", "-g"], capture_output=True, text=True)
            npm_bin = Path(prefix.stdout.strip()) / "bin" if prefix.returncode == 0 else None
            if npm_bin and (npm_bin / "codex").is_file():
                env["PATH"] = str(npm_bin) + os.pathsep + env.get("PATH", "")
    env.update({
        "ZF_ENGINE_DIR": str(runtime),
        "WORKER_SCRATCH_ROOT": str(scratch),
        "ZF_WORKER_HOST": "local",
        "ZF_WORKER_REMOTE_INNER": "1",
        "ZF_WORKER_REMOTE_SCOPE_NAME": job["scope"],
        "ZF_WORKER_SLICE": "zf-remote.slice",
        "LUNA_MEM_HIGH": job["memory_max"],
        "LUNA_MEM_MAX": job["memory_max"],
        "ZF_WORKER_REMOTE_CPU_WEIGHT": str(job["cpu_weight"]),
        "AGENT_WORKER_CPU_WEIGHT": "20",
        "LUNA_PRIORITY": job["priority"],
        "CODEX_MODEL": job["model"],
        "CODEX_EFFORT": job["effort"],
        "WORKER_OUTPUT_CAP_KB": job["output_cap_kb"],
    })
    if job["search"]:
        env["CODEX_SEARCH"] = "1"
    else:
        env.pop("CODEX_SEARCH", None)
    backend = validate_backend(job.get("backend", "luna"))
    command = [str(runtime / "bin" / backend), job["key"], str(cwd), str(staging / "prompt.md")]
    if backend == "luna" and (staging / "schema.json").is_file():
        command.append(str(staging / "schema.json"))
    if backend == "zc":
        # bin/worker points both backends at the shared luna scratch dir; keep bin/zc writing where remote-sync reads.
        env["ZC_OUT_ROOT"] = str(scratch / "luna")
    child = subprocess.Popen(command, env=env, start_new_session=True)

    def stop_child(signum, _frame):
        subprocess.run(["systemctl", "--user", "stop", job["scope"] + ".scope"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            child.send_signal(signum)
        except ProcessLookupError:
            pass

    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, stop_child)
    return child.wait()


def add_bytes(archive, name, data):
    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mode = 0o600
    archive.addfile(info, io.BytesIO(data))


def remote_sync(output, events_offset, stderr_offset):
    output = Path(output)
    with tarfile.open(fileobj=sys.stdout.buffer, mode="w|") as archive:
        for stem, offset in (("events", events_offset), ("stderr", stderr_offset)):
            path = output / ("events.jsonl" if stem == "events" else "stderr.log")
            size = path.stat().st_size if path.is_file() else 0
            reset = offset > size
            start = 0 if reset else offset
            add_bytes(archive, stem + ".size", str(size).encode())
            if reset:
                add_bytes(archive, stem + ".reset", b"1")
            if size > start:
                with path.open("rb") as stream:
                    stream.seek(start)
                    add_bytes(archive, stem + ".delta", stream.read(size - start))
        for name in ("last.md", "rc", "codex.pid", "remote.scope"):
            path = output / name
            if path.is_file():
                archive.add(path, arcname=name, recursive=False)
    return 0


def atomic_write(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + ".remote-tmp")
    temp.write_bytes(data)
    os.replace(temp, path)


def sync_remote(host, sync_script, remote_out, local_out, offsets):
    command = (f"python3 {shlex.quote(sync_script)} remote-sync {shlex.quote(remote_out)} "
               f"{offsets[0]} {offsets[1]}")
    try:
        result = remote_call(host, command, timeout=connect_timeout_seconds() + 15,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except (OSError, subprocess.SubprocessError) as error:
        print(f"worker-remote: sync unavailable on {host} ({type(error).__name__})", file=sys.stderr)
        return offsets
    if result.returncode:
        print(f"worker-remote: sync failed on {host} (rc={result.returncode})", file=sys.stderr)
        return offsets
    local_out = Path(local_out)
    local_out.mkdir(parents=True, exist_ok=True)
    sizes = [offsets[0], offsets[1]]
    try:
        with tarfile.open(fileobj=io.BytesIO(result.stdout), mode="r:") as archive:
            for member in archive:
                data_file = archive.extractfile(member)
                if data_file is None:
                    continue
                data = data_file.read()
                if member.name in {"events.size", "stderr.size"}:
                    index = 0 if member.name == "events.size" else 1
                    sizes[index] = int(data.decode())
                elif member.name in {"events.reset", "stderr.reset"}:
                    target = local_out / ("events.jsonl" if member.name.startswith("events") else "stderr.log")
                    target.write_bytes(b"")
                elif member.name == "events.delta":
                    with (local_out / "events.jsonl").open("ab") as stream:
                        stream.write(data)
                elif member.name == "stderr.delta":
                    with (local_out / "stderr.log").open("ab") as stream:
                        stream.write(data)
                elif member.name in {"last.md", "rc", "codex.pid", "remote.scope"}:
                    atomic_write(local_out / member.name, data)
    except (OSError, tarfile.TarError, ValueError) as error:
        print(f"worker-remote: sync data invalid on {host} ({type(error).__name__})", file=sys.stderr)
        return offsets
    return tuple(sizes)


def stop_remote(host, scope):
    if not re.fullmatch(r"zf-remote-[A-Za-z0-9_-]+-[0-9a-f]{8}", scope):
        raise ValueError("remote scope name is invalid")
    # The remote ssh user is never root (the probe refuses uid 0) and its account has linger on, so the
    # scope lives in its user manager.
    unit = scope + ".scope"
    command = (f"systemctl --user stop {shlex.quote(unit)} >/dev/null 2>&1 || true; "
               f"for i in $(seq 1 100); do systemctl --user is-active --quiet {shlex.quote(unit)} || exit 0; "
               "sleep 0.1; done; exit 1")
    try:
        result = remote_call(host, command, timeout=connect_timeout_seconds() + 15,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        return 1
    return 0 if result.returncode == 0 else 1


def cleanup_remote_staging(host, staging):
    command = f"rm -rf -- {shlex.quote(staging)}"
    try:
        remote_call(host, command, timeout=connect_timeout_seconds() + 10,
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        pass


def command_run(host, key, cwd, prompt, schema, backend="luna"):
    validate_key(key)
    validate_backend(backend)
    root = os.environ.get("ZF_WORKER_REMOTE_ROOT", "/srv/zf-workers")
    if not root.startswith("/") or ".." in PurePosixPath(root).parts:
        raise ValueError("ZF_WORKER_REMOTE_ROOT must be an absolute remote path")
    # bin/worker sets ZC_OUT_ROOT so the zc backend reports in the shared luna dir; standalone callers keep it.
    scratch_root = Path(os.environ.get("WORKER_SCRATCH_ROOT", str(Path.home() / ".zenoforge/scratch")))
    local_out = Path(os.environ.get("ZC_OUT_ROOT") or scratch_root / "luna") / key
    local_out.mkdir(parents=True, exist_ok=True)
    for name in ("events.jsonl", "last.md", "rc", "codex.pid", "stderr.log",
                 "remote-refused", "remote.host", "remote.scope"):
        try:
            (local_out / name).unlink()
        except FileNotFoundError:
            pass
    metrics, reason = probe(host, root, backend)
    if metrics is None or reason:
        detail = reason or "remote capacity probe failed"
        (local_out / "remote-refused").write_text(detail + "\n")
        # The choose-side refusals land here through bin/worker's redirect; this run-side probe writes its own line.
        with (local_out / "placement.log").open("a") as placement_log:
            print(f"worker-host: skipping {host}: {detail}", file=placement_log)
        print(f"worker-remote: refusing {host}: {detail}", file=sys.stderr)
        return 75
    print(f"worker-remote: admitted {format_metrics(host, metrics)}", flush=True)
    staging_id = uuid.uuid4().hex
    staging = posixpath.join(root.rstrip("/"), ".incoming", staging_id)
    target = posixpath.join(root.rstrip("/"), key)
    local_staging_script = posixpath.join(staging, "worker-remote.py")
    with tempfile.TemporaryDirectory(prefix="zf-worker-remote-") as temp:
        archive_path = Path(temp) / "payload.tar"
        top = Path(git_output(cwd, "rev-parse", "--show-toplevel").stdout.strip()).resolve()
        manifest = make_payload(top, cwd, prompt, schema, key, target, archive_path, backend)
        transfer = (f"umask 077; mkdir -p -- {shlex.quote(staging)}; "
                    f"tar -xf - --no-same-owner --no-same-permissions -C {shlex.quote(staging)}")
        try:
            try:
                with archive_path.open("rb") as stream:
                    shipped = remote_call(host, transfer, timeout=setting_seconds("ZF_WORKER_TRANSFER_TIMEOUT", "180"),
                                          stdin=stream, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
            except (OSError, subprocess.SubprocessError) as error:
                print(f"worker-remote: transfer failed on {host} ({type(error).__name__}){remote_said(getattr(error, 'stderr', None))}", file=sys.stderr)
                return 125
            if shipped.returncode:
                print(f"worker-remote: transfer failed on {host} (rc={shipped.returncode}){remote_said(shipped.stderr)}", file=sys.stderr)
                return 125
            prepare = (f"python3 {shlex.quote(local_staging_script)} remote-prepare "
                       f"{shlex.quote(staging)} {shlex.quote(target)}")
            prepared = remote_call(host, prepare, timeout=setting_seconds("ZF_WORKER_TRANSFER_TIMEOUT", "180"),
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if prepared.returncode:
                print(f"worker-remote: clone setup failed on {host} (rc={prepared.returncode})", file=sys.stderr)
                return 125
            scope = manifest["scope"]
            (local_out / "remote.host").write_text(host + "\n")
            (local_out / "remote.scope").write_text(scope + "\n")
            remote_out = posixpath.join(target, ".git/zf-worker-scratch/luna", key)
            command = f"python3 {shlex.quote(local_staging_script)} remote-run {shlex.quote(staging)}"
            stdout_path = local_out / "backend-run.stdout.log"
            stderr_path = local_out / "backend-run.stderr.log"
            offsets = (0, 0)
            interval = setting_seconds("ZF_WORKER_SYNC_INTERVAL_SECONDS", "2")
            with stdout_path.open("ab") as stdout, stderr_path.open("ab") as stderr:
                try:
                    child = subprocess.Popen([*ssh_args(host), command], stdout=stdout, stderr=stderr,
                                             start_new_session=True)
                except OSError as error:
                    print(f"worker-remote: could not start SSH to {host} ({type(error).__name__})", file=sys.stderr)
                    return 125
                while child.poll() is None:
                    if STOP_REQUESTED:
                        stop_remote(host, scope)
                    offsets = sync_remote(host, local_staging_script, remote_out, local_out, offsets)
                    try:
                        child.wait(timeout=interval)
                    except subprocess.TimeoutExpired:
                        pass
                status = child.wait()
            sync_remote(host, local_staging_script, remote_out, local_out, offsets)
            return status if status >= 0 else 128 - status
        finally:
            cleanup_remote_staging(host, staging)


def request_stop(_signum, _frame):
    global STOP_REQUESTED
    STOP_REQUESTED = True


def main(argv):
    if len(argv) in (2, 3) and argv[1] == "choose":
        return command_choose(argv[2] if len(argv) == 3 else "luna")
    if len(argv) in (3, 4) and argv[1] == "probe":
        return command_probe(argv[2], argv[3] if len(argv) == 4 else "luna")
    if len(argv) == 4 and argv[1] == "stop":
        return stop_remote(argv[2], argv[3])
    if len(argv) == 4 and argv[1] == "remote-prepare":
        return remote_prepare(argv[2], argv[3])
    if len(argv) == 3 and argv[1] == "remote-run":
        return remote_run(argv[2])
    if len(argv) == 5 and argv[1] == "remote-sync":
        return remote_sync(argv[2], int(argv[3]), int(argv[4]))
    if len(argv) in (7, 8) and argv[1] == "run":
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(sig, request_stop)
        return command_run(argv[2], argv[3], argv[4], argv[5], argv[6], argv[7] if len(argv) == 8 else "luna")
    print("usage: worker-remote.py choose [luna|zc] | probe <host> [luna|zc] |"
          " run <host> <key> <cwd> <prompt> <schema> [luna|zc]", file=sys.stderr)
    return 64


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError) as error:
        print(f"worker-remote: setup failed ({type(error).__name__}); credentials were not read or copied", file=sys.stderr)
        sys.exit(125)
