#!/usr/bin/env bash
# The one place that resolves where the engine lives and which repository it works on (Line B seam A1; same design as
# Zenoforge S0, engine/config.sh). Source this, do not execute it. Every default reproduces the derivation it replaced, so
# nothing changes until a variable is set. Sourcing runs no git, gh or network call and writes nothing.
#   ZF_ENGINE_DIR  the engine's own files (lib.sh, run-*.sh, night/, ...): default = the directory this file lives in.
#   ZF_REPO_DIR    the target repository the engine works on: default = two levels above the engine (the engine
#                     lives inside it today).
#   ZF_CONFIG_ROOT target-repository config overrides: default = $ZF_REPO_DIR/.zenoforge; a caller-set value wins.
#   ZF_PACK_DIR    the deployment's optional modules and data (lib-migration-gate.sh, supervise-browser-check.sh,
#                     state/risk-paths.json, ...), looked up by relative path. Default = ZF_ENGINE_DIR, where the
#                     the product pack lives today. Empty = no pack: every seam falls back to its generic default.
#   ZF_PACK_REL    where the pack's files sit inside the target repository (git show / git diff / ls-tree pathspecs, repo-relative
#                     reads such as state/incident-guards.json): default = engine. The export rewrites that default to the
#                     public engine location; a deployment whose repo keeps the pack elsewhere sets it. Node and python readers
#                     repeat the default (process.env.ZF_PACK_REL || 'engine') because they cannot see this file.
#   ZF_ENGINE_LIVE the engine the running pipeline executes: the landing queue defaults to its own directory; the
#                     lander and delivery-request default to the live checkout. Not set here.
# In a checkout these are plain shell variables; deployment settings and ZF_PACK_REL are exported, and caller overrides win.
# ZF_CONFIG_ROOT is exported so Node readers use the same config root. `env_prefix` in config.json selects the deployment
# spelling for settings that otherwise use the public ZF_ name.
#   deploy.env        beside this file, written into an immutable engine version directory when it is built (Line B): the
#                     deployment's layout and host settings, so a process with a clean environment (systemd-run) still
#                     sees them. Sourced first, before anything below reads a setting. Its lines export a variable only when
#                     the caller has not set it. A checkout has no such file, so nothing changes there.

[[ -f "$(dirname -- "${BASH_SOURCE[0]}")/deploy.env" ]] && source "$(dirname -- "${BASH_SOURCE[0]}")/deploy.env"
AGENT_HOME="${AGENT_HOME:-${ZF_HOME:-$HOME/.zenoforge}}"

# A directory this file derived on an earlier source is not an override: a script that then loads another
# checkout's lib.sh must get that checkout's directories.
[[ "${ZF_ENGINE_DIR-}" == "${_AGENT_ENGINE_DIR_DERIVED-}" ]] && ZF_ENGINE_DIR=
[[ "${ZF_REPO_DIR-}" == "${_AGENT_REPO_DIR_DERIVED-}" ]] && ZF_REPO_DIR=
if [[ -z "${ZF_ENGINE_DIR-}" ]]; then
  # Logical path (no -P): the parent of a symlinked engine is the link's parent, as lib.sh always derived it.
  ZF_ENGINE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -L)"
  _AGENT_ENGINE_DIR_DERIVED="$ZF_ENGINE_DIR"
fi
_zf_repo_dir_default="${ZF_REPO_DIR:-$(cd -- "$ZF_ENGINE_DIR/.." && pwd -P)}"
if [[ -z "${ZF_CONFIG_ROOT+x}" || ( -n "${_AGENT_CONFIG_ROOT_DERIVED+x}" && "$ZF_CONFIG_ROOT" == "$_AGENT_CONFIG_ROOT_DERIVED" ) ]]; then
  ZF_CONFIG_ROOT="${ZF_REPO_DIR:-$_zf_repo_dir_default}/.zenoforge"
  _AGENT_CONFIG_ROOT_DERIVED="$ZF_CONFIG_ROOT"
fi

# zf_env_get <name> [default] -> the prefixed value, the public ZF_ value, or the supplied default.
# A set empty value is returned unchanged, so callers keep their existing empty-value fallback rules.
zf_env_get() {
  [[ $# -ge 1 && $# -le 2 && "$1" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 2
  local name="$1" prefix="" key config_file
  config_file="${ZF_CONFIG_ROOT:+$ZF_CONFIG_ROOT/config.json}"
  if [[ -n "$config_file" && -f "$config_file" ]]; then
    prefix="$(jq -r 'if type == "object" and (.env_prefix | type) == "string" then .env_prefix else "" end' \
      "$config_file" 2>/dev/null)" || prefix=""
  fi
  if [[ -n "$prefix" ]]; then
    key="${prefix}${name}"
    if [[ -n "${!key+x}" ]]; then
      printf '%s' "${!key}"
      return 0
    fi
  fi
  key="ZF_${name}"
  if [[ -n "${!key+x}" ]]; then
    printf '%s' "${!key}"
    return 0
  fi
  if [[ $# -eq 2 ]]; then
    printf '%s' "$2"
    return 0
  fi
  return 1
}

if _zf_repo_dir_resolved="$(zf_env_get REPO_DIR 2>/dev/null)"; then
  ZF_REPO_DIR="$_zf_repo_dir_resolved"
fi
if [[ -z "${ZF_REPO_DIR-}" ]]; then
  ZF_REPO_DIR="$(cd -- "$ZF_ENGINE_DIR/.." && pwd -P)"
  _AGENT_REPO_DIR_DERIVED="$ZF_REPO_DIR"
else
  unset _AGENT_REPO_DIR_DERIVED
fi
if [[ -z "${ZF_CONFIG_ROOT+x}" || ( -n "${_AGENT_CONFIG_ROOT_DERIVED+x}" && "$ZF_CONFIG_ROOT" == "$_AGENT_CONFIG_ROOT_DERIVED" ) ]]; then
  ZF_CONFIG_ROOT="$ZF_REPO_DIR/.zenoforge"
  _AGENT_CONFIG_ROOT_DERIVED="$ZF_CONFIG_ROOT"
fi
export ZF_CONFIG_ROOT

# Normalize deployment spellings for shell consumers that use the public variable names.
for _zf_env_name in AGENT_GIT_USER_NAME AGENT_GIT_USER_EMAIL; do
  if _zf_env_value="$(zf_env_get "$_zf_env_name" 2>/dev/null)"; then
    printf -v "ZF_${_zf_env_name}" '%s' "$_zf_env_value"
    export "ZF_${_zf_env_name}"
  fi
done
unset _zf_env_name _zf_env_value _zf_repo_dir_default _zf_repo_dir_resolved

# Set (even empty) by the caller = explicit; unset, or still the value this file derived earlier = derive again.
if [[ -z "${ZF_PACK_DIR+x}" || ( -n "${_AGENT_PACK_DIR_DERIVED+x}" && "$ZF_PACK_DIR" == "$_AGENT_PACK_DIR_DERIVED" ) ]]; then
  ZF_PACK_DIR="" # PACK_DIR_DEFAULT: the public export rewrites this default to empty
  _AGENT_PACK_DIR_DERIVED="$ZF_PACK_DIR"
fi

export ZF_PACK_REL="${ZF_PACK_REL:-engine}" # a caller-set value wins; empty is no location, so it falls back

# Deployment identity (Line B seam G9): names of hosts, runners, repositories, CI checks and people that engine code used to
# spell as literals. Each default is the literal it replaced, so nothing changes until a variable is set. A caller that sets a
# variable, even to the empty string, wins (an empty list means none). Plain shell variables like the ones above; node and
# python consumers read the same variable from their environment and repeat the default, because they cannot see these.
#   ZF_CIHOST_HOST            ssh alias of the CI/build host (landing host sync, disk probe, toolchain gate, dashboard).
#   ZF_CIHOST_FILE_STEM       stem of the host's unit and installer files: <stem>-*.service|timer are not installed locally,
#                                sync-<stem>-*.sh are run on the host after a landing.
#   ZF_CIHOST_SYNC_PATHS      whitespace-separated glob patterns (case syntax, * also matches /) of landed paths that
#                                trigger the host sync.
#   ZF_CIHOST_SYNC_ROOTS      whitespace-separated repository paths archived and shipped to the host for a sync.
#   ZF_CI_RUNNER_PREFIX       GitHub runner label stem of the CI host: <stem>, <stem>-light, <stem>-priority, <stem>-main,
#                                <stem>-postsubmit, <stem>-testcontainers.
#   ZF_ACCEPTANCE_USER        the person whose real-user acceptance a hotfix PR record must name in accepted_by.
#   ZF_INFRA_REPO             owner/name of the production build repository.
#   ZF_INFRA_BUILD_WORKFLOW   file name of its image build workflow.
#   ZF_INFRA_PROXY_STEPS      |-separated names of its workflow steps, besides the generic ones, whose proxy timeouts count as
#                                an environment fault.
#   ZF_DEPLOY_HOST            ssh alias of the production host.
#   ZF_DEPLOY_DIR             deployment directory on that host.
#   ZF_PACK_PR_GATE           name of the product's own PR check in the carried-capacity exception and the mail labels.
#   ZF_PACK_HOOK_STEP         name of the CI step that exception requires to be skipped.
#   ZF_REVIEW_SKILL           directory name of the review skill under .agents/skills (scheduler.d/evals-arbiter.sh and eval/run-eval.mjs read it
#                             with the same default, because neither sources this file).
#   ZF_SECRET_CONFIG_NAMES    regex alternation of extra service config file names (before .json/.yml) the secret-dump gate refuses.
[[ -n "${ZF_CIHOST_HOST+x}" ]] || ZF_CIHOST_HOST=cihost
[[ -n "${ZF_CIHOST_FILE_STEM+x}" ]] || ZF_CIHOST_FILE_STEM=cihost
if [[ -z "${ZF_CIHOST_SYNC_PATHS+x}" ]]; then
  ZF_CIHOST_SYNC_PATHS="engine/systemd/cihost-* engine/systemd/sync-cihost-* engine/systemd/build-capacity-gate.sh ops/host/*"
fi
if [[ -z "${ZF_CIHOST_SYNC_ROOTS+x}" ]]; then
  ZF_CIHOST_SYNC_ROOTS="engine/lib.sh engine/closing-keywords.sh engine/systemd ops/host"
fi
[[ -n "${ZF_CI_RUNNER_PREFIX+x}" ]] || ZF_CI_RUNNER_PREFIX=cihost-ci
[[ -n "${ZF_ACCEPTANCE_USER+x}" ]] || ZF_ACCEPTANCE_USER=验收用户
[[ -n "${ZF_INFRA_REPO+x}" ]] || ZF_INFRA_REPO=example-org/example-infra
[[ -n "${ZF_INFRA_BUILD_WORKFLOW+x}" ]] || ZF_INFRA_BUILD_WORKFLOW=build-cihost-images.yml
[[ -n "${ZF_INFRA_PROXY_STEPS+x}" ]] || ZF_INFRA_PROXY_STEPS="Download selected the product source|Seed verified Agent base image"
[[ -n "${ZF_DEPLOY_HOST+x}" ]] || ZF_DEPLOY_HOST=cihost
[[ -n "${ZF_DEPLOY_DIR+x}" ]] || ZF_DEPLOY_DIR=/srv/app
[[ -n "${ZF_PACK_PR_GATE+x}" ]] || ZF_PACK_PR_GATE="Example pack PR gate"
[[ -n "${ZF_PACK_HOOK_STEP+x}" ]] || ZF_PACK_HOOK_STEP="Test Example Agent hook consumer"
[[ -n "${ZF_SECRET_CONFIG_NAMES+x}" ]] || ZF_SECRET_CONFIG_NAMES=agent-runtime
[[ -n "${ZF_REVIEW_SKILL+x}" ]] || ZF_REVIEW_SKILL=code-review

# pack_file <relative path> -- print the pack's copy of that file and succeed, or fail when there is no pack or no such file.
pack_file() {
  [[ -n "${ZF_PACK_DIR-}" && -f "$ZF_PACK_DIR/$1" ]] || return 1
  printf '%s\n' "$ZF_PACK_DIR/$1"
}

# Target overrides win, then pack values retained during migration, then the engine's shipped defaults.
zf_config_file() {
  [[ $# -eq 1 ]] || return 2
  local relative_path="$1" candidate
  [[ "$relative_path" != /* ]] || return 2
  case "/$relative_path/" in
    */../*) return 2 ;;
  esac

  candidate="$ZF_CONFIG_ROOT/$relative_path"
  if [[ -n "${ZF_CONFIG_ROOT-}" && -f "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  if candidate="$(pack_file "$relative_path")"; then
    printf '%s\n' "$candidate"
    return 0
  fi
  candidate="$ZF_ENGINE_DIR/$relative_path"
  if [[ -f "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  return 1
}

# Resolve the target's release runner, retaining the engine runner as fallback.
zf_release_runner() {
  local config runner
  if config="$(zf_config_file release.json)" &&
     runner="$(jq -r '.release.runner // empty | select(type == "string")' "$config" 2>/dev/null)" &&
     [[ -n "$runner" && -f "$ZF_REPO_DIR/$runner" ]]; then
    printf '%s\n' "$ZF_REPO_DIR/$runner"
  else
    printf '%s\n' "$ZF_ENGINE_DIR/run-release.sh"
  fi
}

# Resolve the optional advisor batch runner from advisor.json. A configured path is
# target-repository code; an absent setting keeps the generic engine runner.
zf_advisor_batch_runner() {
  local config runner candidate
  if ! config="$(zf_config_file advisor.json)"; then
    printf '%s\n' "$ZF_ENGINE_DIR/run-advisor-batch.sh"
    return 0
  fi
  jq -e . "$config" >/dev/null 2>&1 || return 2
  if ! jq -e 'type == "object" and has("batchRunner")' "$config" >/dev/null 2>&1; then
    printf '%s\n' "$ZF_ENGINE_DIR/run-advisor-batch.sh"
    return 0
  fi
  runner="$(jq -er '.batchRunner | select(type == "string" and length > 0)' "$config" 2>/dev/null)" || return 2
  [[ "$runner" != /* && "$runner" != *\\* ]] || return 2
  case "/$runner/" in */../*) return 2 ;; esac
  candidate="$ZF_REPO_DIR/$runner"
  [[ -x "$candidate" ]] || return 2
  printf '%s\n' "$candidate"
}

# Resolve the target's optional comment prefix while keeping a neutral default.
# Advisor pruning and comment-origin checks use this exact prefix.
zf_advisor_comment_disclaimer() {
  [[ $# -eq 1 ]] || return 2
  local default="$1" config value
  if ! config="$(zf_config_file advisor.json)"; then
    printf '%s\n' "$default"
    return 0
  fi
  jq -e . "$config" >/dev/null 2>&1 || return 2
  if ! jq -e 'type == "object" and has("commentDisclaimer")' "$config" >/dev/null 2>&1; then
    printf '%s\n' "$default"
    return 0
  fi
  value="$(jq -er '.commentDisclaimer | select(type == "string" and length > 0)' "$config" 2>/dev/null)" || return 2
  printf '%s\n' "$value"
}

# Resolve the migration gate module. Products can keep their gate implementation
# beside their release code; otherwise a configured migration uses the generic
# engine gate and a legacy pack gate remains available during migration.
zf_migration_gate_file() {
  local config gate candidate
  # Only the target's own release.json selects a gate, as before: an engine default config must not activate one.
  config="${ZF_CONFIG_ROOT:-}/release.json"
  if [[ -n "${ZF_CONFIG_ROOT:-}" && -f "$config" ]]; then
    jq -e . "$config" >/dev/null 2>&1 || return 2
    if jq -e 'type == "object" and has("migration")' "$config" >/dev/null 2>&1; then
      if jq -e '.migration | type == "object" and has("gate")' "$config" >/dev/null 2>&1; then
        gate="$(jq -er '.migration.gate | select(type == "string" and length > 0)' "$config" 2>/dev/null)" || return 2
        [[ "$gate" != /* && "$gate" != *\\* ]] || return 2
        case "/$gate/" in */../*) return 2 ;; esac
        candidate="$ZF_REPO_DIR/$gate"
      else
        candidate="$ZF_ENGINE_DIR/lib-migration-gate.sh"
      fi
      [[ -r "$candidate" ]] || return 2
      printf '%s\n' "$candidate"
      return 0
    fi
  fi
  if [[ -n "${ZF_PACK_DIR-}" && -r "$ZF_PACK_DIR/lib-migration-gate.sh" ]]; then
    printf '%s\n' "$ZF_PACK_DIR/lib-migration-gate.sh"
    return 0
  fi
  return 1
}

# Resolve host-owned files, preserving the caller's existing fallback path.
zf_host_ops_file() {
  local relative_path="$1" fallback="${2:-$ZF_ENGINE_DIR/${1#scripts/agent/}}"
  local candidate="${ZF_HOST_OPS_DIR:-$AGENT_HOME/host-ops}/$relative_path"
  if [[ -f "$candidate" ]]; then printf '%s\n' "$candidate"; else printf '%s\n' "$fallback"; fi
}
