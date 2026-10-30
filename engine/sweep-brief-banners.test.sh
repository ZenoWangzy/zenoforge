#!/usr/bin/env bash
# Regression tests for sweep-brief-banners.sh (2026-09-16, V119's backfill
# companion). Plain bash assertions, no framework -- matches this repo's
# other engine/*.test.sh style. No fake `gh` needed (this script
# never calls gh); `stage_unit_active()` shells out to the REAL `systemctl
# --user is-active zf-<stage>-<n>`, which correctly reports "inactive"
# for a nonexistent unit name with zero mocking needed for the common case
# -- only the "skip an active ticket" scenario fakes `systemctl` on PATH.
#
# Fixtures are built with `jq -n --arg` (this repo's own safe-embedding
# convention, same reason jq_arg_file()/--rawfile exist in lib.sh) rather
# than shell-interpolating raw text into another language's source -- a
# brief_md here carries real newlines, `**`, `「」`, and literal "---" text,
# exactly the shapes that break naive string interpolation.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWEEP_SRC="$SCRIPT_DIR/sweep-brief-banners.sh"

FAILED=0
TMP_DIRS=()
cleanup() {
  local d
  for d in "${TMP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}
trap cleanup EXIT

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok - $desc"
  else
    echo "not ok - $desc (expected [$expected], got [$actual])"
    FAILED=1
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "ok - $desc"
  else
    echo "not ok - $desc (expected to find [$needle])"
    FAILED=1
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "ok - $desc"
  else
    echo "not ok - $desc (expected NOT to find [$needle])"
    FAILED=1
  fi
}

new_agent_home() {
  local d
  d="$(mktemp -d)"
  TMP_DIRS+=("$d")
  mkdir -p "$d/state"
  echo "$d"
}

run_sweep() {
  local agent_home="$1"
  shift
  set +e
  RUN_OUTPUT="$(AGENT_HOME="$agent_home" REPO="test/repo" "$@" bash "$SWEEP_SRC" 2>&1)"
  RUN_STATUS=$?
  set -e
}

# write_fixture <path> <state-json-with-guarded/risk/level/conditions-preset> <brief_md>
# jq handles all the escaping -- no shell-into-another-language interpolation.
write_fixture() {
  local path="$1" extra_fields="$2" brief="$3"
  jq -n --arg b "$brief" "$extra_fields + {brief_md: \$b}" > "$path"
}

# banner_for <risk> <level> <conditions> -- builds the SAME banner shape
# guarded_brief() (lib.sh) produces, so fixtures look like the real thing.
# Writes into the global $BANNER_OUT via `printf -v` (bash builtin, no
# command substitution, no nameref) specifically because `$(...)` strips
# ALL trailing newlines -- the banner's own trailing "\n---\n\n" would lose
# its two trailing newlines on every capture, silently breaking a fixture
# built by concatenating layers through `$(...)`. Real newlines throughout,
# all of them preserved. A single well-known output variable (not `local
# -n`) so shellcheck can trace every assignment statically.
banner_for() {
  local risk="$1" level="$2" conditions="$3"
  printf -v BANNER_OUT '**这张票按「加强看护」（guarded）进入无人值守流水线（2026-01-01T00:00:00Z）。** 它没能拆成低风险的小票，也不在常规准入范围内（risk_class=%s, level=%s）；实现与独立评审仍分别解析持久化策略中的角色，不切换模型。下面这份简报里如果出现「维持 ready-for-human」「不会自动写代码」「需要人工」这类结论，那是本次准入之前的旧结论，已经不成立，以本段为准。\n\n**合并前必须满足的条件（实现者必须把它们做进 diff，评审者必须逐条核对）：**\n\n%s\n\n---\n\n' \
    "$risk" "$level" "$conditions"
}

supers_banner() {
  printf -v BANNER_OUT '**顾问已改判（2026-01-01T00:00:00Z），这张票现在按无人值守处理。** 下面这份分诊简报是改判前写的，当前真实状态是 risk_class=%s, level=%s, state=ready-for-agent——简报正文里如果出现「维持 ready-for-human」「不会自动写代码」「需要人工」这类结论，那是改判前的旧结论，已经不成立，以这一行为准。\n\n**顾问给出的合并条件（实现者必须做进 diff，评审者必须逐条核对）：**\n\n%s\n\n---\n\n' \
    "$1" "$2" "$3"
}

printf -v core '## Agent Brief\n\n原始简报正文，从未被任何横幅覆盖过。'

# --- scenario 1: 3 stacked layers -> exactly 1 regenerated banner ----------
AH1="$(new_agent_home)"
banner_for P2 L2 "旧条件 1"; layer1="${BANNER_OUT}${core}"
banner_for P2 L3 "旧条件 2"; layer2="${BANNER_OUT}${layer1}"
banner_for P2 L3 "当前条件"; layer3="${BANNER_OUT}${layer2}"
write_fixture "$AH1/state/9001.json" \
  '{attempts:0, state:"ready-for-agent", guarded:true, risk_class:"P2", level:"L3", merge_conditions_md:"当前条件"}' \
  "$layer3"

run_sweep "$AH1" env
assert_eq "3-stacked ticket: sweep exits 0" "0" "$RUN_STATUS"
assert_contains "...reports the regeneration" "$RUN_OUTPUT" "#9001 -- regenerated brief_md"
new_brief="$(jq -r '.brief_md' "$AH1/state/9001.json")"
sep_count="$(printf '%s' "$new_brief" | grep -c -- '^---$' || true)"
assert_contains "...result starts with exactly one guarded banner" "$new_brief" '**这张票按「加强看护」'
assert_contains "...result carries the CURRENT conditions" "$new_brief" "当前条件"
assert_not_contains "...result does NOT carry the stale layer-2 conditions" "$new_brief" "旧条件 2"
assert_not_contains "...result does NOT carry the stale layer-1 conditions" "$new_brief" "旧条件 1"
assert_contains "...original core content survives underneath" "$new_brief" "原始简报正文"
assert_eq "...exactly one banner separator line, not three" "1" "$sep_count"

# idempotency: run again, must be a true no-op (byte-identical, no output)
before="$(cat "$AH1/state/9001.json")"
run_sweep "$AH1" env
assert_eq "re-running after a real fix is a no-op: exit 0" "0" "$RUN_STATUS"
assert_eq "...no output (nothing left to touch)" "" "$RUN_OUTPUT"
after="$(cat "$AH1/state/9001.json")"
assert_eq "...state file byte-identical to before the re-run" "$before" "$after"

# a backup was written before the real write
backup_count="$(find "$AH1/state-backfill-backups" -name '9001.json' 2>/dev/null | wc -l | tr -d ' ' || true)"
assert_eq "a backup of the pre-fix file was written" "1" "$backup_count"

# --- scenario 2: exactly one banner -> untouched, byte-identical -----------
AH2="$(new_agent_home)"
banner_for P1 L1 "唯一条件"; single="${BANNER_OUT}${core}"
write_fixture "$AH2/state/9002.json" \
  '{attempts:0, state:"ready-for-agent", guarded:true, risk_class:"P1", level:"L1", merge_conditions_md:"唯一条件"}' \
  "$single"

before2="$(cat "$AH2/state/9002.json")"
run_sweep "$AH2" env
assert_eq "single-banner ticket: sweep exits 0" "0" "$RUN_STATUS"
assert_not_contains "...not mentioned at all (healthy, left alone)" "$RUN_OUTPUT" "#9002"
after2="$(cat "$AH2/state/9002.json")"
assert_eq "...file byte-identical (single banner is current, correct content)" "$before2" "$after2"

# --- scenario 3: banner prefix present but separator missing (truncated,
# --- e.g. an untriaged recut parent admitted with an empty old_brief, and
# --- the trailing "\n\n" of its own separator stripped by the very
# --- $(...) capture that stored it) -----------------------------------------
AH3="$(new_agent_home)"
truncated="$(printf '**这张票按「加强看护」（guarded）进入无人值守流水线（2026-01-01T00:00:00Z）。** 未测量。\n\n**合并前必须满足的条件（实现者必须把它们做进 diff，评审者必须逐条核对）：**\n\n条件\n\n---')"
write_fixture "$AH3/state/9003.json" \
  '{attempts:0, state:"ready-for-agent", guarded:true, risk_class:"", level:"", merge_conditions_md:"条件"}' \
  "$truncated"

before3="$(cat "$AH3/state/9003.json")"
run_sweep "$AH3" env
assert_eq "truncated single-banner ticket: sweep exits 0" "0" "$RUN_STATUS"
assert_not_contains "...not mentioned (a missing separator is NOT a second stacked layer)" "$RUN_OUTPUT" "#9003"
after3="$(cat "$AH3/state/9003.json")"
assert_eq "...file byte-identical" "$before3" "$after3"

# --- scenario 4: no banner at all -> untouched, even with a coincidental
# --- "---" of its own in the real content -----------------------------------
AH4="$(new_agent_home)"
plain="$(printf '一份普通的、从未加强看护过的简报，正文里恰好也有一条分隔线：\n\n---\n\n这不是横幅。')"
write_fixture "$AH4/state/9004.json" '{attempts:0, state:"needs-triage"}' "$plain"

before4="$(cat "$AH4/state/9004.json")"
run_sweep "$AH4" env
assert_eq "no-banner ticket (with an unrelated '---' in its own prose): sweep exits 0" "0" "$RUN_STATUS"
assert_not_contains "...not mentioned" "$RUN_OUTPUT" "#9004"
after4="$(cat "$AH4/state/9004.json")"
assert_eq "...file byte-identical -- a coincidental '---' in real content must never be read as a banner" "$before4" "$after4"

# --- scenario 5: DRY_RUN never writes ---------------------------------------
AH5="$(new_agent_home)"
banner_for P2 L3 "条件A"; stacked5="${BANNER_OUT}${core}"
banner_for P2 L3 "条件B"; stacked5="${BANNER_OUT}${stacked5}"
write_fixture "$AH5/state/9005.json" \
  '{attempts:0, state:"ready-for-agent", guarded:true, risk_class:"P2", level:"L3", merge_conditions_md:"条件B"}' \
  "$stacked5"

before5="$(cat "$AH5/state/9005.json")"
run_sweep "$AH5" env AGENT_DRY_RUN=1
assert_eq "dry-run on a genuinely stacked ticket: exits 0" "0" "$RUN_STATUS"
assert_contains "...says what it WOULD do" "$RUN_OUTPUT" "[dry-run] would regenerate"
after5="$(cat "$AH5/state/9005.json")"
assert_eq "...file untouched under AGENT_DRY_RUN=1" "$before5" "$after5"
backup_count5="$(find "$AH5/state-backfill-backups" 2>/dev/null | wc -l | tr -d ' ' || true)"
assert_eq "...no backup directory created under dry-run either" "0" "$backup_count5"

# --- scenario 6: active unit -> skipped, not even backed up ----------------
FAKE_BIN="$(mktemp -d)"
TMP_DIRS+=("$FAKE_BIN")
cat > "$FAKE_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
# Only zf-implement-9006 is "active"; everything else behaves inactive.
for a in "$@"; do
  [ "$a" = "zf-implement-9006" ] && exit 0
done
exit 3
EOF
chmod +x "$FAKE_BIN/systemctl"

AH6="$(new_agent_home)"
banner_for P2 L3 "条件A"; stacked6="${BANNER_OUT}${core}"
banner_for P2 L3 "条件B"; stacked6="${BANNER_OUT}${stacked6}"
write_fixture "$AH6/state/9006.json" \
  '{attempts:0, state:"ready-for-agent", guarded:true, risk_class:"P2", level:"L3", merge_conditions_md:"条件B"}' \
  "$stacked6"

before6="$(cat "$AH6/state/9006.json")"
set +e
RUN_OUTPUT="$(AGENT_HOME="$AH6" REPO="test/repo" PATH="$FAKE_BIN:$PATH" bash "$SWEEP_SRC" 2>&1)"
RUN_STATUS=$?
set -e
assert_eq "active-unit ticket: sweep still exits 0" "0" "$RUN_STATUS"
assert_contains "...explicitly skips it" "$RUN_OUTPUT" "#9006 -- has an active zf-*-9006 unit"
after6="$(cat "$AH6/state/9006.json")"
assert_eq "...file byte-identical -- an active leg's ticket is never rewritten" "$before6" "$after6"
backup_count6="$(find "$AH6/state-backfill-backups" 2>/dev/null | wc -l | tr -d ' ' || true)"
assert_eq "...not even backed up (nothing was touched)" "0" "$backup_count6"

# --- scenario 7: advisor_superseded_brief() path (misclassified correction,
# --- guarded:false) also collapses to exactly one banner -------------------
AH7="$(new_agent_home)"
supers_banner P1 L2 "旧改判条件"; stacked7="${BANNER_OUT}${core}"
supers_banner P1 L2 "当前改判条件"; stacked7="${BANNER_OUT}${stacked7}"
write_fixture "$AH7/state/9007.json" \
  '{attempts:0, state:"ready-for-agent", risk_class:"P1", level:"L2", merge_conditions_md:"当前改判条件"}' \
  "$stacked7"

run_sweep "$AH7" env
assert_eq "misclassified-path (guarded:false) 2-stacked ticket: exits 0" "0" "$RUN_STATUS"
assert_contains "...regenerated via the same mechanism" "$RUN_OUTPUT" "#9007 -- regenerated brief_md"
new_brief7="$(jq -r '.brief_md' "$AH7/state/9007.json")"
assert_contains "...result carries the superseded banner" "$new_brief7" "顾问已改判"
assert_contains "...current conditions" "$new_brief7" "当前改判条件"
assert_not_contains "...not the stale ones" "$new_brief7" "旧改判条件"

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
