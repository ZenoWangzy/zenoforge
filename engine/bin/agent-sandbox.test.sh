#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
test_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
sandbox="$test_dir/agent-sandbox.py"
if ! systemd-run --user --scope --quiet -p TasksMax=100 -- true >/dev/null 2>&1; then
  printf '%s\n' 'SKIP worker sandbox integration: systemd user scope unavailable'
  exit 0
fi
work="$TMPDIR/worker"
remote="$TMPDIR/remote.git"
mkdir -p "$work" "$HOME/.config/gh" "$HOME/.config/production" "$HOME/.aws" "$HOME/.ssh" "$HOME/.codex" "$HOME/.zcode/v2" "$HOME/.claude" "$HOME/.zenoforge/clones/other"
mkdir -p "$HOME/bin"
printf '%s\n' 'oauth_token: host-login-secret' > "$HOME/.config/gh/hosts.yml"
printf '%s\n' 'host-ssh-secret' > "$HOME/.ssh/id_ed25519"
printf '%s\n' '{"selected":"codex-test-only"}' > "$HOME/.codex/auth.json"
cat > "$HOME/.codex/config.toml" <<'TOML'
[profiles.arbiter]
model = "gpt-test"
model_reasoning_effort = "high"
service_tier = "priority"
token = "unselected-profile-secret"
TOML
printf '%s\n' '{"selected":"zcode-test-only"}' > "$HOME/.zcode/v2/credentials.json"
printf '%s\n' '{"selected":"claude-test-only"}' > "$HOME/.claude/.credentials.json"
printf '%s\n' 'other-tenant-worktree-secret' > "$HOME/.zenoforge/clones/other/secret"
printf '%s\n' 'host-git-secret' > "$HOME/.git-credentials"
printf '%s\n' 'production-token-secret' > "$HOME/.config/production/token"
printf '%s\n' 'aws-secret' > "$HOME/.aws/credentials"
cat > "$HOME/bin/codex" <<'SH'
#!/usr/bin/env bash
printf 'selected codex executable\n'
SH
cat > "$HOME/bin/claude" <<'SH'
#!/usr/bin/env bash
printf 'selected claude executable\n'
SH
cat > "$HOME/bin/zcode" <<'SH'
#!/usr/bin/env bash
printf 'selected zcode executable\n'
SH
chmod +x "$HOME/bin/codex"
chmod +x "$HOME/bin/claude"
chmod +x "$HOME/bin/zcode"
PATH="$HOME/bin:$PATH"
export PATH
git init --bare "$remote" >/dev/null
git init -b agent/issue-501 "$work" >/dev/null
git -C "$work" config user.name sandbox-test
git -C "$work" config user.email sandbox-test@example.invalid
git -C "$work" config remote.origin.url "file://$remote"
printf '%s\n' '.env' 'node_modules/' > "$work/.gitignore"
printf '%s\n' initial > "$work/tracked"
printf '%s\n' 'tracked-credential-secret' > "$work/credentials.json"
git -C "$work" add .gitignore tracked credentials.json
git -C "$work" commit -m initial >/dev/null
git -C "$work" branch other
git -C "$work" push origin HEAD:refs/heads/agent/issue-501 >/dev/null
printf '%s\n' 'repo-local-production-secret' > "$work/.env"
printf '%s\n' 'repo-local-env-secret' > "$work/.env.local"
printf '%s\n' '//registry.invalid/:_authToken=repo-local-npm-secret' > "$work/.npmrc"
mkdir -p "$work/node_modules/sample-package"
printf '%s\n' 'module.exports = true' > "$work/node_modules/sample-package/index.js"
printf '%s\n' '//registry.invalid/:_authToken=node-modules-npm-secret' > "$work/node_modules/sample-package/.npmrc"
printf '%s\n' 'node-modules-token-secret' > "$work/node_modules/sample-package/token.json"
printf '%s\n' "$HOME" > "$work/host-home"
python3 - "$work/host-local-port" <<'PY' &
import pathlib
import socket
import sys
import time

server = socket.socket()
server.bind(('127.0.0.1', 0))
server.listen()
pathlib.Path(sys.argv[1]).write_text(str(server.getsockname()[1]))
time.sleep(120)
PY
host_listener_pid=$!
cleanup_host_listener() { kill "$host_listener_pid" 2>/dev/null || true; wait "$host_listener_pid" 2>/dev/null || true; }
trap cleanup_host_listener EXIT
for _ in $(seq 1 50); do [[ -s "$work/host-local-port" ]] && break; sleep 0.1; done
[[ -s "$work/host-local-port" ]]
session_id=11111111-1111-1111-1111-111111111111
mkdir -p "$HOME/.codex/sessions/2026/11/26"
printf '%s\n' 'selected-session' > "$HOME/.codex/sessions/2026/11/26/rollout-test-$session_id.jsonl"
printf '%s\n' 'other-agent-session-secret' > "$HOME/.codex/sessions/2026/11/26/rollout-test-22222222-2222-2222-2222-222222222222.jsonl"
claude_session_id=44444444-4444-4444-4444-444444444444
mkdir -p "$HOME/.claude/projects/-previous-agent" "$HOME/.claude/projects/-other-agent"
printf '%s\n' 'selected-claude-session' > "$HOME/.claude/projects/-previous-agent/$claude_session_id.jsonl"
printf '%s\n' 'other-agent-claude-session-secret' > "$HOME/.claude/projects/-other-agent/55555555-5555-5555-5555-555555555555.jsonl"
cat > "$work/probe.py" <<'PY'
import os
import pathlib
import socket
import subprocess
import sys

mode = sys.argv[1]
if mode in {'write', 'read', 'reject', 'edit'}:
    expected_scope = {'write': 'zf-agent-sandbox-write-test.scope', 'read': 'zf-agent-sandbox-read-test.scope', 'reject': 'zf-agent-sandbox-reject-test.scope', 'edit': 'zf-agent-sandbox-edit-test.scope'}[mode]
    cgroup = pathlib.Path('/proc/self/cgroup').read_text()
    assert expected_scope in cgroup, cgroup
host_home = pathlib.Path('/run/zf-agent/workspace/host-home').read_text().strip()
assert pathlib.Path('/tmp/worker/.codex/auth.json').read_text() == '{"selected":"codex-test-only"}\n'
assert subprocess.run(['codex', '--sandbox-probe'], check=True, capture_output=True, text=True).stdout == 'selected codex executable\n'
assert not pathlib.Path('/run/zf-agent/workspace/.env').exists(), 'ignored repo credential was visible'
for relative in ('credentials.json', '.env.local', '.npmrc', 'node_modules/sample-package/.npmrc', 'node_modules/sample-package/token.json'):
    assert not pathlib.Path('/run/zf-agent/workspace', relative).exists(), relative
assert pathlib.Path('/run/zf-agent/workspace/node_modules/sample-package/index.js').is_file()
try:
    pathlib.Path('/run/zf-agent/workspace/node_modules/sample-package/write-probe').write_text('blocked')
except OSError:
    pass
else:
    raise AssertionError('dependency snapshot accepted a write')
assert any(line.split()[1:3] == ['/var', 'tmpfs'] for line in pathlib.Path('/proc/mounts').read_text().splitlines())
probe = socket.socket()
assert probe.connect_ex(('127.0.0.1', int(pathlib.Path('/run/zf-agent/workspace/host-local-port').read_text()))) != 0, 'worker reached a host-local service'
probe.close()
proxy = socket.create_connection(('127.0.0.1', 3128))
proxy.sendall(b'CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n')
assert b'403 Forbidden' in proxy.recv(1024), 'worker proxy allowed an unscoped destination'
proxy.close()
for relative in ('.config/gh/hosts.yml', '.config/production/token', '.aws/credentials', '.ssh/id_ed25519', '.zcode/v2/credentials.json', '.claude/.credentials.json', '.zenoforge/clones/other/secret', '.git-credentials', 'bin/codex'):
    assert not pathlib.Path(host_home, relative).exists(), relative
for name in ('GH_TOKEN', 'GITHUB_TOKEN', 'ZAI_API_KEY', 'ANTHROPIC_API_KEY', 'PROD_ACCESS_TOKEN'):
    assert name not in os.environ, name
for path in pathlib.Path('/proc').glob('[0-9]*/environ'):
    try:
        process_environment = path.read_bytes()
    except OSError:
        continue
    for name in (b'GH_TOKEN=', b'GITHUB_TOKEN=', b'ZAI_API_KEY=', b'ANTHROPIC_API_KEY=', b'PROD_ACCESS_TOKEN='):
        assert name not in process_environment, (path, name)
assert not list(pathlib.Path(os.environ['CODEX_HOME'], 'sessions').rglob('*.jsonl'))
if mode in {'write', 'reject', 'edit'}:
    name = {'write': 'change', 'reject': 'rejected-change', 'edit': 'edit-change'}[mode]
    pathlib.Path('/run/zf-agent/workspace', name).write_text(mode + '\n')
    subprocess.run(['git', 'add', name], check=True)
    subprocess.run(['git', 'commit', '-m', 'sandbox change'], check=True)
    pushed = subprocess.run(['git', 'push', 'origin', 'agent/issue-501'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if mode in {'reject', 'edit'}:
        assert pushed.returncode != 0
    else:
        assert pushed.returncode == 0, pushed.stderr.decode()
        denied = subprocess.run(['git', 'push', 'origin', 'other'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        assert denied.returncode != 0
else:
    try:
        pathlib.Path('/run/zf-agent/workspace/readonly-change').write_text('blocked\n')
    except OSError:
        pass
    else:
        raise AssertionError('read-only worktree accepted a write')
    denied = subprocess.run(['git', 'push', 'origin', 'agent/issue-501'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert denied.returncode != 0
PY
export ZAI_API_KEY=zcode-unselected-secret ANTHROPIC_API_KEY=claude-unselected-secret GH_TOKEN=host-login-secret PROD_ACCESS_TOKEN=production-token-secret
systemd-run --user --scope --quiet --slice=zf-agent-sandbox-test.slice --unit=zf-agent-sandbox-write-test -p MemoryMax=512M \
  --setenv=GH_TOKEN=host-login-secret --setenv=GITHUB_TOKEN=host-login-secret --setenv=PROD_ACCESS_TOKEN=production-token-secret \
  --setenv=ZAI_API_KEY=zcode-unselected-secret --setenv=ANTHROPIC_API_KEY=claude-unselected-secret -- \
  python3 "$sandbox" --provider codex --access write --repo "$work" -- python3 "$work/probe.py" write
git --git-dir="$remote" show-ref --verify refs/heads/agent/issue-501 >/dev/null
git --git-dir="$remote" show-ref --verify refs/heads/other >/dev/null 2>&1 && { printf '%s\n' 'sandbox published another branch' >&2; exit 1; }
host_head="$(git -C "$work" rev-parse HEAD)"
remote_head="$(git --git-dir="$remote" rev-parse refs/heads/agent/issue-501)"
[[ "$host_head" == "$remote_head" ]] || { printf 'host branch sync mismatch: %s %s\n' "$host_head" "$remote_head" >&2; exit 1; }
[[ -f "$work/change" && "$(<"$work/change")" == write ]]
[[ "$(<"$work/.env")" == repo-local-production-secret ]]
[[ "$(<"$work/.env.local")" == repo-local-env-secret ]]
[[ "$(<"$work/.npmrc")" == '//registry.invalid/:_authToken=repo-local-npm-secret' ]]
[[ "$(<"$work/node_modules/sample-package/.npmrc")" == '//registry.invalid/:_authToken=node-modules-npm-secret' ]]
printf '%s\n' 'PASS write scope: selected auth only and push stayed on the captured branch'
before_failed_push="$(git -C "$work" rev-parse HEAD)"
printf '%s\n' '#!/bin/sh' 'exit 1' > "$remote/hooks/pre-receive"
chmod +x "$remote/hooks/pre-receive"
systemd-run --user --scope --quiet --slice=zf-agent-sandbox-test.slice --unit=zf-agent-sandbox-reject-test -p MemoryMax=512M -- \
  python3 "$sandbox" --provider codex --access write --repo "$work" -- python3 "$work/probe.py" reject
[[ "$(git -C "$work" rev-parse HEAD)" == "$before_failed_push" ]]
[[ "$(git --git-dir="$remote" rev-parse refs/heads/agent/issue-501)" == "$before_failed_push" ]]
rm -f "$remote/hooks/pre-receive"
printf '%s\n' 'PASS rejected push: local and remote branch stayed at the published commit'
before_edit="$(git -C "$work" rev-parse HEAD)"
systemd-run --user --scope --quiet --slice=zf-agent-sandbox-test.slice --unit=zf-agent-sandbox-edit-test -p MemoryMax=512M -- \
  python3 "$sandbox" --provider codex --access edit --repo "$work" -- python3 "$work/probe.py" edit
[[ "$(git -C "$work" rev-parse HEAD)" == "$before_edit" && -f "$work/edit-change" ]]
printf '%s\n' 'PASS edit scope: worktree changes returned to the host and push stayed unavailable'
cat > "$work/session-probe.py" <<'PY'
import os
import pathlib
import sys

session_id = sys.argv[2]
sessions = pathlib.Path(os.environ['CODEX_HOME'], 'sessions')
files = list(sessions.rglob('*.jsonl'))
assert len(files) == 1, files
assert files[0].name.endswith(session_id + '.jsonl'), files[0]
files[0].write_text(files[0].read_text() + 'resumed\n')
PY
systemd-run --user --scope --quiet --slice=zf-agent-sandbox-test.slice --unit=zf-agent-sandbox-session-test -p MemoryMax=512M -- \
  python3 "$sandbox" --provider codex --access read --repo "$work" -- python3 "$work/session-probe.py" resume "$session_id"
grep -Fq 'resumed' "$HOME/.codex/sessions/2026/11/26/rollout-test-$session_id.jsonl"
[[ "$(find "$HOME/.codex/sessions" -name '*.jsonl' | wc -l)" -eq 2 ]]
cat > "$work/fresh-session.py" <<'PY'
import os
import pathlib
import sys

session_id = sys.argv[1]
session = pathlib.Path(os.environ['CODEX_HOME'], 'sessions/2026/11/26', 'rollout-new-' + session_id + '.jsonl')
session.parent.mkdir(parents=True, exist_ok=True)
session.write_text('new-session\n')
PY
fresh_session_id=33333333-3333-3333-3333-333333333333
systemd-run --user --scope --quiet --slice=zf-agent-sandbox-test.slice --unit=zf-agent-sandbox-fresh-session-test -p MemoryMax=512M -- \
  python3 "$sandbox" --provider codex --access read --repo "$work" -- python3 "$work/fresh-session.py" "$fresh_session_id"
grep -Fq 'new-session' "$HOME/.codex/sessions/2026/11/26/rollout-new-$fresh_session_id.jsonl"
printf '%s\n' 'PASS provider state: only the selected session was exposed and new session data returned to the host'
cat > "$work/attachment-probe.py" <<'PY'
import pathlib
import sys

attach = pathlib.Path(sys.argv[sys.argv.index('--attach') + 1])
output = pathlib.Path(sys.argv[sys.argv.index('--output') + 1])
output.write_text(attach.read_text() + '\nreport\n')
PY
mkdir -p "$work/.scratch-supervisor"
printf '%s\n' 'supervisor prompt' > "$work/.scratch-supervisor/prompt.md"
systemd-run --user --scope --quiet --slice=zf-agent-sandbox-test.slice --unit=zf-agent-sandbox-attachment-test -p MemoryMax=512M -- \
  python3 "$sandbox" --provider codex --access read --repo "$work" --engine-root "$test_dir/.." \
  --capture-output "$work/.scratch-supervisor/report.md" -- \
  python3 "$work/attachment-probe.py" --attach "$work/.scratch-supervisor/prompt.md" --output "$work/.scratch-supervisor/report.md"
[[ "$(<"$work/.scratch-supervisor/report.md")" == $'supervisor prompt\n\nreport' ]]
[[ "$(<"$work/credentials.json")" == tracked-credential-secret ]]
printf '%s\n' 'PASS ignored supervisor prompt staged read-only and report captured back to host'
cat > "$work/profile-probe.py" <<'PY'
import os
import pathlib
import tomllib

config_path = pathlib.Path(os.environ['CODEX_HOME'], 'config.toml')
config = tomllib.loads(config_path.read_text())
assert config == {'profiles': {'arbiter': {'model': 'gpt-test', 'model_reasoning_effort': 'high', 'service_tier': 'priority'}}}, config
assert 'unselected-profile-secret' not in config_path.read_text()
PY
systemd-run --user --scope --quiet --slice=zf-agent-sandbox-test.slice --unit=zf-agent-sandbox-profile-test -p MemoryMax=512M -- \
  python3 "$sandbox" --provider codex --access read --repo "$work" -- python3 "$work/profile-probe.py" -p arbiter
printf '%s\n' 'PASS Codex profile: selected safe settings are available and profile secrets are excluded'
cat > "$work/claude-session-probe.py" <<'PY'
import os
import pathlib
import sys

session_id = sys.argv[2]
project = pathlib.Path(os.environ['CLAUDE_CONFIG_DIR'], 'projects/-run-zf-agent-workspace')
files = list(project.glob('*.jsonl'))
assert len(files) == 1 and files[0].name == session_id + '.jsonl', files
files[0].write_text(files[0].read_text() + 'resumed\n')
PY
systemd-run --user --scope --quiet --slice=zf-agent-sandbox-test.slice --unit=zf-agent-sandbox-claude-session-test -p MemoryMax=512M -- \
  python3 "$sandbox" --provider claude --access read --repo "$work" -- python3 "$work/claude-session-probe.py" resume "$claude_session_id"
grep -Fq 'resumed' "$HOME/.claude/projects/-previous-agent/$claude_session_id.jsonl"
[[ "$(find "$HOME/.claude/projects" -name '*.jsonl' | wc -l)" -eq 2 ]]
printf '%s\n' 'PASS Claude session: only the selected project session was exposed and returned'
cat > "$work/zcode-probe.py" <<'PY'
import json
import os
import pathlib

config = json.loads(pathlib.Path('/tmp/worker/.zcode/cli/config.json').read_text())
assert config['features'] == {'mcp': False, 'plugins': False, 'skills': False, 'hooks': False, 'memory': False}
assert pathlib.Path('/tmp/worker/.zcode/v2/credentials.json').read_text() == '{"selected":"zcode-test-only"}\n'
assert 'ZAI_API_KEY' in os.environ
assert 'PROD_ACCESS_TOKEN' not in os.environ
PY
systemd-run --user --scope --quiet --slice=zf-agent-sandbox-test.slice --unit=zf-agent-sandbox-zcode-test -p MemoryMax=512M -- \
  python3 "$sandbox" --provider zcode --access read --repo "$work" -- python3 "$work/zcode-probe.py"
printf '%s\n' 'PASS ZCode scope: only its credential is visible and MCP, plugins, skills, hooks and memory stay off'
systemd-run --user --scope --quiet --slice=zf-agent-sandbox-test.slice --unit=zf-agent-sandbox-broker-holder -p MemoryMax=512M -- \
  python3 "$sandbox" --provider codex --access write --repo "$work" -- \
  sleep 8 &
holder_pid=$!
holder_socket=
for _ in $(seq 1 50); do holder_socket="$(awk '$NF ~ /\/stage\/push\.sock$/ {print $NF; exit}' /proc/net/unix)"; [[ -S "$holder_socket" ]] && break; sleep 0.1; done
[[ -S "$holder_socket" ]]
printf '%s\n' "$holder_socket" > "$work/holder-socket-path"
cat > "$work/peer-probe.py" <<'PY'
import socket
import pathlib

path = pathlib.Path('/run/zf-agent/workspace/holder-socket-path').read_text().strip()
peer = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
try:
    peer.connect(path)
except OSError:
    pass
else:
    raise AssertionError('peer broker socket was reachable: ' + path)
finally:
    peer.close()
PY
systemd-run --user --scope --quiet --slice=zf-agent-sandbox-test.slice --unit=zf-agent-sandbox-peer-test -p MemoryMax=512M -- \
  python3 "$sandbox" --provider codex --access read --repo "$work" -- python3 "$work/peer-probe.py"
wait "$holder_pid"
[[ ! -e "$holder_socket" && ! -e "$(dirname "$(dirname "$holder_socket")")" ]]
printf '%s\n' 'PASS broker isolation: peer could not connect and the per-run socket and staging credentials expired'
git -C "$work" checkout --detach >/dev/null
systemd-run --user --scope --quiet --slice=zf-agent-sandbox-test.slice --unit=zf-agent-sandbox-read-test -p MemoryMax=512M -- \
  python3 "$sandbox" --provider codex --access read --repo "$work" -- python3 "$work/probe.py" read
[[ ! -e "$work/readonly-change" ]]
printf '%s\n' 'PASS read scope: worktree was read-only and no push capability was present'
grep -Fq 'agent-sandbox-run' "$test_dir/luna"
grep -Fq 'agent-sandbox-run' "$test_dir/zc"
grep -Fq 'ZF_AGENT_ACCESS=write' "$test_dir/worker"
grep -Fq 'agent-sandbox-run' "$test_dir/../mac-autopilot/scheduler.d/worker-scope.sh"
grep -Fq 'WORKER_AGENT_PROVIDER="$provider"' "$test_dir/../mac-autopilot/scheduler.d/dispatch.sh"
grep -Fq 'bin/agent-sandbox.py' "$test_dir/worker-remote.py"
grep -Fq 'bin/agent_sandbox_state.py' "$test_dir/worker-remote.py"
grep -Fq 'bin/agent-sandbox-run' "$test_dir/worker-remote.py"
grep -Fq 'codex read "$cwd"' "$test_dir/../lib.d/model-calls.sh"
grep -Fq 'codex write "$cwd"' "$test_dir/../lib.d/model-calls.sh"
grep -Fq 'zcode read "$cwd"' "$test_dir/../lib.d/model-calls.sh"
grep -Fq 'claude read "$cwd"' "$test_dir/../lib.d/triage-claude.sh"
grep -Fq 'agent-sandbox-run' "$test_dir/../eval/stage-call.sh"
grep -Fq 'agent-sandbox-run' "$test_dir/../night/dispatch.sh"
grep -Fq 'agent-sandbox-run' "$test_dir/../dispatch-codex.sh"
grep -Fq 'WORKER_AGENT_PROVIDER=codex' "$test_dir/../mac-autopilot/scheduler.d/supervisor-arbiter.sh"
grep -Fq 'WORKER_AGENT_CAPTURE_OUTPUT' "$test_dir/../mac-autopilot/scheduler.d/worker-scope.sh"
grep -Fq -- '--attach "$SUP/$q"' "$test_dir/../mac-autopilot/scheduler.d/supervisor-arbiter.sh"
grep -Fq -- '--output-last-message "$2" - < "$3"' "$test_dir/../mac-autopilot/scheduler.d/supervisor-arbiter.sh"
[[ "$(grep -cF -- '--attach "$3"' "$test_dir/../mac-autopilot/scheduler.d/supervisor-arbiter.sh" || true)" == 0 ]]
grep -Fq 'agent-sandbox-run' "$test_dir/../lib.d/codex-budget.sh"
python3 - "$test_dir/../mac-autopilot/scheduler.d/worker-scope.sh" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
launch = source.split('worker_scope_launch() {', 1)[1].split('worker_pidfile() {', 1)[0]
assert 'worker_command=("$sandbox"' in launch, 'scheduler fallback can bypass the sandbox'
PY
[[ "$(ZF_AGENT_TEST_MODE=1 ZF_AGENT_TEST_ROOT="$TMPDIR" bash "$test_dir/agent-sandbox-run" codex read "$work" "" -- printf passthrough)" == passthrough ]]
cleanup_host_listener
trap - EXIT
printf '%s\n' 'PASS worker, review, recut and remote launch paths use the sandbox'
