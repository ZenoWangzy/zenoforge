#!/usr/bin/env bash
# Pipeline tests must not inherit live AGENT_* or ZF_* settings.
set -euo pipefail
# Check before the AGENT_/ZF_ purge so a child cannot silently nest. HOME is the signal:
# the eval grader sets ZF_AGENT_TEST_MODE itself before it runs a suite from a host HOME.
case "${HOME:-}" in
  */zenoforge-agent-test-*/home|*/zenoforge-agent-test-*/home/*)
    echo 'test-env: refusing nested test environment' >&2
    return 1 2>/dev/null || exit 1
    ;;
esac
TEST_ENV_HOST_HOME="${HOME:-}"
TEST_ENV_HOST_PATH="$PATH"
export TEST_ENV_HOST_HOME TEST_ENV_HOST_PATH

# Start an independent suite without carrying fixture executables or the test HOME.
test_env_run_clean() {
  env -u ZF_AGENT_TEST_MODE -u ZF_AGENT_TEST_ROOT HOME="$TEST_ENV_HOST_HOME" PATH="$TEST_ENV_HOST_PATH" TEST_ENV_PARENT="$TEST_ENV_NESTED_PARENT" "$@"
}

# Resolve before shadowing PATH; reject the stub itself, including hard links.
test_env_resolve_node() {
  local node
  node="$(type -P node)" || { echo 'test-env: node not found' >&2; return 1; }
  node="$(cd -- "$(dirname -- "$node")" && pwd -P)/${node##*/}"
  if [[ -e "$1" && "$node" -ef "$1" ]]; then
    echo 'test-env: refusing node stub as real node' >&2
    return 1
  fi
  printf '%s\n' "$node"
}

unset LC_ALL LANGUAGE
export LANG=en_US.UTF-8

while IFS= read -r name; do
  case "$name" in
    AGENT_*|ZF_*) unset "$name" ;;
  esac
done < <(compgen -e)
# land-queue.sh runs the lander's preflight with these; land-direct-main.test.sh
# then took the queued ticket's PLAN_PACKAGE instead of its fixture branch.
unset PLAN_PACKAGE REPO_DIR HAND_PRIORITY_STATE
# A hook/gate exports GIT_DIR; a fixture's `git init --bare` then re-inits the shared
# live .git as bare (10-29 18:01Z and 18:17Z flipped core.bare on ~/.zenoforge/checkout).
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR

test_host_home="${HOME:-}"
# A clean child keeps its root inside the parent's root so the parent's cleanup removes it.
test_env_parent="${TEST_ENV_PARENT:-$test_host_home/.cache/zenoforge-agent-test}"
unset TEST_ENV_PARENT
case "${TMPDIR:-}" in
  /tmp/zenoforge-agent-suite-*)
    if [[ "$TMPDIR" =~ ^/tmp/zenoforge-agent-suite-[^/]+$ && -d "$TMPDIR" && ! -L "$TMPDIR" && -O "$TMPDIR" ]]; then
      test_env_real_parent="$(cd -- "$TMPDIR" 2>/dev/null && pwd -P)" || test_env_real_parent=''
      [[ "$test_env_real_parent" == "$TMPDIR" ]] && test_env_parent="$test_env_real_parent"
    fi
    ;;
esac
# A run killed before its exit trap leaves its root behind; roots older than a day are never live.
test_env_prune_old_roots() {
  local parent="${1:-}"
  [[ -n "$parent" && "$parent" != / && "$parent" != "$test_host_home" && "$parent" != "${HOME:-}" ]] || return 0
  find "$parent" -mindepth 1 -maxdepth 1 -type d -name 'zenoforge-agent-test-*' -mmin +1440 -exec rm -rf -- {} + 2>/dev/null || :
}
mkdir -p -- "$test_env_parent"
test_env_prune_old_roots "$test_env_parent"
test_env_root="$(mktemp -d "$test_env_parent/zenoforge-agent-test-XXXXXX")"
# The root goes on exit. A caller's EXIT trap set before this file runs first, so it keeps working.
eval "test_env_prior_exit=$(trap -p EXIT | sed -n 's/^trap -- //; s/ EXIT$//p')"
test_env_chain_exit() {
  if [[ -n "${2:-}" ]]; then eval "$2" || true; fi
  rm -rf -- "$1"
}
trap "test_env_chain_exit $(printf %q "$test_env_root") $(printf %q "$test_env_prior_exit")" EXIT
export TMPDIR="$test_env_root"
export TEST_ENV_NESTED_PARENT="$test_env_root/children"
export HOME="$test_env_root/home"
export AGENT_HOME="$test_env_root/agent"
export ZF_AGENT_TEST_MODE=1 ZF_AGENT_TEST_ROOT="$test_env_root"
# Fixtures name this placeholder repository; the engine reads the target repository from ZF_REPO.
export ZF_REPO="${ZF_REPO:-example-maintainer/example-repo}"
test_env_bin="$test_env_root/bin"
mkdir -p "$HOME/.local/lib" "$AGENT_HOME" "$test_env_bin"
cat > "$test_env_bin/codex" <<'EOF'
#!/usr/bin/env bash
printf 'real codex call in test: %s\n' "$*" >&2
exit 97
EOF
chmod +x "$test_env_bin/codex"
export PATH="$test_env_bin:$PATH"
# A self-exec chain must fail its own fork, not take the host down: 11-06 a node chain reached 2016 processes at 18 a second.
# The limit counts every task of this user, threads included, so it sits above what is running now.
test_env_tasks="$(ps -eLo uid= 2>/dev/null | grep -c "^ *$(id -u)\$" || :)"
if [[ "$(uname -s)" == Linux && "$test_env_tasks" =~ ^[1-9][0-9]*$ ]]; then
  test_env_task_limit="$(ulimit -Su)"
  if [[ "$test_env_task_limit" == unlimited ]] || (( test_env_task_limit > test_env_tasks + 4000 )); then
    ulimit -Su "$(( test_env_tasks + 4000 ))" 2>/dev/null || :
  fi
fi

# The local jq shim resolves its private binary and libraries through HOME.
if [[ -x "$test_host_home/.local/lib/jq.bin" ]]; then
  ln -s "$test_host_home/.local/lib/jq.bin" "$HOME/.local/lib/jq.bin"
  for library in "$test_host_home"/.local/lib/*.so*; do
    [[ -e "$library" ]] || continue
    ln -s "$library" "$HOME/.local/lib/${library##*/}"
  done
fi

MODEL_POLICY_TEST_ENGINE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
MODEL_POLICY_TEST_REPO="$(cd -- "$MODEL_POLICY_TEST_ENGINE/.." && pwd -P)"
export ZF_EXECUTION_MODULE_DIR="$MODEL_POLICY_TEST_ENGINE"
# Fake-model fixtures exercise admission without ambient host load flakiness.
export AGENT_EXECUTION_MIN_MEM_MB=1 AGENT_EXECUTION_MAX_LOAD=1000000
MODEL_POLICY_TEST_DEFAULT_FILE="$MODEL_POLICY_TEST_ENGINE/model-policy.default.json"
MODEL_POLICY_TEST_WORK_MODEL="$(jq -r '.roles.work.model' "$MODEL_POLICY_TEST_DEFAULT_FILE")"
MODEL_POLICY_TEST_WORK_EFFORT="$(jq -r '.roles.work.effort' "$MODEL_POLICY_TEST_DEFAULT_FILE")"
MODEL_POLICY_TEST_WORK_IDENTITY="codex:$MODEL_POLICY_TEST_WORK_MODEL:$MODEL_POLICY_TEST_WORK_EFFORT"
MODEL_POLICY_TEST_WORK_TIER="$(jq -r '.roles.work.service_tier // empty' "$MODEL_POLICY_TEST_DEFAULT_FILE")"
MODEL_POLICY_TEST_PRODUCTION_MODEL="$(jq -r '.roles.production.model' "$MODEL_POLICY_TEST_DEFAULT_FILE")"
MODEL_POLICY_TEST_PRODUCTION_EFFORT="$(jq -r '.roles.production.effort' "$MODEL_POLICY_TEST_DEFAULT_FILE")"
MODEL_POLICY_TEST_PRODUCTION_IDENTITY="codex:$MODEL_POLICY_TEST_PRODUCTION_MODEL:$MODEL_POLICY_TEST_PRODUCTION_EFFORT"
MODEL_POLICY_TEST_PRODUCTION_TIER="$(jq -r '.roles.production.service_tier // empty' "$MODEL_POLICY_TEST_DEFAULT_FILE")"
MODEL_POLICY_TEST_ADVISOR_MODEL="$(jq -r '.roles.advisor.model' "$MODEL_POLICY_TEST_DEFAULT_FILE")"
MODEL_POLICY_TEST_ADVISOR_IDENTITY="web:$MODEL_POLICY_TEST_ADVISOR_MODEL"
MODEL_POLICY_TEST_REVIEW_PROVIDER="$(jq -r '.roles.review.provider' "$MODEL_POLICY_TEST_DEFAULT_FILE")"
MODEL_POLICY_TEST_REVIEW_MODEL="$(jq -r '.roles.review.model' "$MODEL_POLICY_TEST_DEFAULT_FILE")"
MODEL_POLICY_TEST_REVIEW_EFFORT="$(jq -r '.roles.review.effort' "$MODEL_POLICY_TEST_DEFAULT_FILE")"
MODEL_POLICY_TEST_REVIEW_IDENTITY="$MODEL_POLICY_TEST_REVIEW_PROVIDER:$MODEL_POLICY_TEST_REVIEW_MODEL:$MODEL_POLICY_TEST_REVIEW_EFFORT"
export MODEL_POLICY_TEST_REPO MODEL_POLICY_TEST_DEFAULT_FILE MODEL_POLICY_TEST_WORK_MODEL
export MODEL_POLICY_TEST_WORK_EFFORT MODEL_POLICY_TEST_WORK_IDENTITY MODEL_POLICY_TEST_WORK_TIER
export MODEL_POLICY_TEST_PRODUCTION_MODEL MODEL_POLICY_TEST_PRODUCTION_EFFORT
export MODEL_POLICY_TEST_PRODUCTION_IDENTITY MODEL_POLICY_TEST_PRODUCTION_TIER
export MODEL_POLICY_TEST_ADVISOR_MODEL MODEL_POLICY_TEST_ADVISOR_IDENTITY
export MODEL_POLICY_TEST_REVIEW_PROVIDER MODEL_POLICY_TEST_REVIEW_MODEL MODEL_POLICY_TEST_REVIEW_EFFORT
export MODEL_POLICY_TEST_REVIEW_IDENTITY

# Copy lib.sh plus every engine file it references, transitively, into
# $1 (the directory lib.sh lands in); extra args name additional roots (the
# script under test, so its own sourced helpers travel too). References are
# matched textually, suffix-resolved against engine: every load this
# repo uses spells the target as a path ending in the file name. Suite files
# (*.test.*) are skipped: lib.sh names them all in its pipeline wiring, and
# fixtures deliberately ship only the suites they write themselves. Hand-
# maintained per-fixture copy lists rotted three times already (web-advisor-provider
# provider, comms-format, closing-keywords) and each miss only surfaced as
# "No such file" in far-away suites; fixtures copy the closure through this
# helper so a new dependency travels with lib.sh automatically.
copy_agent_library() {
  local dest="$1"; shift
  local src="$MODEL_POLICY_TEST_ENGINE"
  local -a queue=("lib.sh" "proc.sh" "$@") closure=() # proc.sh: runtime-env.sh sources it, lib.sh does not
  local -A queued=()
  local file token rel
  while ((${#queue[@]})); do
    file="${queue[0]}"
    queue=("${queue[@]:1}")
    [[ -z "${queued[$file]:-}" ]] || continue
    queued["$file"]=1
    [[ -f "$src/$file" ]] || { printf 'copy_agent_library: not in engine: %s\n' "$file" >&2; return 1; }
    closure+=("$file")
    while IFS= read -r token; do
      rel="$token"
      while [[ "$rel" == */* && ! -f "$src/$rel" ]]; do rel="${rel#*/}"; done
      [[ -f "$src/$rel" ]] || continue
      [[ "$rel" == *.test.* ]] && continue
      [[ -n "${queued[$rel]:-}" ]] || queue+=("$rel")
    done < <(grep -hoE '[A-Za-z0-9_][A-Za-z0-9._-]*(/[A-Za-z0-9_][A-Za-z0-9._-]+)*\.(sh|mjs|cjs|py|jq|json)' "$src/$file" 2>/dev/null || true)
  done
  mkdir -p -- "$dest"
  for rel in "${closure[@]}"; do
    [[ "$rel" == */* ]] && mkdir -p -- "$dest/${rel%/*}"
    cp -a -- "$src/$rel" "$dest/$rel"
  done
}
