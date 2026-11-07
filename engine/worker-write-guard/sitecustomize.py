"""Preloaded (PYTHONPATH, set by worker_write_guard_env) into
every python process a dispatched worker starts: refuse write-mode file access
below ZF_WORKER_WRITE_GUARD_ROOT, whatever path the script spells. Allow roots
(ZF_WORKER_WRITE_GUARD_ALLOW, the supervisor scratch) stay writable. Same
contract as node-guard.cjs; see worker_write_guard_env for the 2026-11-07 incident."""
import builtins
import os
import shutil

_ROOTS = [
    os.path.realpath(os.path.abspath(entry))
    for entry in os.environ.get("ZF_WORKER_WRITE_GUARD_ROOT", "").split(os.pathsep)
    if entry
]
_ALLOWS = [
    os.path.realpath(os.path.abspath(entry))
    for entry in os.environ.get("ZF_WORKER_WRITE_GUARD_ALLOW", "").split(os.pathsep)
    if entry
]


def _under(path, base):
    return path == base or path.startswith(base + os.sep)


def _refuse(path):
    raise PermissionError(
        13,
        "worker write guard: refusing write into the deployment checkout "
        "(edit this unit's own worktree; deployment files change only through a landed PR)",
        path,
    )


def _guard(path):
    if not _ROOTS:
        return
    try:
        absolute = os.path.realpath(os.path.abspath(os.fspath(path)))
    except (TypeError, ValueError):
        return
    if any(_under(absolute, allow) for allow in _ALLOWS):
        return
    if any(_under(absolute, root) for root in _ROOTS):
        _refuse(path)


def _write_mode(mode):
    return any(flag in mode for flag in ("w", "a", "x", "+"))


def _wrap(holder, name, checker):
    original = getattr(holder, name, None)
    if original is None or getattr(original, "_zf_worker_write_guard", False):
        return

    def patched(*args, **kwargs):
        checker(args)
        return original(*args, **kwargs)

    patched._zf_worker_write_guard = True
    setattr(holder, name, patched)


def _paths(indices):
    def checker(args):
        for index in indices:
            if index < len(args):
                _guard(args[index])

    return checker


if _ROOTS:
    _wrap(builtins, "open", lambda args: _write_mode(args[1] if len(args) > 1 else "r") and _guard(args[0]))
    _wrap(os, "open", lambda args: (len(args) > 1 and (args[1] & 0x3) != 0) and _guard(args[0]))
    _wrap(os, "chmod", _paths([0]))
    _wrap(os, "chown", _paths([0]))
    _wrap(os, "link", _paths([1]))
    _wrap(os, "makedirs", _paths([0]))
    _wrap(os, "mkdir", _paths([0]))
    _wrap(os, "remove", _paths([0]))
    _wrap(os, "removedirs", _paths([0]))
    _wrap(os, "rename", _paths([0, 1]))
    _wrap(os, "replace", _paths([0, 1]))
    _wrap(os, "rmdir", _paths([0]))
    _wrap(os, "symlink", _paths([1]))
    _wrap(os, "truncate", _paths([0]))
    _wrap(os, "unlink", _paths([0]))
    _wrap(os, "utime", _paths([0]))
    _wrap(shutil, "copy", _paths([1]))
    _wrap(shutil, "copy2", _paths([1]))
    _wrap(shutil, "copyfile", _paths([1]))
    _wrap(shutil, "move", _paths([1]))
    _wrap(shutil, "rmtree", _paths([0]))
