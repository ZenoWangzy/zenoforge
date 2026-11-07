#!/usr/bin/env python3
"""Background check of agent memory notes (https://www.anthropic.com/research/components-of-agent-memory).

Runs concurrently with the factory at lowest priority, never waits for idle, never blocks a station.
One run: flock, tar backup, pick the least recently checked notes, copy them to a scratch dir, run one
worker on the copy, then apply. apply() is the only writer of real memory: it replaces a note only if its
mtime is unchanged since the copy, so a peer session's newer write always wins.

Env (defaults in parentheses, overridden by the test):
  MC_STATE (~/.zenoforge/state/memory-check)  MC_MEMORY_GLOB (~/.claude/projects/*/memory)
  MC_WORKER ($ZF_ENGINE_LIVE/bin/worker, else ~/.vecta-agent/engine-live)  MC_NEW_DIR (zenoforge project memory dir)
  MC_REPOS (~/project/zenoforge-pub ~/project/vecta)  MC_BATCH (10)  MC_TIMEOUT (2400)  MC_KEEP (14)
"""
import datetime, fcntl, glob, json, os, re, shlex, shutil, subprocess, sys, tarfile, tempfile, time

HOME = os.path.expanduser('~')
HERE = os.path.dirname(os.path.realpath(__file__))
STATE = os.environ.get('MC_STATE', f'{HOME}/.zenoforge/state/memory-check')
MEM_GLOB = os.environ.get('MC_MEMORY_GLOB', f'{HOME}/.claude/projects/*/memory')
WORKER = os.environ.get('MC_WORKER', os.environ.get('ZF_ENGINE_LIVE', f'{HOME}/.vecta-agent/engine-live') + '/bin/worker')
NEW_DIR = os.environ.get('MC_NEW_DIR', f'{HOME}/.claude/projects/-home-gerald-project-zenoforge/memory')
REPOS = shlex.split(os.environ.get('MC_REPOS', f'{HOME}/project/zenoforge-pub {HOME}/project/vecta'))
BATCH = int(os.environ.get('MC_BATCH', '10'))
TIMEOUT = int(os.environ.get('MC_TIMEOUT', '2400'))
KEEP = int(os.environ.get('MC_KEEP', '14'))
MAX_DELETE = 3  # a worker that deletes more than this in one run is more likely broken than right
MAX_NEW = 2
CITE = re.compile(r'~?/[\w.-]+/[\w./-]+|--[a-z][\w-]+|\b\w+\(\)|`[\w./-]+\.\w+`|\b\d{2,}\b')


def read(p):
    with open(p, encoding='utf-8') as f:
        return f.read()


def atomic_write(path, text, mode=None):
    tmp = os.path.join(os.path.dirname(path), f'.{os.path.basename(path)}.mc-{os.getpid()}')
    with open(tmp, 'w', encoding='utf-8') as f:
        f.write(text)
    if mode is not None:
        os.chmod(tmp, mode)
    return tmp


def note_paths():
    return sorted(p for d in glob.glob(MEM_GLOB) for p in glob.glob(f'{d}/*.md') if os.path.basename(p) != 'MEMORY.md')


def select(paths, checked, n=BATCH):
    """Oldest-checked pool of 2n (unchecked = 0), then notes citing a path/flag/function/number first."""
    pool = sorted(paths, key=lambda p: (checked.get(p, 0), p))[:2 * n]
    pool = sorted(pool, key=lambda p: not CITE.search(read(p)))  # stable: keeps the age order inside each group
    return pool[:n]


def backup(paths_dirs):
    out = f'{STATE}/backups'
    os.makedirs(out, exist_ok=True)
    dest = f'{out}/memory-{time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())}.tar.gz'
    with tarfile.open(dest, 'w:gz') as t:
        for d in paths_dirs:
            t.add(d, arcname=f'{os.path.basename(os.path.dirname(d))}/memory')
    for old in sorted(glob.glob(f'{out}/memory-*.tar.gz'))[:-KEEP]:
        os.remove(old)
    return dest


def frontmatter_name(text):
    m = re.match(r'---\n(.*?)\n---', text, re.S)
    n = re.search(r'^name:\s*(.+)$', m.group(1), re.M) if m else None
    return n.group(1).strip() if n else None


def invalid_change(old, new):
    """Reason a worker rewrite breaks a hard rule, else None."""
    if not new.strip():
        return 'empty result'
    if frontmatter_name(old) != frontmatter_name(new):
        return 'frontmatter name changed'
    for line in (l for l in old.splitlines() if '**Why:**' in l):
        if line not in new.splitlines():
            return 'Why line changed'
    for q in re.findall(r'「[^」]*」', old):
        if q not in new:
            return f'founder quote changed {q[:30]}'
    return None


def edit_index(d, fn):
    """Rewrite d/MEMORY.md through fn(text), only if a peer did not touch it meanwhile; retry 3 times."""
    p = f'{d}/MEMORY.md'
    for _ in range(3):
        if not os.path.exists(p):
            return False
        m0 = os.stat(p).st_mtime_ns
        text = read(p)
        new = fn(text)
        if new == text:
            return True
        tmp = atomic_write(p, new)
        if os.stat(p).st_mtime_ns == m0:
            os.replace(tmp, p)
            return True
        os.remove(tmp)
    return False


def drop_index_line(d, fname):
    key = f']({fname})'
    return edit_index(d, lambda t: ''.join(l for l in t.splitlines(True) if key not in l))


def apply(manifest, work, report, log, now=None):
    """Single writer. manifest: id -> {src, mtime_ns}. Returns ids that were checked (not skipped)."""
    done, deleted = [], 0
    for nid, m in manifest.items():
        src, copy = m['src'], f'{work}/notes/{nid}'
        ev = report.get(nid, {}).get('evidence', 'no evidence reported')
        try:
            if os.stat(src).st_mtime_ns != m['mtime_ns']:
                log('skipped', nid, f'mtime changed since copy (peer wrote it); {ev}')
                continue
        except FileNotFoundError:
            log('skipped', nid, 'original gone since copy')
            continue
        if not os.path.exists(copy):
            if deleted >= MAX_DELETE:
                log('skipped', nid, f'delete cap {MAX_DELETE} per run reached; {ev}')
                continue
            os.remove(src)
            idx = drop_index_line(os.path.dirname(src), os.path.basename(src))
            deleted += 1
            log('deleted', nid, ev + ('' if idx else '; MEMORY.md line not removed (index missing or busy)'))
            done.append(nid)
            continue
        old, new = read(src), read(copy)
        if old == new:
            log('checked', nid, ev)
            done.append(nid)
            continue
        why = invalid_change(old, new)
        if why:
            log('skipped', nid, f'rewrite rejected: {why}; {ev}')
            continue
        tmp = atomic_write(src, new, os.stat(src).st_mode & 0o777)
        if os.stat(src).st_mtime_ns != m['mtime_ns']:  # peer wrote between the first check and now
            os.remove(tmp)
            log('skipped', nid, f'mtime changed during apply; {ev}')
            continue
        os.replace(tmp, src)
        log('changed', nid, ev)
        done.append(nid)
    return done


def apply_new(work, report, log):
    files = sorted(glob.glob(f'{work}/new/*.md'))
    for f in files[:MAX_NEW]:
        text, fn = read(f), os.path.basename(f)
        name = frontmatter_name(text)
        desc = re.search(r'^description:\s*(.+)$', text, re.M)
        dest = f'{NEW_DIR}/{fn}'
        ev = report.get(f'new/{fn}', {}).get('evidence', 'no evidence reported')
        if not (name and desc and re.fullmatch(r'[\w.-]+\.md', fn)) or os.path.exists(dest):
            log('skipped', f'new/{fn}', f'new note rejected (frontmatter or name clash); {ev}')
            continue
        tmp = atomic_write(dest, text, 0o644)
        try:
            os.link(tmp, dest)  # no-clobber: fails if a peer created it meanwhile
        except FileExistsError:
            log('skipped', f'new/{fn}', 'file appeared meanwhile')
            continue
        finally:
            os.remove(tmp)
        line = f'- [{name}]({fn}) — {desc.group(1).strip()}\n'
        edit_index(NEW_DIR, lambda t: t if f']({fn})' in t else t + ('' if t.endswith('\n') or not t else '\n') + line)
        log('changed', f'new/{fn}', f'new note; {ev}')
    for f in files[MAX_NEW:]:
        log('skipped', f'new/{os.path.basename(f)}', f'more than {MAX_NEW} new notes')


def load_report(work):
    out = {}
    try:
        for l in read(f'{work}/report.jsonl').splitlines():
            try:
                r = json.loads(l)
                out[r['note']] = r
            except (ValueError, KeyError, TypeError):
                pass
    except FileNotFoundError:
        pass
    return out


def run_worker(work, key):
    prompt = read(f'{HERE}/memory-check.prompt.md') + f"""
## This run

- Notes to check, one subdirectory per project: `{work}/notes/` (edit or delete these files only).
- New notes (at most {MAX_NEW}) go in `{work}/new/` as `<slug>.md`.
- Report file: `{work}/report.jsonl`, one JSON object per line.
- Repos for `git show origin/main:<path>` and `git grep ... origin/main`: {' '.join(REPOS)}
- Transcripts: `{HOME}/.claude/projects/*/*.jsonl`
"""
    pf = f'{work}/prompt.md'
    with open(pf, 'w', encoding='utf-8') as f:
        f.write(prompt)
    env = dict(os.environ, WORKER_BACKEND='zc', LUNA_PRIORITY='low')
    try:
        r = subprocess.run([WORKER, key, work, pf], env=env, timeout=TIMEOUT, capture_output=True, text=True)
        return r.returncode, (r.stderr or r.stdout)[-300:].strip()
    except subprocess.TimeoutExpired:
        return 124, f'worker timeout after {TIMEOUT}s'


def main():
    os.nice(19)
    os.makedirs(STATE, exist_ok=True)
    lock = open(f'{STATE}/lock', 'w')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print('memory-check: another run holds the lock, exiting')
        return 0
    stamp = time.strftime('%Y%m%dT%H%M%S', time.gmtime())
    logp = f'{STATE}/{datetime.datetime.now(datetime.timezone.utc):%Y-%m-%d}.md'
    lines = []

    def log(kind, nid, ev):
        lines.append(f'- {kind}: `{nid}` — {ev}')

    def flush(head):
        with open(logp, 'a', encoding='utf-8') as f:
            f.write(f'## run {stamp}Z\n{head}\n' + '\n'.join(lines) + '\n\n')

    cj = f'{STATE}/checked.json'
    checked = json.loads(read(cj)) if os.path.exists(cj) else {}
    paths = note_paths()
    if not paths:
        flush('no notes found')
        return 0
    bk = backup(sorted(glob.glob(MEM_GLOB)))
    sel = select(paths, checked)
    os.makedirs(f'{STATE}/scratch', exist_ok=True)  # durable state dir, not the tmpfs scratchpad
    scratch = tempfile.mkdtemp(prefix='run-', dir=f'{STATE}/scratch')
    try:
        manifest = {}
        for p in sel:
            nid = f'{os.path.basename(os.path.dirname(os.path.dirname(p)))}/{os.path.basename(p)}'
            os.makedirs(os.path.dirname(f'{scratch}/notes/{nid}'), exist_ok=True)
            manifest[nid] = {'src': p, 'mtime_ns': os.stat(p).st_mtime_ns}
            shutil.copy2(p, f'{scratch}/notes/{nid}')
        os.makedirs(f'{scratch}/new')
        rc, tail = run_worker(scratch, f'memcheck-{stamp}')
        backend = ''
        try:
            backend = read(f'{os.environ.get("WORKER_SCRATCH_ROOT", HOME + "/.zenoforge/scratch")}/luna/memcheck-{stamp}/backend').strip()
        except OSError:
            pass
        head = f'backup: {bk}\nselected: {len(sel)} of {len(paths)} notes\nworker: rc={rc} backend={backend or "unknown"}' + (f' note={tail!r}' if tail else '')
        if rc != 0:
            log('skipped', 'all', 'worker failed, nothing applied')
            flush(head)
            return 1
        report = load_report(scratch)
        done = apply(manifest, scratch, report, log)
        apply_new(scratch, report, log)
        now = time.time()
        checked = {p: t for p, t in checked.items() if os.path.exists(p)}
        checked.update({manifest[n]['src']: now for n in done if os.path.exists(manifest[n]['src'])})
        tmp = f'{cj}.{os.getpid()}'
        with open(tmp, 'w') as f:
            json.dump(checked, f, indent=1, sort_keys=True)
        os.replace(tmp, cj)
        flush(head)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
