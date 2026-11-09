# Shared total Codex/ZCode capacity used by both backend gates and the scheduler.
LUNA_RUNS_HARD_CAP=10
codex_runs() { local p n=0 pc; for p in $(pgrep -x codex) $(pgrep -x zcode-cli); do pc=$(ps -o comm= -p "$(ps -o ppid= -p "$p" | tr -d ' ')" 2>/dev/null); [[ "$pc" == codex || "$pc" == zcode-cli ]] || n=$((n+1)); done; echo "$n"; }
luna_run_cap() { local cap="${LUNA_MAX:-$LUNA_RUNS_HARD_CAP}"; (( cap < LUNA_RUNS_HARD_CAP )) || cap=$LUNA_RUNS_HARD_CAP; printf '%s\n' "$cap"; }
luna_total_capacity_full() { local runs cap; runs="$(codex_runs)"; cap="$(luna_run_cap)"; (( runs >= cap )); }
