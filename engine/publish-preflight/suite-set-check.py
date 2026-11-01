#!/usr/bin/env python3
"""Ensure selectable target suites are the suites moved from the engine.

Selectable paths under configured roots must share lineage with a same-named baseline engine suite. A baseline suite
must remain in the engine, or reappear with lineage where the pipeline runs suites: under a configured root or in the
target's .zenoforge/systemd directory. This guards against unrelated same-name suites being
selected and baseline suites disappearing during a move.

usage: suite-set-check.py <live version dir> <new version dir> <target repo> <new ref>
"""
import difflib, json, os, re, subprocess, sys

# Match the test path forms understood by the engine's focused suite selector.
SELECTABLE = re.compile(r'(\.test\.(sh|mjs)$|(^|/)test-[^/]+\.sh$)')
# Require enough text similarity to recognize whole-file moves, path adaptations, and split suites.
LINEAGE = 0.4


def _raise(err):
    raise err


def suites(version):
    root = os.path.join(version, 'engine')
    out = {}
    for d, _, files in os.walk(root, onerror=_raise):
        for f in files:
            rel = os.path.relpath(os.path.join(d, f), root)
            if SELECTABLE.search(rel):
                out[rel] = os.path.join(root, rel)
    return out


def main(argv):
    if len(argv) != 5:
        print(__doc__, file=sys.stderr)
        return 2
    bver, nver, repo, ref = argv[1:]
    git = lambda *a: subprocess.run(['git', '-C', repo, *a], capture_output=True, text=True, check=True).stdout
    roots = [r.rstrip('/') for r in json.loads(git('show', f'{ref}:.zenoforge/ci.json')).get('pipeline_suite_roots', [])]
    tracked = [p for p in git('ls-tree', '-r', '--name-only', ref).split('\n') if p]
    base, new = suites(bver), suites(nver)
    by_name = {}
    for rel, path in base.items():
        by_name.setdefault(os.path.basename(rel), []).append(path)
    resolvable = sorted(p for p in tracked
                        if SELECTABLE.search(p) and not p.startswith(('packages/', 'apps/'))
                        and any(r == '.' or p.startswith(r + '/') for r in roots) and os.path.basename(p) in by_name)
    def lineage(p):
        text = git('show', f'{ref}:{p}')
        return max(difflib.SequenceMatcher(None, text, open(b, errors='ignore').read(), autojunk=False).quick_ratio()
                   for b in by_name[os.path.basename(p)])

    bad = moved = 0
    for p in resolvable:
        ratio = lineage(p)
        if ratio >= LINEAGE:
            moved += 1
        else:
            print(f'suite-set-check: NOT A MOVED SUITE (shares a baseline name only, lineage {ratio:.2f}): {p}', file=sys.stderr)
            bad = 1
    # A suite that left the engine must still run somewhere the pipeline looks: a configured root, or the target's
    # systemd dir, whose suites run-ci-suites.sh also runs. It must also descend from the baseline suite.
    runnable = [p for p in resolvable] + [p for p in tracked if os.path.dirname(p) == '.zenoforge/systemd'
                                          and SELECTABLE.search(p) and os.path.basename(p) in by_name]
    for rel in sorted(set(base) - set(new)):
        if not any(os.path.basename(p) == os.path.basename(rel) and lineage(p) >= LINEAGE for p in runnable):
            print(f'suite-set-check: LOST baseline suite: {rel}', file=sys.stderr)
            bad = 1
    if bad:
        return 1
    print(f'suite-set-check: OK resolvable == moved ({moved} suites; baseline {len(base)}, engine keeps {len(set(base) & set(new))})')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
