#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../test-env.sh"
p=$(cd "$(dirname "$0")" && pwd); t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
# hf-merge reads the required names from required-pr-checks.json; the stub builds its
# rollup from the same file so the canned answer cannot drift from the merge bar again.
export REQ="$p/../mac-autopilot/required-pr-checks.json"
cat > "$t/gh" <<'STUB'
#!/usr/bin/env bash
[[ -z ${GH_TOKEN+x} ]]
case "$1 $2" in
 'pr view')
   if [[ "$*" == *'--json files'* ]]; then
     printf '%s\n' 'engine/hotfix/hf-merge.sh'
   else
     jq -cn --arg label "${LABEL:-hotfix}" --arg gate "${GATE:-SUCCESS}" \
       --arg head 0123456789abcdef0123456789abcdef01234567 \
       --argjson required "$(jq -c '.required' "$REQ")" '
       def row(name; concl): {name:name,status:"COMPLETED",conclusion:concl,startedAt:"2026-10-30T00:00:00Z",detailsUrl:"https://github.com/example-maintainer/example-repo/actions/runs/100/job/101"};
       {title:"Fix",state:"OPEN",labels:[{name:$label}],headRefOid:$head,
        body:("<!-- zf-hotfix-acceptance:start -->" + ({schema:"example.hotfix-acceptance/v1",status:"passed",accepted_by:"验收用户",accepted_head_sha:$head,evidence:"验收用户 verified the fix in production"}|tojson) + "<!-- zf-hotfix-acceptance:end -->"),
        statusCheckRollup:(($required|map(row(.;$gate))) + [row("Hotfix acceptance evidence";"SUCCESS")])}'
   fi ;;
 'pr merge') printf '%s\n' "$@" > "$LOG" ;;
esac
STUB
chmod +x "$t/gh"; export PATH="$t:$PATH" LOG="$t/log" GH_TOKEN=secret
LABEL=other "$p/hf-merge.sh" 12 && exit 1
LABEL=hotfix GATE=FAILURE "$p/hf-merge.sh" 12 && exit 1
LABEL=hotfix "$p/hf-merge.sh" 12
grep -Fxq 'Fix [hotfix] (#12)' "$LOG"
LABEL=hotfix GATE=IN_PROGRESS "$p/hf-merge.sh" 12 && exit 1
true
