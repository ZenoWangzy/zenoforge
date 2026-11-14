#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/scheduler.d/reports.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/scheduler.d/review-fixes.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/scheduler.d/clones.sh"

fail() { echo "reviewer-fixes.test.sh: $*" >&2; exit 1; }

report="$test_env_root/review.md"
cat >"$report" <<'REPORT'
VERDICT: READY

```review-findings
  {"findings":[{"id":"F1","severity":"P1","file":"src/example.ts","line":8,"rule":"Defect","status":"fixed-in-review","summary":"The empty value is not handled.","introduced_by":"candidate","base_evidence":"The base lacks this guard.","commit_sha":"1111111111111111111111111111111111111111","test":{"path":"src/example.test.mjs","name":"rejects an empty value"}}],"dispositions":[]}
```
REPORT

parsed="$(findings_block_of "$report")" || fail 'fixed-in-review finding with commit SHA and test was rejected'
[[ "$(jq -r '.findings[0].status' <<<"$parsed")" == fixed-in-review ]] || fail 'fixed-in-review status was lost'
[[ "$(jq -r '.findings[0].commit_sha' <<<"$parsed")" == 1111111111111111111111111111111111111111 ]] || fail 'fixed commit SHA was lost'
[[ "$(jq -r '.findings[0].test.path' <<<"$parsed")" == src/example.test.mjs ]] || fail 'test path was lost'
# Product repos name TypeScript tests (issue-6638 review 2026-11-14 lost its whole block on a .test.ts path).
sed "s#src/example.test.mjs#src/example.test.ts#" "$report" > "$test_env_root/review-ts.md"
parsed_ts="$(findings_block_of "$test_env_root/review-ts.md")" || fail "fixed-in-review finding with a .test.ts path was rejected"
[[ "$(jq -r ".findings[0].test.path" <<<"$parsed_ts")" == src/example.test.ts ]] || fail "ts test path was lost"

jqf() { jq "$@"; }
unit_field() {
  case "$2" in
    .pr) printf '7\n' ;;
    '.branch // empty') printf '%s\n' "$TEST_BRANCH" ;;
    '.lane // empty') printf 'pr\n' ;;
    *) return 1 ;;
  esac
}
tick_pr_head() { printf '%s\n' "$TEST_REMOTE_HEAD"; }
ENGINE_ROOT="$(git rev-parse --show-toplevel)"
SUP="$test_env_root/supervisor"
mkdir -p "$SUP"

checkout_remote="$test_env_root/checkout-remote.git"
checkout_seed="$test_env_root/checkout-seed"
checkout_repo="$test_env_root/checkout-repo"
git init -q --bare "$checkout_remote"
git init -q -b main "$checkout_seed"
git -C "$checkout_seed" config user.name Implementer
git -C "$checkout_seed" config user.email implementer@example.invalid
printf '%s\n' base > "$checkout_seed/source.sh"
git -C "$checkout_seed" add source.sh
git -C "$checkout_seed" commit -q -m base
checkout_base="$(git -C "$checkout_seed" rev-parse HEAD)"
git -C "$checkout_seed" remote add origin "$checkout_remote"
git -C "$checkout_seed" push -q origin main
git --git-dir="$checkout_remote" symbolic-ref HEAD refs/heads/main
git --git-dir="$checkout_remote" update-ref refs/pull/91/head "$checkout_base"
git clone -q "$checkout_remote" "$checkout_repo"
git -C "$checkout_repo" checkout -q -b agent/reviewer "$checkout_base"
checkout_pr_head "$checkout_repo" 91 "$checkout_base" "$checkout_base" agent/reviewer \
  || fail 'PR review checkout did not attach to its branch'
[[ "$(git -C "$checkout_repo" symbolic-ref --short HEAD)" == agent/reviewer ]] \
  || fail 'PR review checkout left the reviewer detached'
git -C "$checkout_repo" config user.name Reviewer
git -C "$checkout_repo" config user.email reviewer@example.invalid
git -C "$checkout_repo" commit -q --allow-empty -m unpushed
checkout_unpushed="$(git -C "$checkout_repo" rev-parse HEAD)"
if checkout_pr_head "$checkout_repo" 91 "$checkout_base" "$checkout_base" agent/reviewer; then
  fail 'PR review checkout reset an unpushed branch commit'
fi
[[ "$(git -C "$checkout_repo" rev-parse HEAD)" == "$checkout_unpushed" ]] \
  || fail 'PR review checkout lost an unpushed branch commit'

make_review_repo() {
  local dir="$1" branch="$2" source="$3" test_file="$4" large="${5:-false}" base_sha fix_sha
  mkdir -p "$dir/src" "$dir/engine"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.name Implementer
  git -C "$dir" config user.email implementer@example.invalid
  printf '%s\n' 'value() { printf "%s\\n" "$1"; }' > "$dir/$source"
  git -C "$dir" add "$source"
  git -C "$dir" commit -q -m base
  base_sha="$(git -C "$dir" rev-parse HEAD)"
  git -C "$dir" checkout -q -b "$branch"
  if [[ "$large" == true ]]; then
    {
      printf '%s\n' '#!/usr/bin/env bash'
      for n in $(seq 1 24); do printf 'value_%s=1\n' "$n"; done
    } > "$dir/$source"
  else
    cat > "$dir/$source" <<'SOURCE'
value() { [[ -n "$1" ]] && printf '%s\n' "$1" || printf 'empty\n'; }
SOURCE
  fi
  cat > "$dir/$test_file" <<'TEST'
#!/usr/bin/env bash
set -euo pipefail
[[ "$(bash -c 'source src/example.sh; value ""')" == empty ]]
TEST
  git -C "$dir" add "$source" "$test_file"
  reviewer_git_identity_configure "$dir" claude reviewer-test-model || fail 'reviewer identity was not configured'
  git -C "$dir" commit -q -m 'review: fix empty value handling'
  fix_sha="$(git -C "$dir" rev-parse HEAD)"
  printf '%s\n%s\n' "$base_sha" "$fix_sha"
}

write_fixed_report() {
  local path="$1" sha="$2" source="$3" test_file="$4"
  jq -cn --arg sha "$sha" --arg source "$source" --arg test "$test_file" \
    '{findings:[{id:"F1",severity:"P1",file:$source,line:1,rule:"Defect",status:"fixed-in-review",summary:"An empty value was not handled.",introduced_by:"candidate",base_evidence:"The base prints an empty value without the required behavior.",commit_sha:$sha,test:{path:$test,name:"returns the empty-value result"}}],dispositions:[]}' > "$path.block"
  {
    printf 'VERDICT: READY\n\n```review-findings\n'
    cat "$path.block"
    printf '```\n'
  } > "$path"
  rm -f "$path.block"
}

small_repo="$test_env_root/small"
readarray -t small_heads < <(make_review_repo "$small_repo" agent/small src/example.sh engine/example.test.sh)
small_base="${small_heads[0]}"; small_head="${small_heads[1]}"
small_report="$SUP/review-small.md"
write_fixed_report "$small_report" "$small_head" src/example.sh engine/example.test.sh
TEST_BRANCH=agent/small; TEST_REMOTE_HEAD="$small_base"
w="$(jq -cn --arg dir "$small_repo" --arg sha "$small_base" --arg head "$small_base" \
  '{workdir:$dir,sha:$sha,pr_head:$head,provider:"claude",model:"reviewer-test-model"}')"
v=; wsha=; wprhead=; report=review-small.md; rep="$small_report"
review_harvest_gate "$w" "$small_report" unit-small review || fail 'un-pushed review fix refusal failed'
[[ "$v" == NOT_READY ]] || fail 'an un-pushed reviewer fix was approved'
TEST_REMOTE_HEAD="$small_head"
v=; wsha=; wprhead=; report=review-small.md; rep="$small_report"
review_harvest_gate "$w" "$small_report" unit-small review || fail 'small review fix gate failed'
[[ "$v" == READY && "$wsha" == "$small_head" && "$wprhead" == "$small_head" ]] \
  || fail "small fixed-in-review finding did not reach the normal approve path on its commit (verdict=$v sha=$wsha head=$wprhead report=$report detail=$(sed -n '1,8p' "$rep" | tr '\n' ' '))"
[[ "$(jqf -r '.sha' <<<"$w")" == "$small_head" && "$(jqf -r '.pr_head' <<<"$w")" == "$small_head" ]] \
  || fail 'approved fix SHA was not carried into harvest state'

large_repo="$test_env_root/large"
readarray -t large_heads < <(make_review_repo "$large_repo" agent/large src/example.sh engine/example.test.sh true)
large_base="${large_heads[0]}"; large_head="${large_heads[1]}"
large_report="$SUP/review-large.md"
write_fixed_report "$large_report" "$large_head" src/example.sh engine/example.test.sh
TEST_BRANCH=agent/large; TEST_REMOTE_HEAD="$large_head"
w="$(jq -cn --arg dir "$large_repo" --arg sha "$large_base" --arg head "$large_base" \
  '{workdir:$dir,sha:$sha,pr_head:$head,provider:"claude",model:"reviewer-test-model"}')"
v=; wsha=; wprhead=; report=review-large.md; rep="$large_report"
review_harvest_gate "$w" "$large_report" unit-large review || fail 'large review fix refusal failed'
[[ "$v" == NOT_READY && "$report" == review-fix-refused-unit-large-*.md ]] \
  || fail 'large fixed-in-review finding did not become request-changes'
large_gate="$(findings_block_of "$rep")" || fail 'large fix refusal did not keep a machine-readable finding'
[[ "$(jq -r '.findings[0].status' <<<"$large_gate")" == open \
  && "$(jq -r '.findings[0].summary' <<<"$large_gate")" == *'limit 20'* ]] \
  || fail 'the refused large finding was not reopened with the scope reason'

echo 'reviewer-fixes.test.sh: PASS (small fix approved in one harvest; large fix returned as request-changes)'
