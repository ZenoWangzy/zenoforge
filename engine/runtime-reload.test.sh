#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/test-env.sh"
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
python3 - "$repo" <<'PY'
import importlib.util
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import tempfile

source = Path(sys.argv[1])
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary) / 'repo'
    agent = root / 'engine'
    agent.mkdir(parents=True)
    home = Path(temporary) / 'home'
    home.mkdir()
    (home / 'capacity.env').write_text('DQ_MAX_AGENTS=8\n')
    for file in ('runtime-reload.sh', 'runtime-code-health.py'):
        shutil.copyfile(source / 'engine' / file, agent / file)
    shutil.copyfile(source / 'engine/hand-completion-refill.sh', home / 'hand-completion-refill.sh')
    (agent / 'lib.sh').write_text('# fixture lib\n')
    subprocess.run(['git', 'init', '-q', '-b', 'fixture', str(root)], check=True)
    subprocess.run(['git', '-C', str(root), 'add', '.'], check=True)
    subprocess.run(['git', '-C', str(root), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                    'commit', '-qm', 'baseline'], check=True)
    spec = importlib.util.spec_from_file_location('health', agent / 'runtime-code-health.py')
    health = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(health)
    fixture = agent / 'fixture.sh'
    body = r'''#!/usr/bin/env bash
set -euo pipefail
source "${0%/*}/runtime-reload.sh"
agent_reload_init "$0" "$@"
version=1
count=0
if [[ "${ZF_RELOAD_PID:-}" != "$BASHPID" ]]; then
  exec 9>"$AGENT_HOME/loop.lock"; flock -n 9 || exit 9
fi
agent_reload_restore
source "$AGENT_HOME/capacity.env"
printf 'start:%s:%s:%s:%s:%s\n' "$version" "$BASHPID" "$count" "$1" "$PWD"
printf 'capacity:%s\n' "$DQ_MAX_AGENTS"
while read -r command; do
  [[ "$command" != stop ]] || exit 0
  printf 'item:%s:%s\n' "$version" "$count"
  read -r command
  count=$((count + 1))
  printf 'finish:%s:%s\n' "$version" "$count"
  agent_reload_checkpoint count
done
'''
    fixture.write_text(body)
    env = dict(os.environ, AGENT_HOME=str(home))
    process = subprocess.Popen(['bash', str(fixture), 'space argument'], cwd=root,
                               env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
    def read():
        # Wall-clock bound detects a missed exec handshake; no timing sleep drives the behavior.
        assert select.select([process.stdout], [], [], 20)[0], 'fixture handshake timed out'
        return process.stdout.readline().decode().rstrip()
    def send(command):
        process.stdin.write((command + '\n').encode())
        process.stdin.flush()
    try:
        pid = process.pid
        assert read() == f'start:1:{pid}:0:space argument:{root}'
        assert read() == 'capacity:8'
        ticks = Path(f'/proc/{pid}/stat').read_text().rsplit(') ', 1)[1].split()[19]
        record = (home / f'state/runtime-code/{pid}.tsv').read_text().split('\t')
        assert record[0] == ticks
        assert record[2] == health.signature(fixture, root, record[1], home), 'Bash/Python signature parity'
        send('begin')
        assert read() == 'item:1:0'
        fixture.write_text(body.replace('version=1', 'version=2'))
        # Script changed inside item: old item completes before any exec.
        assert process.poll() is None
        send('finish')
        assert read() == 'finish:1:1'
        assert read() == f'start:2:{pid}:1:space argument:{root}'
        assert read() == 'capacity:8'
        assert subprocess.run(['flock', '-n', str(home / 'loop.lock'), 'true']).returncode == 1
        send('begin')
        assert read() == 'item:2:1'
        (agent / 'lib.sh').write_text('# new fixture lib\n')
        send('finish')
        assert read() == 'finish:2:2'
        assert read() == f'start:2:{pid}:2:space argument:{root}'
        assert read() == 'capacity:8'
        send('begin')
        assert read() == 'item:2:2'
        (home / 'capacity.env').write_text('DQ_MAX_AGENTS=9\n')
        send('finish')
        assert read() == 'finish:2:3'
        assert read() == f'start:2:{pid}:3:space argument:{root}'
        assert read() == 'capacity:9'
        record = (home / f'state/runtime-code/{pid}.tsv').read_text().split('\t')
        assert record[2] == health.signature(fixture, root, record[1], home), 'capacity signature parity'
        assert subprocess.run(['flock', '-n', str(home / 'loop.lock'), 'true']).returncode == 1
        send('stop')
        assert process.wait(timeout=20) == 0
        assert subprocess.run(['flock', '-n', str(home / 'loop.lock'), 'true']).returncode == 0
        print('ok - script/lib/capacity changes reload between items; PID, args, cwd, state and lock survive')
    finally:
        # Only this throwaway fixture PID belongs to this test.
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=20)
    # Execute the actual watcher boundary with a controlled live identity, no live cleanup.
    lifecycle = (source / 'engine/worktree-lifecycle.sh').read_text()
    watch = 'watch() {' + lifecycle.split('\nwatch() {', 1)[1].split('\n}\n', 1)[0] + '\n}\n'
    harness = r'''set -euo pipefail
n=0
pid_live() { n=$((n+1)); [[ "$n" -eq 1 ]]; }
pid_start_ticks() { printf '42\n'; }
agent_reload_checkpoint() { printf 'checkpoint\n'; }
sleep() { :; }
hand_exit_followup_dependencies() { :; }
finish_worktree() { :; }
hand_exit_blocked_on_dependency() { :; }
NIGHT="$1"; AGENTS_FILE="$1/agents"; ZF_HAND_UNIT=''
_WORKTREE_LIFECYCLE_DIR="$1"; REPO="$1"
python3() {
  if [[ "${2:-}" == run && "${3:-}" == -- && "${4:-}" == bash && "${6:-}" == watch-cleanup ]]; then
    printf 'cleanup\n' >> "$NIGHT/python3-calls"
    return 0
  fi
  printf 'unexpected python3 call: %s\n' "$*" >&2
  return 1
}
'''
    checked = subprocess.run(['bash', '-c', harness + watch + '\nwatch "$NIGHT" 4242 42', '_', str(home)],
                             text=True, capture_output=True)
    assert checked.returncode == 0, checked.stderr
    assert checked.stdout == 'checkpoint\n', checked.stdout
    assert (home / 'python3-calls').read_text() == 'cleanup\n'
    print('ok - real worktree watcher checks reload while waiting, before terminal cleanup')
    proc = Path(temporary) / 'proc'
    directory = proc / '4242'
    directory.mkdir(parents=True)
    (proc / 'uptime').write_text('1800 0')
    fields = ['S', '1'] + ['0'] * 18
    fields[19] = str(90 * os.sysconf('SC_CLK_TCK'))
    (directory / 'stat').write_text('4242 (fixture bash) ' + ' '.join(fields))
    (directory / 'cmdline').write_bytes(b'bash\0' + os.fsencode(fixture) + b'\0')
    os.utime(fixture, (400, 400))
    os.utime(agent / 'lib.sh', (500, 500))
    verdict, detail = health.scan(root, home, proc, 1800)
    assert verdict == 'STUCK' and 'stale_sec=1400' in detail, (verdict, detail)
    first_keys = detail.split('item-keys=', 1)[1].split()[0]
    verdict, repeated_detail = health.scan(root, home, proc, 1801)
    assert verdict == 'STUCK' and 'stale_sec=1401' in repeated_detail, (verdict, repeated_detail)
    assert repeated_detail.split('item-keys=', 1)[1].split()[0] == first_keys
    assert first_keys == f'fixture.sh:pid=4242:start_ticks={fields[19]}'
    fields[19] = str(91 * os.sysconf('SC_CLK_TCK'))
    (directory / 'stat').write_text('4242 (fixture bash) ' + ' '.join(fields))
    verdict, changed_ticks_detail = health.scan(root, home, proc, 1802)
    changed_ticks_keys = changed_ticks_detail.split('item-keys=', 1)[1].split()[0]
    assert verdict == 'STUCK' and changed_ticks_keys != first_keys
    assert changed_ticks_keys == f'fixture.sh:pid=4242:start_ticks={fields[19]}'
    second_directory = proc / '4343'
    second_directory.mkdir()
    (second_directory / 'stat').write_text('4343 (fixture bash) ' + ' '.join(fields))
    (second_directory / 'cmdline').write_bytes(b'bash\0' + os.fsencode(fixture) + b'\0')
    verdict, changed_pid_detail = health.scan(root, home, proc, 1803)
    changed_pid_keys = changed_pid_detail.split('item-keys=', 1)[1].split()[0].split(',')
    assert verdict == 'STUCK' and f'fixture.sh:pid=4343:start_ticks={fields[19]}' in changed_pid_keys
    shutil.rmtree(second_directory)
    print('ok - unregistered legacy process flags code stale over 10 minutes')
    head = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
    records = home / 'state/runtime-code'
    (records / '4242.tsv').write_text('\t'.join([fields[19], head, health.signature(fixture, root, head, home), '100', str(fixture)]) + '\n')
    assert health.scan(root, home, proc, 1800)[0] == 'OK'
    (agent / 'lib.sh').write_text('# newer lib\n')
    assert health.scan(root, home, proc, 1800)[0] == 'OK'
    (proc / 'uptime').write_text('2400 0')
    assert health.scan(root, home, proc, 2400)[0] == 'OK', 'code is not stale at 600 seconds'
    (proc / 'uptime').write_text('2401 0')
    verdict, detail = health.scan(root, home, proc, 2401)
    assert verdict == 'STUCK' and 'stale_sec=601' in detail
    subprocess.run(['git', '-C', str(root), 'add', '.'], check=True)
    subprocess.run(['git', '-C', str(root), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                    'commit', '-qm', 'next'], check=True)
    assert health.scan(root, home, proc, 2401)[0] == 'STUCK', 'new HEAD reset first-stale age'
    shutil.rmtree(directory)
    assert health.scan(root, home, proc, 2401)[0] == 'OK'
    assert json.loads((records / 'stale.json').read_text()) == {}
    print('ok - registered process alert survives rapid HEAD changes; dead PID clears')
    other = proc / '5151'
    other.mkdir()
    (other / 'cmdline').write_bytes(b'bash\0' + os.fsencode(fixture) + b'\0')
    (other / 'stat').write_text('5151 (other bash) ' + ' '.join(fields))
    real_getuid = os.getuid
    os.getuid = lambda: real_getuid() + 1
    try:
        verdict, detail = health.scan(root, home, proc, 2401)
    finally:
        os.getuid = real_getuid
    assert verdict == 'OK' and 'checked=0' in detail, (verdict, detail)
    print("ok - another user's processes are outside the scan, not UNKNOWN")
PY
