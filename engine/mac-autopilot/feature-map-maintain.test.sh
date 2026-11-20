#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

engine_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$engine_dir/engine/mac-autopilot/scheduler.d/locks-views.sh"

fail() { echo "feature-map-maintain.test.sh: $*" >&2; exit 1; }
fixture="$test_env_root/feature-map-maintain"
repo="$fixture/repo"
mkdir -p "$repo/.agents/skills/verify-vecta/features" "$repo/.zenoforge/state"
printf '# Verify VectA\n' > "$repo/.agents/skills/verify-vecta/SKILL.md"
printf '# Feature map\n' > "$repo/.agents/skills/verify-vecta/features/README.md"

node - "$repo/.zenoforge/state/feature-map.json" <<'NODE'
const fs = require('node:fs');
const ids = [
  'dispatch-sheet', 'dispatch-sheet-stated-warehouse', 'received-order',
  'pending-confirmation-reminder', 'settle-price', 'dispatch-freetext',
  'dispatch-edit', 'cash-receipt', 'transfer', 'photo-entry', 'q-inventory',
  'q-receivable', 'proactive-daily-skip', 'q-daily-sheet', 'q-loss-rate',
  'q-sales', 'personal-wechat-web-fallback', 'personal-wechat-ambiguous-web-fallback',
  'a2a-roundtrip', 'personal-daily-dashboard', 'page-chat', 'page-admin', 'page-ontology',
];
const features = Object.fromEntries(ids.map((id) => [id, {
  path: id === 'page-admin' ? '/admin' : id === 'page-ontology' ? '/admin/ontology' : '/chat/',
  selector: id === 'page-admin' ? 'body' : id === 'page-ontology' ? 'button,[role=tab],a' : '#chat-input',
}]));
fs.writeFileSync(process.argv[2], JSON.stringify({ version: 1, features }, null, 2));
NODE

[[ "$(jq '.features | length' "$repo/.zenoforge/state/feature-map.json")" == 23 ]] \
  || fail 'fixture must cover the 23 existing VectA feature-map entries'
[[ "$(feature_map_maintenance_target "$repo")" == "$repo/.agents/skills/verify-vecta/SKILL.md" ]] \
  || fail 'VECTA verification skill was not located under .agents/skills'

clean="$(feature_map_selector_drift "$repo")" || fail 'clean feature map could not be read'
[[ -z "$clean" ]] || fail "clean run reported selector drift: $clean"
echo 'feature-map selector clean: none'

jq '.features["dispatch-sheet"].selector = "#injected-drift"' \
  "$repo/.zenoforge/state/feature-map.json" > "$fixture/feature-map.json"
mv "$fixture/feature-map.json" "$repo/.zenoforge/state/feature-map.json"
drift="$(feature_map_selector_drift "$repo")" || fail 'drifted feature map could not be read'
[[ "$drift" == *'path=/chat/'* && "$drift" == *'feature=dispatch-sheet'* \
  && "$drift" == *'selector=#injected-drift'* && "$drift" == *'expected=#chat-input'* ]] \
  || fail "injected selector drift was not reported: $drift"
printf '%s\n' "$drift"

jq '.features["dispatch-sheet"].selector = "#chat-input"' \
  "$repo/.zenoforge/state/feature-map.json" > "$fixture/feature-map.json"
mv "$fixture/feature-map.json" "$repo/.zenoforge/state/feature-map.json"
clean="$(feature_map_selector_drift "$repo")" || fail 'restored feature map could not be read'
[[ -z "$clean" ]] || fail 'restored clean feature map still reported drift'
grep -Fq 'feature_map_maintenance_schedule' "$engine_dir/engine/mac-autopilot/scheduler.d/locks-views.sh" \
  || fail 'full scheduler views do not schedule the maintenance pass'
grep -Fq '.agents/skills/verify-vecta/SKILL.md' "$engine_dir/engine/mac-autopilot/feature-map-maintain.prompt.md" \
  || fail 'engine-side maintenance prompt does not use the VectA skill path'
if grep -Fq '.cursor/skills/' "$engine_dir/engine/mac-autopilot/feature-map-maintain.prompt.md"; then
  fail 'engine-side maintenance prompt still uses Cursor skill paths'
fi
echo 'feature-map-maintain scheduling: wired'
