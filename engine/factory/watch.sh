#!/usr/bin/env bash
# Emit one line per finished opt-* worker and per newly completed main Pipeline suites run (success/failure only).
L=${HOME:-/tmp}/.zenoforge/scratch/luna; F=${HOME:-/tmp}/.zenoforge/scratch/factory
seen=$F/.opt-seen; runs=$F/.opt-runs; touch "$seen" "$runs"; unset GH_TOKEN; i=0
while true; do
  for d in "$L"/opt-*; do k=${d##*/}; [[ -f $d/rc ]] || continue; kill -0 "$(cat "$d/wrapper.pid" 2>/dev/null)" 2>/dev/null && continue; grep -qx "$k" "$seen" && continue
    echo "$k" >> "$seen"; echo "EXIT $k rc=$(cat "$d/rc") backend=$(head -c 10 "$d/backend" 2>/dev/null)"; done
  if (( i % 5 == 0 )); then
    gh run list --repo "${ZF_REPO:?ZF_REPO is not set}" --workflow "Pipeline suites" --branch main --status completed --limit 10 \
      --json headSha,conclusion,databaseId -q '.[]|select(.conclusion=="success" or .conclusion=="failure")|"\(.databaseId) \(.headSha[0:9]) \(.conclusion)"' 2>/dev/null |
    while read -r id sha c; do grep -qx "$id" "$runs" && continue; echo "$id" >> "$runs"; echo "SUITES $sha $c $id"; done
  fi
  i=$((i+1)); sleep 60
done
