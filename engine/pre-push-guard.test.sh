#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

root="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
guard="$root/engine/pre-push-guard.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

repo="$tmp/repo"
remote="$tmp/origin.git"
mkdir -p "$repo" "$tmp/bin" "$tmp/home"
git init -q --initial-branch=main "$repo"
git -C "$repo" config user.name 'Push Guard Test'
git -C "$repo" config user.email 'push-guard@example.test'
mkdir -p "$repo/engine/ci"
cp "$root/engine/ci-repair-receipt.mjs" "$repo/engine/ci-repair-receipt.mjs"
cp "$root/engine/ci/pr-required-aggregate.mjs" "$repo/engine/ci/pr-required-aggregate.mjs"
printf 'base\n' > "$repo/file.txt"
git -C "$repo" add file.txt engine/ci-repair-receipt.mjs engine/ci/pr-required-aggregate.mjs
git -C "$repo" commit -qm base
base_sha="$(git -C "$repo" rev-parse HEAD)"
git init -q --bare --initial-branch=main "$remote"
git -C "$repo" remote add origin "$remote"
git -C "$repo" push -q origin main
git -C "$repo" checkout -qb agent/issue-123
printf 'local\n' >> "$repo/file.txt"
git -C "$repo" commit -qam local
local_sha="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb remote-fixture "$base_sha"
printf 'remote\n' >> "$repo/file.txt"
git -C "$repo" commit -qam remote
diverged_sha="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" push -q origin "$diverged_sha:refs/heads/agent/issue-123"
git -C "$repo" checkout -q agent/issue-123

cat > "$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${PUSH_GUARD_API_DOWN:-0}" == 1 ]]; then
  echo 'fixture API offline' >&2
  exit 1
fi
case "${1:-} ${2:-}" in
  'pr view')
    jq -cn --arg sha "$PUSH_GUARD_REMOTE_SHA" \
      '{number:123,headRefName:"agent/issue-123",headRefOid:$sha,baseRefName:"main"}'
    ;;
  'pr list')
    jq -cn --arg sha "$PUSH_GUARD_REMOTE_SHA" --arg mergeable "$PUSH_GUARD_MERGEABLE" \
      '[{number:123,headRefName:"agent/issue-123",headRefOid:$sha,baseRefName:"main",mergeable:$mergeable,isDraft:false}]'
    ;;
  'pr checks')
    printf '%s\n' "$PUSH_GUARD_CHECKS"
    [[ "${PUSH_GUARD_CHECK_EXIT:-0}" == 0 ]] || exit "$PUSH_GUARD_CHECK_EXIT"
    ;;
  *) echo "unexpected gh call: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$tmp/bin/gh"
export HOME="$tmp/home" PATH="$tmp/bin:$PATH" ZF_PUSH_GUARD_LOG="$tmp/push-guard.log"

link='https://github.com/example-maintainer/example-repo/actions/runs/999/job/1000'
failed_at='2026-10-10T00:00:00Z'
pass_checks="$(jq -cn --arg link "$link" '[{name:"CI",bucket:"pass",completedAt:"2026-10-10T00:00:00Z",link:$link}]')"
fail_checks="$(jq -cn --arg link "$link" '[{name:"CI",bucket:"fail",completedAt:"2026-10-10T00:00:00Z",link:$link}]')"

set_remote_head() {
  local sha="$1"
  git --git-dir="$remote" update-ref refs/heads/agent/issue-123 "$sha"
  export PUSH_GUARD_REMOTE_SHA="$sha"
}

run_guard() {
  local remote_sha="$1" status=0
  (cd "$repo" && printf 'refs/heads/agent/issue-123 %s refs/heads/agent/issue-123 %s\n' "$local_sha" "$remote_sha" \
    | "$guard" origin "$remote" > "$tmp/stdout" 2> "$tmp/stderr") || status=$?
  return "$status"
}

set_remote_head "$diverged_sha"
export PUSH_GUARD_MERGEABLE=MERGEABLE PUSH_GUARD_CHECKS="$pass_checks" PUSH_GUARD_CHECK_EXIT=0
if run_guard "$diverged_sha"; then echo 'not ok - Rule A refuses green non-fast-forward push' >&2; exit 1; fi
grep -Fq 'Keep this head for the scheduler merge lane' "$tmp/stderr"
echo 'ok - Rule A refuses green mergeable non-fast-forward push'

export PUSH_GUARD_MERGEABLE=CONFLICTING ZF_PUSH_GUARD_OVERRIDE_REASON=conflict-sweeper-conflicting-pr
if ! run_guard "$diverged_sha"; then cat "$tmp/stderr" >&2; echo 'not ok - conflict sweeper override' >&2; exit 1; fi
grep -Fq 'conflict-sweeper-conflicting-pr' "$ZF_PUSH_GUARD_LOG"
unset ZF_PUSH_GUARD_OVERRIDE_REASON
echo 'ok - Rule A allows and logs conflict sweeper override'

set_remote_head "$base_sha"
export PUSH_GUARD_MERGEABLE=MERGEABLE PUSH_GUARD_CHECKS="$fail_checks" PUSH_GUARD_CHECK_EXIT=1
if run_guard "$base_sha"; then echo 'not ok - Rule B refuses missing receipt' >&2; exit 1; fi
grep -Fq -- '--repair-ci-failure-link' "$tmp/stderr"
echo 'ok - Rule B refuses failed CI without receipt'

write_receipt() {
  local status="$1" command="$2" reason="$3" main_sha="${4:-}" failing_path="${5:-}" common failed_ms
  common="$(git -C "$repo" rev-parse --git-common-dir)"
  [[ "$common" == /* ]] || common="$repo/$common"
  mkdir -p "$common/push-guard"
  failed_ms="$(node -p 'Date.parse(process.argv[1])' "$failed_at")"
  jq -cn --arg branch agent/issue-123 --arg link "$link" --arg check CI \
    --arg failed_head "$base_sha" --arg failed_at "$failed_at" --arg tested_head "$local_sha" \
    --arg recorded_at '2026-10-10T00:00:01.000Z' --arg status "$status" --arg command "$command" \
    --arg reason "$reason" --arg main_head "$main_sha" --arg failing_path "$failing_path" \
    --argjson failed_ms "$failed_ms" --argjson recorded_ms "$((failed_ms + 1000))" \
    '{version:(if $status == "reproduces-on-main" then 3 else 2 end),branch:$branch,prNumber:123,failureLink:$link,checkName:$check,failedHeadSha:$failed_head,
      failedAt:$failed_at,failedAtMs:$failed_ms,testedHeadSha:$tested_head,recordedAt:$recorded_at,
      recordedAtMs:$recorded_ms,status:$status}
      + if $status == "passed" then {scope:"whole-check",command:$command}
        elif $status == "focused-passed" then {scope:"failing-unit",command:$command,failingPath:$failing_path}
        elif $status == "ci-only" then {reason:$reason}
        else {scope:"failing-unit",command:$command,mainHeadSha:$main_head,failingPath:$failing_path}
          + if $status == "reproduces-on-main" then {reproductionEvidence:{failingPath:$failing_path,
              testedHeadFailure:($failing_path + " :: not ok 1 - focused test"),
              mainFailure:($failing_path + " :: not ok 1 - focused test")}} else {} end end' \
    > "$common/push-guard/repair-records.jsonl"
}

write_receipt passed 'pnpm --filter @example/test test -- focused.test.ts' ''
if ! run_guard "$base_sha"; then cat "$tmp/stderr" >&2; echo 'not ok - passed receipt' >&2; exit 1; fi
echo 'ok - Rule B allows matching post-failure command receipt'

write_receipt ci-only '' 'CI-only infrastructure: local Docker runtime unavailable'
if ! run_guard "$base_sha"; then cat "$tmp/stderr" >&2; echo 'not ok - CI-only receipt' >&2; exit 1; fi
echo 'ok - Rule B allows and records CI-only limitation receipt'

write_receipt reproduces-on-main 'pnpm --filter @example/test test -- focused.test.ts' '' "$base_sha" package.json
if ! run_guard "$base_sha"; then cat "$tmp/stderr" >&2; echo 'not ok - main reproduction receipt' >&2; exit 1; fi
echo 'ok - Rule B allows exact failing command reproduced on origin/main outside PR diff'
jq '.version = 2 | del(.reproductionEvidence)' "$repo/.git/push-guard/repair-records.jsonl" > "$tmp/legacy-reproduction.jsonl"
mv "$tmp/legacy-reproduction.jsonl" "$repo/.git/push-guard/repair-records.jsonl"
if run_guard "$base_sha"; then echo 'not ok - legacy reproduction receipt without target failure evidence' >&2; exit 1; fi
echo 'ok - Rule B refuses legacy main reproduction receipt without target failure evidence'

write_receipt stale-on-main 'pnpm --filter @example/test test -- focused.test.ts' '' "$base_sha" package.json
if ! run_guard "$base_sha"; then cat "$tmp/stderr" >&2; echo 'not ok - stale-on-main receipt' >&2; exit 1; fi
echo 'ok - Rule B allows a focused unit classified against fresh origin/main'

main_red_link='https://github.com/example-maintainer/example-repo/actions/runs/888/job/1000'
main_red_checks="$(jq -cn --arg link "$main_red_link" '[{name:"CI",bucket:"fail",completedAt:"2026-10-10T00:00:00Z",link:$link}]')"
set_remote_head "$base_sha"
export PUSH_GUARD_CHECKS="$main_red_checks" ZF_PUSH_GUARD_OVERRIDE_REASON=main-red-stale-shared-failure
if ! (cd "$repo" && bash "$guard" --record-override 123 888 "$main_red_link"); then
  echo 'not ok - main-red override record' >&2
  exit 1
fi
if ! run_guard "$base_sha"; then cat "$tmp/stderr" >&2; echo 'not ok - guard must consume main-red override event' >&2; exit 1; fi
echo 'ok - guard consumes exact main-red override event for matching PR head and failed run'

set_remote_head "$diverged_sha"
if run_guard "$diverged_sha"; then echo 'not ok - main-red override must not authorize a different remote head' >&2; exit 1; fi
grep -Fq 'failed-ci-without-receipt' "$ZF_PUSH_GUARD_LOG"
unset ZF_PUSH_GUARD_OVERRIDE_REASON
echo 'ok - main-red override does not authorize different remote head'

set_remote_head "$diverged_sha"
export PUSH_GUARD_API_DOWN=1 PUSH_GUARD_MERGEABLE=MERGEABLE PUSH_GUARD_CHECKS="$pass_checks"
if ! run_guard "$diverged_sha"; then cat "$tmp/stderr" >&2; echo 'not ok - API outage must fail open' >&2; exit 1; fi
grep -Fq 'GitHub API unavailable; allowing push' "$tmp/stderr"
grep -Fq 'api-unavailable' "$ZF_PUSH_GUARD_LOG"
unset PUSH_GUARD_API_DOWN
echo 'ok - GitHub API outage fails open and logs'

export ZF_PUSH_GUARD_OVERRIDE_REASON=main-red-stale-shared-failure
if ! (cd "$repo" && bash "$guard" --record-override 123 999 "$link"); then
  echo 'not ok - main-red override logger' >&2
  exit 1
fi
grep -Fq 'main-red-stale-shared-failure' "$ZF_PUSH_GUARD_LOG"
unset ZF_PUSH_GUARD_OVERRIDE_REASON
echo 'ok - main-red stale update override validates and logs'
jq -se 'map(.event) == ["refusal","override","refusal","refusal","override","override","refusal","api-unavailable","override"]' \
  "$ZF_PUSH_GUARD_LOG" >/dev/null
echo 'ok - each refusal, override and API fail-open appends one event line'

installer="$root/engine/install-pre-push-guard.sh"
install_repo="$tmp/install-repo"
install_remote="$tmp/install-origin.git"
install_home="$tmp/install-home"
mkdir -p "$install_repo/engine" "$install_home/night"
git init -q --initial-branch=main "$install_repo"
git -C "$install_repo" config user.name 'Push Guard Install Test'
git -C "$install_repo" config user.email 'push-guard-install@example.test'
cp "$guard" "$install_repo/engine/pre-push-guard.sh"
cp "$installer" "$install_repo/engine/install-pre-push-guard.sh"
git -C "$install_repo" add engine
git -C "$install_repo" commit -qm 'land guard fixture'
git init -q --bare --initial-branch=main "$install_remote"
git -C "$install_repo" remote add origin "$install_remote"
git -C "$install_repo" push -q origin main
git -C "$install_repo" fetch -q origin main
install_common="$(git -C "$install_repo" rev-parse --git-common-dir)"
if [[ "$install_common" != /* ]]; then install_common="$install_repo/$install_common"; fi
install_hook="$install_common/hooks/pre-push"
install_log="$install_home/night/night.log"
AGENT_HOME="$install_home" ZF_PUSH_GUARD_LOG="$install_log" bash "$installer" "$install_repo" 2> "$tmp/install.stderr"
cmp -s "$install_hook" "$install_repo/engine/pre-push-guard.sh"
echo 'ok - dispatcher installer installs exact guard version present on origin/main'

printf '# drift\n' >> "$install_hook"
AGENT_HOME="$install_home" ZF_PUSH_GUARD_LOG="$install_log" bash "$installer" "$install_repo" 2> "$tmp/install.stderr"
cmp -s "$install_hook" "$install_repo/engine/pre-push-guard.sh"
echo 'ok - installer removes and replaces hook that drifted from origin/main'

printf '\n# not landed\n' >> "$install_repo/engine/pre-push-guard.sh"
AGENT_HOME="$install_home" ZF_PUSH_GUARD_LOG="$install_log" bash "$installer" "$install_repo" 2> "$tmp/install.stderr"
[[ ! -e "$install_hook" ]]
git -C "$install_repo" checkout -q -- engine/pre-push-guard.sh
AGENT_HOME="$install_home" ZF_PUSH_GUARD_LOG="$install_log" bash "$installer" "$install_repo" 2> "$tmp/install.stderr"
cmp -s "$install_hook" "$install_repo/engine/pre-push-guard.sh"
echo 'ok - unlanded guard edit disables hook instead of installing ahead of main'

printf '# runtime drift\n' >> "$install_hook"
if ! (cd "$install_repo" && printf '' | AGENT_HOME="$install_home" ZF_PUSH_GUARD_LOG="$install_log" \
  bash "$install_hook" origin "$install_remote" 2> "$tmp/install.stderr"); then
  cat "$tmp/install.stderr" >&2
  echo 'not ok - stale installed hook should self-remove and fail open' >&2
  exit 1
fi
[[ ! -e "$install_hook" ]]
echo 'ok - installed hook self-removes and fails open when its body differs from origin/main'

grep -Fq 'hook-drift-removed' "$install_log"
if grep -Fq 'install-pre-push-guard.sh' "$root/engine/night/dispatch.sh"; then
  echo 'ok - dispatcher invokes landed-only hook installer'
else
  echo 'not ok - dispatcher does not invoke hook installer' >&2
  exit 1
fi

