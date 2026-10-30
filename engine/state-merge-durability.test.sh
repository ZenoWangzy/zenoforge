#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
trap 'rm -rf -- "$test_env_root"' EXIT
export ZF_REPO_DIR="$MODEL_POLICY_TEST_REPO" REPO=test/repo
mkdir -p "$AGENT_HOME/state" "$test_env_root/python"
jq ".roles.advisor.disabled = false" "$script_dir/model-policy.default.json" > "$AGENT_HOME/model-policy.json"
source "$script_dir/lib.sh"
printf '%s\n' '{"attempts":0}' > "$STATE_DIR/19992.json"
# Observe real syscalls and inject a failed pre-rename flush, without killing a host.
cat > "$test_env_root/python/sitecustomize.py" <<'PY'
import os, stat
original_fsync, original_replace = os.fsync, os.replace

def fsync(fd):
    kind = 'directory' if stat.S_ISDIR(os.fstat(fd).st_mode) else 'file'
    with open(os.environ['FLUSH_LOG'], 'a') as log:
        log.write(kind + '\n')
    if os.environ.get('FAIL_FILE_FLUSH') == '1' and kind == 'file':
        raise OSError('injected file flush failure')
    return original_fsync(fd)

def replace(source, target):
    with open(os.environ['FLUSH_LOG'], 'a') as log:
        log.write('replace\n')
    return original_replace(source, target)

os.fsync, os.replace = fsync, replace
PY
export PYTHONPATH="$test_env_root/python" FLUSH_LOG="$test_env_root/flush.log"
state_merge 19992 '.attempts += 1'
[[ "$(cat "$FLUSH_LOG" 2>/dev/null)" == $'file\nreplace\ndirectory' ]]
[[ "$(jq -r .attempts "$STATE_DIR/19992.json")" == 1 ]]
echo 'ok - issue state flushes file before rename and directory after rename'
cp "$STATE_DIR/19992.json" "$test_env_root/before.json"
: > "$FLUSH_LOG"
export FAIL_FILE_FLUSH=1
if state_merge 19992 '.attempts += 1' > /dev/null 2> "$test_env_root/failure.log"; then
  echo 'not ok - failed flush was accepted' >&2; exit 1
fi
cmp "$test_env_root/before.json" "$STATE_DIR/19992.json"
[[ "$(cat "$FLUSH_LOG")" == file ]]
echo 'ok - failed file flush leaves previous valid state unchanged'
unset FAIL_FILE_FLUSH
if state_merge 19992 'invalid jq filter' > /dev/null 2>&1; then exit 1; fi
cmp "$test_env_root/before.json" "$STATE_DIR/19992.json"
echo 'ok - failed JSON merge leaves previous valid state unchanged'
