#!/usr/bin/env bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
land_script="$script_dir/land-direct-main.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/land-pin-preflight-test.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

fail() { printf 'land-pin-preflight.test.sh: %s\n' "$*" >&2; exit 1; }

# The preflight under test is the lander function itself, extracted like syntax-only-landing.test.sh
# extracts its function: the full land-direct-main.sh entry cannot run inside a suite fixture.
function_file="$tmp/land-pin-preflight.sh"
sed -n '/^land_engine_pin_preflight() {/,/^}$/p' "$land_script" > "$function_file"
[[ -s "$function_file" ]] || fail 'could not extract land_engine_pin_preflight from land-direct-main.sh'
# shellcheck source=/dev/null
source "$function_file"
land_pin_preflight_verified_key=""
# Exercise the focused function without taking the suite's real resource slot.
with_preflight_slot() { "$@"; }

# Engine fixture: the file the product overrides (hotfix/hf-start.sh) changes between v1 and v2
# and is back to the v1 content at v3, so only the v2 pin trips the override guard.
engine_repo="$tmp/engine"
git init -q "$engine_repo"
git -C "$engine_repo" config user.name 'pin preflight fixture'
git -C "$engine_repo" config user.email 'pin-preflight@example.invalid'
mkdir -p "$engine_repo/engine/hotfix"
printf 'hf-start v1\n' > "$engine_repo/engine/hotfix/hf-start.sh"
git -C "$engine_repo" add -A
git -C "$engine_repo" commit -qm 'engine v1'
engine_v1="$(git -C "$engine_repo" rev-parse HEAD)"
printf 'hf-start v2\n' > "$engine_repo/engine/hotfix/hf-start.sh"
git -C "$engine_repo" commit -qam 'engine v2 changes the overridden file'
engine_v2="$(git -C "$engine_repo" rev-parse HEAD)"
printf 'hf-start v1\n' > "$engine_repo/engine/hotfix/hf-start.sh"
printf 'hf-other v1\n' > "$engine_repo/engine/hotfix/hf-other.sh"
git -C "$engine_repo" add -A
git -C "$engine_repo" commit -qm 'engine v3 restores the overridden file'
engine_v3="$(git -C "$engine_repo" rev-parse HEAD)"
v1_blob="$(git -C "$engine_repo" rev-parse "$engine_v1:engine/hotfix/hf-start.sh")"
v2_blob="$(git -C "$engine_repo" rev-parse "$engine_v2:engine/hotfix/hf-start.sh")"

# Product fixture: pins engine v1 and overrides hotfix/hf-start.sh. The build hook implements the
# documented engine-sync contract (--build <pin> <product-sha> --out <root>, then --check <version-dir>)
# with the same override guard as the real one: every overrides.tsv row must name the blob the pinned
# engine has, else the guard lines print and the build fails.
repo="$tmp/product"
git init -q "$repo"
git -C "$repo" config user.name 'pin preflight fixture'
git -C "$repo" config user.email 'pin-preflight@example.invalid'
mkdir -p "$repo/.zenoforge/build" "$repo/docs"
printf '{"hook":".zenoforge/build/engine-sync.sh","engine":"%s"}\n' "$engine_v1" > "$repo/.zenoforge/build.json"
printf 'hotfix/hf-start.sh\t%s\n' "$v1_blob" > "$repo/.zenoforge/build/overrides.tsv"
cat > "$repo/.zenoforge/build/engine-sync.sh" <<HOOK
#!/usr/bin/env bash
set -euo pipefail
calls_log="\${PIN_PREFLIGHT_CALLS:?}"
case "\${1:-}" in
  --build)
    [[ \$# -eq 5 && \$4 == --out ]] || { echo 'engine-sync: usage' >&2; exit 2; }
    printf 'build %s %s\n' "\$2" "\$3" >> "\$calls_log"
    actual=\$(git -C "$engine_repo" rev-parse --verify -q "\$2:engine/hotfix/hf-start.sh" || true)
    expected=\$(awk -F'\t' -v path='hotfix/hf-start.sh' '\$1 == path {print \$2}' "\$(dirname -- "\$0")/overrides.tsv")
    if [[ -z "\$expected" || "\$expected" != "\$actual" ]]; then
      echo "override changed: hotfix/hf-start.sh; adopt the engine version, re-override, or add a seam, then update the row" >&2
      echo 'engine-sync: override guard failed' >&2
      exit 1
    fi
    id="\${2:0:12}-fixture"
    mkdir -p "\$5/\$id/engine"
    printf 'id=%s\n' "\$id" > "\$5/\$id/BUILD-INFO"
    printf 'engine-sync: built %s/%s\n' "\$5" "\$id"
    ;;
  --check)
    printf 'check %s\n' "\$2" >> "\$calls_log"
    [[ -f "\$2/BUILD-INFO" && -d "\$2/engine" ]] || { echo "engine-sync: check FAILED for \$2" >&2; exit 1; }
    printf 'engine-sync: check OK %s\n' "\$2"
    ;;
  *) echo 'engine-sync: usage' >&2; exit 2 ;;
esac
HOOK
printf 'docs\n' > "$repo/docs/readme.md"
git -C "$repo" add -A
git -C "$repo" commit -qm 'fixture: product pins engine v1'
base="$(git -C "$repo" rev-parse HEAD)"

out="$tmp/out"
orig_cwd="$PWD"
run_preflight() { # <base> <head> <calls-log>; output to $out, status as return code
  local base="$1" head="$2" status=0
  export PIN_PREFLIGHT_CALLS="$3"
  land_pin_preflight_verified_key=""
  cd -- "$repo"
  repo_root="$repo"
  if land_engine_pin_preflight "$base" "$head" >"$out" 2>&1; then :; else
    status=$?
  fi
  cd -- "$orig_cwd"
  return "$status"
}

# 1. A landing range that bumps the pin to an engine whose overridden file changed is refused,
#    with the guard lines and the next step (the 2026-11-03 incident, planted as input).
git -C "$repo" checkout -q -b bump-to-changed-override "$base"
printf '{"hook":".zenoforge/build/engine-sync.sh","engine":"%s"}\n' "$engine_v2" > "$repo/.zenoforge/build.json"
git -C "$repo" commit -qam 'fixture: bump pin to engine v2 (overridden file changed)'
head="$(git -C "$repo" rev-parse HEAD)"
status=0
run_preflight "$base" "$head" "$tmp/calls-bad.log" || status=$?
[[ "$status" -eq 1 ]] || fail "pin bump onto a changed override was not refused (exit $status): $(tail -5 "$out")"
grep -Fq 'override changed: hotfix/hf-start.sh; adopt the engine version, re-override, or add a seam, then update the row' "$out" \
  || fail 'refusal is missing the hook guard line'
grep -Fq 'engine-sync: override guard failed' "$out" || fail 'refusal is missing the guard-failed line'
grep -Fq 'refusing push' "$out" || fail 'refusal lacks the refusing-push line'
grep -Fq 'next step: adopt the engine version, re-override' "$out" || fail 'refusal lacks the next-step line'

# Removing the pin file is also a touched pin range: there is no configured engine contract
# left to build or check, so landing must fail closed instead of allowing the target dispatch to break.
git -C "$repo" checkout -q -b removed-pin "$base"
git -C "$repo" rm -q .zenoforge/build.json
git -C "$repo" commit -qm 'fixture: remove the engine pin file'
head="$(git -C "$repo" rev-parse HEAD)"
status=0
run_preflight "$base" "$head" "$tmp/calls-removed.log" || status=$?
[[ "$status" -eq 1 ]] || fail "removed pin file was not refused (exit $status): $(tail -5 "$out")"
grep -Fq 'refusing push' "$out" || fail 'removed-pin refusal lacks the refusing-push line'
grep -Fq 'next step: restore a valid build.json' "$out" || fail 'removed-pin refusal lacks a recovery step'

# 2. A landing range whose pin builds and checks lands (the overridden file is unchanged at v3).
git -C "$repo" checkout -q -b bump-clean "$base"
printf '{"hook":".zenoforge/build/engine-sync.sh","engine":"%s"}\n' "$engine_v3" > "$repo/.zenoforge/build.json"
git -C "$repo" commit -qam 'fixture: bump pin to engine v3 (overridden file unchanged)'
head="$(git -C "$repo" rev-parse HEAD)"
status=0
run_preflight "$base" "$head" "$tmp/calls-good.log" || status=$?
[[ "$status" -eq 0 ]] || fail "clean pin bump was refused (exit $status): $(tail -5 "$out")"
grep -Fq 'engine pin preflight passed' "$out" || fail 'passing run lacks the preflight-passed line'
[[ "$(grep -c '^build ' "$tmp/calls-good.log")" -eq 1 ]] || fail 'clean pin bump did not run exactly one build'
[[ "$(grep -c '^check ' "$tmp/calls-good.log")" -eq 1 ]] || fail 'clean pin bump did not run exactly one check'
# A retried landing with the same base+head reuses the verification instead of rebuilding.
cd -- "$repo"
repo_root="$repo"
land_engine_pin_preflight "$base" "$head" >"$out" 2>&1 || fail 'memoized re-run of the same range failed'
cd -- "$orig_cwd"
[[ "$(grep -c '^build ' "$tmp/calls-good.log")" -eq 1 ]] || fail 'memoized re-run rebuilt the engine'

# 3. A landing range that does not touch the pin or overrides does not run the build.
git -C "$repo" checkout -q -b docs-only "$base"
printf 'note\n' > "$repo/docs/note.md"
git -C "$repo" add docs/note.md
git -C "$repo" commit -qm 'fixture: docs only'
head="$(git -C "$repo" rev-parse HEAD)"
status=0
run_preflight "$base" "$head" "$tmp/calls-docs.log" || status=$?
[[ "$status" -eq 0 ]] || fail "docs-only range was refused (exit $status): $(tail -5 "$out")"
[[ ! -e "$tmp/calls-docs.log" ]] || fail 'build hook ran for a range that touches neither the pin nor the overrides'

# 4. An override-table change alone also runs the guard: a stale row is refused, the incident's
#    manual fix shape (pin bump plus matching re-override) lands.
git -C "$repo" checkout -q -b stale-row "$base"
printf 'hotfix/hf-start.sh\t%s\n' "$v2_blob" > "$repo/.zenoforge/build/overrides.tsv"
git -C "$repo" commit -qam 'fixture: re-override row without the pin bump'
head="$(git -C "$repo" rev-parse HEAD)"
status=0
run_preflight "$base" "$head" "$tmp/calls-stale.log" || status=$?
[[ "$status" -eq 1 ]] || fail "stale overrides row was not refused (exit $status): $(tail -5 "$out")"
grep -Fq 'engine-sync: override guard failed' "$out" || fail 'stale-row refusal is missing the guard-failed line'

git -C "$repo" checkout -q -b reoverride "$base"
printf '{"hook":".zenoforge/build/engine-sync.sh","engine":"%s"}\n' "$engine_v2" > "$repo/.zenoforge/build.json"
printf 'hotfix/hf-start.sh\t%s\n' "$v2_blob" > "$repo/.zenoforge/build/overrides.tsv"
git -C "$repo" commit -qam 'fixture: pin bump with matching re-override'
head="$(git -C "$repo" rev-parse HEAD)"
status=0
run_preflight "$base" "$head" "$tmp/calls-reoverride.log" || status=$?
[[ "$status" -eq 0 ]] || fail "pin bump with matching re-override was refused (exit $status): $(tail -5 "$out")"

echo 'land-pin-preflight.test.sh: all pin preflight guards PASS'
