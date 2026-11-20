#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
unset CODEX_HOME
WORKTREE="$test_env_root/worktrees/current"
OTHER_WORKTREE="$HOME/worktrees/other"
mkdir -p "$WORKTREE" "$OTHER_WORKTREE" "$HOME/.config/gh" "$HOME/.codex" "$HOME/.zcode/v2"
mkdir -p "$test_env_root/guard-root" "$test_env_root/supervisor"
printf 'credential=host\n' > "$HOME/.git-credentials"
cat > "$HOME/.gitconfig" <<'EOF'
[user]
  name = Scope Probe
  email = scope-probe@example.invalid
[http "https://example.invalid"]
  extraheader = Authorization: Bearer host-login-secret
EOF
printf 'secret=other-provider\n' > "$HOME/.codex/auth.json"
printf 'secret=other-provider\n' > "$HOME/.zcode/v2/provider_config.json"
printf 'secret=github\n' > "$HOME/.config/gh/hosts.yml"
printf 'private source\n' > "$OTHER_WORKTREE/README"
printf 'assigned source\n' > "$WORKTREE/README"
printf 'protected\n' > "$test_env_root/guard-root/state.json"
export ZF_WORKER_WRITE_GUARD_ROOT="$test_env_root/guard-root"
export ZF_WORKER_WRITE_GUARD_ALLOW="$test_env_root/supervisor"
export PYTHONPATH="$SCRIPT_DIR/worker-write-guard${PYTHONPATH:+:$PYTHONPATH}"
export NODE_OPTIONS="--require=$SCRIPT_DIR/worker-write-guard/node-guard.cjs${NODE_OPTIONS:+ $NODE_OPTIONS}"

probe='import errno, pathlib, subprocess, sys
import os
protected, allowed, expected_uid = sys.argv[-3], sys.argv[-2], int(sys.argv[-1])
if os.getuid() != expected_uid:
    print(f"FAIL worker uid {os.getuid()}, expected {expected_uid}", file=sys.stderr)
    raise SystemExit(1)
for name in sys.argv[1:-3]:
    try:
        pathlib.Path(name).read_bytes()
    except OSError as error:
        if error.errno != errno.EACCES:
            print(f"FAIL {name}: errno {error.errno}, expected EACCES", file=sys.stderr)
            raise SystemExit(1)
        print(f"PASS denied {name}")
    else:
        print(f"FAIL readable: {name}", file=sys.stderr)
        raise SystemExit(1)
email = subprocess.check_output(["git", "config", "--global", "--get", "user.email"], text=True).strip()
if email != "scope-probe@example.invalid":
    print(f"FAIL scoped git identity {email!r}", file=sys.stderr)
    raise SystemExit(1)
print("PASS scoped git identity preserved")
try:
    pathlib.Path(protected).write_text("escape\n")
except OSError as error:
    if error.errno != errno.EACCES:
        print(f"FAIL protected write: errno {error.errno}, expected EACCES", file=sys.stderr)
        raise SystemExit(1)
    print(f"PASS denied write {protected}")
else:
    print(f"FAIL writable protected path: {protected}", file=sys.stderr)
    raise SystemExit(1)
pathlib.Path(allowed).write_text("report\n")
print("PASS supervisor scratch writable")
pathlib.Path("README").write_text("worktree remains writable\\n")
print("PASS assigned worktree writable")'

"$SCRIPT_DIR/worker-sandbox.py" --cwd "$WORKTREE" --provider none -- \
  python3 -c "$probe" \
  "$HOME/.git-credentials" \
  "$HOME/.gitconfig" \
  "$OTHER_WORKTREE/README" \
  "$HOME/.codex/auth.json" \
  "$HOME/.zcode/v2/provider_config.json" \
  "$HOME/.config/gh/hosts.yml" \
  "$ZF_WORKER_WRITE_GUARD_ROOT/state.json" \
  "$ZF_WORKER_WRITE_GUARD_ROOT/state.json" \
  "$ZF_WORKER_WRITE_GUARD_ALLOW/report.md" \
  "$EUID"

cat > "$test_env_bin/codex" <<'SH'
#!/usr/bin/env bash
exec python3 "$@"
SH
chmod +x "$test_env_bin/codex"
source "$SCRIPT_DIR/mac-autopilot/scheduler.d/worker-scope.sh"
WORKER_SCOPE_PREPARED=true WORKER_SCOPE_MODE=disabled
worker_scope_launch "$test_env_root/worker.pid" "$WORKTREE" "$test_env_root/worker.out" -- \
  codex -c "$probe" \
  "$HOME/.git-credentials" \
  "$HOME/.gitconfig" \
  "$OTHER_WORKTREE/README" \
  "$HOME/.zcode/v2/provider_config.json" \
  "$HOME/.config/gh/hosts.yml" \
  "$ZF_WORKER_WRITE_GUARD_ROOT/state.json" \
  "$ZF_WORKER_WRITE_GUARD_ALLOW/report.md" \
  "$EUID"
wait "$WORKER_SCOPE_PID"
grep -q '^PASS denied ' "$test_env_root/worker.out"
grep -q '^PASS assigned worktree writable$' "$test_env_root/worker.out"
grep -q '^PASS supervisor scratch writable$' "$test_env_root/worker.out"
echo "PASS scheduler worker launcher applies the filesystem scope"

for launch_file in \
  engine/bin/zc \
  engine/dispatch-codex.sh \
  engine/eval/stage-call.sh \
  engine/lib.d/model-calls.sh \
  engine/mac-autopilot/scheduler.d/worker-scope.sh \
  engine/night/dispatch.sh; do
  grep -Fq 'worker-sandbox.py' "$SCRIPT_DIR/../$launch_file" \
    || { echo "FAIL $launch_file bypasses the worker sandbox launcher" >&2; exit 1; }
done
echo "PASS direct worker starts route through the shared sandbox launcher"
