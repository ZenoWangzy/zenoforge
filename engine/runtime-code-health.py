#!/usr/bin/env python3
"""Read-only process scan; persist only first-stale observation, never signal a PID."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time


def signature(script, root, head, home):
    rows = head + '\n'
    for path in (script, root / 'engine/lib.sh', root / 'engine/runtime-reload.sh'):
        rows += hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + str(path) + '\n'
    capacity = home / 'capacity.env'
    if capacity.is_file():
        rows += hashlib.sha256(capacity.read_bytes()).hexdigest() + '  ' + str(capacity) + '\n'
    return hashlib.sha256(rows.encode()).hexdigest()


def scan(root, home, proc=Path('/proc'), now=None):
    now = time.time() if now is None else now
    head = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
    boot = now - float((proc / 'uptime').read_text().split()[0])
    hz = os.sysconf('SC_CLK_TCK')
    state_path = home / 'state/runtime-code/stale.json'
    try:
        prior = json.loads(state_path.read_text())
    except (OSError, ValueError):
        prior = {}
    stale, delayed, unknown = {}, [], []
    checked = 0
    for directory in proc.glob('[0-9]*'):
        try:
            # Pipeline scripts run as this user; another user's cwd is unreadable (cihost CI runners) and made every scan UNKNOWN.
            if directory.stat().st_uid != os.getuid():
                continue
            args = directory.joinpath('cmdline').read_bytes().split(b'\0')
            if Path(os.fsdecode(args[0])).name not in ('bash', 'sh'):
                continue
            # Only the executable script argument, not a bash -c/credentials wrapper's child argv.
            script_arg = next((os.fsdecode(arg) for arg in args[1:] if arg and not arg.startswith(b'-')), '')
            if not script_arg.endswith('.sh'):
                continue
            script = Path(script_arg)
            if not script.is_absolute():
                script = directory.joinpath('cwd').resolve() / script
            script = script.resolve()
            if not script.is_relative_to(root / 'engine'):
                continue
            if script.name.endswith('.test.sh'):
                continue
            fields = directory.joinpath('stat').read_text().rsplit(') ', 1)[1].split()
            if fields[0] == 'Z':
                continue
            ticks = fields[19]
            started = boot + int(ticks) / hz
            checked += 1
            key = directory.name + ':' + ticks
            record_path = home / 'state/runtime-code' / (directory.name + '.tsv')
            since = None
            registered = False
            if record_path.exists():
                record = record_path.read_text().rstrip('\n').split('\t')
                if record[0] == ticks and record[4] == str(script):
                    registered = True
                    if record[2] != signature(script, root, head, home):
                        # Preserve oldest observation even while many newer commits land.
                        since = prior.get(key, now)
            if not registered:
                # Bootstrap old processes without a registration; compare loaded files to start time.
                changed = [p.stat().st_mtime for p in (script, root / 'engine/lib.sh')
                           if p.stat().st_mtime > started]
                if changed:
                    since = prior.get(key, min(changed))
            if since is not None:
                stale[key] = since
                age = int(now - since)
                if age > 600:
                    delayed.append((script.name, directory.name, ticks, age))
        except (FileNotFoundError, ProcessLookupError):
            continue
        except (OSError, ValueError, IndexError) as error:
            unknown.append(directory.name + ':' + type(error).__name__)
    state_path.parent.mkdir(parents=True, exist_ok=True)
    for record_path in state_path.parent.glob('[0-9]*.tsv'):
        if not (proc / record_path.stem).exists():
            try:
                record_path.unlink()
            except FileNotFoundError:
                pass
    tmp = state_path.with_name('stale.' + str(os.getpid()) + '.tmp')
    tmp.write_text(json.dumps(stale))
    tmp.replace(state_path)
    if delayed:
        details = ','.join(f'{name}:pid={pid}:stale_sec={age}' for name, pid, _, age in delayed)
        keys = ','.join(f'{name}:pid={pid}:start_ticks={ticks}' for name, pid, ticks, _ in delayed)
        return 'STUCK', f'live={head[:12]} stale_over_10m={len(delayed)} details={details} item-keys={keys}'
    if unknown:
        return 'UNKNOWN', 'unreadable=' + ','.join(unknown)
    return 'OK', f'live={head[:12]} checked={checked} stale_waiting_safe_point={len(stale)} bound_sec=600'


if __name__ == '__main__':
    try:
        verdict, detail = scan(Path(sys.argv[1]).resolve(), Path(sys.argv[2]))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        verdict, detail = 'UNKNOWN', 'process scan unavailable: ' + type(error).__name__
    print('runtime-code', verdict, detail)
