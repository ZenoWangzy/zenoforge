#!/usr/bin/env python3
"""Fail when engine changes reroute config or state away from product-owned bytes.

The engine resolves each relative path from the target repo's .zenoforge/<rel> first, then from the version's
engine/<rel>. For every path resolved by the new engine, the bytes seen by the live and new versions must match,
unless the path is listed with a one-line reason.

usage: resolved-config-check.py <live version dir> <live target repo> <live ref> \
                                <new version dir> <new target repo> <new ref> [intended-change list]
"""
import fnmatch, hashlib, importlib.util, os, re, subprocess, sys

spec = importlib.util.spec_from_file_location('intended_changes', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'intended_changes.py'))
intended_changes = importlib.util.module_from_spec(spec); spec.loader.exec_module(intended_changes)

CALL = re.compile(r'''(?:zf_config_file|sched_config_file|zfConfigFile|zfConfigJson|zf_config_json)\s*\(?\s*(["'`]?)([^"'`\s,)]+)\1''')


def target_files(repo, ref):
    out = subprocess.run(['git', '-C', repo, 'ls-tree', '-r', '--name-only', ref, '.zenoforge'],
                         capture_output=True, text=True, check=True).stdout.split()
    return {p[len('.zenoforge/'):] for p in out if not p.startswith('.zenoforge/build/')}


def target_bytes(repo, ref, rel):
    r = subprocess.run(['git', '-C', repo, 'show', f'{ref}:.zenoforge/{rel}'], capture_output=True)
    return r.stdout if r.returncode == 0 else None


def git_bytes(repo, ref, path):
    r = subprocess.run(['git', '-C', repo, 'show', f'{ref}:{path}'], capture_output=True)
    return r.stdout if r.returncode == 0 else None


def version_product_ref(version):
    """Read the product commit that supplied a built engine's product or pack data."""
    info = os.path.join(version, 'BUILD-INFO')
    try:
        with open(info, encoding='utf-8') as handle:
            lines = handle.readlines()
    except OSError:
        return None
    for line in lines:
        if line.startswith('product_sha='):
            return line.partition('=')[2].strip() or None
    for line in lines:
        if line.startswith('pack_sha='):
            value = line.partition('=')[2].split(':', 1)[0]
            return value or None
    return None


def commit_exists(repo, ref):
    if not ref:
        return False
    r = subprocess.run(['git', '-C', repo, 'cat-file', '-e', f'{ref}^{{commit}}'],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return r.returncode == 0


def product_pack_sources(version):
    """Map built engine paths back to the product's committed vendored pack files."""
    mapping = {}
    path = os.path.join(version, 'PACK-FILES')
    try:
        with open(path, encoding='utf-8') as handle:
            for line in handle:
                fields = line.rstrip('\n').split('\t')
                if len(fields) >= 2 and fields[0] and fields[1]:
                    mapping.setdefault(fields[1], set()).add('.zenoforge/build/pack/' + fields[0])
    except FileNotFoundError:
        pass
    return mapping


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
    bhave, nhave = target_files(brepo, bref), target_files(nrepo, nref)
    intended = {}
    if len(argv) == 8:
        try:
            # Content rows match the sha256 of the resolved new file (target first, else version engine/), the same n[1] compared below.
            intended = intended_changes.load(argv[7], nver, lambda rel: resolve(nver, nrepo, nref, nhave, rel)[1])
        except (OSError, ValueError) as err:
            print(str(err), file=sys.stderr)
            return 2
    candidates = bhave | nhave
    for v in (bver, nver):
        for root, _, files in os.walk(os.path.join(v, 'engine'), onerror=_raise):
            candidates |= {os.path.relpath(os.path.join(root, f), os.path.join(v, 'engine')) for f in files if not f.endswith('.env')}
    bad, allowed, product_owned = [], [], []
    pack_sources = product_pack_sources(nver)
    old_product_ref = version_product_ref(bver)
    if not commit_exists(brepo, old_product_ref):
        old_product_ref = None
    for rel in sorted(r for r in engine_rels(nver, candidates) if not r.endswith('.env')):
        b = resolve(bver, brepo, bref, bhave, rel)
        n = resolve(nver, nrepo, nref, nhave, rel)
        if n[1] is not None:
            sources = set(pack_sources.get(rel, set()))
            # PACK-FILES maps transformed paths; this direct path covers verbatim pack data
            # whose engine-relative name is unchanged (including state/rulings.json).
            sources.add('.zenoforge/build/pack/scripts/agent/' + rel)
            sources.add('.zenoforge/' + rel)
            changed_product_source = False
            for source in sorted(sources):
                product_new = git_bytes(nrepo, nref, source)
                # The build rewrites a mapped pack file (rulings ids and paths), so its bytes never match the source.
                # The source and the rewrite are both product-owned, so a changed source explains the change.
                mapped = source in pack_sources.get(rel, ())
                if product_new is None or (not mapped and hashlib.sha256(product_new).hexdigest() != n[1]):
                    continue
                product_old = git_bytes(brepo, old_product_ref, source) if old_product_ref else None
                if old_product_ref and product_old != product_new:
                    changed_product_source = True
                    break
            if changed_product_source:
                product_owned.append(f'{rel} (product {old_product_ref[:8]}..{nref[:8]})')
                continue
        if b[1] == n[1]:
            continue
        row = f'{rel}: live {b[0] or "missing"} {(b[1] or "-")[:12]} -> new {n[0] or "missing"} {(n[1] or "-")[:12]}'
        (allowed if rel in intended else bad).append(row + (f'  [intended: {intended[rel]}]' if rel in intended else ''))
    for row in product_owned:
        print(f'resolved-config-check: product-owned change {row}')
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
