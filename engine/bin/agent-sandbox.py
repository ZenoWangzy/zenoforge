#!/usr/bin/env python3
import argparse
import ctypes
import json
import os
import pathlib
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import urllib.parse
from agent_sandbox_state import configure_zcode, prepare as prepare_session_state, prepare_codex_profile, restore as restore_session_state; from agent_sandbox_workspace import snapshot as snapshot_workspace, sync as sync_workspace; from agent_sandbox_network import configure_environment, run as run_sandbox, start_worker_proxy

LIBC = ctypes.CDLL(None, use_errno=True)
MS_RDONLY = 1
MS_NOSUID = 2
MS_NODEV = 4
MS_BIND = 4096
MS_REMOUNT = 32
MS_REC = 16384
MS_PRIVATE = 1 << 18
PR_SET_NO_NEW_PRIVS = 38
PR_CAPBSET_DROP = 24
PR_CAP_AMBIENT = 47
PR_CAP_AMBIENT_CLEAR_ALL = 4
CAP_VERSION_3 = 0x20080522
PUSH_OPTIONS = {"-u", "--set-upstream", "--porcelain", "--progress", "--verbose", "--quiet"}


def run(argv, cwd=None, env=None, check=True, capture=True):
    result = subprocess.run(argv, cwd=cwd, env=env, text=True, stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None)
    if check and result.returncode:
        detail = (result.stderr or result.stdout or "").strip()
        raise RuntimeError(detail or f"command failed with rc={result.returncode}")
    return result


def git(repo, *args, check=True, env=None): return run(["git", "-C", repo, *args], env=env, check=check)


def mount_call(source, target, filesystem=None, flags=0, data=None):
    source_arg = None if source is None else os.fsencode(source)
    target_arg = os.fsencode(target)
    filesystem_arg = None if filesystem is None else os.fsencode(filesystem)
    data_arg = None if data is None else os.fsencode(data)
    if LIBC.mount(source_arg, target_arg, filesystem_arg, flags, data_arg) != 0:
        code = ctypes.get_errno()
        raise OSError(code, f"{os.strerror(code)} source={source!r}", os.fspath(target))


def bind_path(source, target, readonly=False):
    mount_call(source, target, flags=MS_BIND)
    if readonly:
        mount_call(None, target, flags=MS_BIND | MS_REMOUNT | MS_RDONLY | MS_NOSUID | MS_NODEV)


def bind_file(source, target, readonly=True):
    pathlib.Path(target).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(target).touch(exist_ok=True)
    bind_path(source, target, readonly)


def bind_directory(source, target, readonly=False): pathlib.Path(target).mkdir(parents=True, exist_ok=True); bind_path(source, target, readonly)


def tmpfs(target, size="64m"):
    path = pathlib.Path(target)
    if not path.exists():
        return
    flags = MS_NOSUID if target == "/dev" else MS_NOSUID | MS_NODEV
    mount_call("tmpfs", target, "tmpfs", flags, f"mode=755,size={size}")


def opened(path, directory=False):
    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_PATH"):
        flags &= ~os.O_RDONLY
        flags |= os.O_PATH
    if directory:
        flags |= os.O_DIRECTORY
    return os.open(path, flags)


def open_if_exists(path, directory=False):
    try:
        return opened(path, directory)
    except OSError:
        return None


def safe_remote(repo):
    remote = git(repo, "config", "--local", "--get", "remote.origin.url", check=False).stdout.strip()
    if not remote:
        raise RuntimeError("origin remote is missing")
    if re.fullmatch(r"[^/@:]+@[^/:]+:.+", remote):
        host, path = remote.split("@", 1)[1].split(":", 1)
        if not re.fullmatch(r"[A-Za-z0-9.-]+", host) or not re.fullmatch(r"[A-Za-z0-9._/-]+", path):
            raise RuntimeError("origin remote is not a safe SSH repository URL")
        return f"https://{host}/{path}"
    parsed = urllib.parse.urlsplit(remote)
    if parsed.scheme == "file" and not parsed.netloc and not parsed.query and not parsed.fragment:
        return remote
    if parsed.scheme not in {"http", "https"} or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise RuntimeError("origin remote must not contain embedded credentials")
    if parsed.port not in {None, 443 if parsed.scheme == "https" else 80}:
        raise RuntimeError("origin remote uses an unsupported port")
    if not re.fullmatch(r"[A-Za-z0-9.-]+", parsed.hostname) or not re.fullmatch(r"/[A-Za-z0-9._/-]+", parsed.path):
        raise RuntimeError("origin remote is not a safe repository URL")
    return remote


def validate_branch(repo, access):
    branch = git(repo, "symbolic-ref", "--quiet", "--short", "HEAD", check=False).stdout.strip()
    if not branch and access == "read":
        return "sandbox-read"
    if not branch or run(["git", "check-ref-format", "--branch", branch], check=False).returncode:
        raise RuntimeError("worker worktree must be on a named branch")
    if access == "write" and branch in {"main", "master"}:
        raise RuntimeError("write workers cannot receive a push capability on a protected branch")
    return branch


def provider_auth(provider):
    home = pathlib.Path(os.environ.get("HOME", str(pathlib.Path.home()))).resolve()
    if provider == "codex":
        source = pathlib.Path(os.environ.get("CODEX_HOME", home / ".codex")) / "auth.json"
        target = "/tmp/worker/.codex/auth.json"
        keys = ("OPENAI_API_KEY", "CODEX_API_KEY")
    elif provider == "zcode":
        source = pathlib.Path(os.environ.get("ZCODE_CREDENTIALS_FILE", home / ".zcode/v2/credentials.json"))
        target = "/tmp/worker/.zcode/v2/credentials.json"
        keys = ("ZAI_API_KEY", "ZHIPUAI_API_KEY", "GLM_API_KEY")
    else:
        source = pathlib.Path(os.environ.get("CLAUDE_CONFIG_DIR", home / ".claude")) / ".credentials.json"
        target = "/tmp/worker/.claude/.credentials.json"
        keys = ("ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN")
    fd = open_if_exists(source)
    present = any(os.environ.get(name) for name in keys)
    if fd is None and not present:
        raise RuntimeError(f"selected provider has no credential file or API key: {provider}")
    return source, target, fd, keys


def safe_proxy(value):
    parsed = urllib.parse.urlsplit(value)
    return value if parsed.scheme in {"http", "https", "socks5", "socks5h"} and parsed.hostname and not parsed.username and not parsed.password else ""


def clean_environment(provider, stage, access, push_socket):
    env = {
        "HOME": "/tmp/worker",
        "PATH": f"{stage}/bin:/opt/zf-agent/bin:/usr/local/bin:/usr/bin:/bin",
        "TMPDIR": "/tmp",
        "LANG": os.environ.get("LANG", "C.UTF-8"),
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_SYSTEM": "/dev/null",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_ASKPASS": "/bin/false",
        "ZF_AGENT_ACCESS": access,
    }
    for name in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"):
        value = safe_proxy(os.environ.get(name, ""))
        if value:
            env[name] = value
    for name in ("NO_PROXY", "no_proxy", "LANGUAGE", "LC_ALL", "TERM", "CI", "NO_COLOR", "NODE_USE_ENV_PROXY", "COREPACK_ENABLE_DOWNLOAD_PROMPT", "BASH_MAX_OUTPUT_LENGTH"):
        if name in os.environ:
            env[name] = os.environ[name]
    if os.environ.get("CONTEXT_MODE_MCP_SENTINEL_DIR"):
        env["CONTEXT_MODE_MCP_SENTINEL_DIR"] = "/tmp/context-mode-mcp-ready"
    if provider == "codex":
        env["CODEX_HOME"] = "/tmp/worker/.codex"
    elif provider == "zcode":
        env["ZCODE_CREDENTIALS_FILE"] = "/tmp/worker/.zcode/v2/credentials.json"
    else:
        env["CLAUDE_CONFIG_DIR"] = "/tmp/worker/.claude"
    auth_keys = {"codex": ("OPENAI_API_KEY", "CODEX_API_KEY"), "zcode": ("ZAI_API_KEY", "ZHIPUAI_API_KEY", "GLM_API_KEY"),
                 "claude": ("ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN")}[provider]
    for name in auth_keys:
        if os.environ.get(name):
            env[name] = os.environ[name]
    if push_socket is not None:
        env["ZF_PUSH_SOCKET"] = push_socket
    return env


def discover_refs(repo, branch, stage):
    head = git(repo, "rev-parse", "--verify", "HEAD^{commit}").stdout.strip()
    base = git(repo, "rev-parse", "--verify", "refs/remotes/origin/main^{commit}", check=False).stdout.strip()
    refs = [f"refs/heads/{branch}"] if git(repo, "show-ref", "--verify", "--quiet", f"refs/heads/{branch}", check=False).returncode == 0 else ["HEAD"]
    if base:
        refs.append("refs/remotes/origin/main")
    run(["git", "bundle", "create", str(pathlib.Path(stage) / "worker.bundle"), *refs], cwd=repo)
    return head, base, refs


def git_config(git_dir, *args, check=True): return run(["git", f"--git-dir={git_dir}", "config", *args], check=check)


def config_value(repo, key): return git(repo, "config", "--local", "--get", key, check=False).stdout.rstrip("\n")


def prepare_git(repo, branch, remote, stage, access):
    head, base, refs = discover_refs(repo, branch, stage)
    worker_git = pathlib.Path(stage) / "git"
    run(["git", "clone", "--bare", str(pathlib.Path(stage) / "worker.bundle"), str(worker_git)])
    git_config(worker_git, "core.logAllRefUpdates", "true")
    git_config(worker_git, "remote.origin.url", remote)
    git_config(worker_git, "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*")
    git_config(worker_git, "branch." + branch + ".remote", "origin")
    git_config(worker_git, "branch." + branch + ".merge", "refs/heads/" + branch)
    git_config(worker_git, "user.name", os.environ.get("AGENT_GIT_USER_NAME") or config_value(repo, "user.name") or "Zenoforge Agent")
    git_config(worker_git, "user.email", os.environ.get("AGENT_GIT_USER_EMAIL") or config_value(repo, "user.email") or "agent@users.noreply.github.com")
    for key in ("zenoforge.size-admission.limit", "zenoforge.size-admission.exempt", "zenoforge.size-admission.base-branch", "zenoforge.repo"):
        value = config_value(repo, key)
        if value:
            git_config(worker_git, key, value)
    git_config(worker_git, "core.filemode", config_value(repo, "core.filemode") or "true")
    run(["git", f"--git-dir={worker_git}", "update-ref", f"refs/heads/{branch}", head])
    run(["git", f"--git-dir={worker_git}", "symbolic-ref", "HEAD", f"refs/heads/{branch}"])
    if base:
        run(["git", f"--git-dir={worker_git}", "update-ref", "refs/remotes/origin/main", base])
    run(["git", f"--git-dir={worker_git}", f"--work-tree={repo}", "read-tree", head])
    git_config(worker_git, "core.bare", "false")
    git_config(worker_git, "core.worktree", "/run/zf-agent/workspace")
    common = git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir").stdout.strip()
    if access == "read":
        for path in (worker_git / "config", worker_git / "packed-refs"):
            if path.exists():
                path.chmod(0o444)
        for path in (worker_git / "refs", worker_git / "objects"):
            if path.exists():
                for nested in sorted(path.rglob("*"), reverse=True):
                    if nested.is_dir():
                        nested.chmod(0o555)
                    else:
                        nested.chmod(0o444)
                path.chmod(0o555)
    else:
        remotes = worker_git / "refs/remotes"
        if remotes.exists():
            for nested in sorted(remotes.rglob("*"), reverse=True):
                nested.chmod(0o555 if nested.is_dir() else 0o444)
            remotes.chmod(0o555)
        packed = worker_git / "packed-refs"
        if packed.exists():
            packed.chmod(0o444)
    return worker_git, head, base


def sync_host_branch(repo, broker_dir, branch, original_head, stage):
    if broker_dir is None:
        return
    head = run(["git", f"--git-dir={broker_dir}", "rev-parse", f"refs/heads/{branch}"], check=False).stdout.strip()
    if not head or head == original_head:
        return
    bundle = pathlib.Path(stage) / "result.bundle"
    ref = f"refs/zf-agent/sandbox-sync/{branch}"
    run(["git", f"--git-dir={broker_dir}", "bundle", "create", str(bundle), f"refs/heads/{branch}"])
    run(["git", "-C", repo, "fetch", "--quiet", "--no-tags", str(bundle), f"refs/heads/{branch}:{ref}"])
    if run(["git", "-C", repo, "merge-base", "--is-ancestor", original_head, ref], check=False).returncode:
        raise RuntimeError("sandbox branch update is not a fast-forward")
    run(["git", "-C", repo, "update-ref", f"refs/heads/{branch}", ref, original_head])
    run(["git", "-C", repo, "reset", "--mixed", ref])
    run(["git", "-C", repo, "update-ref", "-d", ref])


def broker_git(repo, remote, branch, stage, host_temp, head, base, access):
    broker_dir = pathlib.Path(host_temp) / "broker.git"
    object_format = git(repo, "rev-parse", "--show-object-format").stdout.strip()
    run(["git", "init", "--bare", "--quiet", f"--object-format={object_format}", str(broker_dir)])
    git_config(broker_dir, "core.bare", "false")
    git_config(broker_dir, "core.worktree", repo)
    git_config(broker_dir, "remote.origin.url", remote)
    git_config(broker_dir, "user.name", "Zenoforge Agent")
    git_config(broker_dir, "user.email", "agent@users.noreply.github.com")
    git_config(broker_dir, "branch." + branch + ".remote", "origin")
    git_config(broker_dir, "branch." + branch + ".merge", "refs/heads/" + branch)
    alternate_dirs = [str(pathlib.Path(stage) / "git/objects")]
    pathlib.Path(broker_dir, "objects/info/alternates").write_text("\n".join(alternate_dirs) + "\n")
    for key in ("zenoforge.size-admission.limit", "zenoforge.size-admission.exempt", "zenoforge.size-admission.base-branch", "zenoforge.repo"):
        value = config_value(repo, key)
        if value:
            git_config(broker_dir, key, value)
    if base:
        run(["git", f"--git-dir={broker_dir}", "update-ref", "refs/remotes/origin/main", base])
    run(["git", f"--git-dir={broker_dir}", "update-ref", f"refs/heads/{branch}", head])
    run(["git", f"--git-dir={broker_dir}", "symbolic-ref", "HEAD", f"refs/heads/{branch}"])
    hooks = pathlib.Path(host_temp) / "trusted-hooks"
    hooks.mkdir()
    pack_rel = os.environ.get("ZF_PACK_REL", "engine")
    if not re.fullmatch(r"[A-Za-z0-9._/-]+", pack_rel) or ".." in pack_rel.split("/"):
        raise RuntimeError("invalid engine pack path")
    guard = git(repo, "show", f"refs/remotes/origin/main:{pack_rel}/pre-push-guard.sh", check=False)
    if guard.returncode == 0 and guard.stdout:
        hook = hooks / "pre-push"
        hook.write_text(guard.stdout)
        hook.chmod(0o555)
        hooks.chmod(0o555)
        git_config(broker_dir, "core.hooksPath", str(hooks))
    return broker_dir, alternate_dirs


def push_args_safe(args, branch):
    index = 0
    while index < len(args):
        word = args[index]
        if word in {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"}:
            index += 2
            continue
        if word == "--no-pager" or word == "-P":
            index += 1
            continue
        if word == "push":
            break
        return False
    if index == len(args):
        return False
    positionals = []
    cursor = index + 1
    while cursor < len(args):
        word = args[cursor]
        if word in {"--force", "-f", "--force-with-lease", "--all", "--mirror", "--tags", "--prune", "--delete", "-d", "--atomic", "--receive-pack", "--exec"}:
            return False
        if word.startswith("-"):
            if word in PUSH_OPTIONS:
                cursor += 1
                continue
            if word.startswith("--push-option=") or word.startswith("-o"):
                return False
            return False
        positionals.append(word)
        cursor += 1
    if len(positionals) > 2:
        return False
    refspecs = positionals[1:] if positionals and positionals[0] == "origin" else positionals
    if len(positionals) == 2 and positionals[0] != "origin":
        return False
    if not refspecs:
        return True
    allowed = {branch, "HEAD", f"{branch}:{branch}", f"HEAD:{branch}", f"refs/heads/{branch}:refs/heads/{branch}", f"HEAD:refs/heads/{branch}"}
    return all(spec in allowed for spec in refspecs)


def broker_request(payload, broker_dir, repo, branch, alternate_dirs, access):
    if access != "write" or not push_args_safe(payload.get("args", []), branch):
        return {"ok": False, "output": "push refused: this worker may publish only its captured branch"}
    commit = payload.get("commit", "")
    if not re.fullmatch(r"[0-9a-f]{40,64}", commit):
        return {"ok": False, "output": "push refused: invalid commit id"}
    env = {
        **os.environ,
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_SYSTEM": "/dev/null",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_ASKPASS": "/bin/false",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES": os.pathsep.join(alternate_dirs),
    }
    verify = run(["git", f"--git-dir={broker_dir}", "cat-file", "-e", f"{commit}^{{commit}}"], env=env, check=False)
    if verify.returncode:
        return {"ok": False, "output": "push refused: commit is not present in this worker repository"}
    old = run(["git", f"--git-dir={broker_dir}", "rev-parse", f"refs/heads/{branch}"], env=env, check=False).stdout.strip()
    if not old or run(["git", f"--git-dir={broker_dir}", "merge-base", "--is-ancestor", old, commit], env=env, check=False).returncode:
        return {"ok": False, "output": "push refused: commit must advance the captured branch"}
    update = run(["git", f"--git-dir={broker_dir}", "update-ref", f"refs/heads/{branch}", commit, old], env=env, check=False)
    if update.returncode:
        return {"ok": False, "output": "push refused: worker branch update failed"}
    command = ["git", f"--git-dir={broker_dir}", f"--work-tree={repo}", "-c", "credential.helper=", "-c",
               "credential.helper=!gh auth git-credential", "-c", "http.extraHeader=", "push", "origin", f"{commit}:refs/heads/{branch}"]
    result = run(command, env=env, check=False)
    if result.returncode:
        run(["git", f"--git-dir={broker_dir}", "update-ref", f"refs/heads/{branch}", old, commit], env=env, check=False)
    return {"ok": result.returncode == 0, "output": (result.stdout + result.stderr).strip()}


def broker_loop(server, broker_dir, repo, branch, alternate_dirs, access):
    while True:
        try:
            connection, _ = server.accept()
        except OSError:
            return
        with connection:
            try:
                payload = json.loads(connection.recv(65536).decode("utf-8"))
                result = broker_request(payload, broker_dir, repo, branch, alternate_dirs, access)
            except Exception as error:
                result = {"ok": False, "output": f"push broker failed: {error}"}
            try:
                connection.send(json.dumps(result).encode("utf-8"))
            except OSError:
                continue


def cli_git_script():
    return """#!/usr/bin/env python3
import json, os, socket, subprocess, sys
args = sys.argv[1:]
index = 0
while index < len(args):
    if args[index] in ('-C', '-c', '--git-dir', '--work-tree', '--namespace', '--exec-path'):
        index += 2
        continue
    if args[index] in ('--no-pager', '-P'):
        index += 1
        continue
    break
if index >= len(args) or args[index] != 'push':
    os.execv('/usr/bin/git', ['git', *args])
path = os.environ.get('ZF_PUSH_SOCKET')
if not path:
    print('push refused: this worker has no push capability', file=sys.stderr)
    raise SystemExit(1)
commit = subprocess.run(['/usr/bin/git', 'rev-parse', '--verify', 'HEAD^{commit}'], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
if commit.returncode:
    print(commit.stderr.strip() or 'push refused: no current commit', file=sys.stderr)
    raise SystemExit(1)
channel = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
channel.connect('\\0' + path[1:] if path.startswith('@') else path)
channel.send(json.dumps({'args': args, 'commit': commit.stdout.strip()}).encode())
response = json.loads(channel.recv(65536).decode())
if response.get('output'):
    print(response['output'], file=sys.stdout if response.get('ok') else sys.stderr)
raise SystemExit(0 if response.get('ok') else 1)
"""


def write_script(path, body): path.write_text("#!/bin/sh\n" + body + "\n"); path.chmod(0o555)


def package_root(path):
    for parent in path.parents:
        if (parent / "package.json").is_file():
            return parent
    return path.parent


def tool_mount(stage, source, name, directory=False):
    source = pathlib.Path(source).resolve(strict=True)
    target = pathlib.Path(stage, "tools", name)
    target.parent.mkdir(parents=True, exist_ok=True)
    if directory:
        target.mkdir(exist_ok=True)
    else:
        target.touch(exist_ok=True)
    manifest = pathlib.Path(stage, "tool-mounts.json")
    mounts = json.loads(manifest.read_text()) if manifest.exists() else []
    mounts.append({"source": str(source), "target": f"/run/zf-agent/tools/{name}", "directory": directory})
    manifest.write_text(json.dumps(mounts))
    return target


def node_runtime(stage):
    if pathlib.Path(stage, "tools/node").exists():
        return
    candidate = shutil.which("node")
    if not candidate:
        raise RuntimeError("selected provider requires Node.js, but node is not available")
    tool_mount(stage, candidate, "node")
    write_script(pathlib.Path(stage, "bin/node"), "exec /run/zf-agent/tools/node \"$@\"")


def add_js_tool(stage, name, script, runtime=None):
    script = pathlib.Path(script).resolve(strict=True)
    root = package_root(script)
    tool_mount(stage, root, name + "-package", True)
    entry = pathlib.PurePosixPath(script.relative_to(root).as_posix())
    runner = runtime or "/run/zf-agent/bin/node"
    write_script(pathlib.Path(stage, "bin", name), f"exec {runner} /run/zf-agent/tools/{name}-package/{entry} \"$@\"")


def zcode_argv(command):
    for index in range(len(command) - 1):
        runtime, entry = pathlib.Path(command[index]), pathlib.Path(command[index + 1])
        if runtime.is_file() and os.access(runtime, os.X_OK) and entry.is_file() and entry.suffix in {".js", ".cjs", ".mjs"}:
            return command[index:index + 2]
    candidate = os.environ.get("ZF_ZCODE_BIN") or shutil.which("zcode")
    if candidate and pathlib.Path(candidate).is_file():
        return [candidate]
    raise RuntimeError("selected ZCode executable could not be resolved for the sandbox")


def prepare_provider_tools(provider, command, stage):
    pathlib.Path(stage, "tools").mkdir(exist_ok=True)
    pathlib.Path(stage, "bin").mkdir(exist_ok=True)
    pathlib.Path(stage, "tool-mounts.json").write_text("[]")
    if shutil.which("node"):
        node_runtime(stage)
    for name in ("npm", "npx", "pnpm", "corepack"):
        candidate = shutil.which(name)
        if not candidate:
            continue
        target = pathlib.Path(candidate).resolve()
        try:
            first = target.open("rb").read(128)
        except OSError:
            continue
        if b"node" in first and (target.suffix in {".js", ".cjs", ".mjs"} or first.startswith(b"#!")):
            if shutil.which("node"):
                add_js_tool(stage, name, target)
    if provider == "codex":
        candidate = shutil.which("codex")
        if not candidate:
            raise RuntimeError("Codex executable is not available inside the sandbox")
        target = pathlib.Path(candidate).resolve(strict=True)
        if target.suffix in {".js", ".cjs", ".mjs"}:
            node_runtime(stage)
            add_js_tool(stage, "codex", target)
        else:
            tool_mount(stage, target, "codex")
            write_script(pathlib.Path(stage, "bin/codex"), "exec /run/zf-agent/tools/codex \"$@\"")
    elif provider == "claude":
        candidate = shutil.which("claude")
        if not candidate:
            raise RuntimeError("Claude executable is not available inside the sandbox")
        target = pathlib.Path(candidate).resolve(strict=True)
        tool_mount(stage, target, "claude")
        write_script(pathlib.Path(stage, "bin/claude"), "exec /run/zf-agent/tools/claude \"$@\"")
    else:
        argv = zcode_argv(command)
        if len(argv) == 2 and pathlib.Path(argv[1]).suffix in {".js", ".cjs", ".mjs"}:
            runtime = pathlib.Path(argv[0]).resolve(strict=True)
            tool_mount(stage, runtime, "zcode-runtime")
            entry = pathlib.Path(argv[1]).resolve(strict=True)
            root = package_root(entry)
            tool_mount(stage, root, "zcode-package", True)
            relative = entry.relative_to(root).as_posix()
            write_script(pathlib.Path(stage, "bin/zcode"), f"exec /run/zf-agent/tools/zcode-runtime /run/zf-agent/tools/zcode-package/{relative} \"$@\"")
        else:
            target = pathlib.Path(argv[0]).resolve(strict=True)
            tool_mount(stage, target, "zcode")
            write_script(pathlib.Path(stage, "bin/zcode"), "exec /run/zf-agent/tools/zcode \"$@\"")
    return zcode_argv(command) if provider == "zcode" else []


def write_git_shim(stage):
    binary_dir = pathlib.Path(stage) / "bin"
    binary_dir.mkdir(parents=True, exist_ok=True)
    shim = binary_dir / "git"
    shim.write_text(cli_git_script())
    shim.chmod(0o555)


def drop_capabilities():
    for capability in range(64):
        LIBC.prctl(PR_CAPBSET_DROP, capability, 0, 0, 0)
    LIBC.prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0)
    class CapHeader(ctypes.Structure):
        _fields_ = [("version", ctypes.c_uint32), ("pid", ctypes.c_int)]
    class CapData(ctypes.Structure):
        _fields_ = [("effective", ctypes.c_uint32), ("permitted", ctypes.c_uint32), ("inheritable", ctypes.c_uint32)]
    header = CapHeader(CAP_VERSION_3, 0)
    data = (CapData * 2)()
    if LIBC.capset(ctypes.byref(header), ctypes.byref(data)) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code))
    if LIBC.prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code))


def inner_main(options):
    mount_call(None, "/", flags=MS_REC | MS_PRIVATE)
    tmpfs("/run")
    pathlib.Path("/run/zf-agent").mkdir(parents=True, exist_ok=True)
    bind_directory(options.host_stage, "/run/zf-agent")
    if options.host_sessions:
        bind_directory(options.host_sessions, "/run/zf-agent-sessions")
    for item in json.loads(pathlib.Path("/run/zf-agent/tool-mounts.json").read_text()):
        target = pathlib.Path(item["target"])
        if item["directory"]:
            bind_directory(item["source"], target, True)
        else:
            bind_file(item["source"], target, True)
    capture = pathlib.Path("/run/zf-agent/capture")
    capture.mkdir(exist_ok=True)
    bind_directory(capture, "/run/zf-capture")
    workspace = pathlib.Path("/run/zf-agent/workspace")
    workspace.mkdir(exist_ok=True)
    bind_directory(options.host_workspace, workspace, options.access == "read")
    if options.node_modules: bind_directory(options.node_modules, workspace / "node_modules", True)
    pathlib.Path("/run/zf-agent/dev-null").touch(exist_ok=True); pathlib.Path("/run/zf-agent/dev-urandom").touch(exist_ok=True)
    bind_file("/dev/null", "/run/zf-agent/dev-null", False)
    bind_file("/dev/urandom", "/run/zf-agent/dev-urandom", False)
    worker_git = pathlib.Path("/run/zf-agent/git")
    git_entry = workspace / ".git"
    if options.git_entry_dir:
        bind_directory(worker_git, git_entry, options.access == "read")
    else:
        bind_file("/run/zf-agent/gitfile", git_entry, True)
    pathlib.Path("/run/zf-agent/host-certs").mkdir(exist_ok=True)
    bind_directory("/etc/ssl/certs", "/run/zf-agent/host-certs", True)
    if options.access == "read":
        mount_call(None, "/run/zf-agent", flags=MS_BIND | MS_REMOUNT | MS_RDONLY | MS_NOSUID | MS_NODEV)
    for path in ("/etc", "/home", "/root", "/tmp", "/mnt", "/media", "/srv", "/opt", "/sys", "/dev", "/var"):
        tmpfs(path)
    for path in ("/var/tmp", "/var/cache", "/var/lib"): pathlib.Path(path).mkdir(parents=True, exist_ok=True)
    for name in ("hosts", "resolv.conf", "nsswitch.conf", "passwd", "group", "ld.so.cache"):
        source = pathlib.Path("/run/zf-agent/etc") / name
        if source.exists():
            bind_file(source, pathlib.Path("/etc") / name, True)
    pathlib.Path("/etc/ssl/certs").mkdir(parents=True, exist_ok=True)
    bind_directory("/run/zf-agent/host-certs", "/etc/ssl/certs", True)
    pathlib.Path("/etc/os-release").symlink_to("/usr/lib/os-release")
    pathlib.Path("/etc/localtime").symlink_to("/usr/share/zoneinfo/Etc/UTC")
    pathlib.Path("/tmp/worker").mkdir(parents=True, exist_ok=True)
    pathlib.Path("/tmp/context-mode-mcp-ready").mkdir(parents=True, exist_ok=True)
    if options.provider == "zcode": configure_zcode("/tmp/worker/.zcode/cli/config.json")
    if options.provider == "codex" and pathlib.Path(options.stage_path, "codex-config.toml").is_file(): bind_file(pathlib.Path(options.stage_path, "codex-config.toml"), "/tmp/worker/.codex/config.toml", True)
    if options.host_sessions:
        pathlib.Path(options.session_target).parent.mkdir(parents=True, exist_ok=True)
        bind_directory("/run/zf-agent-sessions", options.session_target)
    pathlib.Path("/dev/null").touch(exist_ok=True)
    bind_path("/run/zf-agent/dev-null", "/dev/null")
    pathlib.Path("/dev/urandom").touch(exist_ok=True)
    bind_path("/run/zf-agent/dev-urandom", "/dev/urandom")
    pathlib.Path("/dev/fd").symlink_to("/proc/self/fd")
    pathlib.Path("/dev/stdin").symlink_to("/proc/self/fd/0")
    pathlib.Path("/dev/stdout").symlink_to("/proc/self/fd/1")
    pathlib.Path("/dev/stderr").symlink_to("/proc/self/fd/2")
    if options.auth_present:
        pathlib.Path(options.auth_target).parent.mkdir(parents=True, exist_ok=True)
        bind_file("/run/zf-agent/provider-auth", options.auth_target, True)
    environ = json.loads(pathlib.Path(options.stage_path, "environment.json").read_text())
    command = json.loads(pathlib.Path(options.stage_path, "command.json").read_text())
    os.chdir(workspace)
    start_worker_proxy()
    drop_capabilities()
    os.execvpe(command[0], command, environ)

def rewrite_args(command, repo, provider, zcode_argv, readonly, capture_output):
    values = []
    home = str(pathlib.Path(os.environ.get("HOME", str(pathlib.Path.home()))).resolve())
    index = 0
    while index < len(command):
        if zcode_argv and command[index:index + len(zcode_argv)] == zcode_argv:
            values.append("/run/zf-agent/bin/zcode")
            index += len(zcode_argv)
            continue
        value = command[index]
        if value == capture_output and capture_output:
            value = "/run/zf-capture/last.md"
        else:
            for source, target in readonly.items():
                value = value.replace(source, target)
            value = value.replace(repo + os.sep, "/run/zf-agent/workspace/")
            if value == repo:
                value = "/run/zf-agent/workspace"
        value = value.replace(home, "/tmp/worker")
        values.append(value)
        index += 1
    return values


def parse_args(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--provider", choices=("codex", "zcode", "claude"), required=True)
    parser.add_argument("--access", choices=("read", "edit", "write"), required=True)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--capture-output", default="")
    parser.add_argument("--engine-root", default="")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    options = parser.parse_args(argv)
    if options.command and options.command[0] == "--":
        options.command = options.command[1:]
    if not options.command:
        parser.error("a command is required after --")
    return options


def main(argv=None):
    options = parse_args(sys.argv[1:] if argv is None else argv)
    if sys.platform != "linux":
        raise RuntimeError("worker sandbox requires Linux user and mount namespaces")
    requested_repo = str(pathlib.Path(options.repo).resolve(strict=True))
    repo = git(requested_repo, "rev-parse", "--show-toplevel").stdout.strip()
    branch = validate_branch(repo, options.access)
    remote = safe_remote(repo)
    temp = tempfile.TemporaryDirectory(prefix="zf-", dir="/tmp")
    host_temp = pathlib.Path(temp.name)
    stage = host_temp / "stage"
    stage.mkdir(mode=0o700)
    etc = stage / "etc"; etc.mkdir()
    (stage / "capture").mkdir()
    hosts = pathlib.Path("/etc/hosts")
    resolv = pathlib.Path("/etc/resolv.conf")
    nsswitch = "hosts: files dns\npasswd: files\ngroup: files\nshadow: files\nservices: files\nnetworks: files\n"
    (etc / "hosts").write_bytes(hosts.read_bytes() if hosts.is_file() else b"127.0.0.1 localhost\n::1 localhost\n")
    (etc / "resolv.conf").write_bytes(resolv.read_bytes() if resolv.is_file() else b"")
    (etc / "nsswitch.conf").write_text(nsswitch)
    (etc / "passwd").write_text("root:x:0:0:worker:/tmp/worker:/bin/sh\n")
    (etc / "group").write_text("root:x:0:\n")
    cache = pathlib.Path("/etc/ld.so.cache")
    if cache.is_file():
        shutil.copyfile(cache, etc / "ld.so.cache")
    (stage / "host-certs").mkdir()
    auth_source, auth_target, auth_fd, _ = provider_auth(options.provider)
    session_state = prepare_session_state(options.provider, options.command, os.environ, repo, host_temp); prepare_codex_profile(options.command, os.environ, stage)
    git_entry_dir = pathlib.Path(repo, ".git").is_dir()
    write_git_shim(stage)
    worker_git, head, base = prepare_git(repo, branch, remote, stage, options.access)
    if not git_entry_dir:
        pathlib.Path(stage, "gitfile").write_text("gitdir: /run/zf-agent/git\n")
        pathlib.Path(stage, "gitfile").chmod(0o444)
    (worker_git / "config").chmod(0o444)
    workspace = stage / "workspace"; initial_untracked, node_modules_arg = snapshot_workspace(repo, workspace, git_entry_dir, host_temp / "dependencies")
    (stage / "dev-null").touch()
    (stage / "dev-urandom").touch()
    if auth_fd is not None:
        shutil.copyfile(auth_source, stage / "provider-auth")
        (stage / "provider-auth").chmod(0o400)
        os.close(auth_fd)
        auth_fd = None
    broker_dir = None
    if options.access == "write":
        broker_dir, alternate_dirs = broker_git(repo, remote, branch, stage, host_temp, head, base, options.access)
        host_sock = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        socket_name = str(stage / "push.sock")
        host_sock.bind(socket_name)
        os.chmod(socket_name, 0o600)
        host_sock.listen()
        broker_thread = threading.Thread(target=broker_loop, args=(host_sock, broker_dir, repo, branch, alternate_dirs, options.access), daemon=True)
        broker_thread.start()
    else:
        host_sock = None
        broker_thread = None
    zcode_command = zcode_argv(options.command) if options.provider == "zcode" else []
    prepare_provider_tools(options.provider, options.command, stage)
    readonly = {}
    engine_root_path = pathlib.Path(options.engine_root) if options.engine_root else pathlib.Path(repo)
    engine_root = engine_root_path.resolve()
    sources = [engine_root_path / "bin/install-guard"]
    sources.extend(pathlib.Path(options.command[index + 1]) for index, value in enumerate(options.command[:-1]) if value in {"--add-dir", "--attach", "--cd", "--settings", "--output-schema"})
    for source in dict.fromkeys(sources):
        raw = str(source)
        source = source.resolve()
        explicit = any(raw == options.command[index + 1] for index, value in enumerate(options.command[:-1]) if value in {"--attach", "--settings", "--output-schema"})
        allowed = explicit or engine_root in source.parents or source == engine_root.parent
        if not source.exists() or source == pathlib.Path(repo) or (pathlib.Path(repo) in source.parents and not explicit) or not allowed:
            continue
        target = tool_mount(stage, source, f"readonly-{len(readonly)}", source.is_dir())
        destination = f"/run/zf-agent/tools/{target.name}"
        readonly[raw] = destination
        readonly[str(source)] = destination
    command = rewrite_args(options.command, repo, options.provider, zcode_command, readonly, options.capture_output)
    env = configure_environment(clean_environment(options.provider, "/run/zf-agent", options.access,
                                                   "/run/zf-agent/push.sock" if options.access == "write" else None))
    (stage / "environment.json").write_text(json.dumps(env))
    (stage / "command.json").write_text(json.dumps(command))
    inner = [sys.executable, str(pathlib.Path(__file__).resolve()), "--inside", "--host-stage", str(stage), "--host-workspace", str(workspace), "--git-entry-dir" if git_entry_dir else "--git-entry-file", "--stage-path", "/run/zf-agent", "--access", options.access, "--provider", options.provider]; node_modules_arg and inner.extend(["--node-modules", node_modules_arg])
    if session_state is not None:
        inner.extend(["--host-sessions", str(session_state["store"]), "--session-target", str(session_state["target"])])
    if (stage / "provider-auth").exists():
        inner.extend(["--auth-present", "--auth-target", auth_target])
    try:
        result = run_sandbox(inner, repo, stage, options.provider)
        restore_session_state(session_state)
        if options.access in {"edit", "write"}: sync_workspace(repo, worker_git, workspace, head, initial_untracked); sync_host_branch(repo, broker_dir, branch, head, stage)
        if options.capture_output and (stage / "capture/last.md").is_file():
            shutil.copyfile(stage / "capture/last.md", options.capture_output)
        if host_sock is not None:
            host_sock.close()
        if broker_thread is not None:
            broker_thread.join(timeout=2)
        return result.returncode
    finally:
        temp.cleanup()


def inside_args(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--inside", action="store_true")
    parser.add_argument("--host-stage", required=True)
    parser.add_argument("--host-workspace", required=True); parser.add_argument("--node-modules", default="")
    parser.add_argument("--git-entry-dir", action="store_true")
    parser.add_argument("--git-entry-file", action="store_true")
    parser.add_argument("--stage-path", required=True)
    parser.add_argument("--host-sessions", default="")
    parser.add_argument("--session-target", default="")
    parser.add_argument("--access", choices=("read", "edit", "write"), required=True); parser.add_argument("--provider", choices=("codex", "zcode", "claude"), required=True)
    parser.add_argument("--auth-present", action="store_true")
    parser.add_argument("--auth-target", default="")
    return parser.parse_args(argv)


if __name__ == "__main__":
    try:
        if "--inside" in sys.argv:
            inner_main(inside_args(sys.argv[1:]))
        else:
            sys.exit(main())
    except Exception as error:
        print(f"agent sandbox: {error}", file=sys.stderr)
        sys.exit(1)
