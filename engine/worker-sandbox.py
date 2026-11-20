#!/usr/bin/env python3
"""Run one worker with a private PID namespace and Landlock filesystem access."""
import argparse
import ctypes
import errno
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import sys
import tempfile


SYS_LANDLOCK_CREATE_RULESET = 444
SYS_LANDLOCK_ADD_RULE = 445
SYS_LANDLOCK_RESTRICT_SELF = 446
LANDLOCK_CREATE_RULESET_VERSION = 1
LANDLOCK_RULE_PATH_BENEATH = 1
ACCESS_WRITE_FILE = 1 << 1
ACCESS_READ_FILE = 1 << 2
ACCESS_READ_DIR = 1 << 3
ACCESS_REMOVE_DIR = 1 << 4
ACCESS_REMOVE_FILE = 1 << 5
ACCESS_MAKE_DIR = 1 << 7
ACCESS_MAKE_REG = 1 << 8
ACCESS_MAKE_SOCK = 1 << 9
ACCESS_MAKE_FIFO = 1 << 10
ACCESS_MAKE_SYM = 1 << 12
ACCESS_REFER = 1 << 13
ACCESS_TRUNCATE = 1 << 14
READ_ONLY = ACCESS_READ_FILE | ACCESS_READ_DIR


class RulesetAttr(ctypes.Structure):
    _fields_ = [("handled_access_fs", ctypes.c_uint64)]


class PathBeneathAttr(ctypes.Structure):
    _fields_ = [("allowed_access", ctypes.c_uint64), ("parent_fd", ctypes.c_int32)]


class CapHeader(ctypes.Structure):
    _fields_ = [("version", ctypes.c_uint32), ("pid", ctypes.c_int)]


class CapData(ctypes.Structure):
    _fields_ = [("effective", ctypes.c_uint32), ("permitted", ctypes.c_uint32),
                ("inheritable", ctypes.c_uint32)]


def access_mask(abi):
    mask = (ACCESS_WRITE_FILE | ACCESS_READ_FILE | ACCESS_READ_DIR | ACCESS_REMOVE_DIR
            | ACCESS_REMOVE_FILE | ACCESS_MAKE_DIR | ACCESS_MAKE_REG | ACCESS_MAKE_SOCK
            | ACCESS_MAKE_FIFO | ACCESS_MAKE_SYM)
    if abi >= 2:
        mask |= ACCESS_REFER
    if abi >= 3:
        mask |= ACCESS_TRUNCATE
    return mask


def syscall(libc, number, *args):
    result = libc.syscall(number, *args)
    if result < 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code))
    return result


def landlock_version(libc):
    if platform.machine() not in {"x86_64", "aarch64", "riscv64", "s390x", "ppc64le"}:
        raise OSError(errno.ENOSYS, "unsupported Linux architecture")
    return syscall(libc, SYS_LANDLOCK_CREATE_RULESET, None, 0, LANDLOCK_CREATE_RULESET_VERSION)


def drop_capabilities(libc):
    header = CapHeader(0x20080522, 0)
    data = (CapData * 2)(CapData(0, 0, 0), CapData(0, 0, 0))
    if libc.capset(ctypes.byref(header), ctypes.byref(data)) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code))
    if libc.prctl(38, 1, 0, 0, 0) != 0:  # PR_SET_NO_NEW_PRIVS
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code))


def add_rule(libc, ruleset_fd, path, rights):
    fd = os.open(path, os.O_PATH | os.O_CLOEXEC)
    try:
        rule = PathBeneathAttr(rights, fd)
        syscall(libc, SYS_LANDLOCK_ADD_RULE, ruleset_fd, LANDLOCK_RULE_PATH_BENEATH,
                ctypes.byref(rule), 0)
    finally:
        os.close(fd)


def add_path_rule(libc, ruleset_fd, path, rights):
    add_rule(libc, ruleset_fd, Path(path).resolve(strict=True), rights)


def resolved_path(path):
    return Path(path).resolve(strict=True)


def apply_landlock(args, env):
    libc = ctypes.CDLL(None, use_errno=True)
    abi = landlock_version(libc)
    handled = access_mask(abi)
    ruleset_fd = syscall(libc, SYS_LANDLOCK_CREATE_RULESET,
                         ctypes.byref(RulesetAttr(handled)), ctypes.sizeof(RulesetAttr), 0)
    try:
        for path in ("/usr", "/bin", "/sbin", "/lib", "/lib32", "/lib64", "/proc",
                     "/etc/ssl/certs", "/etc/ca-certificates", "/etc/pki/ca-trust/extracted/pem",
                     "/etc/pki/tls/certs"):
            if os.path.exists(path):
                add_path_rule(libc, ruleset_fd, path, READ_ONLY)
        for path in ("/etc/ld.so.cache", "/etc/localtime", "/etc/ssl/openssl.cnf",
                     "/etc/ssl/cert.pem", "/etc/ca-certificates.conf", "/etc/passwd", "/etc/group",
                     "/etc/nsswitch.conf", "/etc/hosts", "/etc/resolv.conf", "/etc/gai.conf"):
            if os.path.isfile(path):
                add_path_rule(libc, ruleset_fd, path, ACCESS_READ_FILE)

        for path in ("/dev/null", "/dev/zero", "/dev/random", "/dev/urandom", "/dev/tty"):
            if os.path.exists(path):
                add_path_rule(libc, ruleset_fd, path, ACCESS_READ_FILE | ACCESS_WRITE_FILE)

        write_access = (ACCESS_WRITE_FILE | ACCESS_READ_FILE | ACCESS_READ_DIR | ACCESS_REMOVE_DIR
                        | ACCESS_REMOVE_FILE | ACCESS_MAKE_DIR | ACCESS_MAKE_REG
                        | ACCESS_MAKE_SOCK | ACCESS_MAKE_FIFO | ACCESS_MAKE_SYM)
        if abi >= 2:
            write_access |= ACCESS_REFER
        if abi >= 3:
            write_access |= ACCESS_TRUNCATE

        add_path_rule(libc, ruleset_fd, args.cwd, write_access)
        add_path_rule(libc, ruleset_fd, env["TMPDIR"], write_access)
        sentinel = env.get("CONTEXT_MODE_MCP_SENTINEL_DIR")
        if sentinel and Path(sentinel).is_dir():
            add_path_rule(libc, ruleset_fd, Path(sentinel).resolve(), write_access)
        for path in args.read_path:
            add_path_rule(libc, ruleset_fd, resolved_path(path), READ_ONLY)
        for path in args.write_path:
            add_path_rule(libc, ruleset_fd, resolved_path(path), write_access)

        for path in env.get("ZF_WORKER_WRITE_GUARD_ALLOW", "").split(os.pathsep):
            if path and Path(path).is_dir():
                add_path_rule(libc, ruleset_fd, path, write_access)
        for path in env.get("PYTHONPATH", "").split(os.pathsep):
            guard_dir = Path(path) if path else None
            if guard_dir and (guard_dir / "sitecustomize.py").is_file() and (guard_dir / "node-guard.cjs").is_file():
                add_path_rule(libc, ruleset_fd, guard_dir, READ_ONLY)

        home = Path(env["HOME"]).resolve()
        if args.provider == "codex":
            codex_home = Path(env["CODEX_HOME"]).resolve()
            if codex_home.is_dir():
                add_path_rule(libc, ruleset_fd, codex_home, write_access)
        elif args.provider == "zcode":
            zcode_home = home / ".zcode"
            if zcode_home.is_dir():
                add_path_rule(libc, ruleset_fd, zcode_home, write_access)
            scratch = Path(env.get("WORKER_SCRATCH_ROOT", home / ".zenoforge/scratch")) / "zc-src"
            if scratch.is_dir():
                add_path_rule(libc, ruleset_fd, scratch.resolve(), READ_ONLY)

        for entry in env.get("PATH", "").split(os.pathsep):
            if entry and Path(entry).is_dir():
                add_path_rule(libc, ruleset_fd, Path(entry).resolve(), ACCESS_READ_FILE)

        if libc.prctl(38, 1, 0, 0, 0) != 0:  # PR_SET_NO_NEW_PRIVS
            code = ctypes.get_errno()
            raise OSError(code, os.strerror(code))
        syscall(libc, SYS_LANDLOCK_RESTRICT_SELF, ruleset_fd, 0)
    finally:
        os.close(ruleset_fd)


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cwd", required=True)
    parser.add_argument("--provider", choices=("none", "codex", "zcode"), required=True)
    parser.add_argument("--read-path", action="append", default=[])
    parser.add_argument("--write-path", action="append", default=[])
    parser.add_argument("--inside", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if args.command and args.command[0] == "--":
        args.command = args.command[1:]
    if not args.command:
        parser.error("a command is required after --")
    try:
        args.cwd = str(Path(args.cwd).resolve(strict=True))
    except OSError as error:
        parser.error(f"invalid worker directory: {error}")
    if not Path(args.cwd).is_dir():
        parser.error("worker directory must be a directory")
    return args


def run_inside(args):
    env = os.environ.copy()
    try:
        os.chdir(args.cwd)
        drop_capabilities(ctypes.CDLL(None, use_errno=True))
        apply_landlock(args, env)
        os.execvpe(args.command[0], args.command, env)
    except OSError as error:
        print(f"worker-sandbox: failed to establish filesystem scope: {error}", file=sys.stderr)
        return 125
    return 125


def prepare_git_config(env, private_tmp):
    config = Path(private_tmp) / "gitconfig"
    config.touch(mode=0o600)
    if shutil.which("git"):
        for key in ("user.name", "user.email"):
            result = subprocess.run(["git", "config", "--global", "--null", "--get", key],
                                    env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            if result.returncode == 0:
                value = result.stdout.rstrip(b"\0").decode("utf-8", "surrogateescape")
                subprocess.run(["git", "config", "--file", str(config), key, value],
                               env=env, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    env["GIT_CONFIG_GLOBAL"] = str(config)
    env["GIT_CONFIG_NOSYSTEM"] = "1"


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    env = os.environ.copy()
    env["HOME"] = str(Path(env.get("HOME") or Path.home()).resolve())
    if args.provider == "codex":
        env["CODEX_HOME"] = str(Path(env.get("CODEX_HOME") or (Path(env["HOME"]) / ".codex")).resolve())

    if args.inside:
        return run_inside(args)

    unshare = shutil.which("unshare")
    if not unshare:
        print("worker-sandbox: unshare is required; worker not started", file=sys.stderr)
        return 125

    try:
        with tempfile.TemporaryDirectory(prefix="zf-worker-scope-", dir="/tmp") as private_tmp:
            prepare_git_config(env, private_tmp)
            env["TMPDIR"] = private_tmp
            env["TMP"] = private_tmp
            env["TEMP"] = private_tmp
            env["XDG_CACHE_HOME"] = os.path.join(private_tmp, "cache")
            env["npm_config_cache"] = os.path.join(private_tmp, "npm")
            env["COREPACK_HOME"] = os.path.join(private_tmp, "corepack")
            env["PIP_CACHE_DIR"] = os.path.join(private_tmp, "pip")
            command = [unshare, "--user", "--map-current-user", "--pid", "--fork", "--mount-proc",
                       "--kill-child=TERM", sys.executable, os.path.abspath(__file__), "--inside", "--cwd", args.cwd,
                       "--provider", args.provider]
            for path in args.read_path:
                command.extend(("--read-path", path))
            for path in args.write_path:
                command.extend(("--write-path", path))
            command.extend(("--", *args.command))
            child = subprocess.Popen(command, cwd=args.cwd, env=env)
            previous = {}

            def forward(signum, _frame):
                if child.poll() is None:
                    child.send_signal(signum)

            for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
                previous[signum] = signal.signal(signum, forward)
            try:
                status = child.wait()
            finally:
                for signum, handler in previous.items():
                    signal.signal(signum, handler)
            return status if status >= 0 else 128 - status
    except (OSError, subprocess.SubprocessError) as error:
        print(f"worker-sandbox: worker scope unavailable; worker not started: {error}", file=sys.stderr)
        return 125


if __name__ == "__main__":
    raise SystemExit(main())
