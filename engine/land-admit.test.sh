#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/land-admit.sh"

fail() { printf 'land-admit.test.sh: %s\n' "$*" >&2; exit 1; }
repo_root="$(git -C "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" rev-parse --show-toplevel)"
seed_eval_map() {
  mkdir -p "$1/engine/eval"
  cp "$repo_root/engine/eval/decision-stages.sh" "$1/engine/eval/decision-stages.sh"
}

land_candidate_eval_admission_check "$repo_root" 'engine/prompts/triage.md' \
  || fail 'paired evaluation admission refused a measured prompt'
for path in engine/prompts/retro.md .zenoforge/prompts/retro.md .agents/skills/retro/SKILL.md; do
  if land_candidate_eval_admission_check "$repo_root" "$path" >"$test_env_root/stdout" 2>"$test_env_root/stderr"; then
    fail "paired evaluation admission accepted unmeasurable input $path"
  fi
  [[ "$(cat "$test_env_root/stderr")" == *'candidate input is unmeasurable; leave it as an observation'* ]] \
    || fail "paired evaluation refusal did not explain that $path stays an observation"
done

pin_target="$test_env_root/pin-target"
mkdir -p "$pin_target/.zenoforge" "$test_env_root/published-engine/eval"
printf '{}\n' >"$pin_target/.zenoforge/build.json"
cp "$repo_root/engine/eval/decision-stages.sh" "$test_env_root/published-engine/eval/decision-stages.sh"
if land_prompt_byte_budget_check "$pin_target" '' '' '.zenoforge/build.json' "$pin_target" >"$test_env_root/stdout" 2>"$test_env_root/stderr"; then
  fail 'admission passed without a stage mapping'
fi
land_prompt_byte_budget_check "$pin_target" '' '' '.zenoforge/build.json' "$repo_root" \
  || fail 'pin-only diff refused with the stage mapping in the engine root'
land_prompt_byte_budget_check "$pin_target" '' '' '.zenoforge/build.json' "$test_env_root/published-engine" \
  || fail 'pin-only diff refused with the stage mapping in a published engine directory'

assert_green_rc() {
  local expected_rc="$1" receipt="$2" expected_stderr="${3-}" actual_rc
  if land_receipt_green "$receipt" >"$test_env_root/stdout" 2>"$test_env_root/stderr"; then
    actual_rc=0
  else
    actual_rc=$?
  fi
  [[ "$actual_rc" == "$expected_rc" ]] || fail "expected receipt rc $expected_rc, got $actual_rc for $receipt"
  [[ ! -s "$test_env_root/stdout" ]] || fail "receipt check wrote to stdout: $(cat "$test_env_root/stdout")"
  if [[ -n "$expected_stderr" ]]; then
    [[ "$(cat "$test_env_root/stderr")" == *"$expected_stderr"* ]] || fail "stderr lacks '$expected_stderr': $(cat "$test_env_root/stderr")"
  fi
}

receipt="$test_env_root/receipt"
assert_green_rc 1 "$test_env_root/missing" 'refuse:receipt:missing'

: >"$receipt"
assert_green_rc 1 "$receipt" 'refuse:receipt:empty'

printf 'bad\tcommand\n-1\tcommand\n' >"$receipt"
assert_green_rc 1 "$receipt" 'refuse:receipt:no-valid-lines'

printf '0\tbash engine/example.test.sh\n' >"$receipt"
assert_green_rc 0 "$receipt"

printf '1\tbash engine/example.test.sh\n0\tbash engine/example.test.sh\n' >"$receipt"
assert_green_rc 0 "$receipt"

printf '0\tbash engine/example.test.sh\n1\tbash engine/example.test.sh\n' >"$receipt"
assert_green_rc 1 "$receipt" 'refuse:receipt:failed:bash engine/example.test.sh'

printf '0\tfirst command\n2\tsecond command\n' >"$receipt"
assert_green_rc 1 "$receipt" 'refuse:receipt:failed:second command'

printf '0\tgood command\nnot-a-receipt-line\n' >"$receipt"
LAND_RECEIPT_STRICT=1 assert_green_rc 1 "$receipt" 'malformed receipt line 2'
[[ "$(cat "$test_env_root/stderr")" == 'malformed receipt line 2' ]] || fail 'strict receipt changed the malformed-line refusal'

printf '1\tcommand\tone\n0\tcommand\ttwo\n' >"$receipt"
assert_green_rc 0 "$receipt"
LAND_RECEIPT_STRICT=1 assert_green_rc 1 "$receipt" $'command\tone (exit 1)'
[[ "$(cat "$test_env_root/stderr")" == $'command\tone (exit 1)' ]] || fail 'strict receipt did not retain the full command'

printf '0\t\n' >"$receipt"
LAND_RECEIPT_STRICT=1 assert_green_rc 1 "$receipt" 'malformed receipt line 1'

budget_fixture="$test_env_root/prompt-budget"
mkdir -p "$budget_fixture/engine/prompts"
printf 'review-contract.md\t8192\n' > "$budget_fixture/engine/prompts/byte-budgets.tsv"
head -c 8193 /dev/zero > "$budget_fixture/engine/prompts/review-contract.md"
if land_prompt_byte_budget_check "$budget_fixture" >"$test_env_root/stdout" 2>"$test_env_root/stderr"; then
  fail 'landing accepted an over-budget prompt fixture'
else
  rc=$?
fi
[[ "$rc" == 1 ]] || fail "prompt byte budget returned $rc instead of 1"
[[ "$(cat "$test_env_root/stderr")" == 'engine/prompts/review-contract.md is 8193 bytes, budget 8192 bytes' ]] \
  || fail "prompt byte-budget refusal omitted its path, size or budget: $(cat "$test_env_root/stderr")"

agent_budget_fixture="$test_env_root/agent-budget"
mkdir -p "$agent_budget_fixture"
head -c 8193 /dev/zero > "$agent_budget_fixture/AGENTS.md"
if land_prompt_byte_budget_check "$agent_budget_fixture" '' '' 'AGENTS.md' "$repo_root" >"$test_env_root/stdout" 2>"$test_env_root/stderr"; then
  fail 'landing accepted over-budget always-loaded instructions'
else
  rc=$?
fi
[[ "$rc" == 1 ]] || fail "always-loaded text budget returned $rc instead of 1"
[[ "$(cat "$test_env_root/stderr")" == 'AGENTS.md is 8193 bytes, budget 8192 bytes; remove or demote lower-value text' ]] \
  || fail "always-loaded text refusal omitted its size, budget or remedy: $(cat "$test_env_root/stderr")"
rm "$agent_budget_fixture/AGENTS.md"
head -c 8193 /dev/zero > "$agent_budget_fixture/AGENTS.override.md"
if land_prompt_byte_budget_check "$agent_budget_fixture" '' '' 'AGENTS.override.md' "$repo_root" >"$test_env_root/stdout" 2>"$test_env_root/stderr"; then
  fail 'landing accepted over-budget always-loaded override instructions'
fi
[[ "$(cat "$test_env_root/stderr")" == 'AGENTS.override.md is 8193 bytes, budget 8192 bytes; remove or demote lower-value text' ]] \
  || fail "always-loaded override refusal omitted its size, budget or remedy: $(cat "$test_env_root/stderr")"
head -c 4097 /dev/zero > "$agent_budget_fixture/AGENTS.md"
head -c 4096 /dev/zero > "$agent_budget_fixture/AGENTS.override.md"
if land_prompt_byte_budget_check "$agent_budget_fixture" '' '' 'AGENTS.override.md' "$repo_root" >"$test_env_root/stdout" 2>"$test_env_root/stderr"; then
  fail 'landing accepted combined over-budget always-loaded instructions'
fi
[[ "$(cat "$test_env_root/stderr")" == 'AGENTS.md + AGENTS.override.md is 8193 bytes, budget 8192 bytes; remove or demote lower-value text' ]] \
  || fail "combined always-loaded text refusal omitted its size, budget or remedy: $(cat "$test_env_root/stderr")"
claude_budget_fixture="$test_env_root/claude-budget"
mkdir -p "$claude_budget_fixture"
head -c 8193 /dev/zero > "$claude_budget_fixture/CLAUDE.md"
if land_prompt_byte_budget_check "$claude_budget_fixture" '' '' 'CLAUDE.md' "$repo_root" >"$test_env_root/stdout" 2>"$test_env_root/stderr"; then
  fail 'landing accepted over-budget always-loaded Claude instructions'
fi
[[ "$(cat "$test_env_root/stderr")" == 'CLAUDE.md is 8193 bytes, budget 8192 bytes; remove or demote lower-value text' ]] \
  || fail "always-loaded Claude refusal omitted its size, budget or remedy: $(cat "$test_env_root/stderr")"

selective_fixture="$test_env_root/selective-prompt-budget"
mkdir -p "$selective_fixture/engine/prompts"
printf 'review-contract.md\t4\nother.md\t4\n' > "$selective_fixture/engine/prompts/byte-budgets.tsv"
head -c 4 /dev/zero > "$selective_fixture/engine/prompts/review-contract.md"
head -c 5 /dev/zero > "$selective_fixture/engine/prompts/other.md"
land_prompt_byte_budget_check "$selective_fixture" '' '' 'engine/prompts/review-contract.md' "$repo_root" \
  || fail 'prompt landing check scanned an unchanged template'
if land_prompt_byte_budget_check "$selective_fixture" '' '' 'engine/prompts/byte-budgets.tsv' "$repo_root" \
  >"$test_env_root/stdout" 2>"$test_env_root/stderr"; then
  fail 'budget-table change did not rescan every prompt template'
fi
[[ "$(cat "$test_env_root/stderr")" == 'engine/prompts/other.md is 5 bytes, budget 4 bytes' ]] \
  || fail 'budget-table change did not report the over-budget untouched template'

source_fixture="$test_env_root/source-fixture"
mkdir -p "$source_fixture/tools" "$source_fixture/engine"
cp "$MODEL_POLICY_TEST_REPO/tools/merge-pr.sh" "$MODEL_POLICY_TEST_REPO/tools/merge-pr-bootstrap.sh" "$source_fixture/tools/"
cp "$MODEL_POLICY_TEST_REPO/engine/land-admit.sh" "$source_fixture/engine/"
(cd "$test_env_root" && source "$source_fixture/tools/merge-pr.sh" && declare -F land_receipt_green >/dev/null) \
  || fail 'merge helper could not load admission from its own checkout'
if (cd "$test_env_root" && source "$source_fixture/tools/merge-pr.sh" && merge_pr_squash invalid 0123456789abcdef0123456789abcdef01234567) 2>/dev/null; then
  fail 'merge helper accepted an invalid PR'
else
  rc=$?
fi
[[ "$rc" == 1 ]] || fail "merge helper returned $rc instead of 1 for an invalid PR"
rm "$source_fixture/engine/land-admit.sh"
if (cd "$test_env_root" && source "$source_fixture/tools/merge-pr.sh") >"$test_env_root/stdout" 2>"$test_env_root/stderr"; then
  fail 'merge helper accepted a missing admission file'
fi
[[ "$(cat "$test_env_root/stderr")" == 'merge-pr: cannot load engine/land-admit.sh' ]] || fail 'missing admission file did not produce one clear error'

repo="$test_env_root/repo"
mkdir -p "$repo"
git init -q "$repo"
path="$(land_receipt_file "$repo" head-sha)" || fail 'land_receipt_file refused a Git repository'
[[ "$path" == */zf-test-receipts/head-sha ]] || fail "receipt path has wrong suffix: $path"

ordinary_dir="$test_env_root/ordinary"
mkdir -p "$ordinary_dir"
if land_receipt_file "$ordinary_dir" head-sha >"$test_env_root/stdout" 2>"$test_env_root/stderr"; then
  fail 'land_receipt_file accepted an ordinary directory'
else
  rc=$?
fi
[[ "$rc" == 1 ]] || fail "land_receipt_file returned $rc for an ordinary directory"
[[ ! -s "$test_env_root/stdout" ]] || fail "land_receipt_file wrote unexpected output: $(cat "$test_env_root/stdout")"

GH_LOG_DIR="$test_env_root/gh-calls"
mkdir -p "$GH_LOG_DIR"
GH_CALL_COUNT=0
GH_RC=0
GH_API_RC=0
GH_DELETE_RC=0
GH_META_RC=0
GH_FILES_RC=0
GH_FILES_OUTPUT=''
GH_FILES_JSON_OUTPUT=''
GH_META_OUTPUT='{"head":{"ref":"feature/topic"}}'

gh() {
  local method="" call_number
  if [[ -f "$GH_LOG_DIR/count" ]]; then
    read -r call_number < "$GH_LOG_DIR/count"
  else
    call_number=0
  fi
  call_number=$((call_number + 1))
  printf '%s\n' "$call_number" > "$GH_LOG_DIR/count"
  GH_CALL_COUNT="$call_number"
  printf '%s\0' "$@" > "$GH_LOG_DIR/call-$GH_CALL_COUNT"
  case "${1-} ${2-} ${3-}" in
    'pr merge '*) printf 'gh merge output\n'; return "$GH_RC" ;;
    'pr view '*) [[ "${GH_VIEW_RC:-0}" == 0 ]] || return "$GH_VIEW_RC"; printf '{"headRefName":"feature/topic"}\n'; return 0 ;;
    'api '*)
      local arg
      for arg in "$@"; do
        if [[ "$arg" == *'/pulls/'*'/files?per_page='* ]]; then
          if [[ -n "$GH_FILES_JSON_OUTPUT" ]]; then
            local jq_filter='' i
            local -a api_args=("$@")
            for ((i = 0; i + 1 < ${#api_args[@]}; i++)); do
              [[ "${api_args[i]}" == --jq ]] || continue
              jq_filter="${api_args[i + 1]}"
            done
            printf '%s\n' "$GH_FILES_JSON_OUTPUT" | command jq -r "$jq_filter"
          else
            printf '%s\n' "$GH_FILES_OUTPUT"
          fi
          return "$GH_FILES_RC"
        fi
      done
      while (($#)); do
        if [[ "$1" == -X && $# -ge 2 ]]; then
          method="$2"
          break
        fi
        shift
      done
      case "$method" in
        PUT) [[ -z "${GH_API_OUTPUT:-}" ]] || printf '%s\n' "$GH_API_OUTPUT" >&2; return "$GH_API_RC" ;;
        DELETE) return "$GH_DELETE_RC" ;;
        '') [[ "$GH_META_RC" == 0 ]] || return "$GH_META_RC"; printf '%s\n' "$GH_META_OUTPUT"; return 0 ;;
      esac
      ;;
  esac
  return 90
}

reset_gh_calls() {
  GH_CALL_COUNT=0
  rm -f "$GH_LOG_DIR"/call-*
  rm -f "$GH_LOG_DIR/count"
}

gh_call_count() {
  if [[ -f "$GH_LOG_DIR/count" ]]; then
    cat "$GH_LOG_DIR/count"
  else
    printf '0\n'
  fi
}

assert_merge_rc() {
  local expected_rc="$1" expected_stderr="$2" actual_rc
  shift 2
  if land_merge_pr "$@" >"$test_env_root/stdout" 2>"$test_env_root/stderr"; then
    actual_rc=0
  else
    actual_rc=$?
  fi
  [[ "$actual_rc" == "$expected_rc" ]] || fail "expected land_merge_pr rc $expected_rc, got $actual_rc"
  if [[ -n "$expected_stderr" ]]; then
    [[ "$(cat "$test_env_root/stderr")" == *"$expected_stderr"* ]] \
      || fail "land_merge_pr stderr lacks '$expected_stderr': $(cat "$test_env_root/stderr")"
  fi
}

read_gh_call() {
  local call_number="$1"
  mapfile -d '' -t GH_ARGS < "$GH_LOG_DIR/call-$call_number"
}

assert_gh_arg() {
  local expected="$1" arg
  for arg in "${GH_ARGS[@]}"; do
    [[ "$arg" == "$expected" ]] && return 0
  done
  fail "gh arguments lack '$expected'"
}

assert_gh_pair() {
  local expected_flag="$1" expected_value="$2" i
  for ((i = 0; i < ${#GH_ARGS[@]} - 1; i++)); do
    if [[ "${GH_ARGS[$i]}" == "$expected_flag" && "${GH_ARGS[$((i + 1))]}" == "$expected_value" ]]; then
      return 0
    fi
  done
  fail "gh arguments lack '$expected_flag' followed by '$expected_value'"
}

valid_sha='0123456789abcdef0123456789abcdef01234567'
assert_merge_rc 64 'refuse:merge:bad-pr' abc "$valid_sha"
[[ "$(gh_call_count)" == 0 ]] || fail 'land_merge_pr called gh for an invalid PR number'

reset_gh_calls
assert_merge_rc 64 'refuse:merge:bad-head' 17 "${valid_sha:0:12}"
[[ "$(gh_call_count)" == 0 ]] || fail 'land_merge_pr called gh for a short head SHA'

reset_gh_calls
assert_merge_rc 64 'refuse:merge:bad-head' 17 "${valid_sha^^}"
[[ "$(gh_call_count)" == 0 ]] || fail 'land_merge_pr called gh for an uppercase head SHA'

reset_gh_calls
assert_merge_rc 64 'refuse:merge:bad-option' 17 "$valid_sha" --unknown
[[ "$(gh_call_count)" == 0 ]] || fail 'land_merge_pr called gh for an unknown option'

LAND_PROMPT_GUARD_RC=1
land_pr_prompt_byte_budget_check() {
  [[ "$1" == 17 && "$2" == "$valid_sha" && "$3" == owner/project ]] \
    || fail 'land_merge_pr did not pass the pinned PR, head, and repo to prompt admission'
  printf 'engine/prompts/review-contract.md is 8193 bytes, budget 8192 bytes\n' >&2
  return "$LAND_PROMPT_GUARD_RC"
}
reset_gh_calls
assert_merge_rc 1 'engine/prompts/review-contract.md is 8193 bytes, budget 8192 bytes' \
  17 "$valid_sha" --repo owner/project
[[ "$(gh_call_count)" == 0 ]] || fail 'land_merge_pr reached GitHub merge after prompt admission refused'
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/land-admit.sh"

reset_gh_calls
GH_RC=0
assert_merge_rc 0 '' 17 "$valid_sha"
[[ "$(gh_call_count)" == 2 ]] || fail "land_merge_pr made $(gh_call_count) gh calls for a normal merge"
[[ "$(cat "$test_env_root/stdout")" == 'gh merge output' ]] || fail 'land_merge_pr did not pass gh output through'
read_gh_call 2
[[ "${GH_ARGS[0]}" == pr && "${GH_ARGS[1]}" == merge && "${GH_ARGS[2]}" == 17 ]] \
  || fail 'land_merge_pr called gh with the wrong merge command'
assert_gh_arg --squash
assert_gh_pair --match-head-commit "$valid_sha"

reset_gh_calls
assert_merge_rc 0 '' 17 "$valid_sha" --delete-branch
read_gh_call 2
[[ "${GH_ARGS[*]}" == "pr merge 17 --squash --delete-branch --match-head-commit $valid_sha" ]] \
  || fail 'land_merge_pr changed the merge helper argument order'

reset_gh_calls
subject='ship the "quoted" change'
body='release note with "quotes"'
assert_merge_rc 0 '' 18 "$valid_sha" --repo owner/project --subject "$subject" --body "$body" --delete-branch
[[ "$(gh_call_count)" == 2 ]] || fail "land_merge_pr made $(gh_call_count) gh calls with merge options"
read_gh_call 2
assert_gh_pair --repo owner/project
assert_gh_pair --subject "$subject"
assert_gh_pair --body "$body"
assert_gh_arg --delete-branch

reset_gh_calls
unset LAND_MERGE_REST_FALLBACK
GH_RC=1
assert_merge_rc 1 '' 19 "$valid_sha"
[[ "$(gh_call_count)" == 2 ]] || fail "land_merge_pr made $(gh_call_count) gh calls without REST fallback"

reset_gh_calls
LAND_MERGE_REST_FALLBACK=1
GH_RC=1
GH_API_RC=0
GH_DELETE_RC=0
assert_merge_rc 0 '' 20 "$valid_sha" --repo owner/project
[[ "$(gh_call_count)" == 5 ]] || fail "land_merge_pr made $(gh_call_count) gh calls with REST fallback"
read_gh_call 4
assert_gh_arg 'repos/{owner}/{repo}/pulls/20/merge'
assert_gh_arg "sha=$valid_sha"
assert_gh_pair --repo owner/project
read_gh_call 5
assert_gh_arg 'repos/{owner}/{repo}/git/refs/heads/feature/topic'

reset_gh_calls
GH_VIEW_RC=1
GH_DELETE_RC=5
assert_merge_rc 0 '' 20 "$valid_sha" --repo owner/project --delete-branch
[[ "$(gh_call_count)" == 6 ]] || fail 'REST fallback did not recover the head ref or ignore deletion failure'
read_gh_call 4
assert_gh_arg 'repos/{owner}/{repo}/pulls/20'
assert_gh_pair --repo owner/project
read_gh_call 5
assert_gh_arg 'repos/{owner}/{repo}/pulls/20/merge'
read_gh_call 6
assert_gh_arg 'repos/{owner}/{repo}/git/refs/heads/feature/topic'

reset_gh_calls
GH_META_OUTPUT='invalid metadata'
assert_merge_rc 1 '' 20 "$valid_sha" --repo owner/project --delete-branch
[[ ! -s "$test_env_root/stderr" ]] || fail 'malformed REST metadata leaked a parser error'
[[ "$(gh_call_count)" == 4 ]] || fail 'malformed REST metadata reached the merge or deletion call'
GH_META_OUTPUT='{"head":{"ref":"feature/topic"}}'

reset_gh_calls
GH_META_RC=1
assert_merge_rc 1 '' 20 "$valid_sha" --repo owner/project --delete-branch
[[ ! -s "$test_env_root/stderr" ]] || fail 'failed REST metadata read changed the refusal output'
[[ "$(gh_call_count)" == 4 ]] || fail 'failed REST metadata read reached the merge or deletion call'
GH_META_RC=0

prompt_remote="$test_env_root/prompt-remote.git"
prompt_repo="$test_env_root/prompt-repo"
git init --bare -q "$prompt_remote"
git init -q "$prompt_repo"
git -C "$prompt_repo" config user.email agent@example.invalid
git -C "$prompt_repo" config user.name agent
seed_eval_map "$prompt_repo"
mkdir -p "$prompt_repo/engine/prompts"
printf 'review-contract.md\t4\n' > "$prompt_repo/engine/prompts/byte-budgets.tsv"
head -c 5 /dev/zero > "$prompt_repo/engine/prompts/review-contract.md"
git -C "$prompt_repo" add engine/prompts
git -C "$prompt_repo" commit -qm 'fixture: over-budget prompt'
prompt_sha="$(git -C "$prompt_repo" rev-parse HEAD)"
git -C "$prompt_repo" remote add origin "$prompt_remote"
git -C "$prompt_repo" push -q origin HEAD:refs/pull/37/head
GH_FILES_OUTPUT='engine/prompts/review-contract.md'
reset_gh_calls
git() {
  [[ "$*" != *' archive '* ]] || { printf 'prompt budget check exported the full tree\n' >&2; return 97; }
  command git "$@"
}
if (cd "$prompt_repo" && land_merge_pr 37 "$prompt_sha" --repo owner/project) \
  >"$test_env_root/stdout" 2>"$test_env_root/stderr"; then
  fail 'land_merge_pr accepted an over-budget prompt from the pinned PR head'
fi
unset -f git
[[ "$(cat "$test_env_root/stderr")" == *'engine/prompts/review-contract.md is 5 bytes, budget 4 bytes'* ]] \
  || fail "pinned PR check omitted the prompt size or budget: $(cat "$test_env_root/stderr")"
[[ "$(gh_call_count)" == 1 ]] || fail 'over-budget PR reached the GitHub merge command'
GH_FILES_OUTPUT=''

agent_remote="$test_env_root/agent-remote.git"
agent_repo="$test_env_root/agent-repo"
git init --bare -q "$agent_remote"
git init -q "$agent_repo"
git -C "$agent_repo" config user.email agent@example.invalid
git -C "$agent_repo" config user.name agent
seed_eval_map "$agent_repo"
printf 'x' > "$agent_repo/CLAUDE.md"
git -C "$agent_repo" add -A
git -C "$agent_repo" commit -qm 'fixture: accepted Claude instructions'
head -c 8192 /dev/zero > "$agent_repo/AGENTS.md"
git -C "$agent_repo" add AGENTS.md
git -C "$agent_repo" commit -qm 'fixture: combined over-budget instructions'
agent_sha="$(git -C "$agent_repo" rev-parse HEAD)"
git -C "$agent_repo" remote add origin "$agent_remote"
git -C "$agent_repo" push -q origin HEAD:refs/pull/38/head
GH_FILES_OUTPUT='AGENTS.md'
reset_gh_calls
if (cd "$agent_repo" && land_merge_pr 38 "$agent_sha" --repo owner/project) \
  >"$test_env_root/stdout" 2>"$test_env_root/stderr"; then
  fail 'land_merge_pr accepted over-budget always-loaded instructions'
fi
[[ "$(cat "$test_env_root/stderr")" == *'CLAUDE.md + AGENTS.md is 8193 bytes, budget 8192 bytes; remove or demote lower-value text'* ]] \
  || fail "pinned PR check omitted the always-loaded text refusal: $(cat "$test_env_root/stderr")"
[[ "$(gh_call_count)" == 1 ]] || fail 'over-budget AGENTS.md PR reached the GitHub merge command'
GH_FILES_OUTPUT=''

rename_remote="$test_env_root/rename-remote.git"
rename_repo="$test_env_root/rename-repo"
git init --bare -q "$rename_remote"
git init -q "$rename_repo"
git -C "$rename_repo" config user.email agent@example.invalid
git -C "$rename_repo" config user.name agent
seed_eval_map "$rename_repo"
mkdir -p "$rename_repo/.agents/skills/retro"
printf 'unmeasured skill\n' > "$rename_repo/.agents/skills/retro/SKILL.md"
git -C "$rename_repo" add -A
git -C "$rename_repo" commit -qm 'fixture: unmeasured skill'
git -C "$rename_repo" remote add origin "$rename_remote"
git -C "$rename_repo" mv .agents/skills/retro/SKILL.md docs-retro.md
git -C "$rename_repo" commit -qm 'fixture: rename unmeasured skill'
rename_sha="$(git -C "$rename_repo" rev-parse HEAD)"
git -C "$rename_repo" push -q origin HEAD:refs/pull/40/head
GH_FILES_JSON_OUTPUT='[{"filename":"docs-retro.md","previous_filename":".agents/skills/retro/SKILL.md"}]'
if (cd "$rename_repo" && land_pr_prompt_byte_budget_check 40 "$rename_sha" owner/project) \
  >"$test_env_root/stdout" 2>"$test_env_root/stderr"; then
  fail 'renamed unmeasurable skill passed PR admission'
fi
[[ "$(cat "$test_env_root/stderr")" == *'candidate input is unmeasurable; leave it as an observation'* ]] \
  || fail 'PR admission missed the previous filename of a renamed skill'
GH_FILES_JSON_OUTPUT=''

override_remote="$test_env_root/override-remote.git"
override_repo="$test_env_root/override-repo"
git init --bare -q "$override_remote"
git init -q "$override_repo"
git -C "$override_repo" config user.email agent@example.invalid
git -C "$override_repo" config user.name agent
seed_eval_map "$override_repo"
head -c 5000 /dev/zero > "$override_repo/AGENTS.md"
git -C "$override_repo" add AGENTS.md
git -C "$override_repo" commit -qm 'fixture: accepted base instructions'
head -c 3193 /dev/zero > "$override_repo/AGENTS.override.md"
git -C "$override_repo" add AGENTS.override.md
git -C "$override_repo" commit -qm 'fixture: over-budget combined instructions'
override_sha="$(git -C "$override_repo" rev-parse HEAD)"
git -C "$override_repo" remote add origin "$override_remote"
git -C "$override_repo" push -q origin HEAD:refs/pull/39/head
GH_FILES_OUTPUT='AGENTS.override.md'
reset_gh_calls
if (cd "$override_repo" && land_merge_pr 39 "$override_sha" --repo owner/project) \
  >"$test_env_root/stdout" 2>"$test_env_root/stderr"; then
  fail 'land_merge_pr accepted combined over-budget always-loaded instructions'
fi
[[ "$(cat "$test_env_root/stderr")" == *'AGENTS.md + AGENTS.override.md is 8193 bytes, budget 8192 bytes; remove or demote lower-value text'* ]] \
  || fail "pinned PR check omitted the combined instruction budget refusal: $(cat "$test_env_root/stderr")"
[[ "$(gh_call_count)" == 1 ]] || fail 'over-budget instruction override PR reached the GitHub merge command'
GH_FILES_OUTPUT=''

reset_gh_calls
GH_VIEW_RC=0
GH_API_RC=1
GH_API_OUTPUT='HTTP 409: Head branch was modified'
assert_merge_rc 1 "refuse:merge:head-moved:$valid_sha is no longer the head, not merged" 20 "$valid_sha" --delete-branch
[[ "$(cat "$test_env_root/stderr")" == "refuse:merge:head-moved:$valid_sha is no longer the head, not merged" ]] || fail 'shared head-moved refusal changed'
[[ "$(gh_call_count)" == 4 ]] || fail 'REST fallback deleted the branch after a failed merge'

reset_gh_calls
LAND_MERGE_PR_REFUSAL=1 assert_merge_rc 1 "refusing to merge PR #20: head moved after the gate: $valid_sha is no longer the head, not merged" 20 "$valid_sha" --delete-branch
[[ "$(cat "$test_env_root/stderr")" == "refusing to merge PR #20: head moved after the gate: $valid_sha is no longer the head, not merged" ]] || fail 'head-moved refusal changed'
[[ "$(gh_call_count)" == 4 ]] || fail 'REST fallback deleted the branch after a failed merge'
unset LAND_MERGE_REST_FALLBACK

echo 'land-admit.test.sh: all assertions passed'
