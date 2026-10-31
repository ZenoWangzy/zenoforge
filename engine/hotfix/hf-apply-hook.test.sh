#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../test-env.sh"
p=$(cd "$(dirname "$0")" && pwd)
t=$(mktemp -d -p "$p/../../.git")
mkdir -p "$t/engine/hotfix" "$t/bin" "$t/config" "$t/pack/hotfix" "$t/repo"
cp "$p/hf-apply-hook.sh" "$t/engine/hotfix/"
cp "$p/../config.sh" "$t/engine/"
cat > "$t/engine/hotfix/hf-source-check.sh" <<'STUB'
#!/usr/bin/env bash
exit "${SOURCE_RC:-0}"
STUB
cat > "$t/engine/hotfix/hf-accept.sh" <<'STUB'
#!/usr/bin/env bash
printf 'accept:%s\n' "$HF_SHA" >> "$CALLS"
STUB
for c in scp ssh systemctl git; do
  cat > "$t/bin/$c" <<'STUB'
#!/usr/bin/env bash
case "${0##*/}" in
  systemctl) exit "${RELEASE_RC:-1}" ;;
  git) exit 1 ;;
  ssh) printf 'ssh:' >> "$CALLS"; printf ' <%s>' "$@" >> "$CALLS"; printf '\n' >> "$CALLS"; cat > "$REMOTE" ;;
  *) printf 'scp:' >> "$CALLS"; printf ' <%s>' "$@" >> "$CALLS"; printf '\n' >> "$CALLS" ;;
esac
STUB
done
cat > "$t/bin/restart" <<'STUB'
#!/usr/bin/env bash
printf 'restart:%s\n' "$*" >> "$CALLS"
STUB
chmod +x "$t/bin/"* "$t/engine/hotfix/"*.sh
export PATH="$t/bin:$PATH" ZF_CONFIG_ROOT=$t/config ZF_PACK_DIR=$t/pack ZF_REPO_DIR=$t/repo CALLS=$t/calls REMOTE=$t/remote
printf x > "$t/hook"; printf c > "$t/coord"
cat > "$t/config/hotfix.json" <<'JSON'
{"apply_hook":{"host":"override","host_env":"TEST_HOST","release_unit":"release.service","backup_root":"/backups","coord_root":"/coord","container":"gateway","container_path":"/app/hook.py","profiles_root":"/profiles","profile_path":"plugins/hook.py","registry":"/registry","restart":["restart","target"]}}
JSON
sed 's/override/packhost/' "$t/config/hotfix.json" > "$t/pack/hotfix.json"
SOURCE_RC=1 "$t/engine/hotfix/hf-apply-hook.sh" "$t/hook" tag "$t/coord" >/dev/null 2>&1 && exit 1
[[ ! -s $CALLS ]]
RELEASE_RC=0 "$t/engine/hotfix/hf-apply-hook.sh" "$t/hook" tag "$t/coord" >/dev/null 2>&1 && exit 1
[[ ! -s $CALLS ]]
"$t/engine/hotfix/hf-apply-hook.sh" "$t/hook" tag "$t/coord"
grep -Fq '<override:/backups/tag-patched.py>' "$CALLS"
grep -Fq 'restart:target' "$CALLS"
grep -Fq 'accept:' "$CALLS"
grep -Fq 'docker cp "$N" "$container:$target"' "$REMOTE"
mv "$t/config/hotfix.json" "$t/config/saved"
"$t/engine/hotfix/hf-apply-hook.sh" "$t/hook" tag "$t/coord"
grep -Fq '<packhost:/backups/tag-patched.py>' "$CALLS"
mv "$t/pack/hotfix.json" "$t/pack/saved"
! "$t/engine/hotfix/hf-apply-hook.sh" "$t/hook" tag "$t/coord" >/dev/null 2>&1
printf '#!/usr/bin/env bash\nprintf legacy > "$CALLS"\n' > "$t/pack/hotfix/hf-apply-hook.sh"
"$t/engine/hotfix/hf-apply-hook.sh" "$t/hook" tag "$t/coord"
[[ $(cat "$CALLS") == legacy ]]
