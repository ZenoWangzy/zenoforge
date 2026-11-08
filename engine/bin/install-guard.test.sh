#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
# 2026-11-05: workers symlinked a worktree's node_modules to the shared checkout and ran pnpm install there.
guard=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/install-guard
root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
mkdir -p "$root/real" "$root/shared/node_modules" "$root/shared/packages/p/node_modules"
for t in pnpm npm corepack; do
  printf '#!/usr/bin/env bash\necho "REAL %s $*" >> "$FAKE_LOG"\n' "$t" > "$root/real/$t"; chmod +x "$root/real/$t"
done
export FAKE_LOG="$root/log" PATH="$guard:$root/real:$PATH"
fail() { echo "FAIL: $*" >&2; exit 1; }

new_tree() { # name -> a git work tree with real dirs for node_modules
  local t="$root/$1"; mkdir -p "$t/packages/p/node_modules" "$t/node_modules"; git -C "$t" init -q; echo "$t"
}
refused() { # cmd... in cwd: rc 1, message on stderr, real tool not run
  : > "$FAKE_LOG"; local err rc=0
  err=$("$@" 2>&1 >/dev/null) || rc=$?
  [[ $rc == 1 ]] || fail "$* rc=$rc, want 1"
  grep -q 'install-guard: refusing' <<<"$err" || fail "$*: no refusal message"
  grep -q 'real directory' <<<"$err" || fail "$*: message does not say what to do"
  [[ ! -s $FAKE_LOG ]] || fail "$*: real tool ran"
}
passed() { : > "$FAKE_LOG"; "$@" || fail "$* failed"; grep -q '^REAL' "$FAKE_LOG" || fail "$*: real tool did not run"; }

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

t=$(new_tree f); rm -rf "$t/node_modules"; ln -s "$root/shared/node_modules" "$t/node_modules"
(cd "$t" && passed pnpm test && passed pnpm exec vitest run i && passed pnpm --filter p run build && passed npm run test && passed pnpm -v)
echo "ok - non-install commands pass through a symlinked node_modules"

for f in luna zc; do
  grep -q 'install-guard:' "$guard/../$f" || fail "bin/$f does not put install-guard first on the worker PATH"
done
echo "ok - bin/luna and bin/zc put install-guard on the worker PATH"
