#!/usr/bin/env bash
# hotspot_expand_batch (ancestor lookup built once) must print byte-identical output to the scope-scan program it replaced.
# The old program is kept below as the golden oracle; the fixture has overlapping hotspots, dir and file scopes, a sibling-prefix trap,
# trailing and leading slashes, duplicate scope entries and one commit over 40 files (ignored by the old rule too).
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)/test-env.sh"
engine_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
fail() { printf 'footprint-hotspot-expand.test.sh: %s\n' "$*" >&2; exit 1; }

fixture="$test_env_root/footprint-hotspot-expand"
mkdir -p "$fixture/repo" "$fixture/supervisor/autopi/alerts"
export MAC_AUTOPILOT_ROOT="$fixture/repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$fixture/supervisor" MAC_AUTOPILOT_RUNTIME_DIR="$fixture/supervisor/autopi"
export REQUIRED_PR_CHECKS_FILE="$engine_dir/mac-autopilot/required-pr-checks.json"
cp "$engine_dir/mac-autopilot/config.template.json" "$MAC_AUTOPILOT_RUNTIME_DIR/config.json"
export AUTOPI_TEST_LIBRARY_ONLY=true
source "$engine_dir/mac-autopilot/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY
LOG="$MAC_AUTOPILOT_RUNTIME_DIR/scheduler.log"

commit() { printf '\001\n'; printf '%s\n' "$@"; printf '\n'; }
{
  commit src/app/a.ts src/app/b.ts shared/hot.json README.md
  commit src/app/a.ts shared/hot.json src/ap/c.ts
  commit src/app/a.ts shared/hot.json docs/x.md src/app/sub/d.ts
  commit shared/hot.json src/app/b.ts /abs/z.ts
  commit src/app/a.ts src/app/b.ts shared/hot.json lone.md
  commit a/q.ts a/r.ts
  commit x//y.ts x/w.ts x/v.ts
  commit src/app/a.ts src/app/b.ts shared/hot.json
  commit src/app/a.ts src/app/b.ts shared/hot.json
  commit "$(for i in $(seq 1 41); do echo "src/app/gen/f$i.ts"; done)"
} > "$fixture/log.txt"
HOTSPOT_LOG="$(<"$fixture/log.txt")"; HOTSPOT_LOG_LOADED=true

# Golden oracle: the program hotspot_expand_batch ran before the lookup change.
cat > "$fixture/old.jq" <<'JQ'
def in_scope($scope; $path): any($scope[]; . as $s | . == $path or ($path | startswith($s + "/")));
(split("\u0001") | map(split("\n") | map(select(length > 0)) | unique)) as $commits
| [$candidates[0][] as $candidate
    | ($candidate.scope) as $scope
    | ([ $commits[] | select(length > 1 and length <= 40)
         | select(any(.[]; in_scope($scope; .)))
         | .[] | select(in_scope($scope; .) | not) ]
      | group_by(.) | map(select(length >= 2) | {f:.[0],n:length})
      | sort_by(-.n) | .[:12]) as $old
    | ($old | map(select($min != "off" and .n >= ($min | tonumber)))) as $added
    | {id:$candidate.id, scope:(($scope + ($added | map(.f))) | unique),
       old_scope:(($scope + ($old | map(.f))) | unique),
       counts:($old | map({key:.f,value:.n}) | from_entries)}]
JQ

candidates="$(jq -cn '[
  {id:"file",scope:["src/app/a.ts"]},
  {id:"dir",scope:["src/app"]},
  {id:"trap",scope:["src/ap"]},
  {id:"mix",scope:["shared/hot.json","src/app/a.ts","src/app","src/app"]},
  {id:"slash",scope:["a/"]},
  {id:"root",scope:["/abs"]},
  {id:"none",scope:[]},
  {id:"dirx",scope:["x"]}
]')"
printf '%s' "$candidates" > "$fixture/candidates.json"

for min in off 2 1; do
  oracle="$(jq -Rsc --arg min "$min" --slurpfile candidates "$fixture/candidates.json" -f "$fixture/old.jq" < "$fixture/log.txt")"
  if [[ "$min" == off ]]; then unset ZF_FOOTPRINT_HOTSPOT_MIN; else ZF_FOOTPRINT_HOTSPOT_MIN="$min"; export ZF_FOOTPRINT_HOTSPOT_MIN; fi
  actual="$(hotspot_expand_batch "$candidates")"
  unset ZF_FOOTPRINT_HOTSPOT_MIN
  [[ -n "$oracle" && "$oracle" != '[]' ]] || fail "oracle empty for min=$min"
  [[ "$actual" == "$oracle" ]] || { printf '%s\n' "$oracle" > "$fixture/oracle-$min.json"; printf '%s\n' "$actual" > "$fixture/actual-$min.json"; fail "min=$min output differs from the golden program: $fixture/oracle-$min.json vs $fixture/actual-$min.json"; }
  printf 'min=%s identical candidates=%s\n' "$min" "$(jq 'length' <<<"$actual")"
done
# The fixture must exercise overlap: the dir candidate's expansion adds the hotspot files, and the trap candidate adds none under src/app.
jq -e 'any(.[]; .id == "dir" and (.counts | length) > 0) and (.[] | select(.id == "trap") | .scope == ["src/ap"])' \
  <<<"$(hotspot_expand_batch "$candidates")" >/dev/null || fail "fixture lost its overlap cases"
echo "footprint-hotspot-expand.test.sh: ok"
