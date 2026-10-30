#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$root/hand-codex-liveness.sh"
tmp=$(mktemp -d)
pids=()
trap 'for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done; rm -rf -- "$tmp" "$test_env_root"' EXIT
assert_eq() { [[ "$1" == "$2" ]] || { echo "FAIL expected [$1], got [$2]" >&2; exit 1; }; }
rows="$(printf '%s\n' \
  "codex exec --cd $tmp/old -m test" \
  "codex exec --json --cd $tmp/json -m test" \
  "node /x/codex exec -m test --json --cd $tmp/reordered" \
  "/x/codex exec --cd=$tmp/equal --json" \
  "bash -c codex exec --cd $tmp/decoy" \
  "awk codex exec --cd $tmp/decoy" | hand_codex_parse_processes)"
assert_eq "$(printf '%s\n' "$tmp/old" "$tmp/json" "$tmp/reordered" "$tmp/equal")" "$rows"
echo 'ok - old, --json, reordered, node, --cd=; shell/awk decoys excluded'
mkfifo "$tmp/ready" "$tmp/control"
cat > "$tmp/codex" <<'SCRIPT'
#!/usr/bin/env bash
printf 'ready\n' > "$LIVENESS_READY"
read -r _ < "$LIVENESS_CONTROL"
SCRIPT
chmod +x "$tmp/codex"
source <(sed -n '/^hand_dispatch_pid_state() {/,/^}/p' "$root/supervise-pipeline.sh")
export LIVENESS_READY="$tmp/ready" LIVENESS_CONTROL="$tmp/control"
for form in old json reordered; do
  case "$form" in
    old) args=(exec --cd "$tmp/live" -m test) ;;
    json) args=(exec --json --cd "$tmp/live" -m test) ;;
    reordered) args=(exec -m test --json --cd "$tmp/live") ;;
  esac
  setsid "$tmp/codex" "${args[@]}" &
  pid=$!; pids+=("$pid")
  read -r _ < "$tmp/ready"
  hand_codex_pid_matches "$pid" "$tmp/live"
  if hand_codex_pid_matches "$pid" "$tmp/liv"; then echo 'FAIL worktree prefix matched'; exit 1; fi
  [[ -n "$(hand_codex_worktree_pid "$tmp/live")" ]]
  ticks=$(awk '{print $22}' "/proc/$pid/stat")
  assert_eq live "$(hand_dispatch_pid_state "$pid" "$ticks" "$tmp/live")"
  assert_eq unknown "$(hand_dispatch_pid_state "$pid" "$ticks" "$tmp/liv")"
done

assert_eq 1 "$(hand_codex_worktrees "$tmp/" | wc -l | tr -d ' ')"
bash -c 'printf "ready\n" > "$LIVENESS_READY"; read -r _ < "$LIVENESS_CONTROL"' _ "codex exec --json --cd $tmp/decoy" &
pid=$!; pids+=("$pid")
read -r _ < "$tmp/ready"
if hand_codex_pid_matches "$pid" "$tmp/decoy"; then echo 'FAIL shell decoy matched'; exit 1; fi
"$tmp/codex" exec --json "Repair codex exec --cd $tmp/live" &
pid=$!; pids+=("$pid")
read -r _ < "$tmp/ready"
if hand_codex_pid_matches "$pid" "$tmp/live"; then echo 'FAIL prompt text matched as --cd argv'; exit 1; fi
if hand_codex_pid_matches 99999999 "$tmp/live"; then echo 'FAIL dead PID matched'; exit 1; fi
echo 'ok - live PID, exact worktree, distinct count, dead PID and decoys'
