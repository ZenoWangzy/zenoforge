#!/usr/bin/env bash
# config.sh resolves the engine and target directories; every default must equal the derivation it replaced
# (lib.sh: REPO_DIR from its own location; the AGENT_HOME chain).
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
trap 'rm -rf -- "$test_env_root"' EXIT
fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
check() { [[ "$2" == "$3" ]] || fail "$1: got '$2', want '$3'"; printf 'ok - %s\n' "$1"; }

# resolve <dir holding config.sh> [env args...] -> "engine|repo|agent home" as a script that sources it sees them
resolve() {
  local dir="$1"; shift
  env "$@" bash -c 'source "$1/config.sh"; printf "%s|%s|%s\n" "$ZF_ENGINE_DIR" "$ZF_REPO_DIR" "$AGENT_HOME"' _ "$dir"
}

target="$test_env_root/target"; other="$test_env_root/other"
for r in "$target" "$other"; do mkdir -p "$r/engine"; cp "$SCRIPT_DIR/config.sh" "$r/engine/"; done
target="$(cd -- "$target" && pwd -P)"; other="$(cd -- "$other" && pwd -P)"
unset_all=(-u ZF_ENGINE_DIR -u ZF_REPO_DIR -u ZF_HOME -u AGENT_HOME)

check "engine inside the target: both default to the file's location, home to ~/.zenoforge" \
  "$(resolve "$target/engine" "${unset_all[@]}")" "$target/engine|$target|$HOME/.zenoforge"
check "same repo directory lib.sh derived before config.sh" \
  "$(resolve "$SCRIPT_DIR" "${unset_all[@]}" | cut -d'|' -f2)" "$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
check "an exported ZF_REPO_DIR wins" \
  "$(resolve "$target/engine" "${unset_all[@]}" ZF_REPO_DIR=/elsewhere)" "$target/engine|/elsewhere|$HOME/.zenoforge"
check "split layout: exported engine and target directories both win" \
  "$(resolve "$target/engine" "${unset_all[@]}" ZF_ENGINE_DIR=/engine ZF_REPO_DIR=/target)" "/engine|/target|$HOME/.zenoforge"
check "AGENT_HOME beats ZF_HOME" \
  "$(resolve "$target/engine" "${unset_all[@]}" AGENT_HOME=/a ZF_HOME=/b | cut -d'|' -f3)" "/a"
check "ZF_HOME beats the default" \
  "$(resolve "$target/engine" "${unset_all[@]}" ZF_HOME=/b | cut -d'|' -f3)" "/b"

lookup_env() {
  local dir="$1"; shift
  env -i HOME="$HOME" PATH="$PATH" "$@" bash -c \
    'source "$1/config.sh"; if value="$(zf_env_get SAMPLE)"; then printf "set:%s" "$value"; else printf unset; fi' \
    _ "$dir"
}
mkdir -p "$target/.zenoforge"
check "env lookup without config uses the public spelling" \
  "$(lookup_env "$other/engine" ZF_SAMPLE=public)" "set:public"
check "env lookup with no config has no deployment alias" \
  "$(lookup_env "$other/engine")" "unset"
check "no config uses the supplied engine default" \
  "$(env -i HOME="$HOME" PATH="$PATH" bash -c \
    'source "$1/config.sh"; zf_env_get SAMPLE engine-default' _ "$other/engine")" "engine-default"
printf '%s\n' '{"env_prefix":"DEPLOY_"}' > "$target/.zenoforge/config.json"
check "configured prefix wins over the public spelling" \
  "$(lookup_env "$target/engine" DEPLOY_SAMPLE=deployment ZF_SAMPLE=public)" "set:deployment"
check "configured prefix falls back to the public spelling" \
  "$(lookup_env "$target/engine" ZF_SAMPLE=public)" "set:public"
check "a configured empty value stays empty" \
  "$(lookup_env "$target/engine" DEPLOY_SAMPLE= ZF_SAMPLE=public)" "set:"
check "the configured repo key resolves before the engine default" \
  "$(env -i HOME="$HOME" PATH="$PATH" DEPLOY_REPO_DIR="$test_env_root/deployed" bash -c \
    'source "$1/config.sh"; printf "%s" "$ZF_REPO_DIR"' _ "$target/engine")" \
  "$test_env_root/deployed"

# A script that loads another checkout's lib.sh must get that checkout's directories, not the first one's.
check "sourcing a second checkout's config.sh re-derives" \
  "$(env "${unset_all[@]}" bash -c 'source "$1/config.sh"; source "$2/config.sh"; printf "%s|%s" "$ZF_ENGINE_DIR" "$ZF_REPO_DIR"' _ "$target/engine" "$other/engine")" \
  "$other/engine|$other"

# The logical path of a symlinked engine is kept, and its parent is the link's parent (lib.sh's old cd .. behaviour).
linked="$test_env_root/linked"; mkdir -p "$linked/scripts"; ln -s "$target/engine" "$linked/engine"
linked="$(cd -- "$linked" && pwd -P)"
check "symlinked engine: logical engine path, link parent as target" \
  "$(resolve "$linked/engine" "${unset_all[@]}")" "$linked/engine|$linked|$HOME/.zenoforge"

# Sourcing resolves paths only: no git, gh or network call.
mkdir -p "$test_env_root/shims"
for tool in git gh; do printf '#!/usr/bin/env bash\ntouch "%s/called-%s"\nexit 99\n' "$test_env_root" "$tool" > "$test_env_root/shims/$tool"; chmod +x "$test_env_root/shims/$tool"; done
resolve "$target/engine" "${unset_all[@]}" PATH="$test_env_root/shims:$PATH" >/dev/null
check "sourcing runs no git or gh" "$(find "$test_env_root" -maxdepth 1 -name 'called-*' | wc -l | tr -d ' ')" "0"
# Deployment identity settings: each default is the literal it replaced; a variable the caller sets wins, even when empty.
setting() { env "${unset_all[@]}" -u "$1" "${@:2}" bash -c 'source "$1/config.sh"; printf "%s" "${!2}"' _ "$target/engine" "$1"; }
check "CI host defaults to cihost" "$(setting ZF_CIHOST_HOST)" "cihost"
check "acceptance user defaults to 验收用户" "$(setting ZF_ACCEPTANCE_USER)" "验收用户"
check "an exported value wins" "$(setting ZF_INFRA_REPO ZF_INFRA_REPO=o/r)" "o/r"
check "an empty host sync path list stays empty" "$(setting ZF_CIHOST_SYNC_PATHS ZF_CIHOST_SYNC_PATHS=)" ""
check "host sync roots default to the lib, systemd and ops sources" "$(setting ZF_CIHOST_SYNC_ROOTS | cut -d' ' -f1-3)" "engine/lib.sh engine/closing-keywords.sh engine/systemd"
check "prefixed identity is exported under the public shell name" \
  "$(setting ZF_AGENT_GIT_USER_NAME DEPLOY_AGENT_GIT_USER_NAME=deployment)" "deployment"
check "prefixed identity wins over the public spelling" \
  "$(setting ZF_AGENT_GIT_USER_NAME DEPLOY_AGENT_GIT_USER_NAME=deployment ZF_AGENT_GIT_USER_NAME=public)" "deployment"
check "an empty prefixed identity stays empty" \
  "$(setting ZF_AGENT_GIT_USER_NAME DEPLOY_AGENT_GIT_USER_NAME= ZF_AGENT_GIT_USER_NAME=public)" ""
echo "config.test.sh: PASS"
