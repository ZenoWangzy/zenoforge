#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -r -- "$tmp"' EXIT
mkdir -p "$tmp/repo/lessons/pending" "$tmp/repo/lessons/full" "$tmp/repo/engine/state" "$tmp/repo/.zenoforge/state"
cp "$REPO_DIR/engine/lesson-fragments.sh" "$REPO_DIR/engine/config.sh" "$tmp/repo/engine/"
printf '{"incidents":[]}\n' > "$tmp/registry.json"
printf 'Rule: [V-NEXT](../RULES.md#v-next).\n' > "$tmp/repo/lessons/full/registry-parity.md"
cat > "$tmp/valid-fragment.json" <<'JSON'
{
  "id":"registry-parity",
  "rule":"<a id=\"v-next\"></a>\n**V-NEXT** fixture rule.",
  "catalog_entry":"Applies: [V-NEXT](RULES.md#v-next); full: ./full/registry-parity.md",
  "full_lesson_path":"lessons/full/registry-parity.md",
  "enforcement":{"level":"architecture","enforced_by":["engine/lesson-fragments.sh"]},
  "guard":{
    "id":"registry-parity","date":"2026-10-12","class":"fixture",
    "what_happened":"fragment and registry validation differed","lesson_id":"V-NEXT",
    "classic_pattern":"validation drift",
    "best_known_solution":"Share the validator between commit and landing checks.",
    "root_cause_evidence":"The fragment checker and lander used different inputs.",
    "siblings":{"discovery_command":"grep -n fold_registry engine/lesson-fragments.sh","expected_result":"Both folds share validation."},
    "machine_checks":[{"command":["true"],"expected":"exit:0","why":"fixture"}]
  }
}
JSON
# Documentation fragments have no enforcement or root-cause-field requirements.
jq 'del(.guard, .enforcement)' "$tmp/valid-fragment.json" > "$tmp/repo/lessons/pending/registry-parity.json"
cp "$tmp/registry.json" "$tmp/registry-before.json"
printf '{"incidents":[]}\n' > "$tmp/repo/engine/state/incident-guards.json"
printf '{"incidents":[{"id":"config-only"}]}\n' > "$tmp/repo/.zenoforge/state/incident-guards.json"
printf 'already folded\n' > "$tmp/repo/lessons/full/override-stale.md"
printf '{"guard":{"id":"config-only"},"full_lesson_path":"lessons/full/override-stale.md"}\n' \
  > "$tmp/repo/lessons/pending/override-stale.json"
ZF_REPO_DIR="$tmp/repo" ZF_ENGINE_DIR="$tmp/repo/engine" \
  bash "$tmp/repo/engine/lesson-fragments.sh" --check "$tmp/repo"
rm "$tmp/repo/lessons/pending/override-stale.json"
printf '{"id":"unselected-invalid"}\n' > "$tmp/repo/lessons/pending/unselected-invalid.json"
bash "$tmp/repo/engine/lesson-fragments.sh" --check "$tmp/repo" "$tmp/registry.json" --files "$tmp/repo/lessons/pending/registry-parity.json"
rm "$tmp/repo/lessons/pending/unselected-invalid.json"
bash "$tmp/repo/engine/lesson-fragments.sh" --check "$tmp/repo" "$tmp/registry.json"
jq 'del(.guard, .enforcement)' "$tmp/valid-fragment.json" > "$tmp/expected-fragment.json"
cmp "$tmp/expected-fragment.json" "$tmp/repo/lessons/pending/registry-parity.json"
cmp "$tmp/registry-before.json" "$tmp/registry.json"
# Manual folding preserves searchable docs without writing the incident registry.
printf '# Rules\n' > "$tmp/repo/lessons/RULES.md"
printf '# Catalog\n' > "$tmp/repo/lessons/CATALOG.md"
git init -q "$tmp/repo"
git -C "$tmp/repo" config user.name 'Lesson docs fixture'
git -C "$tmp/repo" config user.email 'lesson@example.invalid'
git -C "$tmp/repo" add lessons
git -C "$tmp/repo" commit -qm 'documentation fragment'
bash "$tmp/repo/engine/lesson-fragments.sh" --fold "$tmp/repo" "$tmp/registry.json"
grep -Fq '**V-NEXT-registry-parity**' "$tmp/repo/lessons/RULES.md"
grep -Fq '#v-next-registry-parity' "$tmp/repo/lessons/CATALOG.md"
grep -Fq 'V-NEXT-registry-parity' "$tmp/repo/lessons/full/registry-parity.md"
test ! -e "$tmp/repo/lessons/pending/registry-parity.json"
cmp "$tmp/registry-before.json" "$tmp/registry.json"
echo 'lesson-fragments.test.sh: PASS'
