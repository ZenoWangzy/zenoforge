#!/usr/bin/env bash
set -euo pipefail

SIM_HARNESS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SIM_ENGINE_DIR="$(cd -- "$SIM_HARNESS_DIR/../.." && pwd -P)"
SIM_REAL_GIT="${SIM_REAL_GIT:-$(type -P git)}"

sim_world_new() {
  local root="${1:?usage: sim_world_new <directory>}"
  mkdir -p -- "$root"
  SIM_WORLD="$(cd -- "$root" && pwd -P)"
  SIM_REMOTE="$SIM_WORLD/remote.git"
  SIM_CLOCK_FILE="$SIM_WORLD/clock"
  SIM_LEASE_S=900
  [[ ! -e $SIM_REMOTE ]] || { echo "simulation remote already exists: $SIM_REMOTE" >&2; return 1; }
  mkdir -p -- "$SIM_WORLD/hosts"
  "$SIM_REAL_GIT" init --bare --quiet "$SIM_REMOTE"
  install -m 0755 "$SIM_HARNESS_DIR/pre-receive" "$SIM_REMOTE/hooks/pre-receive"
  printf '0\n' > "$SIM_CLOCK_FILE"
  : > "$SIM_WORLD/refs.log"
  : > "$SIM_WORLD/dispatch.log"
  : > "$SIM_WORLD/git.log"
  : > "$SIM_WORLD/gh.log"
  mkdir -p "$SIM_WORLD/sinks"
  printf '%s\n' '{"prs":{"31":{"state":"OPEN","mergeCommit":null}},"deployments":[]}' > "$SIM_WORLD/gh-state.json"
  export SIM_HARNESS_DIR SIM_ENGINE_DIR SIM_REAL_GIT SIM_WORLD SIM_REMOTE SIM_CLOCK_FILE SIM_LEASE_S
}

sim_host_new() {
  local id="${1:?usage: sim_host_new <id> [clock-skew-seconds]}"
  local skew="${2:-0}" host repo
  [[ $id =~ ^[A-Za-z0-9_-]+$ ]] || { echo "invalid simulated host id: $id" >&2; return 2; }
  [[ $skew =~ ^-?[0-9]+$ ]] || { echo "invalid clock skew: $skew" >&2; return 2; }
  host="$SIM_WORLD/hosts/$id"
  repo="$host/coord/repo.git"
  [[ ! -e $host ]] || { echo "simulation host already exists: $id" >&2; return 1; }
  mkdir -p -- "${repo%/*}"
  "$SIM_REAL_GIT" clone --bare --quiet "$SIM_REMOTE" "$repo" >/dev/null 2>&1
  "$SIM_REAL_GIT" -C "$repo" config user.name "Simulation $id"
  "$SIM_REAL_GIT" -C "$repo" config user.email "$id@simulation.invalid"
  printf '%s-instance\n' "$id" > "$host/instance"
  printf '%s-instance\n' "$id" > "$host/coord/instance"
  printf '%s\n' "$skew" > "$host/skew"
}

sim_as() {
  local id="${1:?usage: sim_as <id> -- <command...>}"
  shift
  [[ ${1:-} == -- ]] || { echo 'sim_as expects -- before the command' >&2; return 2; }
  shift
  local host="$SIM_WORLD/hosts/$id"
  [[ -d $host ]] || { echo "unknown simulation host: $id" >&2; return 2; }
  (
    export SIM_HOST_ID="$id" SIM_HOST_DIR="$host" SIM_HOST_REPO="$host/coord/repo.git"
    export SIM_HOST_SKEW="$(<"$host/skew")" ZF_HOST_ID="$id"
    export AGENT_HOME="$host" ZF_ENGINE_DIR="$SIM_ENGINE_DIR" ZF_REPO_DIR="$host/coord/repo.git"
    export ZF_COORD=on ZF_COORD_CLOCK_FILE="$SIM_CLOCK_FILE"
    export PATH="$SIM_HARNESS_DIR/bin:$PATH"
    export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=5
    export GIT_CONFIG_KEY_0=protocol.http.allow GIT_CONFIG_VALUE_0=never
    export GIT_CONFIG_KEY_1=protocol.https.allow GIT_CONFIG_VALUE_1=never
    export GIT_CONFIG_KEY_2=protocol.ssh.allow GIT_CONFIG_VALUE_2=never
    export GIT_CONFIG_KEY_3=protocol.git.allow GIT_CONFIG_VALUE_3=never
    export GIT_CONFIG_KEY_4=protocol.ext.allow GIT_CONFIG_VALUE_4=never
    exec "$@"
  )
}

sim_now() {
  local now
  now="$(<"$SIM_CLOCK_FILE")"
  [[ $now =~ ^[0-9]+$ ]] || { echo "invalid simulation clock: $now" >&2; return 1; }
  printf '%s\n' "$((now + ${SIM_HOST_SKEW:-0}))"
}

sim_world_advance() {
  local seconds="${1:?usage: sim_world_advance <seconds>}" now tmp
  [[ $seconds =~ ^[0-9]+$ ]] || { echo "invalid clock advance: $seconds" >&2; return 2; }
  now="$(<"$SIM_CLOCK_FILE")"
  [[ $now =~ ^[0-9]+$ ]] || { echo "invalid simulation clock: $now" >&2; return 1; }
  tmp="$SIM_CLOCK_FILE.tmp.$$"
  printf '%s\n' "$((now + seconds))" > "$tmp"
  mv -- "$tmp" "$SIM_CLOCK_FILE"
}

sim_wait_for() {
  local path="${1:?usage: sim_wait_for <path>}" attempt
  for ((attempt = 0; attempt < 1000; attempt++)); do
    [[ -e $path ]] && return 0
    sleep 0.01
  done
  return 1
}
