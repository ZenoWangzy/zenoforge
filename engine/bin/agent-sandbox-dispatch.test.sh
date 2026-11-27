#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
engine_dir="$(cd -- "$script_dir/.." && pwd -P)"
fixture="$test_env_root/agent-sandbox-dispatch"
repo="$fixture/repo"
remote="$fixture/remote.git"
branch=agent/issue-995

fail() { echo "agent-sandbox-dispatch.test.sh: $*" >&2; exit 1; }

if ! unshare --user --map-root-user --mount --net --pid --fork --kill-child --mount-proc /usr/bin/true >/dev/null 2>&1; then
  printf '%s\n' 'SKIP agent sandbox dispatch: user, mount, network, or PID namespaces unavailable'
  exit 0
fi

mkdir -p "$fixture" "$HOME/.config/gh" "$HOME/.config/production" "$HOME/.aws" "$HOME/.ssh" \
  "$HOME/.codex" "$HOME/.zcode/v2" "$HOME/.claude" "$HOME/.zenoforge/clones/other"
printf '%s\n' 'oauth_token: host-login-secret' > "$HOME/.config/gh/hosts.yml"
printf '%s\n' 'host-git-secret' > "$HOME/.git-credentials"
printf '%s\n' 'production-token-secret' > "$HOME/.config/production/token"
printf '%s\n' 'aws-secret' > "$HOME/.aws/credentials"
printf '%s\n' 'host-ssh-secret' > "$HOME/.ssh/id_ed25519"
printf '%s\n' '{"selected":"codex-test-only"}' > "$HOME/.codex/auth.json"
printf '%s\n' '{"other":"zcode-test-only"}' > "$HOME/.zcode/v2/credentials.json"
printf '%s\n' '{"other":"claude-test-only"}' > "$HOME/.claude/.credentials.json"
printf '%s\n' 'other-worktree-secret' > "$HOME/.zenoforge/clones/other/secret"
export GH_TOKEN=host-login-secret GITHUB_TOKEN=host-login-secret ZAI_API_KEY=zcode-test-only \
  ANTHROPIC_API_KEY=claude-test-only PROD_ACCESS_TOKEN=production-token-secret

git init --bare --quiet "$remote"
git init --quiet -b main "$repo"
git -C "$repo" config user.name sandbox-test
git -C "$repo" config user.email sandbox-test@example.invalid
git -C "$repo" remote add origin "file://$remote"
printf '%s\n' initial > "$repo/tracked"
printf '%s\n' "$HOME" > "$repo/host-home"
python3 - "$repo/host-namespaces.json" <<'PY'
import json
import os
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_text(json.dumps({name: os.readlink(f'/proc/self/ns/{name}') for name in ('user', 'mount', 'net', 'pid')}))
PY
cat > "$repo/dispatch-probe.py" <<'PY'
import json
import os
import pathlib
import subprocess
import sys
import time

mode, branch = sys.argv[1:]
workspace = pathlib.Path('/run/zf-agent/workspace')
host_home = pathlib.Path((workspace / 'host-home').read_text().strip())
host_namespaces = json.loads((workspace / 'host-namespaces.json').read_text())
for name, identity in host_namespaces.items():
    assert os.readlink(f'/proc/self/ns/{name}') != identity, (name, identity)
assert pathlib.Path('/tmp/worker/.codex/auth.json').read_text() == '{"selected":"codex-test-only"}\n'
for relative in ('.config/gh/hosts.yml', '.config/production/token', '.aws/credentials', '.ssh/id_ed25519',
                 '.zcode/v2/credentials.json', '.claude/.credentials.json', '.zenoforge/clones/other/secret', '.git-credentials'):
    assert not (host_home / relative).exists(), relative
for name in ('GH_TOKEN', 'GITHUB_TOKEN', 'ZAI_API_KEY', 'ANTHROPIC_API_KEY', 'PROD_ACCESS_TOKEN', 'GIT_ASKPASS'):
    assert name not in os.environ, name
for path in pathlib.Path('/proc').glob('[0-9]*/environ'):
    try:
        contents = path.read_bytes()
    except OSError:
        continue
    for name in (b'GH_TOKEN=', b'GITHUB_TOKEN=', b'ZAI_API_KEY=', b'ANTHROPIC_API_KEY=', b'PROD_ACCESS_TOKEN='):
        assert name not in contents, (path, name)

if mode == 'write':
    assert os.environ.get('ZF_AGENT_ACCESS') == 'write'
    assert os.environ.get('ZF_PUSH_SOCKET') == '/run/zf-agent/push.sock'
    (workspace / 'worker-change').write_text('worker change\n')
    subprocess.run(['git', 'add', 'worker-change'], check=True)
    subprocess.run(['git', 'commit', '-m', 'worker change'], check=True)
    own = subprocess.run(['git', 'push', 'origin', branch], capture_output=True)
    assert own.returncode == 0, own.stderr.decode()
    for refspec in ('HEAD:refs/heads/main', 'other'):
        denied = subprocess.run(['git', 'push', 'origin', refspec], capture_output=True)
        assert denied.returncode != 0, refspec
        assert b'push refused' in denied.stderr, (refspec, denied.stderr.decode())
    time.sleep(8)
elif mode == 'review':
    assert os.environ.get('ZF_AGENT_ACCESS') == 'read'
    assert 'ZF_PUSH_SOCKET' not in os.environ
    denied = subprocess.run(['git', 'push', 'origin', branch], capture_output=True)
    assert denied.returncode != 0
    assert b'no push capability' in denied.stderr, denied.stderr.decode()
else:
    raise AssertionError(mode)
PY
git -C "$repo" add tracked host-home host-namespaces.json dispatch-probe.py
git -C "$repo" commit -m initial >/dev/null
git -C "$repo" push --quiet origin main
git -C "$repo" fetch --quiet origin main:refs/remotes/origin/main
git -C "$repo" checkout --quiet -b "$branch"
git -C "$repo" push --quiet -u origin "$branch"
git -C "$repo" branch other
git -C "$repo" push --quiet origin other
initial_main="$(git --git-dir="$remote" rev-parse refs/heads/main)"
initial_other="$(git --git-dir="$remote" rev-parse refs/heads/other)"

supervisor="$fixture/supervisor"
runtime="$supervisor/autopi"
agent="$fixture/agent"
mkdir -p "$runtime/alerts" "$agent"
export MAC_AUTOPILOT_ROOT="$repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$supervisor" \
  MAC_AUTOPILOT_RUNTIME_DIR="$runtime" REQUIRED_PR_CHECKS_FILE="$engine_dir/mac-autopilot/required-pr-checks.json"
cp "$engine_dir/mac-autopilot/config.template.json" "$runtime/config.json"
printf '{"units":[{"id":"issue-995","issue":995,"lane":"pr","stage":"repair-pending"}]}\n' > "$runtime/units.json"
printf '{"workers":[]}\n' > "$runtime/workers.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY ZF_AGENT_TEST_MODE ZF_AGENT_TEST_ROOT

LOG="$runtime/scheduler.log"
UNITS="$runtime/units.json"
WORKERS="$runtime/workers.json"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
NOW_EPOCH="$(date +%s)"
SCHED_LOCK_HELD=true
DRY_RUN=0
ROOT="$repo"
SUP="$supervisor"
A="$agent"
CFG='{"engine":{"worker_tasks_max":0}}'
ZF_ENGINE_DIR="$engine_dir"
WORKER_SCOPE_PREPARED=false
WORKER_SCOPE_MODE=''
LIVE_WORKER_CACHE_UNTIL=0

build_codex_command() {
  local type="$1" mode=review
  [[ "$type" == repair ]] && mode=write
  CODEX_COMMAND=(python3 "$repo/dispatch-probe.py" "$mode" "$branch")
  CODEX_MODE=fresh
  CODEX_PATH_REASON=fixture
  CODEX_SESSION_ID=''
  CODEX_USAGE_START='{}'
  WORKER_STDOUT_REPORT=0
}
coord_issue_key() { printf 'issue:%s\n' "$1"; }
coord_new_owner() { printf 'fixture\n'; }
coord_acquire() { return 0; }
coord_assert_owned() { return 0; }
coord_scheduler_live_worker() { return 1; }
coord_renew() { return 0; }
coord_release() { return 0; }
say() { printf '%s\n' "$*" >> "$LOG"; }

dispatch repair codex high issue-995 write.log report.md prompt '' "$repo" '' '' codex \
  || fail 'write worker did not dispatch'
holder_socket=''
for _ in $(seq 1 150); do
  holder_socket="$(python3 - <<'PY'
import pathlib

for line in pathlib.Path('/proc/net/unix').read_text().splitlines():
    fields = line.split()
    if fields and fields[-1].endswith('/stage/push.sock'):
        print(fields[-1])
        break
PY
)"
  [[ -n "$holder_socket" && -S "$holder_socket" ]] && break
  sleep 0.1
done
[[ -n "$holder_socket" && -S "$holder_socket" ]] || fail 'dispatch did not create a live per-run push credential'
cp "${holder_socket%/push.sock}/bin/git" "$fixture/expired-git"
chmod +x "$fixture/expired-git"
worker_pid="$WORKER_SCOPE_LAUNCHER_PID"
worker_status=0
wait "$worker_pid" || worker_status=$?
[[ "$worker_status" == 0 ]] || fail "write worker exited $worker_status: $(cat "$runtime/write.log")"
[[ ! -e "$holder_socket" ]] || fail 'write credential socket remained after the worker ended'

expired_status=0
(cd "$repo" && PATH="$fixture:$PATH" ZF_PUSH_SOCKET="$holder_socket" "$fixture/expired-git" push origin "$branch") \
  > "$fixture/expired.out" 2>&1 || expired_status=$?
[[ "$expired_status" != 0 ]] || fail 'a push through the expired per-run credential succeeded'
worker_head="$(git -C "$repo" rev-parse HEAD)"
remote_worker_head="$(git --git-dir="$remote" rev-parse "refs/heads/$branch")"
[[ "$worker_head" == "$remote_worker_head" ]] || fail 'worker branch push was not synced to the host and remote'
[[ "$(git --git-dir="$remote" rev-parse refs/heads/main)" == "$initial_main" ]] || fail 'worker changed main'
[[ "$(git --git-dir="$remote" rev-parse refs/heads/other)" == "$initial_other" ]] || fail 'worker changed another branch'

dispatch review codex high issue-995 review.log report.md prompt '' "$repo" '' '' codex \
  || fail 'review worker did not dispatch'
worker_pid="$WORKER_SCOPE_LAUNCHER_PID"
worker_status=0
wait "$worker_pid" || worker_status=$?
[[ "$worker_status" == 0 ]] || fail "review worker exited $worker_status: $(cat "$runtime/review.log")"
[[ "$(jq -r '.workers | length' "$WORKERS")" == 2 ]] || fail 'dispatch did not record both worker runs'
printf '%s\n' 'agent-sandbox-dispatch.test.sh: pass'
