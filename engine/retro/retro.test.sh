#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
retro="$dir/retro.py"
root="$test_env_root/scratch"

# Fixture: twelve finished luna workers (rc written, older for smaller numbers), one unfinished, one retro run.
mk() {
  local d="$root/luna/$1"
  mkdir -p "$d"
  seq 1 "$2" | sed 's/.*/{"type":"item.completed","n":&}/' > "$d/events.jsonl"
}
for i in $(seq -w 1 12); do
  mk "w$i" 5
  echo 0 > "$root/luna/w$i/rc"
  touch -d "@$((1000 + 10#$i))" "$root/luna/w$i/rc"
done
mk w13 5                                  # no rc: still running, must be skipped
mk retro-20261111T0300Z 5                 # earlier retro run: must be skipped
echo 0 > "$root/luna/retro-20261111T0300Z/rc"
touch -d "@2000" "$root/luna/retro-20261111T0300Z/rc"

python3 -B "$retro" select "$root" 10 > "$test_env_root/keys.txt"
expected="$(seq -f 'w%02g' 3 12)"
[[ "$(cat "$test_env_root/keys.txt")" == "$expected" ]] || { echo "retro.test.sh: select picked wrong sessions:" >&2; cat "$test_env_root/keys.txt" >&2; exit 1; }
echo "select rc=0"

# Raw model output: one kept candidate, four dropped for four different reasons.
cat > "$test_env_root/raw.json" <<'JSON'
{"candidates":[
 {"category":"navigation","severity":"high","session_key":"w12","event_line":3,"evidence":"read 4 files to find the schema","proposal":"add a pointer"},
 {"category":"navigation","severity":"high","session_key":"w11","evidence":"no line cited","proposal":"add a pointer"},
 {"category":"navigation","severity":"low","session_key":"w10","event_line":99,"evidence":"line past end","proposal":"add a pointer"},
 {"category":"vibes","severity":"low","session_key":"w09","event_line":2,"evidence":"x","proposal":"y"},
 {"category":"tool-economy","severity":"low","session_key":"w01","event_line":2,"evidence":"not selected","proposal":"y"}
]}
JSON
python3 -B "$retro" filter "$root" "$test_env_root/keys.txt" "$test_env_root/raw.json" "$test_env_root/out.json"
jq -e '.candidates | length == 1 and .[0].session_key == "w12" and .[0].event_line == 3' "$test_env_root/out.json" >/dev/null \
  || { echo "retro.test.sh: kept candidate wrong:" >&2; cat "$test_env_root/out.json" >&2; exit 1; }
echo "keep rc=0"
jq -e '.dropped == {"no_event_position":1,"event_line_out_of_range":1,"bad_category":1,"unknown_session":1} and .total == 5' "$test_env_root/out.json" >/dev/null \
  || { echo "retro.test.sh: drop counts wrong:" >&2; cat "$test_env_root/out.json" >&2; exit 1; }
echo "drop-count rc=0"
echo 'retro.test.sh: all assertions passed'
