#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
fake_zcode_pid=""
trap '[ -z "$fake_zcode_pid" ] || { kill "$fake_zcode_pid" 2>/dev/null || true; wait "$fake_zcode_pid" 2>/dev/null || true; }; rm -rf -- "$TMP"' EXIT
AGENT_HOME="$TMP/agent"
ZF_REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
export AGENT_HOME ZF_REPO_DIR
export GITNEXUS_ANALYZE_MEMORY_CAP_MB=3440
export GITNEXUS_ANALYZE_MIN_AVAILABLE_MB=6000
export ZF_WORKTREE_ROOT="$TMP/isolated-worktrees"

source "$SCRIPT_DIR/lib.sh"

FAILED=0
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok - $desc"
  else
    echo "not ok - $desc (expected [$expected], got [$actual])"
    FAILED=1
  fi
}
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "ok - $desc"
  else
    echo "not ok - $desc (missing [$needle])"
    FAILED=1
  fi
}

GITNEXUS_REFRESH_MIN_AVAILABLE_KB="$(gitnexus_refresh_minimum_available_kb)"
assert_eq "WSL refresh floor stays at 3 GiB while analysis runs remotely" 3145728 "$GITNEXUS_REFRESH_MIN_AVAILABLE_KB"

HAND_AGENT_COUNT="$(hand_agent_process_count "$ZF_WORKTREE_ROOT/")"
assert_eq "isolated worktree scan reads hand-agent count" 0 "$HAND_AGENT_COUNT"
mkdir -p "$TMP/bin"
cat >"$TMP/bin/zcode" <<'EOF'
#!/usr/bin/env bash
exec -a "$0 -p ping --cwd $ZF_WORKTREE_ROOT/zcode-agent --mode yolo" sleep 60
EOF
chmod +x "$TMP/bin/zcode"
"$TMP/bin/zcode" -p ping --cwd "$ZF_WORKTREE_ROOT/zcode-agent" --mode yolo &
fake_zcode_pid=$!
for _ in {1..1500}; do
  HAND_AGENT_COUNT="$(hand_agent_process_count "$ZF_WORKTREE_ROOT/")"
  [ "$HAND_AGENT_COUNT" = 1 ] && break
  sleep 0.02
done
assert_eq "isolated worktree scan counts zcode hand agents" 1 "$HAND_AGENT_COUNT"
kill "$fake_zcode_pid" 2>/dev/null || true
wait "$fake_zcode_pid" 2>/dev/null || true
fake_zcode_pid=""

# Real codex shapes: a node wrapper and its vendored binary for one worktree, flags before --cd.
fake_codex_pids=()
for args in "node /x/.local/bin/codex exec --cd $ZF_WORKTREE_ROOT/codex-a -m m" \
  "/x/vendor/bin/codex exec --sandbox danger-full-access --cd $ZF_WORKTREE_ROOT/codex-a --ephemeral" \
  "/x/vendor/bin/codex exec --cd $ZF_WORKTREE_ROOT/codex-b -m m"; do
  bash -c 'exec -a "$1" sleep 60' _ "$args" &
  fake_codex_pids+=("$!")
done
for _ in {1..1500}; do
  HAND_AGENT_COUNT="$(hand_agent_process_count "$ZF_WORKTREE_ROOT/")"
  [ "$HAND_AGENT_COUNT" = 2 ] && break
  sleep 0.02
done
assert_eq "codex hand agents count once per worktree whatever the launcher" 2 "$HAND_AGENT_COUNT"
kill "${fake_codex_pids[@]}" 2>/dev/null || true
wait "${fake_codex_pids[@]}" 2>/dev/null || true

make_stale_repo() {
  local dir="$1" now="$2" stale_epoch
  stale_epoch=$((now - 3 * 60 * 60))
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email refresh-test@example.invalid
  git -C "$dir" config user.name refresh-test
  mkdir -p "$dir/packages/demo"
  printf 'base\n' > "$dir/packages/demo/a.ts"
  GIT_AUTHOR_DATE="@$stale_epoch" GIT_COMMITTER_DATE="@$stale_epoch" \
    git -C "$dir" add packages/demo/a.ts
  GIT_AUTHOR_DATE="@$stale_epoch" GIT_COMMITTER_DATE="@$stale_epoch" \
    git -C "$dir" commit -q -m base
  local indexed
  indexed="$(git -C "$dir" rev-parse HEAD)"
  printf 'changed\n' > "$dir/packages/demo/a.ts"
  GIT_AUTHOR_DATE="@$stale_epoch" GIT_COMMITTER_DATE="@$stale_epoch" \
    git -C "$dir" commit -qam stale-product-change
  printf 'newer change\n' >> "$dir/packages/demo/a.ts"
  GIT_AUTHOR_DATE="@$((now - 60))" GIT_COMMITTER_DATE="@$((now - 60))" \
    git -C "$dir" commit -qam newer-product-change
  FAKE_GITNEXUS_SHA="$(git -C "$dir" rev-parse HEAD)"
  git -C "$dir" update-ref refs/remotes/origin/main "$FAKE_GITNEXUS_SHA"
  mkdir -p "$dir/.gitnexus"
  printf '{"lastCommit":"%s"}\n' "$indexed" > "$dir/.gitnexus/meta.json"
}

NOW="$(date +%s)"
RESUME_REPO="$TMP/resume-repo"
make_stale_repo "$RESUME_REPO" "$NOW"
if gitnexus_product_lag "$RESUME_REPO" "$NOW"; then LAG_STATUS=0; else LAG_STATUS=$?; fi
assert_eq "product lag counts missed product commits" 0 "$LAG_STATUS"
assert_eq "product lag counts every missed product commit" 2 "$GITNEXUS_PRODUCT_LAG_COMMITS"
assert_eq "refresh age uses first missed product commit" 3 "$GITNEXUS_PRODUCT_LAG_HOURS"
# 2026-10-08: the scheduler drain paused implement 30 minutes per stale cycle
# while its in-tick refresh failed every time. GitNexus is optional context;
# no dispatch path may wait on it.
for gated in issue-pipeline.sh night/dispatch.sh lib.sh; do
  if grep -Eq 'gitnexus_refresh_window_admit|GITNEXUS_REFRESH_WINDOW_HOLD|gitnexus-refresh-window' "$SCRIPT_DIR/$gated"; then
    echo "not ok - $gated has no GitNexus refresh drain"; FAILED=1
  else
    echo "ok - $gated has no GitNexus refresh drain"
  fi
done
if [ "$FAILED" -ne 0 ]; then exit 1; fi
echo "gitnexus-refresh-window.test.sh: PASS"
