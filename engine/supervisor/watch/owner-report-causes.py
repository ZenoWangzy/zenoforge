#!/usr/bin/env python3
"""Daily cause finder for the owner report (same pattern as memory-check.py).

At 00:30 UTC one GLM worker reads each material change of today's report (night/maintainer-health-mail.sh material),
traces it in the snapshots and local logs, and writes plain-Chinese causes with the evidence it read. This script is the single
writer: it keeps only rows that pass night/owner-report-compare.py valid_cause_row and writes
<OC_OUT_DIR>/owner-report-causes-YYYY-MM-DD.json (Beijing date). The mail reads that file only when ZF_OWNER_REPORT_CAUSES=on
(off by default); until then the file is for the head to read. It never sends mail and never writes under the agent home.

One run: flock, skip if today's file exists, list the material changes, copy the last snapshots to a scratch dir, run one worker on
the copy, validate its rows, write the file. A worker that fails or times out writes no file (a rerun is possible). The worker
must create causes.jsonl even when it traces nothing (empty file = nothing traced, 未查明); no file at all after rc 0 is a failed
run: the worker is run once more with the time left, the last 40 lines of its output go to the run log, and the job exits 1.
The worker is Codex luna (WORKER_BACKEND=luna), not GLM: factory GLM is paced (glm_factory_cap_2026_11_08). bin/worker may still
fail over to zc on a provider health failure, as for every worker.

Env (defaults in parentheses, overridden by the test):
  OC_STATE (~/.zenoforge/state/owner-report-causes)  OC_OUT_DIR (~/.zenoforge/state/work)
  OC_WORKER ($ZF_ENGINE_LIVE/bin/worker, else ~/.vecta-agent/engine-live)  OC_MAIL (night/maintainer-health-mail.sh beside this engine)
  OC_TIMEOUT (1500, queue at the worker's capacity gate included: the mail goes out at 01:00 UTC, so a later answer is no use today)
  OC_SYSTEMCTL (systemctl)  OC_REPOS (the engine checkout)
"""
import datetime, fcntl, importlib.util, json, os, re, shlex, shutil, signal, subprocess, sys, tempfile, time

HOME = os.path.expanduser('~')
HERE = os.path.dirname(os.path.realpath(__file__))
STATE = os.environ.get('OC_STATE', f'{HOME}/.zenoforge/state/owner-report-causes')
OUT_DIR = os.environ.get('OC_OUT_DIR', f'{HOME}/.zenoforge/state/work')
WORKER = os.environ.get('OC_WORKER', os.environ.get('ZF_ENGINE_LIVE', f'{HOME}/.vecta-agent/engine-live') + '/bin/worker')
MAIL = os.environ.get('OC_MAIL', os.path.join(HERE, '..', '..', 'night', 'maintainer-health-mail.sh'))
COMPARE = os.path.join(HERE, '..', '..', 'night', 'owner-report-compare.py')
TIMEOUT = int(os.environ.get('OC_TIMEOUT', '1500'))
SYSTEMCTL = os.environ.get('OC_SYSTEMCTL', 'systemctl')
REPOS = shlex.split(os.environ.get('OC_REPOS', os.path.realpath(os.path.join(HERE, '..', '..', '..'))))
SNAPSHOTS_KEPT = 8


def compare_module():
    spec = importlib.util.spec_from_file_location('owner_report_compare', COMPARE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def agent_home():
    return os.environ.get('AGENT_HOME') or os.environ.get('ZF_HOME') or f'{HOME}/.zenoforge'


def runtime_dir():
    """Same resolution as maintainer_health_mail_runtime_dir."""
    home = agent_home()
    user_home = home[:-len('/.zenoforge')] if home.endswith('/.zenoforge') else home
    return os.environ.get('MAC_AUTOPILOT_RUNTIME_DIR') or os.environ.get('ZF_MAC_AUTOPILOT_RUNTIME_DIR') \
        or f'{user_home}/checkout/.scratch-supervisor/autopi'


def snapshot_dir():
    return os.environ.get('ZF_OWNER_REPORT_SNAPSHOT_DIR') or f'{agent_home()}/night/owner-report-snapshots'


def material_changes():
    """The report's material changes, or None when they cannot be read."""
    done = subprocess.run(['bash', MAIL, 'material'], capture_output=True, text=True, timeout=300)
    if done.returncode != 0:
        return None
    try:
        rows = json.loads(done.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return None
    return rows if isinstance(rows, list) else None


def run_worker(work, key, timeout=None):
    prompt = open(f'{HERE}/owner-report-causes.prompt.md', encoding='utf-8').read() + f"""
## This run

- Material changes: `{work}/material.json`.
- Snapshots (copies, read-only): `{work}/snapshots/`.
- Local records you may read: the files and directories under `{runtime_dir()}` named in the allowed list, `{agent_home()}/logs/` only the files named in the allowed list, `{agent_home()}/spend/`.
- Repos for `git log origin/main`: {' '.join(REPOS)}
- Output: `{work}/causes.jsonl`, one JSON object per line. Create it as your first command (`: > {work}/causes.jsonl`), then append rows.
"""
    pf = f'{work}/prompt.md'
    with open(pf, 'w', encoding='utf-8') as f:
        f.write(prompt)
    env = dict(os.environ, WORKER_BACKEND='luna', LUNA_PRIORITY='low')
    p = subprocess.Popen([WORKER, key, work, pf], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        out, err = p.communicate(timeout=timeout or TIMEOUT)
        return p.returncode, '\n'.join(((out or '') + (err or '')).strip().splitlines()[-40:])[-6000:]
    except subprocess.TimeoutExpired:
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(p.pid, sig)
                p.wait(10)
                break
            except (ProcessLookupError, subprocess.TimeoutExpired):
                pass
        stop_scopes(key)
        return 124, f'worker timeout after {timeout or TIMEOUT}s'


def stop_scopes(key):
    """bin/zc and bin/luna run the agent in a systemd scope named after the key; killing the wrapper leaves it running (#663)."""
    k = re.sub(r'[^A-Za-z0-9_-]', '-', key)
    for pat in (f'luna-zc-{k}-*.scope', f'luna-{k}-*.scope'):
        subprocess.run([SYSTEMCTL, '--user', 'stop', pat], capture_output=True)


def read_rows(work):
    """Rows of causes.jsonl; the caller has checked that the file exists."""
    rows = []
    for line in open(f'{work}/causes.jsonl', encoding='utf-8').read().splitlines():
        try:
            rows.append(json.loads(line))
        except ValueError:
            rows.append(None)
    return rows


def accept(rows, wanted, valid):
    """(kept rows, dropped [{line, reason}]). Only the code check decides; one row per line key."""
    kept, dropped, seen = [], [], set()
    for row in rows:
        line = row.get('line') if isinstance(row, dict) else None
        if line not in wanted:
            dropped.append({'line': str(line)[:40], 'reason': 'not a material change of today'})
        elif line in seen:
            dropped.append({'line': line, 'reason': 'second row for the same line'})
        elif valid(row) is None:
            dropped.append({'line': line, 'reason': 'no usable evidence, or the cause is not plain Chinese, or it rests on timing'})
        else:
            seen.add(line)
            kept.append({'line': line, 'cause': valid(row), 'evidence': row['evidence'].strip(), 'basis': 'read'})
    return kept, dropped


def main():
    os.nice(19)
    os.makedirs(STATE, exist_ok=True)
    lock = open(f'{STATE}/lock', 'w')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print('owner-report-causes: another run holds the lock, exiting')
        return 0
    cmp = compare_module()
    now = int(time.time())
    day = cmp.beijing_day(now)
    out = f'{OUT_DIR}/owner-report-causes-{day}.json'
    stamp = time.strftime('%Y%m%dT%H%M%S', time.gmtime())
    lines = []

    def flush(head):
        with open(f'{STATE}/{day}.md', 'a', encoding='utf-8') as f:
            f.write(f'## run {stamp}Z\n{head}\n' + '\n'.join(lines) + '\n\n')

    if os.path.exists(out):
        flush('causes file already written for this day, nothing to do')
        return 0
    changes = material_changes()
    if changes is None:
        flush('material changes unreadable, nothing written')
        return 1
    wanted = {c['line'] for c in changes if isinstance(c, dict) and 'line' in c}
    rows, dropped, note = [], [], ''
    if wanted:
        os.makedirs(f'{STATE}/scratch', exist_ok=True)  # durable state dir, not the tmpfs scratchpad
        scratch = tempfile.mkdtemp(prefix='run-', dir=f'{STATE}/scratch')
        try:
            with open(f'{scratch}/material.json', 'w', encoding='utf-8') as f:
                json.dump(changes, f, ensure_ascii=False, indent=1)
            os.makedirs(f'{scratch}/snapshots')
            for p in sorted(f for f in os.listdir(snapshot_dir()) if re.fullmatch(r'\d{4}-\d{2}-\d{2}\.json', f))[-SNAPSHOTS_KEPT:] if os.path.isdir(snapshot_dir()) else []:
                shutil.copy2(f'{snapshot_dir()}/{p}', f'{scratch}/snapshots/{p}')
            started = time.time()
            for attempt in (1, 2):
                rc, tail = run_worker(scratch, f'owncause-{stamp}' + ('-r2' if attempt == 2 else ''), max(int(started + TIMEOUT - time.time()), 1))
                missing = rc == 0 and not os.path.exists(f'{scratch}/causes.jsonl')
                if rc == 0 and not missing:
                    break
                lines.append(f'worker attempt {attempt}: rc={rc}' + (', no causes.jsonl written' if missing else '') + (f'\n```\n{tail}\n```' if tail else ''))
                if not missing or attempt == 2 or started + TIMEOUT - time.time() < 60:
                    flush('worker failed, no file written')
                    return 1
            rows, dropped = accept(read_rows(scratch), wanted, cmp.valid_cause_row)
        finally:
            shutil.rmtree(scratch, ignore_errors=True)
    else:
        note = 'no material change, no worker run'
    os.makedirs(OUT_DIR, exist_ok=True)
    tmp = f'{out}.{os.getpid()}'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump({'day': day, 'generated_at': now, 'material': sorted(wanted), 'rows': rows, 'dropped': dropped}, f, ensure_ascii=False, indent=1)
    os.replace(tmp, out)
    lines.append(f'- kept {len(rows)} of {len(rows) + len(dropped)} rows' + ''.join(f'\n- dropped `{d["line"]}`: {d["reason"]}' for d in dropped))
    flush(f'wrote {out}' + (f'; {note}' if note else ''))
    return 0


if __name__ == '__main__':
    sys.exit(main())
