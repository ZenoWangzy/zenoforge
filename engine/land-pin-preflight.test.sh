#!/usr/bin/env bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
land_script="$script_dir/land-direct-main.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/land-pin-preflight-test.XXXXXX")"
gates_file="$script_dir/publish-preflight/gates.tsv"
cp "$gates_file" "$tmp/gates.original"
restore() { cp "$tmp/gates.original" "$gates_file"; rm -rf -- "$tmp"; }
trap restore EXIT

fail() { printf 'land-pin-preflight.test.sh: %s\n' "$*" >&2; exit 1; }

# Exercise the focused landing function without taking the suite's real resource slot.
function_file="$tmp/land-pin-preflight.sh"
sed -n '/^land_engine_pin_preflight() {/,/^}$/p' "$land_script" > "$function_file"
[[ -s "$function_file" ]] || fail 'could not extract land_engine_pin_preflight from land-direct-main.sh'
# shellcheck source=/dev/null
source "$function_file"
land_pin_preflight_verified_key=""
with_preflight_slot() { "$@"; }

engine_repo="$tmp/engine"
git init -q "$engine_repo"
git -C "$engine_repo" config user.name 'pin preflight fixture'
git -C "$engine_repo" config user.email 'pin-preflight@example.invalid'
mkdir -p "$engine_repo/engine/hotfix" "$engine_repo/engine/prompts" "$engine_repo/engine/state"
printf 'hf-start v1\n' > "$engine_repo/engine/hotfix/hf-start.sh"
cat > "$engine_repo/engine/config-reader.sh" <<'READER'
prompt="$(zf_config_file prompts/supervisor-cap-triage.md)"
rulings="$(zf_config_file state/rulings.json)"
direct="$(zf_config_file state/direct.json)"
READER
printf '{"value":"engine-v1"}\n' > "$engine_repo/engine/state/rulings.json"
git -C "$engine_repo" add -A
git -C "$engine_repo" commit -qm 'engine v1'
engine_v1="$(git -C "$engine_repo" rev-parse HEAD)"

printf 'hf-start v2\n' > "$engine_repo/engine/hotfix/hf-start.sh"
printf 'new engine prompt\n' > "$engine_repo/engine/prompts/supervisor-cap-triage.md"
git -C "$engine_repo" add -A
git -C "$engine_repo" commit -qm 'engine v2 adds an engine-owned prompt'
engine_v2="$(git -C "$engine_repo" rev-parse HEAD)"
v1_blob="$(git -C "$engine_repo" rev-parse "$engine_v1:engine/hotfix/hf-start.sh")"
v2_blob="$(git -C "$engine_repo" rev-parse "$engine_v2:engine/hotfix/hf-start.sh")"

printf 'hf-start v1\n' > "$engine_repo/engine/hotfix/hf-start.sh"
printf 'hf-other v1\n' > "$engine_repo/engine/hotfix/hf-other.sh"
git -C "$engine_repo" add -A
git -C "$engine_repo" commit -qm 'engine v3 restores the override'
engine_v3="$(git -C "$engine_repo" rev-parse HEAD)"

printf '{"value":"engine-v4"}\n' > "$engine_repo/engine/state/rulings.json"
git -C "$engine_repo" add -A
git -C "$engine_repo" commit -qm 'engine v4 changes the resolved rulings data'
engine_v4="$(git -C "$engine_repo" rev-parse HEAD)"

repo="$tmp/product"
git init -q "$repo"
git -C "$repo" config user.name 'pin preflight fixture'
git -C "$repo" config user.email 'pin-preflight@example.invalid'
mkdir -p "$repo/.zenoforge/build/pack/scripts/agent/state" "$repo/.zenoforge/state" "$repo/docs"
printf '{"hook":".zenoforge/build/engine-sync.sh","engine":"%s"}\n' "$engine_v1" > "$repo/.zenoforge/build.json"
printf 'hotfix/hf-start.sh\t%s\n' "$v1_blob" > "$repo/.zenoforge/build/overrides.tsv"
printf '{"pipeline_suite_roots":[]}\n' > "$repo/.zenoforge/ci.json"
printf '{"value":"product-v1"}\n' > "$repo/.zenoforge/build/pack/scripts/agent/state/rulings.json"
printf '{"value":"direct-v1"}\n' > "$repo/.zenoforge/state/direct.json"
cat > "$repo/.zenoforge/build/engine-sync.sh" <<HOOK
#!/usr/bin/env bash
set -euo pipefail
calls_log="\${PIN_PREFLIGHT_CALLS:?}"
engine_src="$script_dir"
engine_repo="$engine_repo"
case "\${1:-}" in
  --build)
    [[ \$# -eq 5 && \$4 == --out ]] || { echo 'engine-sync: usage' >&2; exit 2; }
    printf 'build %s %s\\n' "\$2" "\$3" >> "\$calls_log"
    actual=\$(git -C "\$engine_repo" rev-parse --verify -q "\$2:engine/hotfix/hf-start.sh" || true)
    expected=\$(awk -F'\\t' -v path='hotfix/hf-start.sh' '\$1 == path {print \$2}' "\$(dirname -- "\$0")/overrides.tsv")
    if [[ -z "\$expected" || "\$expected" != "\$actual" ]]; then
      echo 'override changed: hotfix/hf-start.sh; adopt the engine version, re-override, or add a seam, then update the row' >&2
      echo 'engine-sync: override guard failed' >&2
      exit 1
    fi
    id="\${2:0:12}-fixture"
    version="\$5/\$id"
    mkdir -p "\$version/engine"
    cp "\$engine_src/config.sh" "\$engine_src/engine-sync.sh" "\$version/engine/"
    cp -a "\$engine_src/publish-preflight" "\$version/engine/"
    git -C "\$engine_repo" archive "\$2" engine | tar -x -C "\$version"
    printf 'id=%s\\nzenoforge_sha=%s\\nproduct_sha=%s\\n' "\$id" "\$2" "\$3" > "\$version/BUILD-INFO"
    printf 'scripts/agent/state/rulings.json\\tstate/rulings.json\\tPACK\\tnew\\n' > "\$version/PACK-FILES"
    if [[ -n "\${PIN_PREFLIGHT_SAVE_BUILT:-}" ]]; then cp -a "\$version" "\$PIN_PREFLIGHT_SAVE_BUILT"; fi
    echo "engine-sync: built \$version"
    ;;
  --check)
    printf 'check %s\\n' "\$2" >> "\$calls_log"
    [[ -f "\$2/BUILD-INFO" && -d "\$2/engine" ]] || { echo "engine-sync: check FAILED for \$2" >&2; exit 1; }
    echo "engine-sync: check OK \$2"
    ;;
  *) echo 'engine-sync: usage' >&2; exit 2 ;;
esac
HOOK
chmod +x "$repo/.zenoforge/build/engine-sync.sh"
printf 'docs\n' > "$repo/docs/readme.md"
git -C "$repo" add -A
git -C "$repo" commit -qm 'fixture: product pins engine v1'
base="$(git -C "$repo" rev-parse HEAD)"

agent="$tmp/agent"
export AGENT_HOME="$agent"
mkdir -p "$agent/engine-versions"

make_version() { # <version dir> <engine SHA> <product SHA>
  local dir="$1" pin="$2" product="$3"
  mkdir -p "$dir/engine"
  cp "$script_dir/config.sh" "$script_dir/engine-sync.sh" "$dir/engine/"
  cp -a "$script_dir/publish-preflight" "$dir/engine/"
  git -C "$engine_repo" archive "$pin" engine | tar -x -C "$dir"
  printf 'zenoforge_sha=%s\nproduct_sha=%s\n' "$pin" "$product" > "$dir/BUILD-INFO"
  printf 'scripts/agent/state/rulings.json\tstate/rulings.json\tPACK\tnew\n' > "$dir/PACK-FILES"
}

set_live() { # <engine SHA> <product SHA>
  rm -rf -- "$agent/engine-versions/live"
  make_version "$agent/engine-versions/live" "$1" "$2"
  ln -sfn "$agent/engine-versions/live/engine" "$agent/engine-live"
}

out="$tmp/out"
orig_cwd="$PWD"
run_preflight() { # <base> <head> <calls-log>; output to $out
  local base_sha="$1" head_sha="$2" calls_log="$3" status=0
  export PIN_PREFLIGHT_CALLS="$calls_log"
  land_pin_preflight_verified_key=""
  cd -- "$repo"
  repo_root="$repo"
  if land_engine_pin_preflight "$base_sha" "$head_sha" >"$out" 2>&1; then :; else
    status=$?
  fi
  cd -- "$orig_cwd"
  return "$status"
}

# The prior pin gate still refuses an engine whose changed pack file is not re-overridden.
set_live "$engine_v1" "$base"
git -C "$repo" checkout -q -b bump-to-changed-override "$base"
printf '{"hook":".zenoforge/build/engine-sync.sh","engine":"%s"}\n' "$engine_v2" > "$repo/.zenoforge/build.json"
git -C "$repo" commit -qam 'fixture: bump pin to engine v2 without re-override'
head="$(git -C "$repo" rev-parse HEAD)"
status=0
run_preflight "$base" "$head" "$tmp/calls-override.log" || status=$?
[[ "$status" -eq 1 ]] || fail "pin bump onto a changed override was not refused (exit $status): $(tail -5 "$out")"
grep -Fq 'override changed: hotfix/hf-start.sh; adopt the engine version, re-override, or add a seam, then update the row' "$out" \
  || fail 'refusal is missing the hook guard line'
grep -Fq 'engine-sync: override guard failed' "$out" || fail 'refusal is missing the guard-failed line'
grep -Fq 'refusing push' "$out" || fail 'refusal lacks the refusing-push line'

# A removed pin remains fail-closed.
git -C "$repo" checkout -q -b removed-pin "$base"
git -C "$repo" rm -q .zenoforge/build.json
git -C "$repo" commit -qm 'fixture: remove the engine pin file'
head="$(git -C "$repo" rev-parse HEAD)"
status=0
run_preflight "$base" "$head" "$tmp/calls-removed.log" || status=$?
[[ "$status" -eq 1 ]] || fail "removed pin file was not refused (exit $status): $(tail -5 "$out")"
grep -Fq 'refusing push' "$out" || fail 'removed-pin refusal lacks the refusing-push line'
grep -Fq 'next step: restore a valid build.json' "$out" || fail 'removed-pin refusal lacks a recovery step'

# A newly added engine-owned file missing from the intended list is refused before push.
git -C "$repo" checkout -q -b bump-v2-unlisted "$base"
printf '{"hook":".zenoforge/build/engine-sync.sh","engine":"%s"}\n' "$engine_v2" > "$repo/.zenoforge/build.json"
printf 'hotfix/hf-start.sh\t%s\n' "$v2_blob" > "$repo/.zenoforge/build/overrides.tsv"
git -C "$repo" add -A
git -C "$repo" commit -qm 'fixture: pin bump adds an engine-owned prompt'
head="$(git -C "$repo" rev-parse HEAD)"
set_live "$engine_v1" "$base"
status=0
run_preflight "$base" "$head" "$tmp/calls-unlisted.log" || status=$?
[[ "$status" -eq 1 ]] || fail "unlisted engine-owned file was not refused (exit $status): $(tail -8 "$out")"
grep -Fq 'resolved-config-check: CHANGED prompts/supervisor-cap-triage.md' "$out" \
  || fail 'publish preflight did not name the missing intended engine-owned prompt'
grep -Fq 'publish-preflight: resolved-config check failed' "$out" \
  || fail 'publish preflight did not report the resolved-config failure'
grep -Fq 'next step: declare each engine-owned change in .zenoforge/build/intended-changes.tsv with a reason and matching engine SHA' "$out" \
  || fail 'pre-land refusal lacks the intended-changes next step'

# The same pin bump passes only when its intended row carries the new engine SHA.
git -C "$repo" checkout -q -b bump-v2-matching "$base"
printf '{"hook":".zenoforge/build/engine-sync.sh","engine":"%s"}\n' "$engine_v2" > "$repo/.zenoforge/build.json"
printf 'hotfix/hf-start.sh\t%s\n' "$v2_blob" > "$repo/.zenoforge/build/overrides.tsv"
mkdir -p "$repo/.zenoforge/build"
printf '# engine-relative path<TAB>reason<TAB>zenoforge SHA\nprompts/supervisor-cap-triage.md\tnew engine prompt\t%s\n' "${engine_v2:0:7}" \
  > "$repo/.zenoforge/build/intended-changes.tsv"
git -C "$repo" add -A
git -C "$repo" commit -qm 'fixture: pin bump declares the engine prompt for this SHA'
head="$(git -C "$repo" rev-parse HEAD)"
set_live "$engine_v1" "$base"
status=0
run_preflight "$base" "$head" "$tmp/calls-matching.log" || status=$?
[[ "$status" -eq 0 ]] || fail "matching-SHA intended change was refused (exit $status): $(tail -8 "$out")"
grep -Fq 'resolved-config-check: changed as intended prompts/supervisor-cap-triage.md' "$out" \
  || fail 'matching-SHA row did not approve the engine-owned prompt'
matching_publish_ms="$(sed -n 's/.*land-direct-main: publish preflight passed pin=.* duration_ms=\([0-9][0-9]*\)$/\1/p' "$out" | tail -1)"
[[ "$matching_publish_ms" =~ ^[0-9]+$ ]] || fail 'landing output did not record the added publish-preflight time'
[[ "$(grep -c '^build ' "$tmp/calls-matching.log")" -eq 1 ]] || fail 'matching pin bump did not run exactly one build'
[[ "$(grep -c '^check ' "$tmp/calls-matching.log")" -eq 1 ]] || fail 'matching pin bump did not run exactly one check'
# An unchanged push retry reuses the verified range.
cd -- "$repo"
repo_root="$repo"
land_engine_pin_preflight "$base" "$head" >"$out" 2>&1 || fail 'memoized re-run of the same range failed'
cd -- "$orig_cwd"
[[ "$(grep -c '^build ' "$tmp/calls-matching.log")" -eq 1 ]] || fail 'memoized re-run rebuilt the engine'

# A stale SHA and a legacy two-column row are both ignored and warned.
git -C "$repo" checkout -q -b bump-v2-stale "$base"
printf '{"hook":".zenoforge/build/engine-sync.sh","engine":"%s"}\n' "$engine_v2" > "$repo/.zenoforge/build.json"
printf 'hotfix/hf-start.sh\t%s\n' "$v2_blob" > "$repo/.zenoforge/build/overrides.tsv"
printf 'prompts/supervisor-cap-triage.md\told engine approval\t%s\n' "$engine_v1" > "$repo/.zenoforge/build/intended-changes.tsv"
git -C "$repo" add -A && git -C "$repo" commit -qm 'fixture: use stale engine SHA'
head="$(git -C "$repo" rev-parse HEAD)"
set_live "$engine_v1" "$base"
status=0
run_preflight "$base" "$head" "$tmp/calls-stale.log" || status=$?
[[ "$status" -eq 1 ]] || fail "stale-SHA intended row was not refused (exit $status): $(tail -8 "$out")"
grep -Fq "intended-changes: ignoring stale row prompts/supervisor-cap-triage.md (sha $engine_v1, new engine $engine_v2)" "$out" \
  || fail 'stale-SHA row warning is missing from the pre-land check'
grep -Fq 'resolved-config-check: CHANGED prompts/supervisor-cap-triage.md' "$out" \
  || fail 'stale-SHA row approved the engine-owned prompt'

git -C "$repo" checkout -q -b bump-v2-legacy "$base"
printf '{"hook":".zenoforge/build/engine-sync.sh","engine":"%s"}\n' "$engine_v2" > "$repo/.zenoforge/build.json"
printf 'hotfix/hf-start.sh\t%s\n' "$v2_blob" > "$repo/.zenoforge/build/overrides.tsv"
printf 'prompts/supervisor-cap-triage.md\tlegacy approval without SHA\n' > "$repo/.zenoforge/build/intended-changes.tsv"
git -C "$repo" add -A && git -C "$repo" commit -qm 'fixture: use a legacy intended row'
head="$(git -C "$repo" rev-parse HEAD)"
set_live "$engine_v1" "$base"
status=0
run_preflight "$base" "$head" "$tmp/calls-legacy.log" || status=$?
[[ "$status" -eq 1 ]] || fail "legacy intended row was not refused (exit $status): $(tail -8 "$out")"
grep -Fq "intended-changes: ignoring stale row prompts/supervisor-cap-triage.md (sha missing, new engine $engine_v2)" "$out" \
  || fail 'legacy two-column warning is missing from the pre-land check'
grep -Fq 'resolved-config-check: CHANGED prompts/supervisor-cap-triage.md' "$out" \
  || fail 'legacy intended row approved the engine-owned prompt'

# Non-pin ranges skip the engine build and publish gates.
git -C "$repo" checkout -q -b docs-only "$base"
printf 'note\n' > "$repo/docs/note.md"
git -C "$repo" add docs/note.md
git -C "$repo" commit -qm 'fixture: docs only'
head="$(git -C "$repo" rev-parse HEAD)"
status=0
run_preflight "$base" "$head" "$tmp/calls-docs.log" || status=$?
[[ "$status" -eq 0 ]] || fail "docs-only range was refused (exit $status): $(tail -5 "$out")"
[[ ! -e "$tmp/calls-docs.log" ]] || fail 'build hook ran for a range that touches neither the pin nor the overrides'

# A vendored pack change moves the live engine's resolved config, so the gates run for it too.
git -C "$repo" checkout -q -b pack-only "$base"
printf '{"value":"product-v2"}\n' > "$repo/.zenoforge/build/pack/scripts/agent/state/rulings.json"
git -C "$repo" add .zenoforge/build/pack/scripts/agent/state/rulings.json
git -C "$repo" commit -qm 'fixture: vendored rulings only'
head="$(git -C "$repo" rev-parse HEAD)"
status=0
run_preflight "$base" "$head" "$tmp/calls-pack.log" || status=$?
[[ -s "$tmp/calls-pack.log" ]] || fail 'a vendored pack change skipped the engine gates'

# Set up a live v3 engine and product ref so the next pin bump only changes rulings data.
git -C "$repo" checkout -q -b product-base-v3 "$base"
printf '{"hook":".zenoforge/build/engine-sync.sh","engine":"%s"}\n' "$engine_v3" > "$repo/.zenoforge/build.json"
printf 'hotfix/hf-start.sh\t%s\n' "$v1_blob" > "$repo/.zenoforge/build/overrides.tsv"
git -C "$repo" add -A && git -C "$repo" commit -qm 'fixture: product pin v3'
base_v3="$(git -C "$repo" rev-parse HEAD)"
set_live "$engine_v3" "$base_v3"

# A vendored product edit whose committed bytes equal the new resolved bytes is product-owned.
git -C "$repo" checkout -q -b product-owned-rulings "$base_v3"
printf '{"hook":".zenoforge/build/engine-sync.sh","engine":"%s"}\n' "$engine_v4" > "$repo/.zenoforge/build.json"
printf '{"value":"engine-v4"}\n' > "$repo/.zenoforge/build/pack/scripts/agent/state/rulings.json"
printf '{"value":"direct-v2"}\n' > "$repo/.zenoforge/state/direct.json"
git -C "$repo" add -A && git -C "$repo" commit -qm 'fixture: product updates vendored rulings with the pin'
head="$(git -C "$repo" rev-parse HEAD)"
status=0
run_preflight "$base_v3" "$head" "$tmp/calls-product-owned.log" || status=$?
[[ "$status" -eq 0 ]] || fail "product-owned vendored data change was refused (exit $status): $(tail -8 "$out")"
grep -Fq "resolved-config-check: product-owned change state/rulings.json (product ${base_v3:0:8}..${head:0:8})" "$out" \
  || fail 'preflight did not report the product-owned vendored rulings change'
grep -Fq "resolved-config-check: product-owned change state/direct.json (product ${base_v3:0:8}..${head:0:8})" "$out" \
  || fail 'preflight did not report the product-owned direct config change'

# The same path changing on the engine side still blocks unless approved for the new engine SHA.
git -C "$repo" checkout -q -b engine-rulings-unlisted "$base_v3"
printf '{"hook":".zenoforge/build/engine-sync.sh","engine":"%s"}\n' "$engine_v4" > "$repo/.zenoforge/build.json"
git -C "$repo" add -A && git -C "$repo" commit -qm 'fixture: pin engine rulings change without product data edit'
head="$(git -C "$repo" rev-parse HEAD)"
set_live "$engine_v3" "$base_v3"
status=0
run_preflight "$base_v3" "$head" "$tmp/calls-engine-rulings.log" || status=$?
[[ "$status" -eq 1 ]] || fail "unlisted engine-side rulings change was not refused (exit $status): $(tail -8 "$out")"
grep -Fq 'resolved-config-check: CHANGED state/rulings.json' "$out" \
  || fail 'engine-side rulings change was not identified as changed'

git -C "$repo" checkout -q -b engine-rulings-matching "$base_v3"
printf '{"hook":".zenoforge/build/engine-sync.sh","engine":"%s"}\n' "$engine_v4" > "$repo/.zenoforge/build.json"
printf 'state/rulings.json\tengine reroutes rulings data\t%s\n' "$engine_v4" > "$repo/.zenoforge/build/intended-changes.tsv"
git -C "$repo" add -A && git -C "$repo" commit -qm 'fixture: approve engine rulings change for v4'
head="$(git -C "$repo" rev-parse HEAD)"
set_live "$engine_v3" "$base_v3"
status=0
run_preflight "$base_v3" "$head" "$tmp/calls-engine-rulings-matching.log" || status=$?
[[ "$status" -eq 0 ]] || fail "matching-SHA engine-side rulings row was refused (exit $status): $(tail -8 "$out")"
grep -Fq 'resolved-config-check: changed as intended state/rulings.json' "$out" \
  || fail 'matching-SHA row did not approve the engine-side rulings change'

# Both intended-change readers enforce the SHA. A matching row allows a dropped reference;
# stale and legacy rows warn and leave the reference blocking.
drop_base="$tmp/drop-base"
drop_new="$tmp/drop-new"
mkdir -p "$drop_base/engine/mac-autopilot" "$drop_new/engine/mac-autopilot"
printf 'echo watch\n' > "$drop_base/engine/mac-autopilot/zombie-watch.sh"
printf '#!/usr/bin/env bash\nbash "$(dirname "$0")/zombie-watch.sh"\n' > "$drop_base/engine/mac-autopilot/zombie-loop.sh"
cp "$drop_base/engine/mac-autopilot/zombie-loop.sh" "$drop_new/engine/mac-autopilot/zombie-loop.sh"
printf 'zenoforge_sha=%s\n' "$engine_v4" > "$drop_new/BUILD-INFO"
run_drop() { python3 -I "$script_dir/publish-preflight/dropped-file-refs-check.py" "$drop_base" "$drop_new" "$@"; }
printf 'mac-autopilot/zombie-watch.sh\tretire with v4\t%s\n' "$engine_v4" > "$tmp/drop-matching.tsv"
run_drop "$tmp/drop-matching.tsv" >"$out" 2>&1 || fail "matching-SHA dropped-file row was refused: $(tail -5 "$out")"
printf 'mac-autopilot/zombie-watch.sh\tstale retirement\t%s\n' "$engine_v3" > "$tmp/drop-stale.tsv"
status=0; run_drop "$tmp/drop-stale.tsv" >"$out" 2>&1 || status=$?
[[ "$status" -eq 1 ]] || fail "stale-SHA dropped-file row did not block (exit $status)"
grep -Fq "intended-changes: ignoring stale row mac-autopilot/zombie-watch.sh (sha $engine_v3, new engine $engine_v4)" "$out" \
  || fail 'dropped-file checker did not warn for a stale SHA'
printf 'mac-autopilot/zombie-watch.sh\tlegacy retirement\n' > "$tmp/drop-legacy.tsv"
status=0; run_drop "$tmp/drop-legacy.tsv" >"$out" 2>&1 || status=$?
[[ "$status" -eq 1 ]] || fail "legacy dropped-file row did not block (exit $status)"
grep -Fq "intended-changes: ignoring stale row mac-autopilot/zombie-watch.sh (sha missing, new engine $engine_v4)" "$out" \
  || fail 'dropped-file checker did not warn for a legacy row'

# Structural guard: add a gate to the one manifest and prove both the landing check and the
# converger's built-engine preflight run it. The landing does not carry a second local gate list.
git -C "$repo" checkout -q -b shared-gate-list "$base_v3"
printf '{"hook":".zenoforge/build/engine-sync.sh","engine":"%s"}\n' "$engine_v4" > "$repo/.zenoforge/build.json"
printf 'state/rulings.json\tengine reroutes rulings data\t%s\n' "$engine_v4" > "$repo/.zenoforge/build/intended-changes.tsv"
git -C "$repo" add -A && git -C "$repo" commit -qm 'fixture: pin v4 for shared gate list'
head="$(git -C "$repo" rev-parse HEAD)"
set_live "$engine_v3" "$base_v3"
printf 'unit-paths\n' >> "$gates_file"
export PIN_PREFLIGHT_SAVE_BUILT="$tmp/gate-version"
status=0
run_preflight "$base_v3" "$head" "$tmp/calls-shared-gates.log" || status=$?
[[ "$status" -eq 0 ]] || fail "landing did not execute the shared gate list (exit $status): $(tail -8 "$out")"
[[ "$(grep -c '^publish-preflight: checking unit paths$' "$out")" -eq 2 ]] \
  || fail 'landing pin preflight missed a gate added to the shared manifest'
converge_out="$tmp/converge-preflight.out"
AGENT_HOME="$agent" ZF_REPO_DIR="$repo" VECTA_REPO_DIR="$repo" ZF_PREFLIGHT_LIVE_REF="$head" \
  bash "$tmp/gate-version/engine/engine-sync.sh" --preflight "$tmp/gate-version" "$repo/.zenoforge/build/intended-changes.tsv" \
  >"$converge_out" 2>&1 || fail "converge preflight failed with the shared gate list: $(tail -8 "$converge_out")"
[[ "$(grep -c '^publish-preflight: checking unit paths$' "$converge_out")" -eq 2 ]] \
  || fail 'converge preflight missed a gate added to the shared manifest'
unset PIN_PREFLIGHT_SAVE_BUILT

echo "land-pin-preflight.test.sh: pin, publish, intended-change, and shared-gate guards PASS (publish preflight fixture ${matching_publish_ms} ms)"
