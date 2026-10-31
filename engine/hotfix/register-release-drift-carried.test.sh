#!/usr/bin/env bash
# The writer must only record carriers that the release reader can read back.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../test-env.sh"
set +e
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d)"
failed=0
sha=0123456789abcdef0123456789abcdef01234567
check() { # name expected-rc expected-registry-line args...
  local name="$1" want_rc="$2" want_line="$3" rc; shift 3
  : > "$tmp/reg"
  bash "$here/register-release-drift-carried.sh" "$tmp/reg" c1 /app/x.js "$@" /copy 2>"$tmp/err"; rc=$?
  if [[ "$rc" != "$want_rc" ]]; then echo "not ok - $name: rc $rc, want $want_rc"; failed=1; return; fi
  if [[ -n "$want_line" ]]; then
    [[ "$(cat "$tmp/reg")" == "$want_line" ]] || { echo "not ok - $name: wrote [$(cat "$tmp/reg")]"; failed=1; return; }
  else
    [[ ! -s "$tmp/reg" ]] || { echo "not ok - $name: wrote a row"; failed=1; return; }
    grep -q '^usage:' "$tmp/err" || { echo "not ok - $name: no usage line"; failed=1; return; }
  fi
  echo "ok - $name"
}
check "PR number" 0 $'c1\t/app/x.js\t4859\t/copy' 4859
check "40-hex main SHA" 0 $'c1\t/app/x.js\tinstalled_from='"$sha"$'\t/copy' "$sha"
check "SHA combined with PRs is refused" 2 "" "$sha|4859,4874,4878"
check "PR list is refused" 2 "" "4859,4874"
check "zero is refused" 2 "" 0
check "short SHA is refused" 2 "" "${sha:0:12}"
# Distinct carriers coexist; updating one leaves the others and unrelated rows intact.
sha2=abcdef0123456789abcdef0123456789abcdef01
printf 'image\tsvc\tsha256:test\t42\nc1\t/app/other.js\t7\t/other\n' > "$tmp/reg"
register() { bash "$here/register-release-drift-carried.sh" "$tmp/reg" c1 /app/x.js "$1" "$2"; }
expect_registry() {
  if ! diff -u "$tmp/expected" "$tmp/reg"; then echo "not ok - $1"; failed=1; else echo "ok - $1"; fi
}
register 4859 /a
register 4874 /b
printf 'image\tsvc\tsha256:test\t42\nc1\t/app/other.js\t7\t/other\nc1\t/app/x.js\t4859\t/a\nc1\t/app/x.js\t4874\t/b\n' > "$tmp/expected"
expect_registry 'two PRs coexist'
register 4859 /a-new
printf 'image\tsvc\tsha256:test\t42\nc1\t/app/other.js\t7\t/other\nc1\t/app/x.js\t4874\t/b\nc1\t/app/x.js\t4859\t/a-new\n' > "$tmp/expected"
expect_registry 'upsert only the same PR'
register "$sha" /main
register 4874 /b-new
printf 'image\tsvc\tsha256:test\t42\nc1\t/app/other.js\t7\t/other\nc1\t/app/x.js\t4859\t/a-new\nc1\t/app/x.js\tinstalled_from=%s\t/main\nc1\t/app/x.js\t4874\t/b-new\n' "$sha" > "$tmp/expected"
expect_registry 'main and PR carriers coexist'
register "$sha2" /main-new
printf 'image\tsvc\tsha256:test\t42\nc1\t/app/other.js\t7\t/other\nc1\t/app/x.js\t4859\t/a-new\nc1\t/app/x.js\t4874\t/b-new\nc1\t/app/x.js\tinstalled_from=%s\t/main-new\n' "$sha2" > "$tmp/expected"
expect_registry 'new main replaces only old main'
exit "$failed"
