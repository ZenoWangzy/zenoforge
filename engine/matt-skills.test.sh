#!/usr/bin/env bash
# matt-skills.sh: a target repository's own skill wins, otherwise the engine's vendored copy answers.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/matt-skills.sh"
fail() { echo "matt-skills.test.sh: $*" >&2; exit 1; }

engine_skills="$(cd -- "$SCRIPT_DIR/.." && pwd -P)/.agents/skills"
target="$test_env_root/target"
mkdir -p "$target/.agents/skills/tdd"
: > "$target/.agents/skills/tdd/SKILL.md"
mkdir -p "$target/.zenoforge/skills/tdd"
: > "$target/.zenoforge/skills/tdd/SKILL.md"

[[ "$(matt_skill_md tdd "$target")" == "$engine_skills/tdd/SKILL.md" ]] || fail "unversioned target skill loaded before an engine pin"
rm "$target/.zenoforge/skills/tdd/SKILL.md"
[[ "$(matt_skill_md tdd "$target")" == "$engine_skills/tdd/SKILL.md" ]] || fail "unversioned migration skill loaded before an engine pin"
[[ "$(matt_skill_md triage "$target")" == "$engine_skills/triage/SKILL.md" ]] || fail "missing in target must fall back to the engine copy"
[[ "$(cd "$test_env_root" && matt_skill_md triage)" == "$engine_skills/triage/SKILL.md" ]] || fail "no checkout argument must fall back to the engine copy outside a repo with skills"
mkdir -p "$target/.agents/skills/code-review"; : > "$target/.agents/skills/code-review/SKILL.md"
mkdir -p "$target/.zenoforge/skills/code-review"; : > "$target/.zenoforge/skills/code-review/SKILL.md"
[[ "$(matt_skill_md code-review "$target")" == "$engine_skills/code-review/SKILL.md" ]] || fail "unversioned review skill loaded before an engine pin"
[[ "$(matt_engine_skill_md code-review)" == "$engine_skills/code-review/SKILL.md" ]] || fail "engine-only lookup must ignore the target's own skill"
for name in ask-matt triage to-spec to-tickets implement tdd diagnosing-bugs code-review setup-matt-pocock-skills; do
  [[ -f "$engine_skills/$name/SKILL.md" ]] || fail "the engine must vendor $name"
done
note="$(matt_skills_note "$target" tdd triage)"
[[ "$note" == *"tdd=$engine_skills/tdd/SKILL.md; triage=$engine_skills/triage/SKILL.md" ]] || fail "unexpected note: $note"
# Every stage prompt builder names its Matt skill. Exception: release (engine/run-release.sh has no agent prompt on origin/main).
for entry in run-triage.sh:ask-matt run-triage-batch.sh:ask-matt run-recut.sh:to-tickets run-recut.sh:to-spec run-advisor.sh:ask-matt run-advisor-batch.sh:ask-matt; do
  script="${entry%%:*}" skill="${entry##*:}"
  grep -Eq "matt_skills_note .*\b$skill\b" "$SCRIPT_DIR/$script" || fail "$script must name Matt skill $skill in its prompt"
  [[ -f "$engine_skills/$skill/SKILL.md" ]] || fail "Matt skill $skill for $script is not vendored"
done
unset ZF_REVIEW_SKILL
sched_config_file() { printf '%s\n' engine/prompts/review-contract.md; }
source "$SCRIPT_DIR/mac-autopilot/scheduler.d/evals-arbiter.sh"
unit_rule="$(matt_method_rule "$target")"
for skill in implement tdd diagnosing-bugs; do
  expected="$(matt_skill_md "$skill" "$target")"
  [[ "$unit_rule" == *"$skill"*"$expected"* ]] || fail "unit stage must default to Matt $skill"
done
review_rule="$(review_contract_rule)"
[[ "$review_rule" == *"code-review"*"$engine_skills/code-review/SKILL.md"* ]] || fail "review stage must default to Matt code-review"
grep -Fq '`ask-matt` first to route each incoming issue' "$SCRIPT_DIR/prompts/triage.md" || fail "new incoming issues must enter through ask-matt"
method_doc="$SCRIPT_DIR/../docs/architecture.md"
for row in \
  '| triage | `ask-matt` routing' \
  '| advisor | `ask-matt` routes judgment calls' \
  '| recut | `to-tickets`' \
  '| implement | `implement`, test-first with `tdd`' \
  '| repair, CI repair, self-fix | `diagnosing-bugs`' \
  '| review | `code-review`' \
  '| release | **Exception:** the engine supplies no Matt skill' \
  '| supervisor arbiter | **Exception:** no Matt skill runs'; do
  grep -Fq "$row" "$method_doc" || fail "stage method map is missing $row"
done
solve="$(matt_engine_skill_md solve)" router="$(matt_engine_skill_md ask-zeno)"
[[ -f "$solve" && -f "$router" ]] || fail "the engine must ship solve and ask-zeno"
router_named="$(grep -oE '`[a-z][a-z-]+`' "$router" | tr -d '`' | sort -u)"
vendored="$({ for d in "$engine_skills"/*/ "$SCRIPT_DIR"/vendor/pstack/skills/*/; do [[ ! -f "$d/SKILL.md" ]] || basename "$d"; done; echo ub-mode; } | sort -u)"
(( $(wc -l <<<"$vendored") >= 90 )) || fail "the vendored skills were not found"
[[ -f "$SCRIPT_DIR/vendor/ub-mode/SKILL.md" ]] || fail "ub-mode must be vendored"
unknown="$(comm -23 <(printf '%s\n' "$router_named") <(printf '%s\n' "$vendored"))"
[[ -z "$unknown" ]] || fail "ask-zeno names skills that are not vendored: $(paste -sd' ' <<<"$unknown")"
unrouted="$(comm -13 <(printf '%s\n' "$router_named") <(printf '%s\n' "$vendored") | grep -vE '^(principle-|ask-zeno$)' || true)"
[[ -z "$unrouted" ]] || fail "vendored skills with no route in .agents/skills/ask-zeno/SKILL.md: $(paste -sd' ' <<<"$unrouted")"

pinned_target="$test_env_root/pinned-target"
pinned_version="$test_env_root/pinned-version"
mkdir -p "$pinned_target/.agents/skills/tdd" "$pinned_target/.zenoforge/skills/tdd" "$pinned_version/.agents/skills/tdd" "$pinned_version/.zenoforge/skills/tdd"
git -C "$pinned_target" init -q
git -C "$pinned_target" config user.name 'Pinned skill fixture'
git -C "$pinned_target" config user.email 'pinned-skill@example.invalid'
printf 'before evaluation\n' > "$pinned_target/.agents/skills/tdd/SKILL.md"
printf 'before evaluation\n' > "$pinned_target/.zenoforge/skills/tdd/SKILL.md"
printf 'accepted instructions\n' > "$pinned_target/AGENTS.md"
printf 'accepted override instructions\n' > "$pinned_target/AGENTS.override.md"
printf 'accepted Claude instructions\n' > "$pinned_target/CLAUDE.md"
git -C "$pinned_target" add .
git -C "$pinned_target" commit -qm 'accepted skill revision'
accepted_sha="$(git -C "$pinned_target" rev-parse HEAD)"
printf 'candidate skill\n' > "$pinned_target/.agents/skills/tdd/SKILL.md"
printf 'candidate config skill\n' > "$pinned_target/.zenoforge/skills/tdd/SKILL.md"
printf 'candidate instructions\n' > "$pinned_target/AGENTS.md"
printf 'candidate override instructions\n' > "$pinned_target/AGENTS.override.md"
printf 'candidate Claude instructions\n' > "$pinned_target/CLAUDE.md"
git -C "$pinned_target" add .
git -C "$pinned_target" commit -qm 'candidate skill revision'
candidate_sha="$(git -C "$pinned_target" rev-parse HEAD)"
printf 'accepted config skill\n' > "$pinned_version/.zenoforge/skills/tdd/SKILL.md"
printf 'accepted migration skill\n' > "$pinned_version/.agents/skills/tdd/SKILL.md"
printf 'accepted Claude instructions\n' > "$pinned_version/CLAUDE.md"
printf 'product_sha=%s\n' "$accepted_sha" > "$pinned_version/BUILD-INFO"
_MATT_SKILLS_ENGINE_DIR="$pinned_version/.agents/skills"
[[ "$(matt_skill_md tdd "$pinned_target")" == "$pinned_version/.zenoforge/skills/tdd/SKILL.md" ]] \
  || fail 'an unevaluated target skill overrode the accepted product copy'
[[ "$(matt_codex_context_root "$pinned_target")" == "$pinned_version" ]] \
  || fail 'Codex loaded an unevaluated target AGENTS.md instead of the pinned instructions'
printf 'product_sha=%s\n' "$candidate_sha" > "$pinned_version/BUILD-INFO"
printf 'candidate config skill\n' > "$pinned_version/.zenoforge/skills/tdd/SKILL.md"
[[ "$(matt_skill_md tdd "$pinned_target")" == .zenoforge/skills/tdd/SKILL.md ]] \
  || fail 'a target config skill did not activate after its product revision was pinned'
[[ "$(matt_codex_context_root "$pinned_target")" == "$pinned_target" ]] \
  || fail 'accepted target AGENTS.md did not load from the product checkout'
git -C "$pinned_target" rm -q .zenoforge/skills/tdd/SKILL.md
git -C "$pinned_target" commit -qm 'remove config override'
legacy_sha="$(git -C "$pinned_target" rev-parse HEAD)"
[[ "$(matt_skill_md tdd "$pinned_target")" == "$pinned_version/.zenoforge/skills/tdd/SKILL.md" ]] \
  || fail 'an unaccepted target skill deletion did not retain the accepted product copy'
printf 'product_sha=%s\n' "$legacy_sha" > "$pinned_version/BUILD-INFO"
[[ "$(matt_skill_md tdd "$pinned_target")" == .agents/skills/tdd/SKILL.md ]] \
  || fail 'a migration skill did not activate after its product revision was pinned'
printf 'accepted current instructions\n' > "$pinned_version/AGENTS.md"
printf 'accepted current override\n' > "$pinned_version/AGENTS.override.md"
printf 'candidate override only\n' > "$pinned_target/AGENTS.override.md"
git -C "$pinned_target" add AGENTS.override.md
git -C "$pinned_target" commit -qm 'change only the override instructions'
override_sha="$(git -C "$pinned_target" rev-parse HEAD)"
printf 'product_sha=%s\n' "$legacy_sha" > "$pinned_version/BUILD-INFO"
[[ "$(matt_codex_context_root "$pinned_target")" == "$pinned_version" ]] \
  || fail 'an unevaluated AGENTS.override.md changed the Codex instruction context'
printf 'product_sha=%s\n' "$override_sha" > "$pinned_version/BUILD-INFO"
[[ "$(matt_codex_context_root "$pinned_target")" == "$pinned_target" ]] \
  || fail 'an accepted AGENTS.override.md did not restore the target context'
matt_codex_context_prepare "$pinned_target" "$pinned_version"
[[ "${MATT_CODEX_CONTEXT_ROOT}" == "$pinned_target" && " ${MATT_CODEX_CONTEXT_ARGS[*]} " == *" --add-dir $pinned_version "* ]] \
  || fail 'paired eval did not retain access to the candidate product root when instructions matched'
printf 'evaluation prompt\n' > "$test_env_root/evaluation-prompt.md"
[[ "$(matt_codex_prompt_input "$test_env_root/evaluation-prompt.md" "$pinned_target" "$pinned_target")" == *"$pinned_version"* ]] \
  || fail 'paired eval prompt omitted the candidate product root'
export ZF_EVAL_CANDIDATE_ROOT="$pinned_target"
matt_codex_context_prepare "$pinned_target" "$pinned_version"
eval_prompt_input="$(matt_codex_prompt_input "$test_env_root/evaluation-prompt.md" "$pinned_target" "$MATT_CODEX_CONTEXT_ROOT")"
[[ "$eval_prompt_input" == *'candidate instructions'* && "$eval_prompt_input" == *'candidate Claude instructions'* ]] \
  || fail 'paired eval prompt omitted candidate root instructions'
unset ZF_EVAL_CANDIDATE_ROOT
printf 'candidate Claude instructions only\n' > "$pinned_target/CLAUDE.md"
git -C "$pinned_target" add CLAUDE.md
git -C "$pinned_target" commit -qm 'change only Claude instructions'
claude_sha="$(git -C "$pinned_target" rev-parse HEAD)"
printf 'product_sha=%s\n' "$override_sha" > "$pinned_version/BUILD-INFO"
[[ "$(matt_codex_context_root "$pinned_target")" == "$pinned_version" ]] \
  || fail 'an unaccepted CLAUDE.md changed the engine instruction context'
printf 'candidate Claude instructions only\n' > "$pinned_version/CLAUDE.md"
printf 'product_sha=%s\n' "$claude_sha" > "$pinned_version/BUILD-INFO"
[[ "$(matt_codex_context_root "$pinned_target")" == "$pinned_target" ]] \
  || fail 'an accepted CLAUDE.md did not restore the target context'
rm "$pinned_version/BUILD-INFO"
! matt_target_file_revision_is_pinned "$pinned_target" CLAUDE.md \
  || fail 'missing build metadata admitted target instructions'
[[ "$(matt_codex_context_root "$pinned_target")" == "$pinned_version" ]] \
  || fail 'missing build metadata did not use accepted engine instructions'
_MATT_SKILLS_ENGINE_DIR="$engine_skills"

for rel in ../solve/SKILL.md ../tdd/SKILL.md ../../../engine/vendor/pstack/skills/reframe/SKILL.md ../../../engine/vendor/ub-mode/SKILL.md; do
  [[ -f "${router%/*}/$rel" ]] || fail "ask-zeno's path $rel does not resolve"
done
rule="$(bash -c 'source "$1/incident-rule.sh"; incident_rule_text' _ "$SCRIPT_DIR")"
[[ "$rule" == *"$solve"* ]] || fail "the incident rule must point at the solve flow"
grep -Fq 'matt_engine_skill_md solve' "$SCRIPT_DIR/mac-autopilot/scheduler.d/evals-arbiter.sh" || fail "the worker method rule must point at the solve flow"
echo 'matt-skills.test.sh: PASS'
