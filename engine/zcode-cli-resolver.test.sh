#!/usr/bin/env bash
# The GLM CLI resolver and its fallback bell (2026-11-03: 68 `review-family fallback
# ... reviewer=sonnet reason=glm cli missing` lines over 8.5h while the host carried
# the CLI only as the worker bundle; every engine site demanded a bare `zcode` on PATH).
# Covers: resolver order (env > config engine.zcode_bin > bundle > PATH), the review
# availability check passing with only the bundle present, and the bell filing exactly
# one incident after N consecutive glm-runtime fallbacks.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
trap 'rm -rf -- "$test_env_root"' EXIT
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
check() { [[ "$2" == "$3" ]] || fail "$1: got '$2', want '$3'"; printf 'ok - %s\n' "$1"; }

# The host may carry a zcode shim on its PATH; every scenario pins a PATH without it.
strict_path="$test_env_bin:$(dirname "$(command -v jq)"):/usr/bin:/bin"

fixture="$test_env_root/zcode-resolver"
bundle="$fixture/bundle"
cfg_dir="$fixture/cfg"
empty_root="$fixture/empty"
path_bin="$fixture/pathbin"
env_bin="$fixture/envbin"
mkdir -p "$bundle/zc-src/bin" "$bundle/zc-src/repo/apps/zcode-cli/packages/cli/dist" \
  "$cfg_dir" "$empty_root" "$path_bin" "$env_bin"
printf '#!/bin/sh\nexit 0\n' > "$bundle/zc-src/bin/zcode"
chmod +x "$bundle/zc-src/bin/zcode"
: > "$bundle/zc-src/repo/apps/zcode-cli/packages/cli/dist/zcode.cjs"
for f in "$cfg_dir/config-zcode" "$env_bin/config-zcode" "$path_bin/zcode"; do
  printf '#!/bin/sh\nexit 0\n' > "$f"
  chmod +x "$f"
done
bundle_entry="$bundle/zc-src/repo/apps/zcode-cli/packages/cli/dist/zcode.cjs"

# resolve <label> <expected words...> -- env assignments for a fresh config.sh source
resolve() {
  local label="$1" expected="$2"; shift 2
  local got
  got="$(env -i HOME="$HOME" PATH="$strict_path" ZF_CONFIG_ROOT="$cfg_dir" "$@" \
    bash -c 'source "$1/config.sh"; zf_zcode_bin_argv' _ "$SCRIPT_DIR" 2>/dev/null || true)"
  check "$label" "$got" "$expected"
}

printf '%s\n' '{}' > "$cfg_dir/config.json"
resolve "bundle default: the bin/zc two-word command (node binary + CLI entry)" \
  "$bundle/zc-src/bin/zcode"$'\n'"$bundle_entry" \
  WORKER_SCRATCH_ROOT="$bundle"
resolve "PATH fallback when no bundle, config or env names one" \
  "$path_bin/zcode" \
  PATH="$path_bin:$strict_path" WORKER_SCRATCH_ROOT="$empty_root"
resolve "no candidate anywhere resolves to nothing" \
  "" \
  WORKER_SCRATCH_ROOT="$empty_root"

jq -n --arg bin "$cfg_dir/config-zcode" '{engine:{zcode_bin:$bin}}' > "$cfg_dir/config.json"
resolve "config engine.zcode_bin wins over the bundle" \
  "$cfg_dir/config-zcode" \
  WORKER_SCRATCH_ROOT="$bundle"
resolve "env override ZF_ZCODE_BIN wins over config and bundle" \
  "$env_bin/config-zcode" \
  WORKER_SCRATCH_ROOT="$bundle" ZF_ZCODE_BIN="$env_bin/config-zcode"
jq -n --arg bin "$fixture/no-such-zcode" '{engine:{zcode_bin:$bin}}' > "$cfg_dir/config.json"
resolve "an explicit config path that is not executable resolves to nothing (no silent fallthrough)" \
  "" \
  WORKER_SCRATCH_ROOT="$bundle"
jq -n '{engine:{zcode_bin:""}}' > "$cfg_dir/config.json"
resolve "an empty config value falls back to the bundle" \
  "$bundle/zc-src/bin/zcode"$'\n'"$bundle_entry" \
  WORKER_SCRATCH_ROOT="$bundle"

# --- the review availability check passes with only the bundle present -------------
# No zcode on PATH, no config: only the worker bundle exists, and the policy's zcode
# review identity must be available (this is the exact 2026-11-03 incident shape).
review_home="$fixture/review-home"
review_agent="$fixture/review-agent"
mkdir -p "$review_home/.zcode/v2" "$review_agent/state"
jq -n '{config:{defaultModelSelection:{modelId:"GLM-5.3"}}}' > "$review_home/.zcode/v2/provider_config.json"
REVIEW_OUT="$(env HOME="$review_home" AGENT_HOME="$review_agent" PATH="$strict_path" \
  WORKER_SCRATCH_ROOT="$bundle" bash -c '
    source "$0/lib.sh"
    review_identity_available "zcode:GLM-5.3:max" review && echo "glm-available"
    echo "reason=$(review_identity_unavailable_reason "zcode:GLM-5.3:max" review)"
  ' "$SCRIPT_DIR" 2>/dev/null || true)"
check "bundle-only: the zcode review identity is available" "$(grep -c glm-available <<<"$REVIEW_OUT")" "1"
check "bundle-only: the unavailable reason is not glm cli missing" \
  "$(grep -c 'reason=glm cli missing' <<<"$REVIEW_OUT")" "0"

# --- the bell: one incident after N consecutive glm-runtime fallbacks, no repeat ----
bell="$fixture/bell"
bell_home="$bell/home"
bell_agent="$bell/agent"
bell_ghbin="$bell/ghbin"
bell_claude="$bell/claudebin"
bell_cfg="$bell/cfg"
bell_locks="$bell/issue-locks"
mkdir -p "$bell_home" "$bell_agent/state" "$bell_ghbin" "$bell_claude" "$bell_cfg" "$bell_locks"
# Policy: the default plus the Sonnet fallback permission the live claude-saving mode runs.
# roadmap-order off: the upsert attaches created issues to the seeded roadmap tree like
# pipeline-issue-upsert.test.sh does, without ordering side quests.
jq '.allow_roles = {sonnet: ["review_fallback"]} | .switches["roadmap-order"] = false' \
  "$MODEL_POLICY_TEST_DEFAULT_FILE" > "$bell_agent/model-policy.json"
cat > "$bell/roadmap-tree.json" <<'JSON'
{"roots":[{"number":900,"title":"the product roadmap","state":"open","labels":["roadmap"],"children":[{"number":910,"title":"开发流水线与运行稳定","state":"open","milestone":"开发流水线与运行稳定","labels":["roadmap-theme"],"children":[{"number":912,"title":"Automation issue tracking","state":"open","labels":["roadmap-epic"],"children":[]}]},{"number":911,"title":"产品研发","state":"open","milestone":"产品研发","labels":["roadmap-theme"],"children":[{"number":913,"title":"待归类","state":"open","labels":["roadmap-epic"],"children":[]}]}]}]}
JSON
printf '%s\n' '{"engine":{"glm_fallback_incident_threshold":3}}' > "$bell_cfg/config.json"
printf '#!/usr/bin/env bash\nexit 0\n' > "$bell_claude/claude"
chmod +x "$bell_claude/claude"
# The fake gh from pipeline-issue-upsert.test.sh: records every call, serves one unrelated
# open pipeline-system issue, and appends created issues to the same pool.
cat > "$bell_ghbin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
case "${1:-}:${2:-}" in
  label:list)
    cat "$FAKE_LABELS"
    ;;
  label:create)
    label="${3:?}"
    grep -qx -- "$label" "$FAKE_LABELS" || printf '%s\n' "$label" >> "$FAKE_LABELS"
    ;;
  api:--method)
    [[ "${FAKE_GH_LIST_FAIL:-0}" != 1 ]] || exit 42
    jq -c 'if length == 0 then [[]] else [.[0:1], .[1:]] end' "$FAKE_ISSUES"
    ;;
  issue:create)
    title=""; body_file=""; previous=""; labels=()
    for arg in "$@"; do
      case "$previous" in
        --title) title="$arg" ;;
        --body-file) body_file="$arg" ;;
        --label) labels+=("$arg") ;;
      esac
      previous="$arg"
    done
    [[ -n "$title" && -r "$body_file" ]]
    number="$(cat "$FAKE_NEXT_NUMBER")"
    printf '%s\n' "$((number + 1))" > "$FAKE_NEXT_NUMBER"
    labels_json="$(printf '%s\n' "${labels[@]}" | jq -R . | jq -s 'map({name:.})')"
    jq --argjson number "$number" --arg title "$title" --argjson labels "$labels_json" --rawfile body "$body_file" \
      '. + [{number:$number,title:$title,body:$body,state:"OPEN",labels:$labels}]' \
      "$FAKE_ISSUES" > "$FAKE_ISSUES.tmp"
    mv "$FAKE_ISSUES.tmp" "$FAKE_ISSUES"
    printf 'https://github.com/test/repo/issues/%s\n' "$number"
    ;;
  issue:comment)
    number="${3:-}"; body_file=""; previous=""
    for arg in "$@"; do
      [[ "$previous" != --body-file ]] || body_file="$arg"
      previous="$arg"
    done
    [[ "$number" =~ ^[1-9][0-9]*$ && -r "$body_file" ]]
    jq -cn --argjson number "$number" --rawfile body "$body_file" '{number:$number,body:$body}' \
      >> "$FAKE_COMMENTS"
    ;;
  issue:view)
    jq -ce --argjson number "${3:?}" '[.[] | select(.number == $number)][0]' "$FAKE_ISSUES"
    ;;
  issue:edit)
    echo '{}'
    ;;
  api:repos/*/issues/*/sub_issues)
    echo '{}'
    ;;
  api:repos/*/issues/*)
    echo 501000
    ;;
  *) echo "unexpected fake gh call: $*" >&2; exit 90 ;;
esac
FAKE_GH
chmod +x "$bell_ghbin/gh"
export FAKE_GH_LOG="$bell/gh.log" FAKE_ISSUES="$bell/issues.json" FAKE_COMMENTS="$bell/comments.jsonl" \
  FAKE_NEXT_NUMBER="$bell/next-number" FAKE_LABELS="$bell/labels"
printf '[{"number":4999,"title":"Unrelated open issue","body":"no class marker","state":"OPEN","labels":[{"name":"pipeline-system"}]}]\n' > "$FAKE_ISSUES"
printf '%s\n' pipeline-system ready-for-agent > "$FAKE_LABELS"
: > "$FAKE_GH_LOG"
: > "$FAKE_COMMENTS"
printf '5001\n' > "$FAKE_NEXT_NUMBER"

# Five fallback decisions with threshold 3: one filing at the third, streak back to 2.
BELL_OUT="$(env HOME="$bell_home" AGENT_HOME="$bell_agent" ZF_CONFIG_ROOT="$bell_cfg" \
  ZF_ISSUE_LOCK_DIR="$bell_locks" ZF_GH_REAL_CLI="$bell_ghbin/gh" \
  ZF_ROADMAP_TREE_CACHE_FILE="$bell/roadmap-tree.json" \
  PATH="$SCRIPT_DIR/gh-shim:$bell_claude:$strict_path" \
  WORKER_SCRATCH_ROOT="$empty_root" TMPDIR="$test_env_root" bash -c '
    source "$0/lib.sh"
    for i in 1 2 3 4 5; do
      review_model_for_implementer 4300 "$MODEL_POLICY_TEST_WORK_IDENTITY" "" "zcode:GLM-5.3:max" "claude:claude-sonnet-4-5:high" "unit-$i"
    done
    printf "streak=$(cat "$AGENT_HOME/glm-fallback-streak")\n"
  ' "$SCRIPT_DIR" 2>"$bell/stderr.log" || true)"
check "every fallback decision still selects the Sonnet reviewer" \
  "$(grep -c '^claude:claude-sonnet-4-5:high$' <<<"$BELL_OUT")" "5"
check "all five decisions logged the glm cli missing fallback" \
  "$(grep -c 'review-family fallback .*reviewer=claude-sonnet-4-5 reason=glm cli missing' "$bell/stderr.log")" "5"
check "the bell filed exactly once" \
  "$(grep -c 'glm fallback bell: filed glm-cli-fallback incident after 3 consecutive' "$bell/stderr.log")" "1"
check "exactly one issue create reached gh" "$(grep -c '^issue create' "$FAKE_GH_LOG")" "1"
check "no repeat: nothing commented while the incident is open" "$(grep -c '^issue comment' "$FAKE_GH_LOG")" "0"
check "the streak restarted after the filing (two more fallbacks)" \
  "$(grep -c '^streak=2$' <<<"$BELL_OUT")" "1"

echo 'PASS zcode-cli-resolver: resolver order, bundle-only availability, glm fallback bell'
