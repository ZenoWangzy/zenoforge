#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
trap 'rm -rf -- "$test_env_root"' EXIT

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
check() { [[ "$2" == "$3" ]] || fail "$1: got '$2', want '$3'"; printf 'ok - %s\n' "$1"; }

root="$test_env_root/layers"
engine="$root/engine" pack="$root/pack" target="$root/target"
mkdir -p "$engine" "$pack" "$target/sub"
for f in all.json pack-eng.json engine-only.json; do printf engine > "$engine/$f"; done
for f in all.json pack-eng.json pack-only.json; do printf pack > "$pack/$f"; done
printf target > "$target/all.json"
printf target > "$target/sub/new.json"
# dump [VAR=value...] [path]: run the command under the three-layer fixture; leading VAR=value words extend the environment.
dump() {
  local vars=()
  while [[ ${1-} == *=* ]]; do vars+=("$1"); shift; done
  env ZF_ENGINE_DIR="$engine" ZF_PACK_DIR="$pack" ZF_CONFIG_ROOT="$target" ${vars[@]+"${vars[@]}"} \
    bash "$SCRIPT_DIR/config-dump.sh" "$@"
}
files_of() { sed '/^$/q' | sed '$d'; }

check 'target beats pack and engine, pack beats engine, engine-only and pack-only are hidden' \
  "$(dump | files_of)" \
  "$(printf 'all.json\ttarget\tpack,engine\npack-eng.json\tpack\tengine\nsub/new.json\ttarget\t-')"
check 'a missing pack dir still works' \
  "$(dump ZF_PACK_DIR="$root/missing" | files_of)" \
  "$(printf 'all.json\ttarget\tengine\nsub/new.json\ttarget\t-')"

check 'single path: target wins' "$(dump all.json)" \
  "$(printf 'target\t%s\twinner\npack\t%s\t\nengine\t%s\t' "$target/all.json" "$pack/all.json" "$engine/all.json")"
check 'single path: pack wins' "$(dump pack-eng.json)" \
  "$(printf 'target\t-\t\npack\t%s\twinner\nengine\t%s\t' "$pack/pack-eng.json" "$engine/pack-eng.json")"
check 'single path: engine only' "$(dump engine-only.json)" \
  "$(printf 'target\t-\t\npack\t-\t\nengine\t%s\twinner' "$engine/engine-only.json")"

for bad in ../x.json a/../x.json "$engine/all.json"; do
  if dump "$bad" >/dev/null 2>&1; then fail "unsafe path accepted: $bad"; fi
done
echo 'ok - dot-dot and absolute paths are refused'

printf '{"env_prefix":"DEP_"}' > "$target/config.json"
env_part="$(dump DEP_COLOR=blue ZF_COLOR=red ZF_ONLY=zf DEP_API_TOKEN=hunter2 ZF_DB_PASSWORD=pw9 | sed '1,/^$/d')"
check 'prefix variable beats ZF_ and says so' "$(grep '^COLOR' <<<"$env_part")" "$(printf 'COLOR\tprefix\tblue\tshadows ZF_COLOR')"
check 'ZF-only variable' "$(grep '^ONLY' <<<"$env_part")" "$(printf 'ONLY\tZF\tzf')"
check 'secret-looking values are masked' "$(grep -E '^(API_TOKEN|DB_PASSWORD)' <<<"$env_part")" \
  "$(printf 'API_TOKEN\tprefix\t<set>\nDB_PASSWORD\tZF\t<set>')"
if grep -q -e hunter2 -e pw9 <<<"$env_part"; then fail 'secret value leaked'; fi

before="$(find "$root" "$AGENT_HOME" -type f 2>/dev/null | sort | xargs cat | cksum)"
dump >/dev/null
check 'writes no file' "$(find "$root" "$AGENT_HOME" -type f 2>/dev/null | sort | xargs cat | cksum)" "$before"
echo 'PASS config-dump'
