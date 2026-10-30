#!/usr/bin/env bash
# config.sh: every default equals the derivation it replaced, the host id is sanitized and persisted once,
# the coordination stubs do nothing, and sourcing runs no git or gh.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

ENGINE_SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home"

eq() { # <name> <want> <got>
  [[ "$2" == "$3" ]] || { printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3" >&2; exit 1; }
  echo "ok - $1"
}

# The derivations config.sh replaced (lib.sh lines 18 and 314 to 316 before S0), verbatim.
cat > "$tmp/old-derive.sh" <<'OLD'
AGENT_HOME="${AGENT_HOME:-${ZF_HOME:-$HOME/.zenoforge}}"
REPO_DIR="${ZF_REPO_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}"
REPO="${ZF_REPO:-$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null | sed -E 's#^(git@[^:]+:|[a-z+]+://([^/@]+@)?[^/]+/)##; s#\.git$##' || true)}"
OLD

# mk_target <dir> [origin-url]: a target repository with the engine files inside it.
mk_target() {
  mkdir -p "$1/engine"
  cp "$ENGINE_SRC/config.sh" "$tmp/old-derive.sh" "$1/engine/"
  git -C "$1" init -q
  if [[ -n "${2:-}" ]]; then git -C "$1" remote add origin "$2"; fi
}

# derive <old|new> <engine-dir> [VAR=value...]: AGENT_HOME|repo dir|repo from a clean environment, under set -euo pipefail.
derive() {
  local mode="$1" dir="$2"; shift 2
  env -i PATH="$PATH" HOME="$tmp/home" "$@" bash -c '
    set -euo pipefail
    if [[ $1 == old ]]; then
      source "$2/old-derive.sh"; printf "%s|%s|%s" "$AGENT_HOME" "$REPO_DIR" "$REPO"
    else
      source "$2/config.sh"; zf_repo_resolve; printf "%s|%s|%s" "$AGENT_HOME" "$ZF_REPO_DIR" "$ZF_REPO"
    fi' _ "$mode" "$dir"
}
same() { # <name> <want> <engine-dir> [VAR=value...]: old and new both produce <want>
  local name="$1" want="$2" dir="$3"; shift 3
  eq "$name (old)" "$want" "$(derive old "$dir" "$@")"
  eq "$name (new)" "$want" "$(derive new "$dir" "$@")"
}

# Layout 1: engine inside the target; the slug comes from the origin remote in every URL form.
mk_target "$tmp/t1" https://github.com/acme/widgets.git
t1="$(cd -- "$tmp/t1" && pwd -P)"
same 'engine inside target, https origin' "$tmp/home/.zenoforge|$t1|acme/widgets" "$tmp/t1/engine"
git -C "$tmp/t1" remote set-url origin git@github.com:acme/widgets.git
same 'scp-style origin' "$tmp/home/.zenoforge|$t1|acme/widgets" "$tmp/t1/engine"
git -C "$tmp/t1" remote set-url origin ssh://git@github.com/acme/widgets
same 'ssh:// origin' "$tmp/home/.zenoforge|$t1|acme/widgets" "$tmp/t1/engine"

# The engine reached through a symlink: the checkout is the link's parent, as lib.sh derived it.
mkdir -p "$tmp/link"
ln -s "$tmp/t1/engine" "$tmp/link/engine"
git -C "$tmp/link" init -q
link="$(cd -- "$tmp/link" && pwd -P)"
same 'symlinked engine directory' "$tmp/home/.zenoforge|$link|" "$tmp/link/engine"

# Layout 2: AGENT_HOME, ZF_HOME, ZF_REPO_DIR and ZF_REPO overrides win in the same order.
mk_target "$tmp/t2" https://github.com/acme/other.git
t2="$(cd -- "$tmp/t2" && pwd -P)"
same 'AGENT_HOME override' "$tmp/ah|$t1|acme/widgets" "$tmp/t1/engine" AGENT_HOME="$tmp/ah"
same 'ZF_HOME fallback' "$tmp/zh|$t1|acme/widgets" "$tmp/t1/engine" ZF_HOME="$tmp/zh"
same 'AGENT_HOME beats ZF_HOME' "$tmp/ah|$t1|acme/widgets" "$tmp/t1/engine" ZF_HOME="$tmp/zh" AGENT_HOME="$tmp/ah"
same 'ZF_REPO_DIR override' "$tmp/home/.zenoforge|$t2|acme/other" "$tmp/t1/engine" ZF_REPO_DIR="$t2"
same 'ZF_REPO override' "$tmp/home/.zenoforge|$t1|me/mine" "$tmp/t1/engine" ZF_REPO=me/mine

# Layout 3: no origin remote leaves the slug empty and does not abort the shell.
mk_target "$tmp/t3"
t3="$(cd -- "$tmp/t3" && pwd -P)"
same 'no origin remote' "$tmp/home/.zenoforge|$t3|" "$tmp/t3/engine"

# ZF_ENGINE_DIR is the directory config.sh lives in; a directory it derived is re-derived when another checkout is sourced.
eq 'ZF_ENGINE_DIR is the engine directory' "$tmp/t1/engine" \
  "$(env -i PATH="$PATH" HOME="$tmp/home" bash -c 'source "$1/config.sh"; printf "%s" "$ZF_ENGINE_DIR"' _ "$tmp/t1/engine")"
eq 'sourcing a second checkout re-derives the directories' "$t1|$t3" \
  "$(env -i PATH="$PATH" HOME="$tmp/home" bash -c 'source "$1/config.sh"; a=$ZF_REPO_DIR; source "$2/config.sh"; printf "%s|%s" "$a" "$ZF_REPO_DIR"' _ "$tmp/t1/engine" "$tmp/t3/engine")"
eq 'an explicit ZF_REPO_DIR survives a second source' "$t2|$t2" \
  "$(env -i PATH="$PATH" HOME="$tmp/home" ZF_REPO_DIR="$t2" bash -c 'source "$1/config.sh"; a=$ZF_REPO_DIR; source "$2/config.sh"; printf "%s|%s" "$a" "$ZF_REPO_DIR"' _ "$tmp/t1/engine" "$tmp/t3/engine")"

# Sourcing runs no git or gh, in either coordination mode; only zf_repo_resolve asks git, and only when ZF_REPO is unset.
shim="$tmp/shim"
mkdir -p "$shim"
for tool in git gh; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\nexit 1\n' "$tool" "$tmp" > "$shim/$tool"
  chmod +x "$shim/$tool"
done
for mode in off on; do
  rm -f "$tmp/calls"
  env -i PATH="$shim:$PATH" HOME="$tmp/home" AGENT_HOME="$tmp/ah-shim-$mode" ZF_COORD="$mode" \
    bash -c 'set -euo pipefail; source "$1/config.sh"' _ "$tmp/t1/engine"
  [[ ! -e "$tmp/calls" ]] || { echo "FAIL sourcing config.sh ran: $(cat "$tmp/calls")" >&2; exit 1; }
  echo "ok - sourcing config.sh with ZF_COORD=$mode runs no git or gh"
done
env -i PATH="$shim:$PATH" HOME="$tmp/home" bash -c 'set -euo pipefail; source "$1/config.sh"; zf_repo_resolve' _ "$tmp/t1/engine"
grep -q '^git .*remote get-url origin' "$tmp/calls"
rm -f "$tmp/calls"
env -i PATH="$shim:$PATH" HOME="$tmp/home" ZF_REPO=me/mine bash -c 'set -euo pipefail; source "$1/config.sh"; zf_repo_resolve' _ "$tmp/t1/engine"
[[ ! -e "$tmp/calls" ]]
echo "ok - zf_repo_resolve asks git only when ZF_REPO is unset"

# Sourcing writes nothing: with coordination off AGENT_HOME is not even created.
env -i PATH="$PATH" HOME="$tmp/home" AGENT_HOME="$tmp/ah-off" bash -c 'set -euo pipefail; source "$1/config.sh"' _ "$tmp/t1/engine"
[[ ! -e "$tmp/ah-off" ]]
echo "ok - ZF_COORD=off creates no host-id file or AGENT_HOME"

# Host id: sanitized hostname, persisted once, explicit value wins.
host_id() { # <hostname> [VAR=value...]
  local host="$1"; shift
  env -i PATH="$PATH" HOME="$tmp/home" ZF_COORD=on "$@" bash -c '
    set -euo pipefail
    HOSTNAME=$2; source "$1/config.sh"; printf "%s" "$ZF_HOST_ID"' _ "$tmp/t1/engine" "$host"
}
eq 'host id: lowercased, dots end the short name, other characters become -' my-host \
  "$(host_id 'My_Host.example.com' AGENT_HOME="$tmp/ah-a")"
eq 'host id: a leading - is dropped' lead "$(host_id '-Lead' AGENT_HOME="$tmp/ah-b")"
eq 'host id: nothing usable falls back to host' host "$(host_id '___' AGENT_HOME="$tmp/ah-c")"
long="$(host_id "$(printf 'a%.0s' {1..40})" AGENT_HOME="$tmp/ah-d")"
eq 'host id: at most 32 characters' 32 "${#long}"
[[ "$(host_id 'Sérveur-ünï' AGENT_HOME="$tmp/ah-e")" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]]
echo 'ok - host id: non-ASCII names still match the published pattern'
eq 'host id: written once to AGENT_HOME/host-id' alpha "$(host_id 'Alpha.local' AGENT_HOME="$tmp/ah-p")"
eq 'host id: the file holds the id' alpha "$(cat "$tmp/ah-p/host-id")"
eq 'host id: a later hostname does not change it' alpha "$(host_id 'beta' AGENT_HOME="$tmp/ah-p")"
printf 'Preset_ID\n' > "$tmp/ah-p/host-id"
eq 'host id: a hand-written file is read and sanitized' preset-id "$(host_id 'beta' AGENT_HOME="$tmp/ah-p")"
eq 'host id: an explicit ZF_HOST_ID wins' boxy "$(host_id 'beta' AGENT_HOME="$tmp/ah-q" ZF_HOST_ID=Boxy)"
[[ ! -e "$tmp/ah-q/host-id" ]]
echo 'ok - host id: an explicit ZF_HOST_ID writes no file'
: > "$tmp/afile"
eq 'host id: an unwritable AGENT_HOME still yields the hostname id' gamma "$(host_id 'Gamma' AGENT_HOME="$tmp/afile/ah" 2>/dev/null)"
for trial in 1 2 3 4 5 6 7 8 9 10; do
  rm -rf "$tmp/ah-r"
  host_id first AGENT_HOME="$tmp/ah-r" > "$tmp/r1" &
  host_id second AGENT_HOME="$tmp/ah-r" > "$tmp/r2" &
  wait
  [[ "$(cat "$tmp/r1")" == "$(cat "$tmp/r2")" ]] || { echo "FAIL racing shells chose $(cat "$tmp/r1") and $(cat "$tmp/r2")" >&2; exit 1; }
done
echo 'ok - host id: racing first writers agree'

# Coordination switches: defaults, overrides, and a value that is neither off nor on is refused.
eq 'coordination defaults' 'off|900|60|600|300|30|30|8192|git' "$(env -i PATH="$PATH" HOME="$tmp/home" bash -c '
  source "$1/config.sh"
  printf "%s|%s|%s|%s|%s|%s|%s|%s|%s" "$ZF_COORD" "$ZF_COORD_LEASE_S" "$ZF_COORD_RENEW_S" "$ZF_COORD_SELF_FENCE_S" \
    "$ZF_COORD_DEAD_GRACE_S" "$ZF_COORD_REFRESH_MIN_S" "$ZF_COORD_GIT_TIMEOUT_S" "$ZF_COORD_CHECKPOINT_MAX" "$ZF_COORD_BACKEND"' _ "$tmp/t1/engine")"
eq 'coordination overrides are kept' 'on|120' "$(env -i PATH="$PATH" HOME="$tmp/home" AGENT_HOME="$tmp/ah-o" ZF_COORD=on ZF_COORD_LEASE_S=120 \
  bash -c 'source "$1/config.sh"; printf "%s|%s" "$ZF_COORD" "$ZF_COORD_LEASE_S"' _ "$tmp/t1/engine")"
set +e
bad="$(env -i PATH="$PATH" HOME="$tmp/home" ZF_COORD=maybe bash -c 'source "$1/config.sh"' _ "$tmp/t1/engine" 2>&1)"
bad_status=$?
set -e
eq 'ZF_COORD=maybe is refused' '1|config.sh: ZF_COORD must be off or on, got: maybe' "$bad_status|$bad"

# Stubs: success and silence; the two wrappers run their command and return its status; nobody else is running anything.
stubs="coord_init coord_refresh coord_enter coord_acquire coord_release coord_assert_owned coord_checkpoint_set coord_event_once coord_unit_restore coord_lane_acquire coord_lane_release effect_begin effect_complete effect_reconcile"
eq 'stubs succeed and print nothing' '' "$(env -i PATH="$PATH" HOME="$tmp/home" bash -c '
  set -euo pipefail
  source "$1/config.sh"
  for f in $2; do "$f" claim key kind --class once; done' _ "$tmp/t1/engine" "$stubs" 2>&1)"
eq 'coord_with_ticket and effect_run run their command' 'a b|c d' "$(env -i PATH="$PATH" HOME="$tmp/home" bash -c '
  source "$1/config.sh"
  coord_with_ticket issue-7 -- printf "%s %s|" a b
  effect_run claim merge:pr-1 merge -- printf "%s %s" c d' _ "$tmp/t1/engine")"
eq 'the wrappers return their command status' '3|4' "$(env -i PATH="$PATH" HOME="$tmp/home" bash -c '
  source "$1/config.sh"
  coord_with_ticket issue-7 -- bash -c "exit 3" && s1=0 || s1=$?
  effect_run claim k kind -- bash -c "exit 4" && s2=0 || s2=$?
  printf "%s|%s" "$s1" "$s2"' _ "$tmp/t1/engine")"
eq 'coord_remote_active is false' 1 "$(env -i PATH="$PATH" HOME="$tmp/home" bash -c 'source "$1/config.sh"; coord_remote_active x 1 && echo 0 || echo $?' _ "$tmp/t1/engine")"

# platform-env.sh is sourced first, and only when it exists.
mk_target "$tmp/t4"
printf 'PLATFORM_SAW_AGENT_HOME="${AGENT_HOME-unset}"\nZF_OS=test\n' > "$tmp/t4/engine/platform-env.sh"
eq 'platform-env.sh runs before config.sh resolves anything' 'unset|test' "$(env -i PATH="$PATH" HOME="$tmp/home" bash -c '
  source "$1/config.sh"; printf "%s|%s" "$PLATFORM_SAW_AGENT_HOME" "$ZF_OS"' _ "$tmp/t4/engine")"
eq 'config.sh sources cleanly without platform-env.sh' ok "$(env -i PATH="$PATH" HOME="$tmp/home" bash -c 'set -euo pipefail; source "$1/config.sh" && echo ok' _ "$tmp/t1/engine")"

# lib.sh takes its values from config.sh unchanged.
repo_root="$(cd -- "$ENGINE_SRC/.." && pwd -P)"
eq 'lib.sh: AGENT_HOME, REPO_DIR, ZF_REPO_DIR and ZF_REPO' "$AGENT_HOME|$repo_root|$repo_root|$ZF_REPO" \
  "$(bash -c 'source "$1/lib.sh"; printf "%s|%s|%s|%s" "$AGENT_HOME" "$REPO_DIR" "$ZF_REPO_DIR" "$ZF_REPO"' _ "$ENGINE_SRC")"
