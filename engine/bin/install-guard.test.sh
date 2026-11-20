#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
# 2026-11-05: workers symlinked a worktree's node_modules to the shared checkout and ran pnpm install there.
guard=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/install-guard
root="$test_env_root/install-guard"; mkdir -p "$root"
mkdir -p "$root/real" "$root/shared/node_modules" "$root/shared/packages/p/node_modules"
for t in pnpm npm corepack npx vitest node bash; do
  if [[ "$t" == bash ]]; then
    cat > "$root/real/$t" <<'SH'
#!/bin/sh
case "${1:-}" in "$GUARD_DIR"/*) exec /bin/bash "$@" ;; esac
printf 'REAL %s' "${0##*/}" >> "$FAKE_LOG"
printf ' %s' "$@" >> "$FAKE_LOG"
printf '\n' >> "$FAKE_LOG"
exit 0
SH
  else
    cat > "$root/real/$t" <<'SH'
#!/bin/sh
printf 'REAL %s' "${0##*/}" >> "$FAKE_LOG"
printf ' %s' "$@" >> "$FAKE_LOG"
printf '\n' >> "$FAKE_LOG"
SH
  fi
  chmod +x "$root/real/$t"
done
export FAKE_LOG="$root/log" GUARD_DIR="$guard" PATH="$guard:$root/real:$PATH"
export WORKER_SCRATCH_ROOT="$root/scratch"
export TMPDIR="$WORKER_SCRATCH_ROOT/tmp/test-key"
mkdir -p "$TMPDIR" "$root/no-config"
export ZF_CONFIG_ROOT="$root/no-config"
suite_log="$TMPDIR/suite-guard.log"
fail() { echo "install-guard.test.sh: $*" >&2; exit 1; }

new_tree() { # name -> a git work tree with real dirs for node_modules
  local t="$root/$1"; mkdir -p "$t/packages/p/node_modules" "$t/node_modules"; git -C "$t" init -q; echo "$t"
}
refused() { # install: rc 1, message on stderr, real tool not run
  : > "$FAKE_LOG"; local err rc=0
  err=$("$@" 2>&1 >/dev/null) || rc=$?
  [[ $rc == 1 ]] || fail "$* rc=$rc, want 1"
  grep -q 'install-guard: refusing' <<<"$err" || fail "$*: no refusal message"
  grep -q 'real directory' <<<"$err" || fail "$*: message does not say what to do"
  [[ ! -s $FAKE_LOG ]] || fail "$*: real tool ran"
}
passed() { : > "$FAKE_LOG"; "$@" || fail "$* failed"; grep -q '^REAL ' "$FAKE_LOG" || fail "$*: real tool did not run"; }
routed() { # selected test: the configured runner gets the worktree and original argv
  : > "$FAKE_LOG"; : > "$RUNNER_LOG"
  ZF_TEST_EXEC="$root/test-exec" "$@" || fail "$* did not route successfully"
  grep -Fxq "WORKTREE=$PWD" "$RUNNER_LOG" || fail "$*: runner got the wrong worktree"
  local arg; for arg in "$@"; do grep -Fxq "ARG=$arg" "$RUNNER_LOG" || fail "$*: runner missed argv $arg"; done
  ! grep -q '^REAL ' "$FAKE_LOG" || fail "$*: command ran locally"
}
whole_suite_refused() { # suite command: rc 64, ruling printed and one refusal logged
  : > "$FAKE_LOG"; local before after rc=0
  before=$(grep -c '^suite-guard refused ' "$suite_log" 2>/dev/null || true)
  "$@" >"$root/stdout" 2>"$root/stderr" || rc=$?
  [[ $rc == 64 ]] || fail "$* rc=$rc, want 64"
  grep -Fxq 'zenoforge: whole-suite test run refused for luna workers (head ruling 2026-11-20): name the test files you changed and their related tests, e.g. `pnpm vitest run path/to/x.test.ts`. CI runs the full suite.' "$root/stderr" \
    || fail "$*: refusal message is missing or changed"
  [[ ! -s $FAKE_LOG ]] || fail "$*: real command ran"
  after=$(grep -c '^suite-guard refused ' "$suite_log" 2>/dev/null || true)
  [[ $after == $((before + 1)) ]] || fail "$*: did not append one refusal line to $suite_log"
}

t=$(new_tree a); (cd "$t" && passed pnpm install --frozen-lockfile && passed npm ci && passed corepack pnpm install)
echo "ok - real node_modules dirs install"

t=$(new_tree b); rm -rf "$t/node_modules"; ln -s "$root/shared/node_modules" "$t/node_modules"
(cd "$t" && refused pnpm install --frozen-lockfile --prefer-offline && refused pnpm i && refused pnpm add left-pad \
  && refused npm install && refused npm ci && refused corepack pnpm install)
echo "ok - symlinked root node_modules refused for pnpm, npm and corepack"

t=$(new_tree c); rm -rf "$t/packages/p/node_modules"; ln -s "$root/shared/packages/p/node_modules" "$t/packages/p/node_modules"
(cd "$t" && refused pnpm install --filter p... --prefer-offline && refused pnpm --filter p install \
  && cd packages/p && refused pnpm install)
echo "ok - package-level symlink refused, also with --filter and from a subdirectory"

t=$(new_tree d); rm -rf "$t/node_modules"; ln -s "$root/gone" "$t/node_modules"
(cd "$t" && refused pnpm install)
echo "ok - dangling symlink refused"

t=$(new_tree e); mkdir -p "$root/elsewhere/p"; rm -rf "$t/packages/p"; ln -s "$root/elsewhere/p" "$t/packages/p"; mkdir "$root/elsewhere/p/node_modules"
(cd "$t" && refused pnpm install)
echo "ok - node_modules under a symlinked parent resolves outside and is refused"

t=$(new_tree f); mkdir -p "$t/packages/a"; : > "$t/packages/a/x.test.ts"; : > "$t/packages/a/x.test.sh"; : > "$t/packages/a/existing.js"
(cd "$t" && whole_suite_refused pnpm test && whole_suite_refused pnpm run test && whole_suite_refused pnpm -r test \
  && whole_suite_refused pnpm --filter fruit-industry-pack test \
  && whole_suite_refused pnpm --filter fruit-industry-pack run test \
  && whole_suite_refused pnpm exec vitest && whole_suite_refused pnpm exec vitest run \
  && whole_suite_refused pnpm vitest && whole_suite_refused pnpm vitest run \
  && whole_suite_refused npm test && whole_suite_refused npm run test \
  && whole_suite_refused npx vitest run && whole_suite_refused vitest run \
  && whole_suite_refused node --test \
  && whole_suite_refused corepack pnpm test && whole_suite_refused bash -c 'pnpm test' \
  && whole_suite_refused bash -c 'pnpm test --changed' \
  && whole_suite_refused bash -c 'for f in packages/a/*.test.sh; do bash "$f"; done')
echo "ok - whole-suite test commands refused and counted"

(cd "$t" && passed pnpm vitest run packages/a/x.test.ts && passed pnpm --filter fruit-industry-pack run test packages/a/x.test.ts \
  && passed pnpm exec vitest run packages/a/x.test.ts && passed pnpm vitest --related packages/a/x.test.ts \
  && passed pnpm vitest --changed && passed npm test packages/a/x.test.ts \
  && passed npm run test -- packages/a/x.test.ts && passed npx vitest run packages/a/x.test.ts \
  && passed vitest run packages/a/x.test.ts && passed node --test packages/a/x.test.ts \
  && passed pnpm test packages/a/existing.js && passed bash packages/a/x.test.sh \
  && passed bash -c 'bash packages/a/x.test.sh' && passed pnpm install && passed pnpm build)
echo "ok - selected tests, installs and non-test commands pass through"

cat > "$root/test-exec" <<'SH'
#!/bin/sh
printf 'WORKTREE=%s\n' "$1" >> "$RUNNER_LOG"
shift
for arg do printf 'ARG=%s\n' "$arg" >> "$RUNNER_LOG"; done
exit "${RUNNER_RC:-0}"
SH
chmod +x "$root/test-exec"
export RUNNER_LOG="$root/runner.log"
(cd "$t" && : > "$RUNNER_LOG" && : > "$FAKE_LOG" \
  && routed pnpm vitest run packages/a/x.test.ts \
  && routed npm test packages/a/x.test.ts \
  && routed npx vitest run packages/a/x.test.ts \
  && routed vitest run packages/a/x.test.ts \
  && routed node --test packages/a/x.test.ts \
  && routed bash packages/a/x.test.sh \
  && routed bash -c 'bash packages/a/x.test.sh' \
  && routed bash -c 'pnpm vitest run packages/a/x.test.ts' \
  && routed bash -c 'pnpm vitest --changed') \
  || fail 'ZF_TEST_EXEC did not receive the selected command and worktree'
mkdir -p "$root/config"; printf '{"engine":{"test_exec":"%s"}}\n' "$root/test-exec" > "$root/config/config.json"
(cd "$t" && : > "$RUNNER_LOG" && ZF_CONFIG_ROOT="$root/config" pnpm vitest run packages/a/x.test.ts \
  && grep -Fxq "WORKTREE=$t" "$RUNNER_LOG") || fail 'engine.test_exec config did not route the test'
for runner_rc in 75 125; do
  rc=0
  (cd "$t" && RUNNER_RC="$runner_rc" ZF_TEST_EXEC="$root/test-exec" pnpm vitest run packages/a/x.test.ts) \
    >"$root/stdout" 2>"$root/stderr" || rc=$?
  [[ $rc == "$runner_rc" ]] || fail "runner exit $runner_rc became $rc"
  grep -Fxq "zenoforge: test host unavailable (runner exit $runner_rc); not running tests locally" "$root/stderr" \
    || fail "runner exit $runner_rc did not explain why local tests were skipped"
  [[ ! -s $FAKE_LOG ]] || fail "runner exit $runner_rc fell back to a local command"
done
(cd "$t" && ZF_ALLOW_WHOLE_SUITE=1 ZF_TEST_EXEC="$root/test-exec" pnpm test)
grep -q '^suite-guard allowed-by-override ' "$suite_log" || fail 'whole-suite override was not logged as allowed-by-override'
echo "ok - configured and override test runners are honored without local fallback"

(cd "$t" && whole_suite_refused pnpm test && passed pnpm build)
echo "ok - non-test commands remain available"

for f in luna zc; do
  grep -q 'install-guard:' "$guard/../$f" || fail "bin/$f does not put install-guard first on the worker PATH"
done
echo "ok - bin/luna and bin/zc put install-guard on the PATH"

[[ -z $(find "$guard" -type l) ]] || fail "install-guard holds a symlink: npm pack drops them (cli test 34)"
echo "ok - install-guard has no symlinks"
