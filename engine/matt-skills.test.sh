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

[[ "$(matt_skill_md tdd "$target")" == .zenoforge/skills/tdd/SKILL.md ]] || fail "target config skill must win, as a relative path"
rm "$target/.zenoforge/skills/tdd/SKILL.md"
[[ "$(matt_skill_md tdd "$target")" == .agents/skills/tdd/SKILL.md ]] || fail "target's migration skill must win, as a relative path"
[[ "$(matt_skill_md triage "$target")" == "$engine_skills/triage/SKILL.md" ]] || fail "missing in target must fall back to the engine copy"
[[ "$(cd "$test_env_root" && matt_skill_md triage)" == "$engine_skills/triage/SKILL.md" ]] || fail "no checkout argument must fall back to the engine copy outside a repo with skills"
mkdir -p "$target/.agents/skills/code-review"; : > "$target/.agents/skills/code-review/SKILL.md"
mkdir -p "$target/.zenoforge/skills/code-review"; : > "$target/.zenoforge/skills/code-review/SKILL.md"
[[ "$(matt_skill_md code-review "$target")" == .zenoforge/skills/code-review/SKILL.md ]] || fail "target config review skill must win for normal lookup"
[[ "$(matt_engine_skill_md code-review)" == "$engine_skills/code-review/SKILL.md" ]] || fail "engine-only lookup must ignore the target's own skill"
for name in ask-matt triage to-spec to-tickets implement tdd diagnosing-bugs code-review setup-matt-pocock-skills; do
  [[ -f "$engine_skills/$name/SKILL.md" ]] || fail "the engine must vendor $name"
done
note="$(matt_skills_note "$target" tdd triage)"
[[ "$note" == *"tdd=.agents/skills/tdd/SKILL.md; triage=$engine_skills/triage/SKILL.md" ]] || fail "unexpected note: $note"
# Every stage prompt builder names its Matt skill. Exception: release (engine/run-release.sh has no agent prompt on origin/main).
for entry in run-triage.sh:ask-matt run-triage-batch.sh:ask-matt run-recut.sh:to-tickets run-advisor.sh:ask-matt run-advisor-batch.sh:ask-matt; do
  script="${entry%%:*}" skill="${entry##*:}"
  grep -Eq "matt_skills_note .*\b$skill\b" "$SCRIPT_DIR/$script" || fail "$script must name Matt skill $skill in its prompt"
  [[ -f "$engine_skills/$skill/SKILL.md" ]] || fail "Matt skill $skill for $script is not vendored"
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
for rel in ../solve/SKILL.md ../tdd/SKILL.md ../../../engine/vendor/pstack/skills/reframe/SKILL.md ../../../engine/vendor/ub-mode/SKILL.md; do
  [[ -f "${router%/*}/$rel" ]] || fail "ask-zeno's path $rel does not resolve"
done
rule="$(bash -c 'source "$1/incident-rule.sh"; incident_rule_text' _ "$SCRIPT_DIR")"
[[ "$rule" == *"$solve"* ]] || fail "the incident rule must point at the solve flow"
grep -Fq 'matt_engine_skill_md solve' "$SCRIPT_DIR/mac-autopilot/scheduler.d/evals-arbiter.sh" || fail "the worker method rule must point at the solve flow"
echo 'matt-skills.test.sh: PASS'
