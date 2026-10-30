#!/usr/bin/env bash
# Pipeline tests must not inherit live AGENT_* or ZF_* settings.
set -euo pipefail
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
test_env_parent="$test_host_home/.cache/zenoforge-agent-test"
case "${TMPDIR:-}" in
  /tmp/zenoforge-agent-suite-*)
    if [[ "$TMPDIR" =~ ^/tmp/zenoforge-agent-suite-[^/]+$ && -d "$TMPDIR" && ! -L "$TMPDIR" && -O "$TMPDIR" ]]; then
      test_env_real_parent="$(cd -- "$TMPDIR" 2>/dev/null && pwd -P)" || test_env_real_parent=''
      [[ "$test_env_real_parent" == "$TMPDIR" ]] && test_env_parent="$test_env_real_parent"
    fi
    ;;
esac
mkdir -p -- "$test_env_parent"
test_env_root="$(mktemp -d "$test_env_parent/zenoforge-agent-test-XXXXXX")"
export TMPDIR="$test_env_root"
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

# The local jq shim resolves its private binary and libraries through HOME.
if [[ -x "$test_host_home/.local/lib/jq.bin" ]]; then
  ln -s "$test_host_home/.local/lib/jq.bin" "$HOME/.local/lib/jq.bin"
  for library in "$test_host_home"/.local/lib/*.so*; do
    [[ -e "$library" ]] || continue
    ln -s "$library" "$HOME/.local/lib/${library##*/}"
  done
fi

MODEL_POLICY_TEST_REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
export ZF_EXECUTION_MODULE_DIR="$MODEL_POLICY_TEST_REPO/engine"
# Fake-model fixtures exercise admission without ambient host load flakiness.
export AGENT_EXECUTION_MIN_MEM_MB=1 AGENT_EXECUTION_MAX_LOAD=1000000
MODEL_POLICY_TEST_DEFAULT_FILE="$MODEL_POLICY_TEST_REPO/engine/model-policy.default.json"
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
  local src="$MODEL_POLICY_TEST_REPO/engine"
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
