#!/usr/bin/env bash
# Unified maintainer-communication formatter (issue #4658, GAP-12 rulings).
#
# Ruling rules-become-mechanisms: prose and memory are indexes only, so the
# maintainer's communication contract lives as a persistent profile
# (state/comms-profile.json) that this file loads and enforces
# deterministically. Two rulings name these paths:
#   maintainer-replies-chinese-local-time — replies in Chinese; every time shown to
#     the maintainer is rendered through maintainer_local_time, which reads the
#     profile timezone (an IANA zone name; DST follows the zoneinfo
#     database, not a fixed offset). Chinese itself is the positive gate in
#     notify.sh (looks_like_maintainer_readable).
#   local-artifacts-only — deliverables are local temporary files whose
#     absolute path is handed over; claude.ai artifact links are banned.
#     local_artifact_dir mints the sanctioned path (never inside a repo
#     checkout); comms_artifact_rejection_reason is the pre-send check every
#     notify.sh send runs.
#
# Sourced, never executed. lib.sh loads it before notify.sh; notify.sh loads
# it again behind a guard because run-tick.sh sources notify.sh standalone
# (see notify.sh's header). Only needs jq, date, and a readable profile.

_COMMS_FORMAT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# notify.sh can load this module without lib.sh, so make the shared config
# resolver available in both load paths.
if ! declare -F zf_config_file >/dev/null 2>&1; then
  source "$_COMMS_FORMAT_DIR/config.sh"
fi

comms_profile_file() {
  if [[ -n "${ZF_COMMS_PROFILE:-}" ]]; then
    printf '%s\n' "$ZF_COMMS_PROFILE"
  else
    zf_config_file state/comms-profile.json
  fi
}

# comms_profile_get <jq-path> — one value from the persistent profile.
comms_profile_get() {
  jq -er "$1" "$(comms_profile_file)" 2>/dev/null
}

# Fail closed: GNU date silently falls back to UTC for an unknown TZ string,
# which would hand the maintainer wrong times with no error anywhere
# (ruling maintainer-replies-chinese-local-time names exactly this failure).
maintainer_timezone() {
  local tz
  tz="$(comms_profile_get '.maintainer.timezone')" || return 1
  [[ "$tz" =~ ^[A-Za-z0-9_+./-]+$ ]] || return 1
  [ -r "/usr/share/zoneinfo/$tz" ] || return 1
  printf '%s\n' "$tz"
}

# maintainer_local_time <epoch> [format] — founder-facing wall-clock time.
# DST transitions come from the zoneinfo database, so summer/winter render
# correctly without any offset arithmetic here.
maintainer_local_time() {
  local epoch="$1" format="${2:-%-m月%-d日 %H:%M}" tz
  [[ "$epoch" =~ ^[0-9]{10,}$ ]] || return 1
  tz="$(maintainer_timezone)" || return 1
  TZ="$tz" date -d "@$epoch" "+$format"
}

# The one-line note every mail that shows times carries.
maintainer_timezone_note() {
  printf '时间均为%s。\n' "$(comms_profile_get '.maintainer.timezone_label')"
}

# Just the label (e.g. 协调世界时), for inline use next to a single timestamp.
maintainer_timezone_label() {
  comms_profile_get '.maintainer.timezone_label'
}

# local_artifact_dir — mint a local temporary directory for a deliverable and
# print its absolute path. mktemp places it under ZF_ARTIFACT_TMPDIR /
# TMPDIR / /tmp; refusing a base inside the repository keeps artifacts out of
# version control and out of worktree reclamation (local-artifacts-only:
# [...]).
local_artifact_dir() {
  local base="${ZF_ARTIFACT_TMPDIR:-${TMPDIR:-/tmp}}" real
  real="$(cd -- "$base" 2>/dev/null && pwd -P)" || return 1
  case "$real/" in
    "${REPO_DIR:-/nonexistent-repo-dir}"/|"${AGENT_HOME:-${ZF_HOME:-$HOME/.zenoforge}}"/checkout*)
      echo "comms: artifact base '$real' is inside a repository checkout; use a repo-external temp dir" >&2
      return 1
      ;;
  esac
  mktemp -d "$real/zf-artifact.XXXXXX"
}

# comms_artifact_rejection_reason <text> — empty when the text may go out;
# "remote-artifact" when it links a banned artifact host (claude.ai and
# subdomains, per the profile). Called on subject+body for every mail send,
# maintainer or reporter: the ban is on publishing the link at all
# (local-artifacts-only: [...]).
comms_artifact_rejection_reason() {
  local text="$1" host
  while IFS= read -r host; do
    [ -n "$host" ] || continue
    if grep -Fq "$host" <<< "$text"; then
      printf 'remote-artifact'
      return 0
    fi
  done < <(comms_profile_get '.artifacts.banned_hosts[]')
  return 0
}
