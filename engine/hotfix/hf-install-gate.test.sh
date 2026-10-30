#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../test-env.sh"
p=$(cd "$(dirname "$0")" && pwd); t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
cat > "$t/gh" <<'STUB'
#!/usr/bin/env bash
[[ -z ${GH_TOKEN+x} ]]
case "$1 $2" in
 'pr view') echo '{"state":"MERGED","mergeCommit":{"oid":"merge"}}' ;;
 'run list') echo '[{"databaseId":1,"headSha":"later","status":"completed","conclusion":"success","event":"push","workflowName":"CI"}]' ;;
 'run view') printf '{"jobs":[{"name":"Postsubmit validate","status":"completed","conclusion":"%s"}]}' "$RESULT" ;;
esac
STUB
cat > "$t/git" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$t/gh" "$t/git"; export PATH="$t:$PATH" GH_TOKEN=secret
rc=0; RESULT=failure "$p/hf-install-gate.sh" 1 || rc=$?; [[ $rc == 3 ]]
RESULT=success "$p/hf-install-gate.sh" 1
