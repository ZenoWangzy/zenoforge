#!/usr/bin/env bash
# Require recent, spaced successful acceptance runs.
set -uo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$here/../config.sh"
f=$AGENT_HOME/hf-demo-accept.jsonl; need=${HF_DEMO_GREENS:-3}; set_name=${HF_DEMO_SET:-demo}; gap=${HF_DEMO_MIN_GAP_MIN:-20}; max=${HF_DEMO_MAX_AGE_MIN:-90}
[[ -r $f ]] || { echo "demo-gate: NOT READY, no hf-accept run recorded in $f (run hf-accept.sh)"; exit 1; }
recs=$(jq -c --arg s "$set_name" 'select(.set == $s)' "$f" | tail -n "$need" | jq -cs '.') || { echo "demo-gate: NOT READY, $f is unreadable"; exit 1; }
[[ $(jq 'length' <<< "$recs") -ge $need ]] || { echo "demo-gate: NOT READY, need $need green runs, have $(jq 'length' <<< "$recs") recorded"; exit 1; }
bad=$(jq -r '[.[] | select(.rc != 0)] | length' <<< "$recs")
((bad == 0)) || { echo "demo-gate: NOT READY, $bad of the last $need runs failed (see $(jq -r '[.[]|select(.rc != 0)][-1].log' <<< "$recs"))"; exit 1; }
now=$(date -u +%s); prev=0; newest=0
for at in $(jq -r '.[].at' <<< "$recs"); do
  t=$(date -u -d "$at" +%s) || { echo "demo-gate: NOT READY, bad timestamp $at"; exit 1; }
  ((prev == 0 || t - prev >= gap * 60)) || { echo "demo-gate: NOT READY, green runs less than $gap min apart ($at)"; exit 1; }
  prev=$t; newest=$t
done
age=$(( (now - newest) / 60 ))
((age <= max)) || { echo "demo-gate: NOT READY, newest green run is ${age} min old (max $max)"; exit 1; }
echo "demo-gate: READY, last $need runs green, newest ${age} min ago"
