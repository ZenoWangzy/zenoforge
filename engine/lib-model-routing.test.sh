#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
ROUTING_TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$ROUTING_TEST_ROOT/lib.d/model-routing.sh"
ROUTING_FIXTURE_DIR="$(mktemp -d)"
ROUTING_FILE="$ROUTING_FIXTURE_DIR/routing.json"
NOW_EPOCH=1000

write_quota() {
  printf '{"week_pct":%s,"read_at":1000}\n' "$2" > "$ROUTING_FIXTURE_DIR/$1.json"
}

write_routing() {
  jq -n \
    --arg claude "$ROUTING_FIXTURE_DIR/claude.json" \
    --arg codex "$ROUTING_FIXTURE_DIR/codex.json" \
    --arg glm "$ROUTING_FIXTURE_DIR/glm.json" \
    --argjson pool_priority "$1" \
    --argjson implement_order "$2" \
    --argjson glm_implement "$3" '
      {stale_after_seconds:3600,
       families:{claude:{quota_file:$claude},codex:{quota_file:$codex},glm:{quota_file:$glm,implement:$glm_implement}}}
      + (if $pool_priority == null then {} else {pool_priority:$pool_priority} end)
      + (if $implement_order == null then {} else {implement_order:$implement_order} end)
    ' > "$ROUTING_FILE"
  CFG="$(jq -cn --arg routing "$ROUTING_FILE" '{models:{routing_file:$routing}}')"
}

assert_order() {
  local label="$1" expected="$2" actual
  actual="$(routing_implement_family_order)"
  if [[ "$actual" != "$expected" ]]; then
    printf '%s\nexpected:\n%s\nactual:\n%s\n' "$label" "$expected" "$actual" >&2
    return 1
  fi
}

write_quota claude 10
write_quota codex 70
write_quota glm 50
write_routing '{"implement":["codex","glm","claude"]}' null true
assert_order 'pool priority is strict even when Claude has more quota left' $'codex\nglm\nclaude'

write_quota claude 30
write_quota codex 70
write_quota glm 10
write_routing null '["glm","claude"]' true
assert_order 'legacy implement order is used when pool priority is absent' $'glm\nclaude\ncodex'

write_quota claude 86
write_quota codex 20
write_quota glm 40
write_routing '{"implement":["codex","glm","claude"]}' null true
assert_order 'Claude at the default stop percentage is dropped from factory order' $'codex\nglm'

write_quota claude 10
write_quota codex 20
write_quota glm 30
write_routing '{"implement":["codex","glm","claude"]}' null false
assert_order 'implement false still drops a family' $'codex\nclaude'

write_quota claude 10
write_quota codex 70
write_quota glm 30
write_routing '{"implement":["codex"]}' null true
assert_order 'unlisted families follow priority in quota order' $'codex\nclaude\nglm'

write_quota claude 10
write_quota codex 20
write_quota glm 30
write_routing '{}' null true
assert_order 'pool priority without a list uses its default order' $'codex\nglm\nclaude'

write_quota claude 86
write_quota codex 20
write_quota glm 40
write_routing '{"implement":["codex","glm","claude"],"factory_stop_pct":90}' null true
assert_order 'factory stop percentage comes from the routing file' $'codex\nglm\nclaude'

write_quota claude 10
write_quota codex 70
write_quota glm 50
write_routing null null true
assert_order 'without either priority key quota order is unchanged' $'claude\nglm\ncodex'
