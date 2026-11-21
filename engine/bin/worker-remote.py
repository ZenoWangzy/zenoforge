#!/usr/bin/env python3
"""Ship one Luna worktree to an SSH worker and mirror its run files locally."""
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
import uuid

RUNTIME_FILES = (
    "bin/luna",
    "bin/luna-capacity.sh",
    "lib.d/codex-mcp.sh",
    "lib.d/worker-output-cap.sh",
    "thread-budget.sh",
)
STOP_REQUESTED = False


def setting_seconds(name, default):
    try:
        value = float(os.environ.get(name, default))
    except ValueError:
        raise ValueError(f"{name} must be a number") from None
    if value <= 0:
        raise ValueError(f"{name} must be greater than zero")
    return value


def ssh_args(host):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", host):
        raise ValueError("worker host must be an SSH alias")
    try:
        connect_timeout = int(os.environ.get("ZF_WORKER_SSH_CONNECT_TIMEOUT", "15"))
    except ValueError:
        raise ValueError("ZF_WORKER_SSH_CONNECT_TIMEOUT must be an integer") from None
    if not 1 <= connect_timeout <= 120:
        raise ValueError("ZF_WORKER_SSH_CONNECT_TIMEOUT must be between 1 and 120")
    return ["ssh", "-o", "BatchMode=yes", "-o", f"ConnectTimeout={connect_timeout}", host]


def remote_call(host, command, timeout=None, **kwargs):
    return subprocess.run(
        [*ssh_args(host), command],
        timeout=timeout or connect_timeout_seconds() + 10,
        **kwargs,
    )


def connect_timeout_seconds():
    try:
        return int(os.environ.get("ZF_WORKER_SSH_CONNECT_TIMEOUT", "15"))
    except ValueError:
        return 15


def remote_probe_command(root):
    code = r'''import json, os, pathlib, re, subprocess, sys
root = pathlib.Path(sys.argv[1])
proc = pathlib.Path(os.environ.get("ZF_WORKER_REMOTE_PROC_ROOT", "/proc"))
path = root
while not path.exists() and path != path.parent:
    path = path.parent
load5 = float((proc / "loadavg").read_text().split()[1])
mem = int(re.search(r"^MemAvailable:\s+(\d+)", (proc / "meminfo").read_text(), re.M).group(1)) // 1024
psi = (proc / "pressure/cpu").read_text()
match = re.search(r"^some\s+[^\n]*\bavg60=([0-9.]+)", psi, re.M)
if not match:
    raise RuntimeError("CPU PSI some avg60 is unavailable")
disk = subprocess.check_output(["df", "-P", str(path)], text=True).splitlines()[-1].split()
disk_pct = int(disk[-2].rstrip("%"))
print(json.dumps({"load5": load5, "memavailable_mb": mem, "disk_percent": disk_pct,
                  "cpu_psi_some_avg60": float(match.group(1))}))
'''
    return f"python3 -c {shlex.quote(code)} {shlex.quote(root)}"


def probe(host, root=None):
    root = root or os.environ.get("ZF_WORKER_REMOTE_ROOT", "/srv/zf-workers")
    try:
        result = remote_call(host, remote_probe_command(root), capture_output=True, text=True)
    except (OSError, subprocess.SubprocessError) as error:
        return None, f"ssh unavailable ({type(error).__name__})"
    if result.returncode:
        return None, f"ssh failed (rc={result.returncode})"
    try:
        metrics = json.loads(result.stdout)
        metrics["load5"] = float(metrics["load5"])
        metrics["memavailable_mb"] = int(metrics["memavailable_mb"])
        metrics["disk_percent"] = int(metrics["disk_percent"])
        metrics["cpu_psi_some_avg60"] = float(metrics["cpu_psi_some_avg60"])
    except (ValueError, KeyError, TypeError):
        return None, "remote capacity metrics were unreadable"
    reasons = []
    if metrics["memavailable_mb"] < 8192:
        reasons.append(f"MemAvailable {metrics['memavailable_mb']} MB is below 8192 MB")
    if metrics["disk_percent"] > 95:
        reasons.append(f"disk use {metrics['disk_percent']}% is above 95%")
    if metrics["cpu_psi_some_avg60"] > 60:
        reasons.append(f"CPU PSI some avg60 {metrics['cpu_psi_some_avg60']:g} is above 60")
    metrics["reason"] = "; ".join(reasons)
    return metrics, metrics["reason"]


def format_metrics(host, metrics):
    return (f"{host}: load5={metrics['load5']:g}, MemAvailable={metrics['memavailable_mb']} MB, "
            f"disk={metrics['disk_percent']}%, CPU PSI some avg60={metrics['cpu_psi_some_avg60']:g}")


def command_probe(host):
    metrics, reason = probe(host)
    if metrics is None or reason:
        print(f"worker-host: {host} refused: {reason}", file=sys.stderr)
        return 1
    print(f"worker-host: admitted {format_metrics(host, metrics)}", file=sys.stderr)
    return 0


def command_choose():
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
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", host):
            print(f"worker-host: skipping invalid SSH alias {host!r}", file=sys.stderr)
            continue
        metrics, reason = probe(host)
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
    if path.is_absolute() or not path.parts or any(part in {
        "", ".", "..", ".git", ".codex", ".ssh", ".aws", ".azure", ".docker", ".gnupg", ".kube", "node_modules"
    } for part in path.parts):
        return None
    name = path.name.lower()
    if (name.startswith((".env", ".npmrc")) or name in {
        ".git-credentials", ".netrc", ".pypirc", "auth.json", "credentials", "credentials.json",
        "id_rsa", "id_ed25519", "token.json", "access_token", "refresh_token", "client_secret.json",
        "service-account.json", "service_account.json",
    }):
        return None
    if name.endswith((".pem", ".key")):
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


def git_output(cwd, *args, allow_failure=False):
    result = subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True)
    if result.returncode and not allow_failure:
        raise RuntimeError("git operation failed: " + " ".join(args[:2]))
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
    return top, relative, branch, origin_url, head


def make_payload(top, cwd, prompt, schema, key, target, archive_path):
    _, relative, branch, origin, head = repository_info(cwd)
    engine = Path(__file__).resolve().parent.parent
    temp = archive_path.parent
    bundle = temp / "snapshot.bundle"
    patch = temp / "worktree.patch"
    subprocess.run(["git", "-C", str(top), "bundle", "create", str(bundle), "HEAD"],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    with patch.open("wb") as stream:
        subprocess.run(["git", "-C", str(top), "diff", "--binary", "HEAD", "--", ".",
                        ":(exclude)**/.env*", ":(exclude)**/.npmrc", ":(exclude)**/.netrc",
                        ":(exclude)**/.pypirc", ":(exclude)**/.git-credentials",
                        ":(exclude)**/.codex/**", ":(exclude)**/.ssh/**", ":(exclude)**/.aws/**",
                        ":(exclude)**/.azure/**", ":(exclude)**/.docker/**", ":(exclude)**/.gnupg/**",
                        ":(exclude)**/.kube/**",
                        ":(exclude)**/auth.json", ":(exclude)**/credentials*", ":(exclude)**/*.pem",
                        ":(exclude)**/*.key", ":(exclude)**/token.json", ":(exclude)**/access_token",
                        ":(exclude)**/refresh_token", ":(exclude)**/client_secret.json",
                        ":(exclude)**/service-account.json", ":(exclude)**/service_account.json"],
                       check=True, stdout=stream, stderr=subprocess.PIPE)
    manifest = {
        "key": key,
        "branch": branch,
        "origin": origin,
        "head": head,
        "cwd": relative,
        "target": target,
        "memory_max": os.environ.get("ZF_WORKER_REMOTE_MEMORY_MAX", "8G"),
        "model": os.environ.get("CODEX_MODEL", "gpt-6-luna"),
        "effort": os.environ.get("CODEX_EFFORT", "max"),
        "search": bool(os.environ.get("CODEX_SEARCH")),
        "priority": os.environ.get("LUNA_PRIORITY", "normal"),
        "output_cap_kb": os.environ.get("WORKER_OUTPUT_CAP_KB", "64"),
        "scope": scope_name(key),
    }
    if not re.fullmatch(r"[1-9][0-9]*(?:[KMGTP]i?B?)?", manifest["memory_max"], re.I):
        raise ValueError("ZF_WORKER_REMOTE_MEMORY_MAX must be a systemd size such as 8G")
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
    staging = Path(staging)
    target = Path(target)
    job = json.loads((staging / "job.json").read_text())
    key, branch, origin = job["key"], job["branch"], job["origin"]
    validate_key(key)
    target.parent.mkdir(parents=True, exist_ok=True)
    fresh = not (target / ".git").exists()
    if fresh:
        if origin:
            clone = subprocess.run(["git", "clone", "--quiet", "--single-branch", "--branch", branch, origin, str(target)],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            if clone.returncode:
                raise RuntimeError("clone from GitHub failed")
        else:
            target.mkdir(parents=True, exist_ok=True)
            subprocess.run(["git", "-C", str(target), "init", "-q"], check=True, stdout=subprocess.DEVNULL)
    dirty = bool(git_output(target, "status", "--porcelain").stdout.strip()) if not fresh else False
    current_branch = git_output(target, "branch", "--show-current", allow_failure=True).stdout.strip()
    if dirty and current_branch != branch:
        raise RuntimeError("remote worktree is dirty on a different branch")
    if not dirty:
        if origin:
            subprocess.run(["git", "-C", str(target), "fetch", "--quiet", "origin", branch],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        subprocess.run(["git", "-C", str(target), "fetch", "--quiet", str(staging / "snapshot.bundle"),
                        "+HEAD:refs/remotes/zf/worker-input"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        if current_branch != branch:
            base_ref = f"refs/remotes/origin/{branch}" if origin else "refs/remotes/zf/worker-input"
            subprocess.run(["git", "-C", str(target), "checkout", "-B", branch, base_ref],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        input_ref = "refs/remotes/zf/worker-input"
        merge = subprocess.run(["git", "-C", str(target), "merge", "--ff-only", input_ref],
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        if merge.returncode:
            raise RuntimeError("local branch and remote branch have diverged")
        if (staging / "worktree.patch").stat().st_size:
            subprocess.run(["git", "-C", str(target), "apply", "--3way", str(staging / "worktree.patch")],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
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
    if shutil.which("codex") is None:
        npm = shutil.which("npm")
        if npm:
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
    command = [str(runtime / "bin/luna"), job["key"], str(cwd), str(staging / "prompt.md")]
    if (staging / "schema.json").is_file():
        command.append(str(staging / "schema.json"))
    child = subprocess.Popen(command, env=env, start_new_session=True)

    def stop_child(signum, _frame):
        subprocess.run(["systemctl", "stop", job["scope"] + ".scope"],
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
    unit = scope + ".scope"
    command = (f"systemctl stop {shlex.quote(unit)} >/dev/null 2>&1 || true; "
               f"for i in $(seq 1 100); do systemctl is-active --quiet {shlex.quote(unit)} || exit 0; "
               "sleep 0.1; done; exit 1")
    try:
        result = remote_call(host, command, timeout=connect_timeout_seconds() + 15,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        return 1
    return 0 if result.returncode == 0 else 1


def command_run(host, key, cwd, prompt, schema):
    validate_key(key)
    root = os.environ.get("ZF_WORKER_REMOTE_ROOT", "/srv/zf-workers")
    if not root.startswith("/") or ".." in PurePosixPath(root).parts:
        raise ValueError("ZF_WORKER_REMOTE_ROOT must be an absolute remote path")
    local_out = Path(os.environ.get("WORKER_SCRATCH_ROOT", str(Path.home() / ".zenoforge/scratch"))) / "luna" / key
    local_out.mkdir(parents=True, exist_ok=True)
    for name in ("events.jsonl", "last.md", "rc", "codex.pid", "stderr.log",
                 "remote-refused", "remote.host", "remote.scope"):
        try:
            (local_out / name).unlink()
        except FileNotFoundError:
            pass
    metrics, reason = probe(host, root)
    if metrics is None or reason:
        detail = reason or "remote capacity probe failed"
        (local_out / "remote-refused").write_text(detail + "\n")
        print(f"worker-remote: refusing {host}: {detail}", file=sys.stderr)
        return 75
    print(f"worker-remote: admitted {format_metrics(host, metrics)}", flush=True)
    top, _, _, _, _ = repository_info(cwd)
    staging_id = uuid.uuid4().hex
    staging = posixpath.join(root.rstrip("/"), ".incoming", staging_id)
    target = posixpath.join(root.rstrip("/"), key)
    local_staging_script = posixpath.join(staging, "worker-remote.py")
    with tempfile.TemporaryDirectory(prefix="zf-worker-remote-") as temp:
        archive_path = Path(temp) / "payload.tar"
        manifest = make_payload(top, cwd, prompt, schema, key, target, archive_path)
        transfer = (f"umask 077; mkdir -p -- {shlex.quote(staging)}; "
                    f"tar -xf - --no-same-owner --no-same-permissions -C {shlex.quote(staging)}")
        try:
            with archive_path.open("rb") as stream:
                shipped = remote_call(host, transfer, timeout=setting_seconds("ZF_WORKER_TRANSFER_TIMEOUT", "180"),
                                      stdin=stream, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except (OSError, subprocess.SubprocessError) as error:
            print(f"worker-remote: transfer failed on {host} ({type(error).__name__})", file=sys.stderr)
            return 125
        if shipped.returncode:
            print(f"worker-remote: transfer failed on {host} (rc={shipped.returncode})", file=sys.stderr)
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
                child = subprocess.Popen([*ssh_args(host), command], stdout=stdout, stderr=stderr, start_new_session=True)
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
        offsets = sync_remote(host, local_staging_script, remote_out, local_out, offsets)
        cleanup = f"rm -rf -- {shlex.quote(staging)}"
        try:
            remote_call(host, cleanup, timeout=connect_timeout_seconds() + 10,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except (OSError, subprocess.SubprocessError):
            pass
        return status if status >= 0 else 128 - status


def request_stop(_signum, _frame):
    global STOP_REQUESTED
    STOP_REQUESTED = True


def main(argv):
    if len(argv) == 2 and argv[1] == "choose":
        return command_choose()
    if len(argv) == 3 and argv[1] == "probe":
        return command_probe(argv[2])
    if len(argv) == 4 and argv[1] == "stop":
        return stop_remote(argv[2], argv[3])
    if len(argv) == 4 and argv[1] == "remote-prepare":
        return remote_prepare(argv[2], argv[3])
    if len(argv) == 3 and argv[1] == "remote-run":
        return remote_run(argv[2])
    if len(argv) == 5 and argv[1] == "remote-sync":
        return remote_sync(argv[2], int(argv[3]), int(argv[4]))
    if len(argv) == 7 and argv[1] == "run":
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(sig, request_stop)
        return command_run(argv[2], argv[3], argv[4], argv[5], argv[6])
    print("usage: worker-remote.py choose | probe <host> | run <host> <key> <cwd> <prompt> <schema>", file=sys.stderr)
    return 64


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError) as error:
        print(f"worker-remote: setup failed ({type(error).__name__}); credentials were not read or copied", file=sys.stderr)
        sys.exit(125)
