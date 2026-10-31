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
# Image upsert preserves retained rows byte-for-byte, including a CRLF file row,
# keeps other services' images, and appends the new image row.
printf 'c1\t/app/one.js\tinstalled_from=%s\t/copy-one\r\nimage\tservice-a\tsha256:a\t124\nc2\t/app/two.js\tinstalled_from=%s\t/copy-two\nimage\tother-service\tsha256:other\t125\n' "$sha" "$sha" > "$tmp/reg"
printf 'c1\t/app/one.js\tinstalled_from=%s\t/copy-one\r\nc2\t/app/two.js\tinstalled_from=%s\t/copy-two\nimage\tother-service\tsha256:other\t125\nimage\tservice-a\tsha256:a\t123\n' "$sha" "$sha" > "$tmp/expected"
if (cd -- "$tmp" && bash "$here/register-release-drift-carried.sh" --image "$tmp/reg" service-a sha256:a 123) 2>"$tmp/err"; then
  :
else
  rc=$?
  echo "not ok - image upsert: rc $rc, want 0"
  failed=1
fi
if ! cmp -s "$tmp/expected" "$tmp/reg"; then
  echo 'not ok - image upsert: retained bytes or appended row differ'
  failed=1
else
  echo 'ok - image upsert preserves file rows and other image services'
fi
if ! awk -F '\t' '$1 == "image" && $2 == "service-a" { n++; good = ($3 == "sha256:a" && $4 == "123") } END { exit !(n == 1 && good) }' "$tmp/reg"; then
  echo 'not ok - image upsert: service-a does not have exactly one PR 123 row'
  failed=1
fi
if ! awk -F '\t' '$1 == "image" && $2 == "other-service" && $3 == "sha256:other" && $4 == "125" { found = 1 } END { exit !found }' "$tmp/reg"; then
  echo 'not ok - image upsert: another service image row was not kept'
  failed=1
fi
printf 'future-format\tunknown\r\nimage\tservice-a\tsha256:old\t124\n' > "$tmp/unknown-reg"
printf 'future-format\tunknown\r\nimage\tservice-a\tsha256:new\t123\n' > "$tmp/unknown-expected"
if (cd -- "$tmp" && bash "$here/register-release-drift-carried.sh" --image "$tmp/unknown-reg" service-a sha256:new 123) 2>"$tmp/err" \
  && cmp -s "$tmp/unknown-expected" "$tmp/unknown-reg"; then
  echo 'ok - image upsert preserves unknown rows byte-for-byte'
else
  echo 'not ok - image upsert changed an unknown row'
  failed=1
fi

cp "$tmp/reg" "$tmp/reg.snapshot"
check_bad_image() { # name service image-id PR
  local name="$1" service="$2" image_id="$3" pr="$4" rc
  if (cd -- "$tmp" && bash "$here/register-release-drift-carried.sh" --image "$tmp/reg" "$service" "$image_id" "$pr") 2>"$tmp/err"; then
    rc=0
  else
    rc=$?
  fi
  if [[ "$rc" != 2 ]]; then echo "not ok - $name: rc $rc, want 2"; failed=1; return; fi
  if ! cmp -s "$tmp/reg.snapshot" "$tmp/reg"; then echo "not ok - $name: registry changed"; failed=1; return; fi
  if ! grep -q '^usage: .*--image' "$tmp/err"; then echo "not ok - $name: no image usage line"; failed=1; return; fi
  if ! grep -q 'main SHA is not accepted' "$tmp/err"; then echo "not ok - $name: usage does not reject main SHA"; failed=1; return; fi
  echo "ok - $name"
}
check_bad_image 'bad image id is rejected without mutation' service-a sha256: 123
check_bad_image 'image main SHA is rejected without mutation' service-a sha256:a "$sha"
check_bad_image 'bad image service is rejected without mutation' 'bad/service' sha256:a 123

exit "$failed"
