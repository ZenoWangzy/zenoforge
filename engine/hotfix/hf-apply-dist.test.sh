#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../test-env.sh"
p=$(cd "$(dirname "$0")" && pwd); t=$(mktemp -d -p "$p/../../.git")
mkdir -p "$t/engine/hotfix" "$t/bin" "$t/config" "$t/pack/hotfix" "$t/repo" "$t/work"
cp "$p/hf-apply-dist.sh" "$t/engine/hotfix/"; cp "$p/../config.sh" "$t/engine/"
printf '#!/usr/bin/env bash\nprintf "accept:%%s\\n" "$HF_SHA" >> "$CALLS"\n' > "$t/engine/hotfix/hf-accept.sh"
for c in git systemctl scp ssh tar build install restart; do
  cat > "$t/bin/$c" <<'STUB'
#!/usr/bin/env bash
case "${0##*/}" in
  systemctl) exit "${RELEASE_RC:-1}" ;;
  git)
    case "$*" in
      *'rev-parse --verify'*) printf '%040d\n' 1 ;;
      *'worktree add'*) mkdir -p "${@: -2:1}/pkg" ;;
    esac ;;
  ssh) printf 'ssh:' >> "$CALLS"; printf ' <%s>' "$@" >> "$CALLS"; printf '\n' >> "$CALLS"; cat > "$REMOTE" ;;
  *) printf '%s:' "${0##*/}" >> "$CALLS"; printf ' <%s>' "$@" >> "$CALLS"; printf '\n' >> "$CALLS" ;;
esac
STUB
done
chmod +x "$t/bin/"* "$t/engine/hotfix/"*.sh
export PATH="$t/bin:$PATH" ZF_CONFIG_ROOT=$t/config ZF_PACK_DIR=$t/pack ZF_REPO_DIR=$t/repo PREPUSH_TMP=$t/work CALLS=$t/calls REMOTE=$t/remote TEST_REPO=$t/repo
printf c > "$t/coord"
cat > "$t/config/hotfix.json" <<'JSON'
{"apply_dist":{"host":"override","host_env":"TEST_HOST","repo_env":"TEST_REPO","repo_home_relative":"checkout","release_unit":"release.service","backup_root":"/backups","coord_root":"/coord","registry":"/registry","package_dir":"pkg","container_path":"/app/dist","containers":["first","second"],"install":["install","one argument"],"build":["build"],"restart":["restart","container"]}}
JSON
sed 's/override/packhost/' "$t/config/hotfix.json" > "$t/pack/hotfix.json"
! "$t/engine/hotfix/hf-apply-dist.sh" invalid tag "$t/coord" >/dev/null 2>&1
RELEASE_RC=0 "$t/engine/hotfix/hf-apply-dist.sh" abcdef1 tag "$t/coord" >/dev/null 2>&1 && exit 1
[[ ! -s $CALLS ]]
"$t/engine/hotfix/hf-apply-dist.sh" abcdef1 tag "$t/coord"
grep -Fq 'install: <one argument>' "$CALLS"
grep -Fq '<override:/backups/tag-dist.tgz>' "$CALLS"
grep -Fq 'restart: <container> <first>' "$CALLS"
grep -Fq 'restart: <container> <second>' "$CALLS"
grep -Fq 'accept:abcdef1' "$CALLS"
grep -Fq 'docker cp "$S/dist/." "$c:$target/"' "$REMOTE"
mv "$t/config/hotfix.json" "$t/config/saved"
"$t/engine/hotfix/hf-apply-dist.sh" abcdef1 tag "$t/coord"
grep -Fq '<packhost:/backups/tag-dist.tgz>' "$CALLS"
mv "$t/pack/hotfix.json" "$t/pack/saved"
! "$t/engine/hotfix/hf-apply-dist.sh" abcdef1 tag "$t/coord" >/dev/null 2>&1
printf '#!/usr/bin/env bash\nprintf legacy > "$CALLS"\n' > "$t/pack/hotfix/hf-apply-dist.sh"
"$t/engine/hotfix/hf-apply-dist.sh" abcdef1 tag "$t/coord"
[[ $(cat "$CALLS") == legacy ]]
