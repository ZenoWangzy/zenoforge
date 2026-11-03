#!/usr/bin/env bash
# Focused recurrence guard: a product PR cannot override an engine file through overrides.tsv or a pack copy.
# 2026-11-03 incident: a product PR forked engine-owned mac-autopilot/scheduler.d/dispatch-queue.sh via a new
# overrides.tsv row; nothing refused it at review and only the converge override guard fired, after merge.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

repo_root="$MAC_AUTOPILOT_ENV_ROOT"
source "$repo_root/engine/incident-rule.sh"
source "$repo_root/engine/mac-autopilot/scheduler.d/review-rules.sh"
source "$repo_root/engine/mac-autopilot/scheduler.d/reports.sh" # findings_block_of validates the synthesized block
jqf() { command jq "$@"; }

fail() { printf 'engine-override-review-gate.test.sh: %s\n' "$*" >&2; exit 1; }

# Engine fixture: a zenoforge-shaped git repo. The pin commit ships the engine file the product forks;
# the guard must classify engine ownership from this pin, not from a list of its own.
engine_repo="$test_env_root/engine-repo"
git init -q "$engine_repo"
git -C "$engine_repo" config user.name 'override gate fixture'
git -C "$engine_repo" config user.email 'override-gate@example.invalid'
mkdir -p "$engine_repo/engine/mac-autopilot/scheduler.d" "$engine_repo/engine/hotfix"
printf 'engine dispatch queue\n' > "$engine_repo/engine/mac-autopilot/scheduler.d/dispatch-queue.sh"
printf 'engine hf-start\n' > "$engine_repo/engine/hotfix/hf-start.sh"
git -C "$engine_repo" add -A
git -C "$engine_repo" commit -qm 'engine fixture'
engine_pin="$(git -C "$engine_repo" rev-parse HEAD)"
hf_blob="$(git -C "$engine_repo" rev-parse "$engine_pin:engine/hotfix/hf-start.sh")"
export ZF_ENGINE_DIR="$engine_repo"

# Product fixture: pins the engine, ships one legitimate override row, and branches off main like a product PR.
product="$test_env_root/product"
git init -q -b main "$product"
git -C "$product" config user.name 'override gate fixture'
git -C "$product" config user.email 'override-gate@example.invalid'
mkdir -p "$product/.zenoforge/build" "$product/src"
printf '{"hook":".zenoforge/build/engine-sync.sh","engine":"%s"}\n' "$engine_pin" > "$product/.zenoforge/build.json"
{
  printf '# engine-relative path\tblob the pinned engine has\n'
  printf 'hotfix/hf-start.sh\t%s\n' "$hf_blob"
} > "$product/.zenoforge/build/overrides.tsv"
printf 'feature\n' > "$product/src/feature.ts"
git -C "$product" add -A
git -C "$product" commit -qm 'product main'
git -C "$product" update-ref refs/remotes/origin/main "$(git -C "$product" rev-parse HEAD)"

# 1. A PR diff adding an overrides row for an engine-owned file is refused at review.
git -C "$product" checkout -q -b agent/issue-5200
printf 'mac-autopilot/scheduler.d/dispatch-queue.sh\t%s\n' "$(printf '1%.0s' {1..40})" \
  >> "$product/.zenoforge/build/overrides.tsv"
git -C "$product" add -A
git -C "$product" commit -qm 'fork the engine dispatch queue'
fork_head="$(git -C "$product" rev-parse HEAD)"
tick_prs() { printf '[{"number":5200,"labels":[]}]'; }
reason="$(engine_override_gate_reason 5200 engine-override-approved "$product" "$fork_head")"
[[ "$reason" == *'.zenoforge/build/overrides.tsv:3'* ]] \
  || fail "refusal does not name the overrides row with file:line: $reason"
[[ "$reason" == *'engine/mac-autopilot/scheduler.d/dispatch-queue.sh'* ]] \
  || fail "refusal does not name the engine path: $reason"
[[ "$reason" == *'engine change: file it on ZenoWangzy/zenoforge'* ]] \
  || fail "refusal does not point the change at the engine repo: $reason"
verdict="$(engine_override_review_verdict 5200 engine-override-approved "$product" "$fork_head" READY)"
[[ "$verdict" == NOT_READY ]] || fail "READY survived an overrides row for an engine file (verdict=$verdict)"
echo 'ok - an overrides row for an engine file is refused with file:line, the engine path, and the engine-change pointer'

# The synthesized findings block must parse and keep its finding (rerun evidence included), or repair gets nothing.
findings_file="$test_env_root/synthesized-findings.md"
printf '```review-findings\n%s\n```\n' "$(engine_override_findings_json "$product" "$fork_head")" > "$findings_file"
parsed="$(findings_block_of "$findings_file")" || fail "synthesized findings block does not parse"
[[ "$(jq -r '.dropped' <<<"$parsed")" == 0 ]] || fail "synthesized finding was dropped from the block"
[[ "$(jq -r '.findings | length' <<<"$parsed")" == 1 ]] || fail "expected exactly one synthesized finding"
[[ "$(jq -r '.findings[0].file' <<<"$parsed")" == '.zenoforge/build/overrides.tsv' ]] \
  || fail "synthesized finding names the wrong file"
echo 'ok - the refusal ships a schema-valid blocking finding with rerun evidence'

# 2. With the approval label the same diff passes; the label name comes from config with a stable default.
[[ "$(engine_override_approved_label '{}')" == engine-override-approved ]] \
  || fail 'default approval label is not engine-override-approved'
[[ "$(engine_override_approved_label '{"engine_override":{"approved_label":"product-override-ok"}}')" == product-override-ok ]] \
  || fail 'configured approval label is not read from engine_override.approved_label'
tick_prs() { printf '[{"number":5200,"labels":[{"name":"engine-override-approved"}]}]'; }
verdict="$(engine_override_review_verdict 5200 engine-override-approved "$product" "$fork_head" READY)"
[[ "$verdict" == READY ]] || fail "the approval label did not skip the guard (verdict=$verdict)"
tick_prs() { printf '[{"number":5200,"labels":[{"name":"product-override-ok"}]}]'; }
verdict="$(engine_override_review_verdict 5200 product-override-ok "$product" "$fork_head" READY)"
[[ "$verdict" == READY ]] || fail "a configured approval label did not skip the guard (verdict=$verdict)"
tick_prs() { printf '[{"number":5200,"labels":[{"name":"some-other-label"}]}]'; }
verdict="$(engine_override_review_verdict 5200 engine-override-approved "$product" "$fork_head" READY)"
[[ "$verdict" == NOT_READY ]] || fail "an unrelated label skipped the guard (verdict=$verdict)"
echo 'ok - the supervisor label (config engine_override.approved_label, default engine-override-approved) is the only escape'

# 3. A product-only diff is untouched.
git -C "$product" checkout -q main
git -C "$product" checkout -q -b agent/issue-5300
printf 'feature v2\n' > "$product/src/feature.ts"
git -C "$product" commit -qam 'product-only change'
plain_head="$(git -C "$product" rev-parse HEAD)"
tick_prs() { printf '[{"number":5300,"labels":[]}]'; }
[[ -z "$(engine_override_gate_reason 5300 engine-override-approved "$product" "$plain_head")" ]] \
  || fail 'a product-only diff produced guard findings'
verdict="$(engine_override_review_verdict 5300 engine-override-approved "$product" "$plain_head" READY)"
[[ "$verdict" == READY ]] || fail "a product-only diff was refused (verdict=$verdict)"
echo 'ok - a product-only diff passes without findings'

# A changed row (same engine file, new blob) is refused too, not just a new row.
git -C "$product" checkout -q main
git -C "$product" checkout -q -b agent/issue-5320
{
  printf '# engine-relative path\tblob the pinned engine has\n'
  printf 'hotfix/hf-start.sh\t%s\n' "$(printf '2%.0s' {1..40})"
} > "$product/.zenoforge/build/overrides.tsv"
git -C "$product" commit -qam 're-override hf-start'
reoverride_head="$(git -C "$product" rev-parse HEAD)"
tick_prs() { printf '[{"number":5320,"labels":[]}]'; }
reason="$(engine_override_gate_reason 5320 engine-override-approved "$product" "$reoverride_head")"
[[ "$reason" == *'.zenoforge/build/overrides.tsv:2'*'engine/hotfix/hf-start.sh'* ]] \
  || fail "a changed overrides row was not refused at its line: $reason"
echo 'ok - changing an existing overrides row for an engine file is refused'

# A pack copy shadows an engine file only when the pinned engine ships the same relative path.
git -C "$product" checkout -q main
git -C "$product" checkout -q -b agent/issue-5310
mkdir -p "$product/.zenoforge/build/pack/mac-autopilot/scheduler.d"
printf 'shadow dispatch queue\n' > "$product/.zenoforge/build/pack/mac-autopilot/scheduler.d/dispatch-queue.sh"
printf 'fresh pack module\n' > "$product/.zenoforge/build/pack/mac-autopilot/fresh-module.sh"
git -C "$product" add -A
git -C "$product" commit -qm 'pack copies'
pack_head="$(git -C "$product" rev-parse HEAD)"
tick_prs() { printf '[{"number":5310,"labels":[]}]'; }
reason="$(engine_override_gate_reason 5310 engine-override-approved "$product" "$pack_head")"
[[ "$reason" == *'.zenoforge/build/pack/mac-autopilot/scheduler.d/dispatch-queue.sh:1'*'engine change: file it on ZenoWangzy/zenoforge'* ]] \
  || fail "a pack copy of an engine file was not refused: $reason"
[[ "$reason" != *'fresh-module'* ]] \
  || fail 'a pack file the engine does not ship was refused (classification is not the pinned engine tree)'
verdict="$(engine_override_review_verdict 5310 engine-override-approved "$product" "$pack_head" READY)"
[[ "$verdict" == NOT_READY ]] || fail "a pack copy of an engine file passed review (verdict=$verdict)"
echo 'ok - a pack copy of an engine-owned file is refused; a pack file the engine does not ship is not'

# A built engine version directory (files, no git) still classifies through the running engine tree.
engine_tree="$test_env_root/engine-tree"
mkdir -p "$engine_tree/mac-autopilot/scheduler.d"
printf 'engine dispatch queue\n' > "$engine_tree/mac-autopilot/scheduler.d/dispatch-queue.sh"
ZF_ENGINE_DIR="$engine_tree" verdict="$(engine_override_review_verdict 5200 engine-override-approved "$product" "$fork_head" READY)"
[[ "$verdict" == NOT_READY ]] || fail "the file-tree engine fallback lost the classification (verdict=$verdict)"
echo 'ok - engine ownership also resolves from a non-git engine tree'

echo 'engine-override-review-gate.test.sh: PASS'
