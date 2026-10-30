#!/usr/bin/env bash
# Launch the next queued ticket only when no opt worker is still waiting at the capacity gate, so queue order = start order.
S=${WORKER_SCRATCH_ROOT:-${HOME:-/tmp}/.zenoforge/scratch}; F=$S/factory; L=$S/luna
while true; do
  waiting=0
  for d in "$L"/opt-*; do [[ -f $d/rc || ! -f $d/wrapper.pid ]] && continue; kill -0 "$(cat "$d/wrapper.pid")" 2>/dev/null || continue
    [[ -f $d/codex.pid ]] && kill -0 "$(cat "$d/codex.pid")" 2>/dev/null || waiting=$((waiting+1)); done
  # Hotfixes come first (maintainer 10-29): the hotfix supervisor pauses intake by touching FEEDER-PAUSE.
  if (( waiting == 0 )) && [[ -s $F/queue.txt && ! -e $F/FEEDER-PAUSE ]]; then
    read -r key issue note < "$F/queue.txt"; sed -i 1d "$F/queue.txt"
    [[ -z $note || $note == - ]] && note= || { [[ $note == /* ]] || note=$F/$note; }  # 10-29: absolute notes were prefixed with $F and launched empty
    (cd "$F" && ./launch.sh "$key" "$issue" $note); sed -i "/^$key\$/d" "$F/.opt-seen"
  fi
  sleep 60
done
