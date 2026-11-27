#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

root="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
guard="$root/engine/pre-push-guard.sh"
tmp="$test_env_root"

repo="$tmp/repo"
remote="$tmp/origin.git"
mkdir -p "$repo" "$tmp/bin" "$tmp/home"
git init -q --initial-branch=main "$repo"
git -C "$repo" config user.name 'Push Guard Test'
git -C "$repo" config user.email 'push-guard@example.test'
mkdir -p "$repo/engine/ci"
cp "$root/engine/land-admit.sh" "$repo/engine/land-admit.sh"
cp "$root/engine/ci-repair-receipt.mjs" "$repo/engine/ci-repair-receipt.mjs"
cp "$root/engine/ci/pr-required-aggregate.mjs" "$repo/engine/ci/pr-required-aggregate.mjs"
printf 'base\n' > "$repo/file.js"
git -C "$repo" add file.js engine/land-admit.sh engine/ci-repair-receipt.mjs engine/ci/pr-required-aggregate.mjs
git -C "$repo" commit -qm base
base_sha="$(git -C "$repo" rev-parse HEAD)"
git init -q --bare --initial-branch=main "$remote"
git -C "$repo" remote add origin "$remote"
git -C "$repo" push -q origin main
git -C "$repo" fetch -q origin main
git -C "$repo" checkout -qb agent/issue-123
printf 'local\n' >> "$repo/file.js"
git -C "$repo" commit -qam local
local_sha="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -qb agent/issue-docs "$base_sha"
printf 'docs\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" -c user.name='Push Guard Test' -c user.email=push-guard@example.test commit -qm docs
docs_sha="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -q agent/issue-123
git -C "$repo" checkout -qb remote-fixture "$base_sha"
printf 'remote\n' >> "$repo/file.js"
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
  local remote_sha="$1" branch="${2:-agent/issue-123}" pushed_sha="${3:-$local_sha}" status=0
  (cd "$repo" && printf 'refs/heads/%s %s refs/heads/%s %s\n' "$branch" "$pushed_sha" "$branch" "$remote_sha" \
    | "$guard" origin "$remote" > "$tmp/stdout" 2> "$tmp/stderr") || status=$?
  return "$status"
}

write_green_test_receipt() {
  local target="$1" common sha
  common="$(git -C "$target" rev-parse --git-common-dir)"
  [[ "$common" == /* ]] || common="$target/$common"
  sha="$(git -C "$target" rev-parse HEAD)"
  mkdir -p "$common/zf-test-receipts"
  printf '0\tbash engine/example.test.sh\n' > "$common/zf-test-receipts/$sha"
}

common="$(git -C "$repo" rev-parse --git-common-dir)"
[[ "$common" == /* ]] || common="$repo/$common"
receipt="$common/zf-test-receipts/$local_sha"
mkdir -p "$(dirname -- "$receipt")"
set_remote_head "$base_sha"
export PUSH_GUARD_MERGEABLE=CONFLICTING PUSH_GUARD_CHECKS="$pass_checks" PUSH_GUARD_CHECK_EXIT=0
printf '0\tbash engine/example.test.sh\n1\tbash engine/example.test.sh\n' > "$receipt"
if run_guard "$base_sha"; then cat "$tmp/stderr" >&2; echo 'not ok - failed local receipt is refused' >&2; exit 1; fi
grep -Fq 'is not green' "$tmp/stderr"
echo 'ok - failed local receipt is refused'
rm -f -- "$receipt"
if run_guard "$base_sha"; then echo 'not ok - missing local receipt is refused' >&2; exit 1; fi
grep -Fq 'no test receipt' "$tmp/stderr"
echo 'ok - missing local receipt is refused'
printf '0\tbash engine/example.test.sh\n' > "$common/zf-test-receipts/$base_sha"
if run_guard "$base_sha"; then echo 'not ok - receipt for another SHA is refused' >&2; exit 1; fi
grep -Fq 'no test receipt' "$tmp/stderr"
echo 'ok - receipt for another SHA is refused'
rm -f -- "$common/zf-test-receipts/$base_sha"
printf '0\tbash engine/example.test.sh\n' > "$receipt"
if ! run_guard "$base_sha"; then cat "$tmp/stderr" >&2; echo 'not ok - green local receipt' >&2; exit 1; fi
echo 'ok - green local receipt allows push'
if ! run_guard "$base_sha" agent/issue-docs "$docs_sha"; then cat "$tmp/stderr" >&2; echo 'not ok - documentation-only push exemption' >&2; exit 1; fi
echo 'ok - documentation-only push remains exempt'
rm -f -- "$receipt"
git -C "$repo" remote set-url origin https://github.com/example-maintainer/zenoforge.git
if ! run_guard "$base_sha"; then cat "$tmp/stderr" >&2; echo 'not ok - Zenoforge engine push exemption' >&2; exit 1; fi
echo 'ok - Zenoforge engine push remains exempt'
git -C "$repo" remote set-url origin https://github.com/example-maintainer/zenoforge-vecta-pack.git
if run_guard "$base_sha"; then echo 'not ok - Vecta pack still requires a receipt' >&2; exit 1; fi
grep -Fq 'no test receipt' "$tmp/stderr"
echo 'ok - Zenoforge Vecta pack still requires a receipt'
git -C "$repo" remote set-url origin "$remote"
write_green_test_receipt "$repo"
: > "$ZF_PUSH_GUARD_LOG"

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

source "$root/engine/mac-autopilot/scheduler.d/size-admission.sh"
SIZE_ADMISSION_LINES=800
size_repo="$tmp/size-repo"
size_remote="$tmp/size-origin.git"
mkdir -p "$size_repo/engine/mac-autopilot/scheduler.d"
git init -q --initial-branch=main "$size_repo"
git -C "$size_repo" config user.name 'Push Guard Size Test'
git -C "$size_repo" config user.email 'push-guard-size@example.test'
cp "$guard" "$size_repo/engine/pre-push-guard.sh"
cp "$root/engine/install-pre-push-guard.sh" "$size_repo/engine/install-pre-push-guard.sh"
cp "$root/engine/mac-autopilot/scheduler.d/size-admission.sh" "$size_repo/engine/mac-autopilot/scheduler.d/size-admission.sh"
cp "$root/engine/land-admit.sh" "$size_repo/engine/land-admit.sh"
printf 'base\n' > "$size_repo/base.txt"
git -C "$size_repo" add .
git -C "$size_repo" commit -qm base
git init -q --bare --initial-branch=main "$size_remote"
git -C "$size_repo" remote add origin "$size_remote"
git -C "$size_repo" push -q origin main
source "$root/engine/mac-autopilot/scheduler.d/worker-command.sh"
source "$root/engine/mac-autopilot/scheduler.d/clones.sh"
jqf() { command jq "$@"; }
say() { :; }
: > "$tmp/product-lane-skills"
setup_size_worker() {
  local id="$1" branch="$2" unit_json="$3"
  local ROOT="$size_repo" WT_ROOT="$tmp/size-workers" UNITS="$tmp/size-units.json"
  local MAIN_HEAD="$(git -C "$size_repo" rev-parse HEAD)" SHA_RE='^[0-9a-f]{40,64}$'
  local STAMP=test TAG=test ZF_REPO=example/zenoforge ZF_PACK_REL=engine
  local CFG='{"size_admission":{}}' SIZE_ADMISSION_LINES=800 PRODUCT_LANE_SKILLS="$tmp/product-lane-skills"
  printf '%s\n' "$(jqf -cn --argjson unit "$unit_json" '{units:[$unit]}')" > "$UNITS"
  ensure_clone "$id" "$branch"
}
size_worker="$(setup_size_worker issue-801 agent/issue-801 '{"id":"issue-801","lane":"pr"}')"
mkdir -p "$size_worker/src"
awk 'BEGIN { for (i = 0; i < 801; i++) print "line" }' > "$size_worker/src/change.ts"
git -C "$size_worker" add src/change.ts
git -C "$size_worker" commit -qm oversized
write_green_test_receipt "$size_worker"
size_count="$(changed_lines_in_checkout "$size_worker" main)"
[[ "$size_count" == 801 ]] || { echo "not ok - size admission counted $size_count lines instead of 801" >&2; exit 1; }
if size_output="$(git -C "$size_worker" push origin agent/issue-801 2>&1)"; then
  echo 'not ok - 801-line worker push passed' >&2
  exit 1
fi
grep -Fq 'SPLIT' <<<"$size_output" || { printf '%s\n' "$size_output" >&2; echo 'not ok - size refusal omitted SPLIT' >&2; exit 1; }
grep -Fq "$size_count changed lines" <<<"$size_output" || { printf '%s\n' "$size_output" >&2; echo 'not ok - push check count differed from changed_lines_in_checkout' >&2; exit 1; }
echo 'ok - worker push refuses 801 changed lines, reports SPLIT, and uses changed_lines_in_checkout count'

awk 'BEGIN { for (i = 0; i < 800; i++) print "line" }' > "$size_worker/src/change.ts"
git -C "$size_worker" add src/change.ts
git -C "$size_worker" commit -qm 'trim to admitted size'
write_green_test_receipt "$size_worker"
if ! git -C "$size_worker" push -q origin agent/issue-801; then
  echo 'not ok - 800-line worker push was refused' >&2
  exit 1
fi
echo 'ok - worker push admits 800 changed lines'

size_waived_worker="$(setup_size_worker issue-802 agent/issue-802 '{"id":"issue-802","lane":"pr","size_waiver":{"max_lines":1000}}')"
mkdir -p "$size_waived_worker/src"
awk 'BEGIN { for (i = 0; i < 801; i++) print "line" }' > "$size_waived_worker/src/change.ts"
git -C "$size_waived_worker" add src/change.ts
git -C "$size_waived_worker" commit -qm 'waived size'
write_green_test_receipt "$size_waived_worker"
if ! git -C "$size_waived_worker" push -q origin agent/issue-802; then
  echo 'not ok - waived 801-line worker push was refused' >&2
  exit 1
fi
echo 'ok - worker push admits an 801-line diff with the unit size waiver'

