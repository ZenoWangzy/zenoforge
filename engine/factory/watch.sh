#!/usr/bin/env bash
# Emit one line per finished opt-* worker. Main suite reds are not watched here: landing-owned reds open
# fix-forward units themselves (5a60b08d2), and release/prod belong to zf-ab/zf-57 (maintainer 10-30).
S=${WORKER_SCRATCH_ROOT:-${HOME:-/tmp}/.zenoforge/scratch}; L=$S/luna; F=$S/factory
seen=$F/.opt-seen; touch "$seen"
while true; do
  for d in "$L"/opt-*; do k=${d##*/}; [[ -f $d/rc ]] || continue; kill -0 "$(cat "$d/wrapper.pid" 2>/dev/null)" 2>/dev/null && continue; grep -qx "$k" "$seen" && continue
    echo "$k" >> "$seen"; echo "EXIT $k rc=$(cat "$d/rc") backend=$(head -c 10 "$d/backend" 2>/dev/null)"; done
  sleep 60
done
