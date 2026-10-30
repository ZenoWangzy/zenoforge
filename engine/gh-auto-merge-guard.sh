#!/usr/bin/env bash
# Shared by guarded_write and the direct-agent gh shim.
reject_native_auto_merge() {
  local -a words=("$@")
  local i=0 expected token
  # Unwrap GNU timeout's supported options, then gh's parent options.
  # Inspect argv only: eval would turn a guard into a command injection path.
  if [ "${words[i]:-}" = timeout ]; then
    i=1
    while [ "$i" -lt "${#words[@]}" ]; do
      case "${words[i]}" in
        --) i=$((i + 1)) ;;
        -k|--kill-after|-s|--signal) i=$((i + 2)) ;;
        -k?*|-s?*|--kill-after=*|--signal=*|--foreground|--preserve-status|-v|--verbose)
          i=$((i + 1)) ;;
        -*) break ;;
        *) i=$((i + 1)); break ;; # duration
      esac
    done
  fi
  if [ "${words[i]:-}" = gh ]; then
    i=$((i + 1))
    for expected in pr merge; do
      while [ "$i" -lt "${#words[@]}" ]; do
        token="${words[i]}"
        case "$token" in
          -R|--repo|--hostname|--config) i=$((i + 2)) ;;
          -R?*|--repo=*|--hostname=*|--config=*|--debug|--help|-h|--version)
            i=$((i + 1)) ;;
          "$expected") i=$((i + 1)); break ;;
          *) break ;;
        esac
      done
      [ "${words[i-1]:-}" = "$expected" ] || break
    done
    if [ "$expected" = merge ] && [ "${words[i-1]:-}" = merge ]; then
      for ((; i < ${#words[@]}; i++)); do
        case "${words[i]}" in
          --auto|--auto-merge|--auto=*|--auto-merge=*)
            echo "guarded_write: native auto-merge refused: branch protection is unavailable on this plan, so there is no required-checks list and GitHub may merge before CI concludes" >&2
            return 64 ;;
        esac
      done
    fi
  fi
}
