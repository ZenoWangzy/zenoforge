#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../test-env.sh"
p=$(cd "$(dirname "$0")" && pwd); t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
cat > "$t/git" <<'STUB'
#!/usr/bin/env bash
case "$1" in
 fetch) exit 0 ;;
 ls-tree) [[ $3 == origin/main ]] && echo "100644 blob mainblob	a.py"; [[ $3 == prhead ]] && echo "100644 blob prblob	a.py" ;;
 hash-object) cat "$2" ;;
esac
STUB
cat > "$t/gh" <<'STUB'
#!/usr/bin/env bash
[[ -z ${GH_TOKEN+x} ]]; echo "7 prhead"
STUB
chmod +x "$t/git" "$t/gh"; export PATH="$t:$PATH" GH_TOKEN=secret
printf mainblob > "$t/m"; printf prblob > "$t/p"; printf liveonly > "$t/x"
"$p/hf-source-check.sh" "$t/m" "$t/p"
rc=0; "$p/hf-source-check.sh" "$t/m" "$t/x" 2>"$t/err" || rc=$?
[[ $rc == 1 ]] && grep -q REFUSED "$t/err"
