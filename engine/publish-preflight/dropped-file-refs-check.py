#!/usr/bin/env python3
"""Fail when the new engine drops a file that a script the new version dir keeps still references.

A dropped file is in the live engine tree but not the new one (tests excluded, using suite-set-check's test-name
rule). A script is *.sh, *.py, *.mjs, *.js, or any file starting with a shebang. A reference is a fixed-string match of
the dropped file's basename, in a script under the new engine tree or beside it in the new version dir — the skill
trees and release scripts the build ships there are declared consumers that load engine files through the engine's own
path helpers. Paths on the intended-change list (relative to engine/) are allowed.

usage: dropped-file-refs-check.py <live version dir> <new version dir> [intended-change list]
"""
import importlib.util, os, sys

spec = importlib.util.spec_from_file_location('suite_set', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'suite-set-check.py'))
suite_set = importlib.util.module_from_spec(spec); spec.loader.exec_module(suite_set)
spec = importlib.util.spec_from_file_location('intended_changes', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'intended_changes.py'))
intended_changes = importlib.util.module_from_spec(spec); spec.loader.exec_module(intended_changes)


def files(version):
    root = os.path.join(version, 'engine')
    return {os.path.relpath(os.path.join(d, f), root) for d, _, fs in os.walk(root, onerror=suite_set._raise) for f in fs}


def is_script(path):
    return path.endswith(('.sh', '.py', '.mjs', '.js')) or open(path, 'rb').read(2) == b'#!'


def consumer_scripts(version):
    # Scripts the build ships beside the engine (injected skill trees, release scripts) are declared consumers: they
    # resolve engine files through zfHostOpsFile and friends, whose last fallback is the engine dir.
    root = os.path.abspath(version)
    out = []
    for d, dirs, fs in os.walk(root, onerror=suite_set._raise):
        if os.path.abspath(d) == root:
            dirs[:] = [x for x in dirs if x != 'engine']
        for f in fs:
            p = os.path.join(d, f)
            if is_script(p):
                out.append((os.path.relpath(p, root), p))
    return out


def main(argv):
    if len(argv) not in (3, 4):
        print(__doc__, file=sys.stderr)
        return 2
    bver, nver = argv[1:3]
    intended = set()
    if len(argv) == 4:
        try:
            intended = set(intended_changes.load(argv[3], nver))
        except (OSError, ValueError) as err:
            print(str(err), file=sys.stderr)
            return 2
    base, new = files(bver), files(nver)
    isfile = lambda r: not suite_set.SELECTABLE.search(r) and '.test.' not in os.path.basename(r)
    dropped = sorted(r for r in base - new if isfile(r))
    lines = []
    for r in sorted(new):
        p = os.path.join(nver, 'engine', r)
        if is_script(p):
            lines += [(r, i, t) for i, t in enumerate(open(p, errors='ignore'), 1)]
    for rel, p in sorted(consumer_scripts(nver)):
        lines += [(rel, i, t) for i, t in enumerate(open(p, errors='ignore'), 1)]
    bad = 0
    for r in dropped:
        hit = next(((f, i) for f, i, t in lines if os.path.basename(r) in t), None)
        if hit and r not in intended:
            print(f'dropped-file-refs-check: DROPPED but still referenced: {r} (referenced at {hit[0]}:{hit[1]})', file=sys.stderr)
            bad = 1
    if bad:
        return 1
    print(f'dropped-file-refs-check: OK ({len(dropped)} dropped files, none referenced by the new engine unless intended)')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
