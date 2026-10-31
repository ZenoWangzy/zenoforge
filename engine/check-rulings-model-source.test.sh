#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/test-env.sh"

scripts="$MODEL_POLICY_TEST_REPO/engine"
candidate="$TMPDIR/candidate"
mkdir -p "$candidate/engine/nested"
copy_agent_library "$candidate/engine"
# lesson-guard-schema validates machine_checks test files for registry
# records dated on/after its schema start; suite files are the one class the
# closure helper excludes on purpose, so follow the register here (empty
# today, self-maintaining once a schema-dated record lands).
while IFS= read -r suite; do
  suite="${suite#\$\{REPO_DIR\}/}"
  [[ -f "$MODEL_POLICY_TEST_REPO/$suite" ]] || continue
  mkdir -p -- "$candidate/${suite%/*}"
  cp -a -- "$MODEL_POLICY_TEST_REPO/$suite" "$candidate/$suite"
done < <(jq -r '.incidents[]
  | select(.date >= "2026-10-30")
  | (.machine_checks // [])[]?.test_file // empty' "$scripts/state/incident-guards.json")
cat > "$candidate/engine/selected.test.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/test-env.sh"
EOF

check_source() {
  # ZF_ENGINE_DIR must follow ZF_REPO_DIR into the candidate: left unset it
  # derives from this repo's engine, so suite discovery scans the real engine
  # (whose self-contained suites skip test-env.sh) and the model scan reads the
  # real sources, never the candidate under test.
  ZF_REPO_DIR="$candidate" ZF_ENGINE_DIR="$candidate/engine" AGENT_RULINGS_MODE=source \
    bash "$scripts/check-rulings.sh" "$@"
}

check_source > "$TMPDIR/source-clean.log" 2>&1 || { cat "$TMPDIR/source-clean.log" >&2; exit 1; }
grep -q 'check-rulings: source checks passed' "$TMPDIR/source-clean.log"
traffic="$candidate/engine/network-traffic.py"
cat >> "$traffic" <<'PY'

def process_label(comm):
    if comm in ('codex', 'claude'):
        return 'codex/model'
PY
check_source > "$TMPDIR/process-label.log" 2>&1 || { cat "$TMPDIR/process-label.log" >&2; exit 1; }
grep -q 'check-rulings: source checks passed' "$TMPDIR/process-label.log"
printf "%s\n" "MODEL = 'claude'" >> "$traffic"
if check_source > "$TMPDIR/model-selection.log" 2>&1; then
  echo 'not ok - source mode accepted a forbidden model selection in network-traffic.py' >&2
  exit 1
else
  status=$?
fi
[[ "$status" == 2 ]]
grep -Fq "forbidden model name 'claude' appears in $traffic" "$TMPDIR/model-selection.log"
printf '#!/usr/bin/env python3\n' > "$traffic"
for extension in py sh js txt; do
  file="$candidate/engine/nested/traffic.$extension"
  printf "MODEL = '%s'\n" "$(jq -r '.forbidden[0]' "$scripts/model-policy.default.json")" > "$file"
  if [[ "$extension" == sh ]]; then
    if check_source --sources-only > "$TMPDIR/source-rejected.log" 2>&1; then
      echo "not ok - source-only mode accepted forbidden model in $file" >&2
      exit 1
    else
      status=$?
    fi
  elif check_source "$candidate/engine/selected.test.sh" > "$TMPDIR/source-rejected.log" 2>&1; then
    echo "not ok - source mode accepted forbidden model in $file" >&2
    exit 1
  else
    status=$?
  fi
  [[ "$status" == 2 ]]
  grep -Fq "appears in $file" "$TMPDIR/source-rejected.log"
  grep -q 'ERROR check-rulings: a forbidden model name appears in pipeline sources' "$TMPDIR/source-rejected.log"
  rm "$file"
done
printf 'codex\n' > "$candidate/engine/nested/traffic.py"
check_source > "$TMPDIR/source-fixed.log" 2>&1
grep -q 'check-rulings: source checks passed' "$TMPDIR/source-fixed.log"
echo 'check-rulings-model-source: PASS'
