#!/usr/bin/env bash
# The one place that resolves where the engine lives and which host this is (distributed design, section 4.1, ticket S0).
# Source this, do not execute it. Every default reproduces the derivation it replaced, so nothing changes until a
# variable is set. Sourcing runs no git, gh or network call and, with coordination off, writes nothing; the two values
# that need I/O have resolvers below (zf_repo_resolve, zf_host_id_resolve).

_zf_config_src="$(dirname -- "${BASH_SOURCE[0]}")"
if [[ -r "$_zf_config_src/platform-env.sh" ]]; then source "$_zf_config_src/platform-env.sh"; fi

AGENT_HOME="${AGENT_HOME:-${ZF_HOME:-$HOME/.zenoforge}}"

# A directory this file derived on an earlier source is not an override: a script that then loads another
# checkout's lib.sh must get that checkout's directories.
[[ "${ZF_ENGINE_DIR-}" == "${_zf_engine_dir_derived-}" ]] && ZF_ENGINE_DIR=
[[ "${ZF_REPO_DIR-}" == "${_zf_repo_dir_derived-}" ]] && ZF_REPO_DIR=
if [[ -z "${ZF_ENGINE_DIR-}" ]]; then
  # Logical path (no -P): the parent of a symlinked engine/ is the link's parent, as lib.sh always derived it.
  ZF_ENGINE_DIR="$(cd -- "$_zf_config_src" && pwd)"
  _zf_engine_dir_derived="$ZF_ENGINE_DIR"
fi
if [[ -z "${ZF_REPO_DIR-}" ]]; then
  ZF_REPO_DIR="$(cd -- "$ZF_ENGINE_DIR/.." && pwd -P)"
  _zf_repo_dir_derived="$ZF_REPO_DIR"
fi

# Coordination is the host's own switch and stays off until set (4.1).
ZF_COORD="${ZF_COORD:-off}"
case "$ZF_COORD" in
  off|on) ;;
  *) echo "config.sh: ZF_COORD must be off or on, got: $ZF_COORD" >&2; return 1 ;;
esac
: "${ZF_COORD_LEASE_S:=900}" "${ZF_COORD_RENEW_S:=60}" "${ZF_COORD_SELF_FENCE_S:=600}" "${ZF_COORD_DEAD_GRACE_S:=300}"
: "${ZF_COORD_REFRESH_MIN_S:=30}" "${ZF_COORD_GIT_TIMEOUT_S:=30}" "${ZF_COORD_CHECKPOINT_MAX:=8192}" "${ZF_COORD_BACKEND:=git}"

# ZF_REPO is the target as owner/name: ZF_REPO, else derived from the origin remote of ZF_REPO_DIR. No origin leaves it
# empty (|| true: a missing remote is exit 2, which set -e would turn into a silent exit). Callers that need it call this
# where they used to run the git lookup; it is not run at source time.
zf_repo_resolve() {
  ZF_REPO="${ZF_REPO:-$(git -C "$ZF_REPO_DIR" remote get-url origin 2>/dev/null | sed -E 's#^(git@[^:]+:|[a-z+]+://([^/@]+@)?[^/]+/)##; s#\.git$##' || true)}"
}

# Host ids are lowercase, [a-z0-9-], start alphanumeric, at most 32 characters (4.1).
_zf_host_id_clean() {
  local LC_ALL=C h="${1,,}" # C: a-z means ASCII a-z in every locale
  h="${h//[^a-z0-9-]/-}"
  h="${h#"${h%%[!-]*}"}"
  h="${h:0:32}"
  printf '%s\n' "${h:-host}"
}

# ZF_HOST_ID is the logical host name published in coordination records: the value already set, else the id persisted
# in $AGENT_HOME/host-id, else the short hostname, written there once. ln makes the first writer's file the one every
# racing shell reads back. Run at source time only when ZF_COORD=on; with it off no file is created.
zf_host_id_resolve() {
  local f="$AGENT_HOME/host-id" id="${ZF_HOST_ID-}" tmp host="${HOSTNAME-}"
  host="${host%%.*}"
  if [[ -z "$id" && ! -s "$f" ]]; then
    tmp="$f.$$"
    if mkdir -p "$AGENT_HOME" && _zf_host_id_clean "$host" > "$tmp"; then ln "$tmp" "$f" 2>/dev/null || true; fi
    rm -f "$tmp"
  fi
  if [[ -z "$id" && -s "$f" ]]; then IFS= read -r id < "$f" || true; fi
  ZF_HOST_ID="$(_zf_host_id_clean "${id:-$host}")"
}
if [[ "$ZF_COORD" == on ]]; then zf_host_id_resolve; fi

# Coordination stubs: with coordination off every verb succeeds and does nothing, so call sites can call them
# unconditionally. The two wrappers just run their command, and "is another host running this" is no.
coord_init() { :; }
coord_refresh() { :; }
coord_enter() { :; }
coord_acquire() { :; }
coord_release() { :; }
coord_assert_owned() { :; }
coord_checkpoint_set() { :; }
coord_event_once() { :; }
coord_unit_restore() { :; }
coord_lane_acquire() { :; }
coord_lane_release() { :; }
coord_remote_active() { return 1; }
coord_with_ticket() { shift; if [[ "${1-}" == -- ]]; then shift; fi; "$@"; } # <key> -- <command...>
effect_begin() { :; }
effect_complete() { :; }
effect_reconcile() { :; }
effect_run() { shift 3; if [[ "${1-}" == -- ]]; then shift; fi; "$@"; } # <claim> <key> <kind> -- <command...>
