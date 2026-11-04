#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../test-env.sh"
here=$(cd "$(dirname "$0")" && pwd -P)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir -p "$t/repo/packages/fruit-industry-pack" "$t/bin" "$t/config" "$t/empty" "$t/remote/tmp" "$t/remote/live"
git init -q --bare "$t/origin.git"
git init -q -b main "$t/repo"
git -C "$t/repo" config user.name fixture
git -C "$t/repo" config user.email fixture@example.invalid
printf 'same\n' > "$t/repo/packages/fruit-industry-pack/a.js"
printf 'map\n' > "$t/repo/packages/fruit-industry-pack/a.js.map"
git -C "$t/repo" add .
git -C "$t/repo" commit -qm fixture
git -C "$t/repo" remote add origin "$t/origin.git"
git -C "$t/repo" push -q -u origin main
sha=$(git -C "$t/repo" rev-parse HEAD)
# The ssh stub is the production host: it runs the shipped remote script with REMOTE=1 and a remote-side TMPDIR,
# so the docker stub can refuse any call that did not come from inside an ssh session.
cat > "$t/bin/ssh" <<'SH'
#!/usr/bin/env bash
printf 'ssh: %s\n' "$*" >> "$SSH_LOG"
words=()
for a in "$@"; do
  if [[ $a == *[[:space:]]* ]]; then read -r -a parts <<< "$a"; words+=("${parts[@]}"); else words+=("$a"); fi
done
i=0
while (( i < ${#words[@]} )) && [[ ${words[i]} != bash && ${words[i]} != rm ]]; do i=$((i + 1)); done
if [[ ${words[i]:-} == bash ]]; then
  [[ ${words[i+1]:-} == -s && ${words[i+2]:-} == -- ]] || { echo "ssh stub: unexpected remote command: $*" >&2; exit 1; }
  REMOTE=1 TMPDIR="$REMOTE_TMP" bash -s -- "${words[@]:i+3}"
else
  # The only other remote command is the idempotent staging cleanup.
  [[ ${words[i]:-} == rm && ${words[i+1]:-} == -rf && ${words[i+2]:-} == -- && ${words[i+3]:-} == /* ]] || { echo "ssh stub: unexpected remote command: $*" >&2; exit 1; }
  rm -rf -- "${words[i+3]}"
fi
SH
cat > "$t/bin/scp" <<'SH'
#!/usr/bin/env bash
printf 'scp: %s\n' "$*" >> "$SSH_LOG"
src="${@: -2:1}" dst="${@: -1}"
[[ $dst == *:* ]] && cp -- "$src" "${dst#*:}"
SH
cat > "$t/bin/docker" <<'SH'
#!/usr/bin/env bash
[[ ${REMOTE:-} == 1 ]] || { echo "docker called outside the ssh stub: $*" >&2; exit 1; }
printf 'docker: %s\n' "$*" >> "$SSH_LOG"
[[ $1 == exec && $2 == service && $3 == cat && $4 == -- ]]
cat "$LIVE/${5##*/}"
SH
cat > "$t/bin/build-fixture" <<'SH'
#!/usr/bin/env bash
printf 'build-fixture: <%s>\n' "$PWD" >> "$SSH_LOG"
mkdir -p packages/fruit-industry-pack/dist
cp packages/fruit-industry-pack/a.js packages/fruit-industry-pack/a.js.map packages/fruit-industry-pack/dist/
SH
cat > "$t/bin/pnpm" <<'SH'
#!/usr/bin/env bash
printf 'pnpm: <%s> <%s>\n' "$1" "$PWD" >> "$SSH_LOG"
[[ $* == *'run build' ]] || exit 0
mkdir -p packages/fruit-industry-pack/dist
cp packages/fruit-industry-pack/a.js packages/fruit-industry-pack/a.js.map packages/fruit-industry-pack/dist/
SH
chmod +x "$t/bin/"*
export PATH="$t/bin:$PATH" ZF_CONFIG_ROOT="$t/config" FIXTURE_REPO="$t/repo" LIVE="$t/remote/live" SSH_LOG="$t/calls" REMOTE_TMP="$t/remote/tmp"
cat > "$t/config/hotfix.json" <<'JSON'
{"apply_dist":{"host":"localship","host_env":"SHIP_HOST","repo_env":"FIXTURE_REPO","repo_home_relative":"checkout","package_dir":"packages/fruit-industry-pack","container_path":"/app/packages/fruit-industry-pack/dist","install":["true"],"build":["build-fixture"]}}
JSON
cp "$t/repo/packages/fruit-industry-pack/a.js" "$t/remote/live/a.js"
cp "$t/repo/packages/fruit-industry-pack/a.js.map" "$t/remote/live/a.js.map"
registry="$t/remote/registry"
target=/app/packages/fruit-industry-pack/dist
rows() { printf 'service\t%s/a.js\t123\t/copy/a.js\nservice\t%s/a.js.map\t123\t/copy/a.js.map\nother\t%s/a.js\t456\t/copy/other\n' "$target" "$target" "$target" > "$registry"; }
# Stub the product resolver's PR-blocking contract; ancestry is tested in that product.
resolver() { awk -F '\t' '$3 == "123" { found=1 } END { exit !found }' "$registry"; }
run() { bash "$here/hf-supersede.sh" "$@"; }
# Every build command must run on this host inside the local worktree, never under the emulated remote root.
build_local() {
  local line cwd bad=0 n=0
  while IFS= read -r line; do
    n=$((n + 1))
    cwd=${line%>} cwd=${cwd##*<}
    [[ $cwd == */tree && $cwd != "$t"/remote* ]] || bad=1
  done < <(grep -E '^(build-fixture|pnpm): ' "$SSH_LOG")
  (( n > 0 && bad == 0 ))
}
compare_remote() { grep -q '^docker: exec service cat -- /app' "$SSH_LOG"; }
rows
: > "$SSH_LOG"
run "$registry" 123 "$sha" > "$t/out"
[[ $(grep -c "carried_by=$sha" "$registry") == 2 ]]
[[ $(find "$t/remote" -maxdepth 1 -name 'registry.backup-*' | wc -l) == 1 ]]
! resolver
build_local
compare_remote
grep -Fq "bash -s -- 123 $sha $registry $target " "$SSH_LOG"
grep -Eq '^scp: -q [^ ]+/dist.tgz [^ ]+:[^ ]+/dist.tgz$' "$SSH_LOG"
printf 'ok: ssh-driven run builds locally and compares remote-side; identical rows replaced\n'
rm -f "$t/remote"/registry.backup-*
rows
printf 'different\n' > "$t/remote/live/a.js.map"
set +e
run "$registry" 123 "$sha" > "$t/out" 2>"$t/err"
rc=$?
set -e
[[ $rc == 3 ]]
grep -Fq "carried_by=$sha" "$registry"
grep -Fq "$(printf 'service\t%s/a.js.map\t123\t/copy/a.js.map' "$target")" "$registry"
grep -Fq $'DIFFERENT\tservice\t'$target'/a.js.map' "$t/out"
resolver
[[ $(find "$t/remote" -maxdepth 1 -name 'registry.backup-*' | wc -l) == 1 ]]
printf 'ok: mixed rows retain and report differing map\n'
rm -f "$t/remote"/registry.backup-*
rows
cp "$registry" "$t/before"
set +e
run --dry-run "$registry" 123 "$sha" > "$t/out"
rc=$?
set -e
[[ $rc == 3 ]]
cmp "$registry" "$t/before"
[[ $(find "$t/remote" -maxdepth 1 -name 'registry.backup-*' | wc -l) == 0 ]]
grep -q '^IDENTICAL' "$t/out"
grep -q '^DIFFERENT' "$t/out"
printf 'ok: dry run leaves registry and backups unchanged\n'
rows
cp "$registry" "$t/before"
printf 'service\t/app/other/x.js\t123\t/copy/x.js\n' >> "$registry"
set +e
run "$registry" 123 "$sha" > "$t/out" 2>"$t/err"
rc=$?
set -e
[[ $rc == 1 && $(grep -c 'out-of-scope row' "$t/err") == 1 ]]
cmp <(grep -v '/app/other/x.js' "$registry") "$t/before"
[[ $(find "$t/remote" -maxdepth 1 -name 'registry.backup-*' | wc -l) == 0 ]]
printf 'ok: out-of-scope row aborts without editing\n'
rows
cp "$registry" "$t/before"
rm "$t/remote/live/a.js.map"
set +e
run "$registry" 123 "$sha" > "$t/out" 2>"$t/err"
rc=$?
set -e
[[ $rc == 1 && $(grep -c 'cannot read service' "$t/err") == 1 ]]
cmp "$registry" "$t/before"
[[ $(find "$t/remote" -maxdepth 1 -name 'registry.backup-*' | wc -l) == 0 ]]
printf 'ok: unreadable live file aborts without editing\n'
cp "$t/repo/packages/fruit-industry-pack/a.js.map" "$t/remote/live/a.js.map"
bogus=$(printf 'a%.0s' {1..40})
: > "$SSH_LOG"
set +e
run "$registry" 123 "$bogus" > "$t/out" 2>"$t/err"
rc=$?
set -e
[[ $rc == 1 && $(grep -c 'SHA is not on main' "$t/err") == 1 ]]
[[ ! -s $SSH_LOG ]]
printf 'ok: off-main SHA aborts before any ssh traffic\n'
# The shipped engine default (no config-root or pack hotfix.json) must drive the whole run by itself.
rows
: > "$SSH_LOG"
env ZF_CONFIG_ROOT="$t/empty" VECTA_REPO_DIR="$t/repo" ZF_PROD_SSH=ship2 bash "$here/hf-supersede.sh" "$registry" 123 "$sha" > "$t/out"
[[ $(grep -c "carried_by=$sha" "$registry") == 2 ]]
grep -q '^pnpm: <install> ' "$SSH_LOG"
grep -q '^pnpm: <--filter> ' "$SSH_LOG"
grep -q '^ssh: -o ConnectTimeout=8 ship2 bash -s -- 123' "$SSH_LOG"
build_local
compare_remote
printf 'ok: engine default hotfix.json builds locally and ships to the configured host\n'
