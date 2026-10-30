#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/lib.sh"
jq ".roles.advisor.disabled = false" "$SCRIPT_DIR/model-policy.default.json" > "$AGENT_HOME/model-policy.json"

TEST_ISSUE=9901755
CODEX_HOME="$test_env_root/codex-home"
export CODEX_HOME
mkdir -p "$CODEX_HOME"
cat > "$CODEX_HOME/config.toml" <<TOML
model = "$MODEL_POLICY_TEST_WORK_MODEL"
model = "$MODEL_POLICY_TEST_WORK_MODEL"
model_reasoning_effort = "$MODEL_POLICY_TEST_WORK_EFFORT"
model_reasoning_effort = "$MODEL_POLICY_TEST_WORK_EFFORT"
TOML

cat > "$test_env_bin/codex" <<'CODEX'
#!/usr/bin/env bash
printf 'Error: failed to load bootstrap configuration\n' >&2
printf 'Caused by:\n' >&2
printf '    0: %s/config.toml:2:1: duplicate key\n' "$CODEX_HOME" >&2
exit 1
CODEX
chmod +x "$test_env_bin/codex"

FAILED=0
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok - %s\n' "$label"
  else
    printf 'not ok - %s (expected [%s], got [%s])\n' "$label" "$expected" "$actual"
    FAILED=1
  fi
}
assert_contains() {
  local label="$1" value="$2" expected="$3"
  if [[ "$value" == *"$expected"* ]]; then
    printf 'ok - %s\n' "$label"
  else
    printf 'not ok - %s (expected to find [%s])\n' "$label" "$expected"
    FAILED=1
  fi
}

if declare -F codex_config_probe >/dev/null && declare -F codex_config_fast_failure >/dev/null; then
  if codex_config_probe; then probe_status=0; else probe_status=$?; fi
  assert_eq 'config-only probe refuses duplicate-key config' 1 "$probe_status"
  assert_contains 'probe captures exact parser error' "$CODEX_CONFIG_PROBE_OUTPUT" 'duplicate key'
else
  printf 'not ok - shared Codex config probe and fast-failure classifier are defined\n'
  exit 1
fi

state_merge "$TEST_ISSUE" '{attempts:1,model_policy:{unit:"implement",step:"work",active:{unit:"implement",step:"work"}}}'
model_identity="$(model_policy identity work)"
IFS=: read -r _ model effort <<< "$model_identity"
schema_file="$test_env_root/schema.json"
prompt_file="$test_env_root/prompt.md"
printf '%s\n' '{"type":"object"}' > "$schema_file"
printf '%s\n' 'Return one object.' > "$prompt_file"
if output="$(run_codex_json "$SCRIPT_DIR" "$model" "$effort" "$schema_file" "$prompt_file")"; then
  call_status=0
else
  call_status=$?
fi
assert_eq 'duplicate-key Codex launch exits before model work' 1 "$call_status"
assert_contains 'launch error retains Codex parser evidence' "$output" 'duplicate key'
assert_eq 'rapid duplicate-key exit is classified as config fault' true "$(codex_config_fast_failure "$output" && echo true || echo false)"

pause_for_backoff "$TEST_ISSUE" "$output" "$call_status" 0 codex "$model_identity" run-implement:implement
assert_eq 'Codex config fault refunds charged ticket attempt' 0 "$(state_read "$TEST_ISSUE" | jq -r '.attempts')"
inbox="$AGENT_HOME/supervisor-inbox"
assert_eq 'Codex config fault writes one supervisor inbox line' 1 "$(wc -l < "$inbox" | tr -d '[:space:]')"
assert_contains 'inbox names environment fault and parser error' "$(cat "$inbox")" 'env:codex-config-invalid'
assert_contains 'inbox retains duplicate-key error detail' "$(cat "$inbox")" 'duplicate key'

transcript_file="$test_env_root/triage-transcript.log"
if run_codex_text "$SCRIPT_DIR" "$model" "$effort" 1 "$prompt_file" "$transcript_file"; then
  text_status=0
else
  text_status=$?
fi
assert_eq 'triage Codex runner returns parser failure' 1 "$text_status"
assert_contains 'triage transcript records startup elapsed seconds' "$(cat "$transcript_file")" 'codex-exec-elapsed-seconds='
assert_eq 'triage parser failure is configuration-classified' true \
  "$(model_call_is_configuration_error "$(tail -c 4000 "$transcript_file")" "$text_status" && echo true || echo false)"
state_merge "$TEST_ISSUE" '.attempts = 1'
record_model_config_fault "$TEST_ISSUE" triage work "$model_identity" "$(tail -c 4000 "$transcript_file")"
assert_eq 'direct triage config-fault handling refunds the charged attempt' 0 "$(state_read "$TEST_ISSUE" | jq -r '.attempts')"
assert_contains 'direct triage config-fault handling records triage stage' \
  "$(cat "$AGENT_HOME/env-faults/env:codex-config-invalid.log")" 'triage'
[ ! -e "$AGENT_HOME/model-config-work.json" ] || { printf 'not ok - Codex parse fault must not poison the role model config\n'; FAILED=1; }

implement_log="$test_env_root/implement.log"
if run_codex_implement "$SCRIPT_DIR" "$model" "$effort" "$prompt_file" "$implement_log" 1 run-implement:implement; then
  implement_status=0
else
  implement_status=$?
fi
assert_eq 'implement Codex runner returns parser failure' 1 "$implement_status"
assert_contains 'implement log records startup elapsed seconds' "$(cat "$implement_log")" 'codex-exec-elapsed-seconds='
assert_eq 'implement parser failure is fast-config-classified' true \
  "$(codex_config_fast_failure "$(tail -c 4000 "$implement_log")" && echo true || echo false)"

python3 - "$SCRIPT_DIR" <<'PY'
from pathlib import Path
import re
import sys

repo = Path(sys.argv[1]).resolve().parents[1]
writer = re.compile(r"(?:>>?|\btee\b|\b(?:write|append|copy|rename|truncate)File(?:Sync)?\b|\b(?:cp|mv|install|truncate)\b|\bopen\s*\([^\n]*[, ]['\"](?:w|a|x))", re.I)
violations = []
for source_root in (repo / "scripts", repo / ".agents"):
    for path in source_root.rglob("*"):
        if not path.is_file() or ".test." in path.name or path.name.endswith(".test.sh"):
            continue
        if path.suffix not in {".sh", ".mjs", ".js", ".cjs", ".py", ".ts"}:
            continue
        for number, line in enumerate(path.read_text(errors="ignore").splitlines(), 1):
            if line.lstrip().startswith(("#", "//", "*")) or "config.toml" not in line.lower():
                continue
            if writer.search(line):
                violations.append(f"{path}:{number}:{line.strip()}")
if violations:
    print("not ok - agent scripts write Codex config.toml")
    print("\n".join(violations))
    raise SystemExit(1)
print("ok - no agent script writes Codex config.toml")
PY
static_status=$?
(( static_status == 0 )) || FAILED=1

if (( FAILED )); then exit 1; fi
printf 'codex-config.test.sh: PASS\n'
