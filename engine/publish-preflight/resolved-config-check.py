#!/usr/bin/env python3
"""Fail when a new engine version resolves different config or state bytes than the live version.

The engine resolves each relative path from the target repo's .zenoforge/<rel> first, then from the version's
engine/<rel>. For every path resolved by the new engine, the bytes seen by the live and new versions must match,
unless the path is listed with a one-line reason.

usage: resolved-config-check.py <live version dir> <live target repo> <live ref> \
                                <new version dir> <new target repo> <new ref> [intended-change list]
"""
import fnmatch, hashlib, os, re, subprocess, sys

CALL = re.compile(r'''(?:zf_config_file|sched_config_file|zfConfigFile|zfConfigJson|zf_config_json)\s*\(?\s*(["'`]?)([^"'`\s,)]+)\1''')


def target_files(repo, ref):
    out = subprocess.run(['git', '-C', repo, 'ls-tree', '-r', '--name-only', ref, '.zenoforge'],
                         capture_output=True, text=True, check=True).stdout.split()
    return {p[len('.zenoforge/'):] for p in out if not p.startswith('.zenoforge/build/')}


def target_bytes(repo, ref, rel):
    r = subprocess.run(['git', '-C', repo, 'show', f'{ref}:.zenoforge/{rel}'], capture_output=True)
    return r.stdout if r.returncode == 0 else None


def resolve(version, repo, ref, have, rel):
    """Return (source, sha) for rel, or (None, None) if nothing resolves."""
    if rel in have:
        return 'target', hashlib.sha256(target_bytes(repo, ref, rel)).hexdigest()
    f = os.path.join(version, 'engine', rel)
    if os.path.isfile(f):
        with open(f, 'rb') as h:
            return 'engine', hashlib.sha256(h.read()).hexdigest()
    return None, None


def _raise(err):
    raise err


def engine_rels(version, candidates):
    """Literal and dynamic paths the engine passes to its config resolvers."""
    rels, globs = set(), set()
    for root, _, files in os.walk(os.path.join(version, 'engine'), onerror=_raise):
        for name in files:
            if '.test.' in name or name.startswith('test-') or name.endswith('.env'):
                continue
            # An unreadable file raises: a partial scan must not pass as "unchanged".
            text = open(os.path.join(root, name), encoding='utf-8', errors='ignore').read()
            for _, arg in CALL.findall(text):
                if arg.startswith(('$', '/', '-')) or '/' not in arg and '.' not in arg:
                    continue
                if '$' in arg or '{' in arg:
                    globs.add(re.sub(r'\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*', '*', arg))
                else:
                    rels.add(arg)
    rels |= {c for c in candidates for g in globs if fnmatch.fnmatch(c, g)}
    return rels


def main(argv):
    if len(argv) not in (7, 8):
        print(__doc__, file=sys.stderr)
        return 2
    bver, brepo, bref, nver, nrepo, nref = argv[1:7]
    intended = {}
    if len(argv) == 8:
        for line in open(argv[7], encoding='utf-8'):
            line = line.rstrip('\n')
            if line and not line.startswith('#'):
                rel, _, reason = line.partition('\t')
                if not reason.strip():
                    print(f'resolved-config-check: intended entry without a reason: {rel}', file=sys.stderr)
                    return 2
                intended[rel] = reason
    bhave, nhave = target_files(brepo, bref), target_files(nrepo, nref)
    candidates = bhave | nhave
    for v in (bver, nver):
        for root, _, files in os.walk(os.path.join(v, 'engine'), onerror=_raise):
            candidates |= {os.path.relpath(os.path.join(root, f), os.path.join(v, 'engine')) for f in files if not f.endswith('.env')}
    bad, allowed = [], []
    for rel in sorted(r for r in engine_rels(nver, candidates) if not r.endswith('.env')):
        b = resolve(bver, brepo, bref, bhave, rel)
        n = resolve(nver, nrepo, nref, nhave, rel)
        if b[1] == n[1]:
            continue
        row = f'{rel}: live {b[0] or "missing"} {(b[1] or "-")[:12]} -> new {n[0] or "missing"} {(n[1] or "-")[:12]}'
        (allowed if rel in intended else bad).append(row + (f'  [intended: {intended[rel]}]' if rel in intended else ''))
    for row in allowed:
        print(f'resolved-config-check: changed as intended {row}')
    sys.stdout.flush()
    if bad:
        for row in bad:
            print(f'resolved-config-check: CHANGED {row}', file=sys.stderr)
        return 1
    print('resolved-config-check: OK')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv))
    except OSError as err:
        print(f'resolved-config-check: cannot read: {err}', file=sys.stderr)
        sys.exit(2)
