#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../test-env.sh"
p=$(cd "$(dirname "$0")" && pwd); t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
cat > "$t/gh" <<'STUB'
#!/usr/bin/env bash
[[ -z ${GH_TOKEN+x} ]]; printf '%s\n' "$PRS"
STUB
chmod +x "$t/gh"; export PATH="$t:$PATH" GH_TOKEN=secret HF_NOW=1793300000
fresh=$(date -u -d @1793299700 +%FT%TZ); old=$(date -u -d @1793290000 +%FT%TZ)
PRS="[{\"number\":1,\"title\":\"a\",\"updatedAt\":\"$fresh\",\"isDraft\":false}]" "$p/hf-stale.sh"
rc=0; out=$(PRS="[{\"number\":2,\"title\":\"b\",\"updatedAt\":\"$old\",\"isDraft\":false}]" "$p/hf-stale.sh") || rc=$?
[[ $rc == 1 && $out == *'#2 idle 166 min: b'* ]]
