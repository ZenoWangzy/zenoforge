import os
import pathlib
import re
import shutil
import stat
import subprocess


def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], check=True, stdout=subprocess.PIPE).stdout


def names(data):
    return {value.decode("utf-8", "surrogateescape") for value in data.split(b"\0") if value}


def private_path(name):
    parts = pathlib.PurePosixPath(name).parts
    lowered = tuple(part.lower() for part in parts)
    if any(part in {".aws", ".ssh", ".codex", ".claude", ".zcode", ".gnupg", ".kube", ".docker", ".azure"} for part in lowered):
        return True
    if any(lowered[index:index + 2] in ((".config", "gh"), (".config", "gcloud"), (".config", "production")) for index in range(len(lowered) - 1)):
        return True
    base = parts[-1].lower() if parts else ""
    stem = base.split(".", 1)[0]
    return (base.startswith(".env") or base in {".npmrc", ".pypirc", ".netrc", ".git-credentials"}
            or stem in {"auth", "credential", "credentials", "secret", "secrets", "token", "tokens", "id_rsa", "id_ed25519"}
            or re.search(r"\.(?:pem|key|p12|pfx)$", base) is not None)


def source_path(root, name):
    parts = pathlib.PurePosixPath(name).parts
    if not parts or pathlib.PurePosixPath(name).is_absolute() or any(part in {".", "..", ".git"} for part in parts):
        return None
    path = pathlib.Path(root)
    for index, part in enumerate(parts):
        path /= part
        try:
            mode = path.lstat().st_mode
        except OSError:
            return None
        if index < len(parts) - 1 and stat.S_ISLNK(mode):
            return None
    return path


def stage_path(root, name):
    path = pathlib.Path(root)
    for part in pathlib.PurePosixPath(name).parts:
        if part in {".", "..", ".git"}:
            return None
        path /= part
    return path


def destination_path(root, name):
    path = pathlib.Path(root)
    parts = pathlib.PurePosixPath(name).parts
    if not parts or pathlib.PurePosixPath(name).is_absolute() or any(part in {".", "..", ".git"} for part in parts):
        return None
    for part in parts[:-1]:
        path /= part
        try:
            mode = path.lstat().st_mode
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(mode) or not stat.S_ISDIR(mode):
            return None
    return path / parts[-1]


def remove(path):
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError:
        return
    if stat.S_ISDIR(mode):
        try:
            path.rmdir()
        except OSError as error:
            raise RuntimeError(f"cannot replace workspace path containing local files: {path.name}") from error
    else:
        path.unlink()


def copy_file(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists() and target.is_dir() and not target.is_symlink():
        remove(target)
    if source.is_symlink():
        temporary = target.with_name(target.name + ".zf-link")
        temporary.unlink(missing_ok=True)
        temporary.symlink_to(os.readlink(source))
        os.replace(temporary, target)
    elif source.is_file():
        shutil.copy2(source, target)


def link_dependency(source, target):
    try:
        os.link(source, target, follow_symlinks=False)
    except OSError:
        shutil.copy2(source, target)


def staged_files(repo):
    entries = git(repo, "ls-files", "--stage", "-z").split(b"\0")
    modes = {}
    for entry in entries:
        if not entry:
            continue
        metadata, raw_path = entry.split(b"\t", 1)
        name = raw_path.decode("utf-8", "surrogateescape")
        if not private_path(name):
            modes[name] = metadata.split()[0].decode()
    return modes


def copy_gitlink(source, target):
    if target.exists() and (not target.is_dir() or target.is_symlink()):
        remove(target)
    target.mkdir(parents=True, exist_ok=True)
    nested_modes = staged_files(source)
    nested_untracked = {name for name in names(git(source, "ls-files", "--others", "--exclude-standard", "-z"))
                        if not private_path(name) and "node_modules" not in pathlib.PurePosixPath(name).parts}
    for name in set(nested_modes) | nested_untracked:
        if "node_modules" in pathlib.PurePosixPath(name).parts and name not in nested_modes:
            continue
        origin = source_path(source, name)
        destination = stage_path(target, name)
        if origin is None or destination is None or not origin.exists() and not origin.is_symlink():
            continue
        if nested_modes.get(name) == "160000" and origin.is_dir() and not origin.is_symlink():
            copy_gitlink(origin, destination)
        elif not origin.is_dir() or origin.is_symlink():
            copy_file(origin, destination)


def copy_repo_files(repo, workspace):
    modes = staged_files(repo)
    untracked = {name for name in names(git(repo, "ls-files", "--others", "--exclude-standard", "-z"))
                 if not private_path(name) and "node_modules" not in pathlib.PurePosixPath(name).parts}
    for name in set(modes) | untracked:
        if "node_modules" in pathlib.PurePosixPath(name).parts and name not in modes:
            continue
        origin = source_path(repo, name)
        destination = stage_path(workspace, name)
        if destination is None:
            continue
        if origin is None:
            continue
        if modes.get(name) == "160000" and origin.is_dir() and not origin.is_symlink():
            copy_gitlink(origin, destination)
        elif not origin.is_dir() or origin.is_symlink():
            copy_file(origin, destination)
    return untracked


def snapshot(repo, workspace, git_entry_dir, dependency_root):
    pathlib.Path(workspace).mkdir(parents=True, exist_ok=True)
    untracked = copy_repo_files(repo, workspace)
    (pathlib.Path(workspace) / ".git").mkdir() if git_entry_dir else (pathlib.Path(workspace) / ".git").touch()
    dependencies = pathlib.Path(repo, "node_modules")
    destination = pathlib.Path(dependency_root, "node_modules")
    if dependencies.is_dir() and not dependencies.is_symlink():
        destination.parent.mkdir(parents=True, exist_ok=True)
        def ignored(directory, entries):
            relative = pathlib.Path(directory).relative_to(dependencies)
            return [name for name in entries if private_path((relative / name).as_posix())]
        shutil.copytree(dependencies, destination, symlinks=True, ignore=ignored, copy_function=link_dependency)
    if destination.is_dir():
        pathlib.Path(workspace, "node_modules").mkdir(exist_ok=True)
    return untracked, str(destination) if destination.is_dir() else ""


def changed_paths(worker_git, workspace, original_head):
    diff = subprocess.run(["git", f"--git-dir={worker_git}", f"--work-tree={workspace}", "diff", "--no-renames", "--name-only", "-z", original_head], check=True, stdout=subprocess.PIPE).stdout
    untracked = subprocess.run(["git", f"--git-dir={worker_git}", f"--work-tree={workspace}", "ls-files", "--others", "--exclude-standard", "-z"], check=True, stdout=subprocess.PIPE).stdout
    modes = subprocess.run(["git", f"--git-dir={worker_git}", f"--work-tree={workspace}", "ls-files", "--stage", "-z"], check=True, stdout=subprocess.PIPE).stdout
    return names(diff) | names(untracked), names(untracked), modes


def sync(repo, worker_git, workspace, original_head, initial_untracked):
    changed, untracked, raw_modes = changed_paths(worker_git, workspace, original_head)
    modes = {}
    for entry in raw_modes.split(b"\0"):
        if entry:
            metadata, raw_path = entry.split(b"\t", 1)
            modes[raw_path.decode("utf-8", "surrogateescape")] = metadata.split()[0].decode()
    changed.update(initial_untracked)
    changed = {name for name in changed if not private_path(name)}
    untracked = {name for name in untracked if not private_path(name)}
    missing = []
    present = []
    for name in changed | untracked:
        origin = source_path(workspace, name)
        if origin is None or not origin.exists() and not origin.is_symlink():
            missing.append(name)
        elif modes.get(name) == "160000" and origin.is_dir() and not origin.is_symlink():
            present.append((name, origin, True))
        elif not origin.is_dir() or origin.is_symlink():
            present.append((name, origin, False))
    for name in sorted(missing, key=lambda value: value.count("/"), reverse=True):
        destination = destination_path(repo, name)
        if destination is not None:
            remove(destination)
    for name, origin, gitlink in sorted(present, key=lambda entry: entry[0].count("/")):
        destination = destination_path(repo, name)
        if destination is None:
            continue
        if gitlink:
            copy_gitlink(origin, destination)
        else:
            copy_file(origin, destination)
