#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/test-env.sh"
engine="$(cd "$(dirname "$0")" && pwd -P)"
export ZF_ENGINE_DIR="$engine" ZF_CONFIG_ROOT="$TMPDIR/config" ZF_PACK_DIR="$TMPDIR/pack"
mkdir -p "$ZF_CONFIG_ROOT" "$ZF_PACK_DIR" "$TMPDIR/repo"
source "$engine/config.sh"
source "$engine/lib-migration-gate.sh"
REPO=example/repo
REPO_DIR="$TMPDIR/repo"
git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" config user.name test
git -C "$REPO_DIR" config user.email test@example.invalid
cat > "$ZF_CONFIG_ROOT/release.json" <<'JSON'
{"migration":{"path":"migrations","renumber":"scripts/renumber.mjs","prEnvironment":"TEST_PR","gitUserName":"test","gitUserEmail":"test@example.invalid","commitMessage":"assign numbers","gitUserNameEnvironment":"TEST_GIT_NAME","gitUserEmailEnvironment":"TEST_GIT_EMAIL"}}
JSON
mkdir -p "$REPO_DIR/scripts"
cat > "$REPO_DIR/scripts/renumber.mjs" <<'JS'
import { appendFileSync } from 'node:fs';
appendFileSync(process.env.CALL_LOG, `target ${process.env.TEST_PR} ${process.argv.slice(2).join(' ')}\n`);
JS
cat > "$ZF_PACK_DIR/fruit-migration-renumber.mjs" <<'JS'
import { appendFileSync } from 'node:fs';
appendFileSync(process.env.CALL_LOG, `pack ${process.env.TEST_PR} ${process.argv.slice(2).join(' ')}\n`);
JS
export CALL_LOG="$TMPDIR/calls"
git -C "$REPO_DIR" add scripts
git -C "$REPO_DIR" commit -qm initial
head_oid="$(git -C "$REPO_DIR" rev-parse HEAD)"
git -C "$REPO_DIR" update-ref refs/remotes/origin/branch "$head_oid"
gh() { printf '{"changedFiles":1,"headRefName":"branch","headRefOid":"%s","files":[{"path":"migrations/0001_test.sql"}]}\n' "$head_oid"; }
git_fetch_bounded() { :; }
worktree_lifecycle_finish() { git -C "$2" worktree remove --force "$1"; }
check_agent_pr_migration_numbers 42 "$head_oid"
grep -qx 'target 42 --check' "$CALL_LOG"
pack_rebase_hook "$REPO_DIR" 42
tail -n 2 "$CALL_LOG" | diff -u <(printf 'target 42 \ntarget 42 --check\n') -
# A configured script absent from this checkout falls back to the pack.
jq '.migration.renumber="missing.mjs"' "$ZF_CONFIG_ROOT/release.json" > "$TMPDIR/new-config"
cp "$TMPDIR/new-config" "$ZF_CONFIG_ROOT/release.json"
check_agent_pr_migration_numbers 42 "$head_oid"
tail -n 1 "$CALL_LOG" | grep -qx 'pack 42 --check'
pack_rebase_hook "$REPO_DIR" 42
tail -n 2 "$CALL_LOG" | diff -u <(printf 'pack 42 \npack 42 --check\n') -
export ZF_PACK_DIR="$TMPDIR/empty"
mkdir -p "$ZF_PACK_DIR"
if check_agent_pr_migration_numbers 42 "$head_oid"; then exit 1; else [[ $? == 2 ]]; fi
if pack_rebase_hook "$REPO_DIR" 42; then exit 1; fi
printf 'migration gate call sites passed\n'
