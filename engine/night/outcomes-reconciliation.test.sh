#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../test-env.sh"
source "$MODEL_POLICY_TEST_REPO/engine/lib.sh"
source "$MODEL_POLICY_TEST_REPO/engine/night/outcomes-audit.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/home/state"
now="$(date +%s)"
printf 'false\n' > "$tmp/comments-previous.json"

# Bodies returned by the fourteen-day search need not appear in the recent summary.
cat > "$tmp/prs.json" <<'JSON'
{"data":{"recent":{"nodes":[],"pageInfo":{"hasNextPage":false}},"boundary":{"nodes":[],"pageInfo":{"hasNextPage":false}},"refs":{"nodes":[{"number":3019,"title":"fix: MCP reconnect","body":"Refs #3013, #3016","headRefName":"hand/mcp","baseRefName":"main","mergedAt":"MERGED_AT"}],"pageInfo":{"hasNextPage":false}},"implements":{"nodes":[],"pageInfo":{"hasNextPage":false}},"titles":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}
JSON
sed -i "s/MERGED_AT/$(date -u -d "@$((now - 345600))" +%Y-%m-%dT%H:%M:%SZ)/" "$tmp/prs.json"
cat > "$tmp/issues.json" <<'JSON'
{"data":{"repository":{"i3013":{"__typename":"Issue","number":3013,"state":"OPEN","labels":{"nodes":[],"pageInfo":{"hasNextPage":false}}},"i3016":{"__typename":"Issue","number":3016,"state":"OPEN","labels":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}}}
JSON
gh_q() {
  case "$*" in
    *'search(query:'*) cat "$tmp/prs.json" ;;
    *'repository(owner:'*)
      if [[ "$*" == *'comments(last:100)'* ]]; then
        grep -oE 'i[0-9]+: issue\(number:[0-9]+\)' <<< "$*" |
          sed -E 's/^i([0-9]+): issue\(number:([0-9]+)\)$/\2/' |
          jq -Rn '[inputs | tonumber]' > "$tmp/comment-ids.json"
        jq 'length' "$tmp/comment-ids.json" >> "$tmp/comment-batch-sizes"
        printf '%s\n' "${OUTCOMES_GH_TIMEOUT_SECONDS:-unset}" >> "$tmp/comment-timeouts"
        [[ "${comment_batch_status:-0}" == 0 ]] || return 1
        jq -n --slurpfile ids "$tmp/comment-ids.json" --slurpfile comments "$tmp/comments.json" \
          --slurpfile previous "$tmp/comments-previous.json" '
          ($comments[0] | flatten | map(select(type == "object") | {
            body:(.body // ""), createdAt:(.createdAt // .created_at // ""),
            author:{login:(.user.login // .author.login // "")}
          })) as $nodes |
          {data:{repository:(reduce $ids[0][] as $id ({};
            .["i" + ($id | tostring)] = {comments:{nodes:$nodes,pageInfo:{hasPreviousPage:$previous[0]}}}
          ))}}
        '
        return
      fi
      if [[ "$*" == *'issueOrPullRequest('* && "$*" == *'comments('* ]]; then
        echo 'not ok - state query includes heavy comment bodies' >&2; return 1
      fi
      grep -oE 'i[0-9]+: issueOrPullRequest' <<< "$*" | wc -l >> "$tmp/batch-sizes"
      grep -oE 'i[0-9]+: issueOrPullRequest' <<< "$*" | head -1 >> "$tmp/batch-starts"
      if [[ "${missing_alias_fixture:-0}" == 1 && "$*" == *'i94423:'* ]]; then
        printf 'gh: Could not resolve to an issue or pull request with the number of 94423.\n' > "${_OUTCOMES_GH_STDERR_FILE:?}"
        return 1
      fi
      cat "$tmp/issues.json"
      return "${state_read_status:-0}" ;;
    *'issue list'*|*'pr list'*) printf '[]\n' ;;
    *'/comments?'*)
      printf 'REST comment read\n' >> "$tmp/rest-comment-reads"
      [[ "${comment_read_status:-0}" == 0 ]] || return 1
      cat "$tmp/comments.json" ;;
    *) echo 'unexpected GitHub read' >&2; return 1 ;;
  esac
}
conclude_merged_run() { printf '%s %s\n' "$1" "$2" >> "$tmp/concluded"; }
check() { grep -Fq "$1" <<< "$result" || { printf 'not ok - missing %s\n%s\n' "$1" "$result" >&2; exit 1; }; }
assert_eq() { [[ "$2" == "$1" ]] || { printf 'not ok - %s: expected <%s> got <%s>\n' "$3" "$1" "$2" >&2; exit 1; }; }
printf '[[]]\n' > "$tmp/comments.json"
result="$(SECONDS=0 OUTCOMES_RECONCILE_DRY_RUN=1 outcomes_reconcile_merged_issues test/repo "$tmp/home" "$now")"
check 'match issue=#3013 pr=#3019'
check 'match issue=#3016 pr=#3019'
printf 'ok - fourteen-day multi-issue PR associates with both issues\n'

rewrite() { jq "$1" "$2" > "$tmp/rewrite.json"; mv "$tmp/rewrite.json" "$2"; }
preview() { result="$(SECONDS=0 OUTCOMES_RECONCILE_DRY_RUN=1 outcomes_reconcile_merged_issues test/repo "$tmp/home" "$now")"; }

# Title-only references older than the two-day summary still enter the fourteen-day
# scan. Explicit rounds select the latest merge; an owner decision can override it.
cp "$tmp/prs.json" "$tmp/initial-prs.json"
cp "$tmp/issues.json" "$tmp/initial-issues.json"
cp "$tmp/comments.json" "$tmp/initial-comments.json"
round_earlier_at="$(date -u -d "@$((now - 518400))" +%Y-%m-%dT%H:%M:%SZ)"
round_later_at="$(date -u -d "@$((now - 517080))" +%Y-%m-%dT%H:%M:%SZ)"
cat > "$tmp/prs.json" <<JSON
{"data":{
  "recent":{"nodes":[],"pageInfo":{"hasNextPage":false}},
  "boundary":{"nodes":[],"pageInfo":{"hasNextPage":false}},
  "refs":{"nodes":[{"number":2545,"title":"fix: source live hot-fix behaviour, round 2 (issue 2527)","body":"Refs #2527","headRefName":"hand/parity-sweep2","baseRefName":"main","mergedAt":"$round_later_at"}],"pageInfo":{"hasNextPage":false}},
  "implements":{"nodes":[],"pageInfo":{"hasNextPage":false}},
  "titles":{"nodes":[{"number":2534,"title":"fix: source remaining live hot-fix behaviour (issue 2527)","body":"","headRefName":"hand/parity-sweep","baseRefName":"main","mergedAt":"$round_earlier_at"}],"pageInfo":{"hasNextPage":false}}
}}
JSON
cat > "$tmp/issues.json" <<'JSON'
{"data":{"repository":{"i2527":{"__typename":"Issue","number":2527,"state":"OPEN","closedAt":null,"stateReason":null,"labels":{"nodes":[{"name":"ready-for-agent"}],"pageInfo":{"hasNextPage":false}}}}}}
JSON
printf '[[]]\n' > "$tmp/comments.json"
: > "$tmp/concluded"
preview
check 'rounds issue=#2527 prs=#2534,#2545 anchor=#2545'
check 'match issue=#2527 pr=#2545'
result="$(SECONDS=0 outcomes_reconcile_merged_issues test/repo "$tmp/home" "$now")"
assert_eq '2527 2545' "$(cat "$tmp/concluded")" 'latest explicit round is merge anchor'
assert_eq OPEN "$(jq -r '.data.repository.i2527.state' "$tmp/issues.json")" 'round association leaves issue lifecycle open'
[[ ! -s "$tmp/home/supervisor-inbox" && ! -e "$tmp/home/maintainer-outcomes.json" ]]

cat > "$tmp/comments.json" <<'JSON'
[[{"user":{"login":"test"},"body":"Decision (supervisor, 2026-10-12): PR 2534 (merged) is the accepted implementation for this issue."}]]
JSON
: > "$tmp/concluded"
result="$(SECONDS=0 outcomes_reconcile_merged_issues test/repo "$tmp/home" "$now")"
assert_eq '2527 2534' "$(cat "$tmp/concluded")" 'trusted decision overrides latest round anchor'
[[ ! -s "$tmp/home/supervisor-inbox" && ! -e "$tmp/home/maintainer-outcomes.json" ]]
printf 'ok - explicit title-only rounds use latest merge; trusted decision overrides without closing issue\n'

rewrite '.data.refs.nodes += [.data.refs.nodes[0] | .number=2546 | .title="revert: undo round (issue 2527)" | .body="Refs #2527" | .headRefName="revert/2545"]' "$tmp/prs.json"
printf '[[]]\n' > "$tmp/comments.json"
preview
check 'ambiguous issue=#2527'
check 'reason=reverted candidate PR'
printf 'ok - reverted candidate keeps conflicting rounds ambiguous\n'

mv "$tmp/initial-prs.json" "$tmp/prs.json"
mv "$tmp/initial-issues.json" "$tmp/issues.json"
mv "$tmp/initial-comments.json" "$tmp/comments.json"

# Several plausible implementations remain ambiguous; decisions work for any open issue.
rewrite '.data.refs.nodes += [.data.refs.nodes[0] | .number=3020 | .title="fix: alternate MCP implementation" | .body="Fixes #3013" | .headRefName="hand/alternate"]' "$tmp/prs.json"
preview
check 'ambiguous issue=#3013'
cat > "$tmp/comments.json" <<'JSON'
[[{"user":{"login":"test"},"body":"Decision (supervisor, 2026-10-11): PR 3020 (merged) is the accepted implementation for this issue."}]]
JSON
preview
check 'match issue=#3013 pr=#3020'
[[ "$result" != *'ambiguous issue=#3013'* ]]
printf 'ok - supervisor decision resolves competing merged PRs without awaiting-release label\n'
rewrite '.[0] = [{user:{login:"test"},body:"<!-- zf-merged-outcome issue=3013 pr=3019 -->"}] + .[0]' "$tmp/comments.json"
preview
check 'match issue=#3013 pr=#3020'
[[ "$result" != *'ambiguous issue=#3013'* ]]
printf 'ok - explicit supervisor decision wins over older merge marker\n'
cat > "$tmp/comments.json" <<'JSON'
[[{"user":{"login":"test"},"body":"<!-- zf-merged-outcome issue=3013 pr=3019 -->"}]]
JSON
preview
check 'match issue=#3013 pr=#3019'
rewrite '.[0][0].user.login="intruder"' "$tmp/comments.json"
preview
check 'ambiguous issue=#3013'
rewrite '.[0][0].user.login="test" | .[0][0].body="<!-- zf-merged-outcome issue=3013 pr=99999 -->"' "$tmp/comments.json"
preview
check 'ambiguous issue=#3013'
printf 'ok - existing marker supported; untrusted and unrelated decisions ignored\n'

# One failed batched comment read or GraphQL alias cannot abort readable siblings.
comment_batch_status=1
preview
check 'match issue=#3016 pr=#3019'
check 'unreadable=1 issues=3013'
comment_batch_status=0
rewrite 'del(.data.refs.nodes[1])' "$tmp/prs.json"
rewrite '.data.repository.i3013=null | .errors=[{path:["repository","i3013"],message:"read failed"}]' "$tmp/issues.json"
state_read_status=1
preview
check 'match issue=#3016 pr=#3019'
check 'unreadable=1 issues=3013'
state_read_status=0
rewrite 'del(.errors) | .data.repository.i3013={"__typename":"Issue","number":3013,"state":"OPEN","labels":{"nodes":[],"pageInfo":{"hasNextPage":true}}}' "$tmp/issues.json"
preview
check 'match issue=#3016 pr=#3019'
check 'unreadable=1 issues=3013'
result="$(SECONDS=0 outcomes_audit test/repo "$tmp/home" "$now")"
check '"verdict":"BROKEN"'
check 'skipped 1 unreadable issue(s)'
printf 'ok - partial GitHub errors and malformed item shapes yield readable BROKEN verdict\n'

# Test-only issue fixes count. Reference-only docs/test/revert PRs stay out of its way.
rewrite '.data.refs.nodes = [.data.refs.nodes[0] | .number=3179 | .title="test(example): assert correction UUID index plan" | .body="Refs #3171" | .headRefName="agent/issue-3171"] |
 .data.refs.nodes += [.data.refs.nodes[0] | .number=3180 | .title="docs: mention test issue" | .headRefName="hand/docs", . | .number=3181 | .title="test: unrelated coverage" | .headRefName="hand/tests", . | .number=3182 | .title="revert: unrelated change" | .headRefName="revert/3181"]' "$tmp/prs.json"
cat > "$tmp/issues.json" <<'JSON'
{"data":{"repository":{"i3171":{"__typename":"Issue","number":3171,"state":"OPEN","labels":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}}}
JSON
printf '[[]]\n' > "$tmp/comments.json"
preview
check 'match issue=#3171 pr=#3179'
check 'ambiguous=0'
rewrite 'del(.data.refs.nodes[0])' "$tmp/prs.json"
preview
check 'matches=0 ambiguous=0'
printf 'ok - #3171/#3179 accepted; reference-only docs/test/revert PRs never block\n'

# Bodies and title references, including multiple Fixes and issue N, use stdin.
rewrite '.data.refs.nodes=[.data.refs.nodes[0] | .number=3200 | .title="fix: issue 3013 and issue 3016" | .body=("Fixes #3013, #3016\n" + ("x" * 140000)) | .headRefName="hand/multiref"]' "$tmp/prs.json"
cat > "$tmp/issues.json" <<'JSON'
{"data":{"repository":{"i3013":{"__typename":"Issue","number":3013,"state":"OPEN","labels":{"nodes":[],"pageInfo":{"hasNextPage":false}}},"i3016":{"__typename":"Issue","number":3016,"state":"OPEN","labels":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}}}
JSON
preview
check 'match issue=#3013 pr=#3200'
check 'match issue=#3016 pr=#3200'
printf 'ok - multi-issue Fixes/title references and bodies over 128 KiB\n'

# Association questions route once to supervisor, even after inbox is cleared.
rewrite '.data.refs.nodes[0].title="fix: batch fixture"' "$tmp/prs.json"
rewrite '.data.refs.nodes += [.data.refs.nodes[0] | .number=3201]' "$tmp/prs.json"
result="$(SECONDS=0 outcomes_reconcile_merged_issues test/repo "$tmp/home" "$now")"
[[ "$(grep -c 'merged-pr-association-ambiguous' "$tmp/home/supervisor-inbox")" == 2 ]]
if grep -q 'maintainer-decision' "$tmp/home/supervisor-inbox"; then
  echo 'not ok - association emitted maintainer-decision' >&2; exit 1
fi
: > "$tmp/home/supervisor-inbox"
result="$(SECONDS=0 outcomes_reconcile_merged_issues test/repo "$tmp/home" "$now")"
[[ ! -s "$tmp/home/supervisor-inbox" ]]
[[ ! -e "$tmp/home/night/maintainer-outcomes.json" ]]
printf 'ok - association routes only to supervisor once, never maintainer-decision\n'

# Sixty issue aliases must split into 25/25/10, not one oversized query.
rewrite '.data.refs.nodes=[.data.refs.nodes[0] | .number=3300 | .title="fix: batch fixture" | .body=([range(5000;5060) | "#" + tostring] | "Refs " + join(", "))]' "$tmp/prs.json"
jq -n '{data:{repository:([range(5000;5060) | {key:("i"+tostring),value:{__typename:"Issue",number:.,state:"OPEN",labels:{nodes:[],pageInfo:{hasNextPage:false}}}}] | from_entries)}}' > "$tmp/issues.json"
: > "$tmp/batch-sizes"
preview
check 'matches=60 ambiguous=0'
[[ "$(cat "$tmp/batch-sizes")" == $'25\n25\n10' ]]
printf 'ok - merged issue state queries bounded to 25 aliases\n'
# Count process launches, not wall time: other hand suites share this host.
jq_count_log="$tmp/jq-count"
: > "$jq_count_log"
jq() { printf 'jq\n' >> "$jq_count_log"; command jq "$@"; }
preview
jq_count="$(wc -l < "$jq_count_log")"
unset -f jq
[[ "$jq_count" -le 160 ]] || { echo "not ok - sixty-item scan starts $jq_count jq processes" >&2; exit 1; }
printf 'ok - sixty-item scan uses %s jq processes, bounded metadata parsing\n' "$jq_count"

# A budget-deferred state cohort resumes after its last attempted issue; a
# complete scan removes the cursor, so ordinary ordering is restored.
printf '5024\n' > "$tmp/home/night/outcomes-merged-state-cursor"
: > "$tmp/batch-starts"
preview
check 'matches=60 ambiguous=0'
grep -Fxq 'i5025: issueOrPullRequest' "$tmp/batch-starts"
test ! -f "$tmp/home/night/outcomes-merged-state-cursor"
printf 'ok - saved issue-state cursor rotates cohort and clears after complete read\n'
printf '5024\n' > "$tmp/home/night/outcomes-merged-group-cursor"
preview
[[ "$(sed -n '1p' <<< "$result")" == 'match issue=#5025 pr=#3300' ]]
test ! -f "$tmp/home/night/outcomes-merged-group-cursor"
printf 'ok - saved decision cursor resumes beyond processed prefix\n'

# Complete batched comment pages resolve decisions; truncated pages skip only that item.
rewrite '(.data.refs.nodes[0] | .body="Refs #5000") as $pr | .data.refs.nodes=[$pr, ($pr | .number=3301)]' "$tmp/prs.json"
cat > "$tmp/comments.json" <<'JSON'
[[{"user":{"login":"test"},"body":"Decision (supervisor): PR 3301 is the accepted implementation","created_at":"2026-10-11T22:00:00Z"}]]
JSON
: > "$tmp/rest-comment-reads"
preview
check 'match issue=#5000 pr=#3301'
check 'unreadable=0'
printf 'true\n' > "$tmp/comments-previous.json"
preview
check 'unreadable=1 issues=5000'
[[ ! -s "$tmp/rest-comment-reads" ]]
printf 'false\n' > "$tmp/comments-previous.json"
printf 'ok - complete comments use one batch; truncated pages skip item without serial fallback\n'

# Large comment cohorts stop after two bounded batches and resume after cursor next tick.
cp "$tmp/prs.json" "$tmp/pre-comment-budget-prs.json"
cp "$tmp/issues.json" "$tmp/pre-comment-budget-issues.json"
rewrite '.data.refs.nodes=[.data.refs.nodes[0] | .number=3399 | .title="test: bounded comments" | .body=([range(6000;6060) | "#" + tostring] | "Refs " + join(", ")) | .headRefName="hand/tests"]' "$tmp/prs.json"
jq -n '{data:{repository:([range(6000;6060) | {key:("i"+tostring),value:{__typename:"Issue",number:.,state:"OPEN",labels:{nodes:[],pageInfo:{hasNextPage:false}}}}] | from_entries)}}' > "$tmp/issues.json"
printf '[[]]\n' > "$tmp/comments.json"
: > "$tmp/comment-batch-sizes"
: > "$tmp/comment-timeouts"
preview
check 'comments-deferred=10 issues=#6050,#6051'
[[ "$(cat "$tmp/comment-batch-sizes")" == $'25\n25' ]]
awk '$1 < 1 || $1 > 3 { bad=1 } END { exit (NR == 0 || bad) }' "$tmp/comment-timeouts"
: > "$tmp/comment-batch-sizes"
preview
check 'comments-deferred=10 issues=#6040,#6041'
[[ "$(cat "$tmp/comment-batch-sizes")" == $'25\n25' ]]
printf 'ok - two comment batches max, timeout bounded, cursor rotates deferred cohort\n'
: > "$tmp/comment-batch-sizes"
result="$(SECONDS=0 ZF_OUTCOMES_SECTION_TIMEOUT_SECONDS=25 OUTCOMES_RECONCILE_DRY_RUN=1 \
  outcomes_reconcile_merged_issues test/repo "$tmp/home" "$now")"
check 'unreadable=60'
[[ ! -s "$tmp/comment-batch-sizes" ]]
printf 'ok - comment reads defer when less than 20 seconds remain\n'
if result="$(SECONDS=0 ZF_OUTCOMES_SECTION_TIMEOUT_SECONDS=5 OUTCOMES_RECONCILE_DRY_RUN=1 \
  outcomes_reconcile_merged_issues test/repo "$tmp/home" "$now")"; then
  echo 'not ok - expired budget allowed initial discovery' >&2; exit 1
fi
[[ -z "$result" ]]
[[ ! -s "$tmp/comment-batch-sizes" ]]
printf 'ok - expired budget fails closed before initial GitHub discovery\n'
mv "$tmp/pre-comment-budget-prs.json" "$tmp/prs.json"
mv "$tmp/pre-comment-budget-issues.json" "$tmp/issues.json"

# Runtime gh_q drops failed stdout when a nonexistent alias errors the batch.
rewrite '.data.refs.nodes[0].body="Refs #5000, #94423" | .data.refs.nodes |= [.[0]]' "$tmp/prs.json"
missing_alias_fixture=1
preview
check 'match issue=#5000 pr=#3300'
check 'unreadable=1 issues=94423'
missing_alias_fixture=0
printf 'ok - named nonexistent alias removed; readable batch siblings reread\n'

# The word issue in narrative does not promote every referenced PR number to an issue.
rewrite '.data.refs.nodes[0].body="The issue was discussed in PR #94423. Implements issue 5000."' "$tmp/prs.json"
preview
check 'match issue=#5000 pr=#3300'
check 'unreadable=0'
[[ "$result" != *'issue=#94423'* ]]
printf 'ok - narrative PR numbers remain context, explicit issue N still associates\n'
