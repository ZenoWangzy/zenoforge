set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
fail() { printf 'issue-loop-merge-boundary.test.sh: %s\n' "$*" >&2; exit 1; }

allowlist=(
  'engine/issue-pipeline.sh 1 # pipeline_system_hand_external_pr_conclusion: merges a green factory-repo PR for a hand-owned issue; the lane merges the product repo only'
)

scan_root() {
  local root="$1" f n
  while IFS= read -r f; do
    n="$(grep -vE '^[[:space:]]*#' "$root/$f" | grep -cE 'gh[[:space:]]+pr[[:space:]]+merge|pulls/[^[:space:]]*/merge' || true)"
    if [[ "${n:-0}" -gt 0 ]]; then printf '%s %s\n' "$f" "$n"; fi
  done < <(git -C "$root" ls-files 'engine/run-*.sh' 'engine/issue-pipeline*.sh' 'engine/hand-*.sh' 'engine/supervisor-holds.sh' 'engine/lib.sh' 'engine/lib.d/*.sh' | grep -vE '\.test\.sh$|^engine/lib\.d/merge-lane\.sh$')
  return 0
}

expected="$(printf '%s\n' "${allowlist[@]}" | awk '{print $1, $2}' | sort)"
actual="$(scan_root "$root" | sort)"
[[ "$actual" == "$expected" ]] || fail "direct PR-merge calls on the issue-loop side differ from the allowlist. Got: $actual. A new merge must go through the merge lane (engine/lib.d/merge-lane.sh); an allowlist entry needs a reason and an exact count; a removed call needs its entry deleted."

fx="$test_env_root/merge-boundary"
mkdir -p "$fx/engine/lib.d"
git -C "$fx" init -q
m='merge'
printf '%s\n' "# gh pr $m \"\$pr\"" > "$fx/engine/issue-pipeline.sh"
printf '%s\n' 'merge_agent_pr "$n" "$pr" "" 1 0' > "$fx/engine/supervisor-holds.sh"
printf '%s\n' "gh pr $m \"\$pr\"" > "$fx/engine/lib.d/merge-lane.sh"
git -C "$fx" add -A
[[ -z "$(scan_root "$fx")" ]] || fail "comment, lane call, or merge-lane file was reported: $(scan_root "$fx")"

printf 'gh pr %s "$pr"\n' "$m" > "$fx/engine/lib.d/new.sh"
git -C "$fx" add -A
reported="$(scan_root "$fx")"
[[ "$reported" == 'engine/lib.d/new.sh 1' ]] || fail "new direct merge call not reported exactly: $reported"

echo 'issue-loop-merge-boundary.test.sh: all assertions passed'
