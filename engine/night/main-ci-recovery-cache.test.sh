#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
trap 'rm -rf -- "$test_env_root"' EXIT

export ZF_REPO=test/repo ZF_REPO_DIR="$MODEL_POLICY_TEST_REPO"
head_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
fake_bin="$test_env_root/fake-bin"
mkdir -p -- "$fake_bin"
cat > "$fake_bin/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in
  'api repos/test/repo/git/ref/heads/main'*)
    printf '{"object":{"sha":"%s"}}\n' "${MAIN_RED_SHA:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" ;;
  *'repos/test/repo/actions/workflows/pipeline-suites.yml/runs?branch=main&per_page=100&page=1'*)
    printf '%s\n' "$*" >> "$AGENT_HOME/workflow-run-calls"
    jq -cn --arg red "$MAIN_RED_SHA" --arg green "$MAIN_GREEN_SHA" '{workflow_runs:[
      {id:811,head_sha:$red,head_branch:"main",event:"push",conclusion:"failure",run_attempt:1,created_at:"2026-01-02T00:00:00Z"},
      {id:810,head_sha:$green,head_branch:"main",event:"push",conclusion:"success",run_attempt:1,created_at:"2026-01-01T00:00:00Z"}]}' ;;
  *'repos/test/repo/actions/runs?status=in_progress&per_page=100'*)
    printf '%s\n' "$*" >> "$AGENT_HOME/status-run-calls"
    printf '[{"workflow_runs":[]}]\n' ;;
  *'repos/test/repo/actions/runs?status=queued&per_page=100'*)
    printf '%s\n' "$*" >> "$AGENT_HOME/status-run-calls"
    printf '[{"workflow_runs":[]}]\n' ;;
  'run view '*)
    run_id="${3:-}"
    printf '%s\n' "$*" >> "$AGENT_HOME/job-view-calls"
    cat "$AGENT_HOME/run-view-$run_id.json" ;;
  *'/actions/workflows/pipeline-suites.yml/runs?branch=main&status='*) printf '{"workflow_runs":[]}\n' ;;
  'run rerun 811 --repo test/repo --failed') printf '%s\n' "$*" >> "$AGENT_HOME/reruns" ;;
  *) exit 97 ;;
esac
GH
chmod +x "$fake_bin/gh"
export PATH="$fake_bin:$PATH"

source "$MODEL_POLICY_TEST_REPO/engine/lib.d/gh-key-cache.sh"
cache_file="$(gh_key_cache_file "check-runs:$ZF_REPO:$head_sha")"
mkdir -p -- "${cache_file%/*}"
{ date +%s; printf '%s' '{"total_count":1,"check_runs":[{"status":"completed"}]}'; } > "$cache_file"

bash "$MODEL_POLICY_TEST_REPO/engine/night/main-ci-recovery.sh" \
  handle pipeline-suites 811 1 completed failure "$head_sha"
[[ ! -e "$cache_file" ]] || { printf 'main-ci-recovery-cache.test.sh: successful rerun kept completed check-run cache\n' >&2; exit 1; }
[[ "$(cat "$AGENT_HOME/reruns")" == 'run rerun 811 --repo test/repo --failed' ]] \
  || { printf 'main-ci-recovery-cache.test.sh: expected rerun did not happen\n' >&2; exit 1; }

history_repo="$test_env_root/run-history"
mkdir -p -- "$history_repo"
git init -q -b main "$history_repo"
git -C "$history_repo" config user.name Test
git -C "$history_repo" config user.email test@example.invalid
printf 'green\n' > "$history_repo/state"
git -C "$history_repo" add state
git -C "$history_repo" commit -qm green
MAIN_GREEN_SHA="$(git -C "$history_repo" rev-parse HEAD)"
printf 'red\n' >> "$history_repo/state"
git -C "$history_repo" commit -qam red
MAIN_RED_SHA="$(git -C "$history_repo" rev-parse HEAD)"
export MAIN_GREEN_SHA MAIN_RED_SHA ZF_REPO_DIR="$history_repo"
: > "$AGENT_HOME/workflow-run-calls"
window="$(bash "$MODEL_POLICY_TEST_REPO/engine/night/main-ci-recovery.sh" attribute-red 811 1 "$MAIN_RED_SHA")"
window_again="$(bash "$MODEL_POLICY_TEST_REPO/engine/night/main-ci-recovery.sh" attribute-red 811 1 "$MAIN_RED_SHA")"
[[ "$window" == fallback=no-direct-pipeline-candidate && "$window_again" == "$window" ]] \
  || { printf 'main-ci-recovery-cache.test.sh: red-window lookup changed: %s / %s\n' "$window" "$window_again" >&2; exit 1; }
[[ "$(wc -l < "$AGENT_HOME/workflow-run-calls" | tr -d ' ')" == 1 ]] \
  || { printf 'main-ci-recovery-cache.test.sh: workflow run page was fetched more than once\n' >&2; exit 1; }

: > "$AGENT_HOME/job-view-calls"
printf '{"headSha":"%s","attempt":1,"status":"completed","conclusion":"success","jobs":[]}\n' "$MAIN_RED_SHA" \
  > "$AGENT_HOME/run-view-812.json"
bash "$MODEL_POLICY_TEST_REPO/engine/night/main-ci-recovery.sh" handle pipeline-suites 812 2 completed success "$MAIN_RED_SHA"
bash "$MODEL_POLICY_TEST_REPO/engine/night/main-ci-recovery.sh" handle pipeline-suites 812 2 completed success "$MAIN_RED_SHA"
[[ "$(wc -l < "$AGENT_HOME/job-view-calls" | tr -d ' ')" == 1 ]] \
  || { printf 'main-ci-recovery-cache.test.sh: completed run jobs were fetched more than once\n' >&2; exit 1; }

snapshot_file="$AGENT_HOME/open-prs.json"
printf '{"sampled_at":"%s","open_prs":[]}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$snapshot_file"
export ZF_OPEN_ISSUES_CACHE_FILE="$snapshot_file"
: > "$AGENT_HOME/status-run-calls"
bash "$MODEL_POLICY_TEST_REPO/engine/night/main-ci-recovery.sh" cancel-closed-pr-runs
bash "$MODEL_POLICY_TEST_REPO/engine/night/main-ci-recovery.sh" cancel-closed-pr-runs
[[ "$(wc -l < "$AGENT_HOME/status-run-calls" | tr -d ' ')" == 2 ]] \
  || { printf 'main-ci-recovery-cache.test.sh: status workflow runs were fetched more than once per status\n' >&2; exit 1; }

printf 'main-ci-recovery-cache.test.sh: pass\n'
