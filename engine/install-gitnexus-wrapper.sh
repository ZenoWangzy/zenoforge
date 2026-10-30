#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="${ZF_REPO_DIR:-$(git -C "$script_dir/.." rev-parse --show-toplevel)}"
npm_bin="${ZF_NPM_GLOBAL_BIN_DIR:-${HOME:?HOME is not set}/.npm-global/bin}"
agent_home="${AGENT_HOME:-${ZF_HOME:-$HOME/.zenoforge}}"
cli="$npm_bin/gitnexus"
real_cli="$npm_bin/gitnexus.real-link"

if ! git -C "$repo_dir" merge-base --is-ancestor HEAD origin/main; then
  echo "Refusing to install GitNexus wrapper before HEAD is on origin/main: $repo_dir" >&2
  exit 1
fi

source_tmp="$(mktemp)"
trap 'rm -f -- "$source_tmp"' EXIT
if ! git -C "$repo_dir" show "origin/main:${ZF_PACK_REL:-engine}/gitnexus-wrapper.sh" > "$source_tmp"; then
  echo "Could not read GitNexus wrapper from origin/main in $repo_dir" >&2
  exit 1
fi

install -d -m 0755 "$npm_bin"
if [[ ! -e "$real_cli" && ! -L "$real_cli" ]]; then
  if [[ -x "$cli" ]]; then
    mv -- "$cli" "$real_cli"
  else
    echo "GitNexus CLI missing at $cli; install gitnexus before installing its wrapper." >&2
    exit 1
  fi
fi
if [[ ! -x "$real_cli" ]]; then
  echo "GitNexus real CLI missing or not executable: $real_cli" >&2
  exit 1
fi

temporary="$cli.tmp.$$"
trap 'rm -f -- "$temporary" "$source_tmp"' EXIT
install -m 0755 "$source_tmp" "$temporary"
mv -fT -- "$temporary" "$cli"
rm -f -- "$source_tmp"
trap - EXIT

install -d -m 0700 "$agent_home"
printf '%s\n' "$(date +%s)" > "$agent_home/gitnexus-analyze-guard-live-since.tmp.$$"
mv -f -- "$agent_home/gitnexus-analyze-guard-live-since.tmp.$$" "$agent_home/gitnexus-analyze-guard-live-since"
printf 'Installed %s; preserved real CLI at %s\n' "$cli" "$real_cli"
