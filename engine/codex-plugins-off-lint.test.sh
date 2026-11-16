#!/usr/bin/env bash
# Every engine script that starts a codex run disables plugins and gives the process an empty per-run context-mode sentinel directory.
# Sites were found by grep, not by audit: a new one must carry both guards too.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
engine="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(cd -- "$engine/.." && pwd -P)"
# Known launch sites still without the flag, pinned as file:line, each with its tracking issue. Only shrinks.
allowlist=(
  engine/eval/stage-call.sh:72 # #1037 stage-call
  engine/eval/stage-call.sh:100 # #1037 stage-call
  engine/eval/stage-call.sh:133 # #1037 stage-call
)
# worker-command.sh adds the flag to codex_config_args once; every codex_config_args launch in that file inherits it.
helper_line='codex_config_args+=("${CODEX_PLUGINS_OFF_ARGS[@]}")'
fail() { printf 'codex-plugins-off-lint.test.sh: %s\n' "$*" >&2; exit 1; }

# Prints file:line for each codex launch under $1 that lacks the flag and is not allowlisted.
scan_root() {
  local root="$1" f g hit hits helper a allowed
  local -a files=()
  while IFS= read -r f; do files+=("$f"); done < <(git -C "$root" ls-files 'engine/*.sh' | grep -vE '\.test\.sh$|/fixtures?/')
  # Extensionless engine files (engine/bin/luna) are scanned when `file` calls them shell scripts.
  while IFS= read -r g; do
    if file -b "$root/$g" | grep -q 'shell script'; then files+=("$g"); fi
  done < <(git -C "$root" ls-files engine | awk -F/ '$NF !~ /\./')
  for f in "${files[@]}"; do
    helper=0; grep -Fq "$helper_line" "$root/$f" && helper=1
    # Hit = a codex run or codex_args=(exec (any case); its window is the line plus backslash continuations.
    hits="$(awk -v file="$f" -v helper="$helper" '
      { line[NR] = $0 }
      END {
        for (i = 1; i <= NR; i++) {
          s = line[i]
          if (s ~ /^[[:space:]]*#/) continue
          t = tolower(s)
          if (t !~ /(^|[[:space:](])codex[[:space:]]+exec([[:space:]]|$)/ && t !~ /codex_args=\(exec/) continue
          win = s
          for (j = i; j < NR && line[j] ~ /\\[[:space:]]*$/; j++) win = win "\n" line[j + 1]
          if (win ~ /CODEX_PLUGINS_OFF_ARGS|features\.plugins=false/ || (helper && win ~ /codex_config_args/)) continue
          printf "%s:%d\n", file, i
        }
      }' "$root/$f")"
    while IFS= read -r hit; do
      [[ -n "$hit" ]] || continue
      allowed=0
      for a in "${allowlist[@]}"; do [[ $a == "$hit" ]] && allowed=1; done
      ((allowed)) || printf '%s\n' "$hit"
    done <<< "$hits"
  done
  return 0
}

# Prints file:line for each Codex process launch whose command does not use the shared per-run sentinel helper.
scan_context_mode_root() {
  local root="$1" f g hit hits
  local -a files=()
  while IFS= read -r f; do files+=("$f"); done < <(git -C "$root" ls-files 'engine/*.sh' | grep -vE '\.test\.sh$|/fixtures?/')
  while IFS= read -r g; do
    if file -b "$root/$g" | grep -q 'shell script'; then files+=("$g"); fi
  done < <(git -C "$root" ls-files engine | awk -F/ '$NF !~ /\./')
  for f in "${files[@]}"; do
    hits="$(awk -v file="$f" '
      { line[NR] = $0 }
      END {
        for (i = 1; i <= NR; i++) {
          s = line[i]
          if (s ~ /^[[:space:]]*#/) continue
          t = tolower(s)
          if (t !~ /(^|[[:space:](])codex[[:space:]]+exec([[:space:]]|$)/ &&
              t !~ /(^|[[:space:]])codex[[:space:]].*"\$\{[a-z_][a-z0-9_]*\[@\]\}"/) continue
          win = s
          for (j = i; j < NR && line[j] ~ /\\[[:space:]]*$/; j++) win = win "\n" line[j + 1]
          for (j = i - 1; j >= 1 && line[j] ~ /\\[[:space:]]*$/; j--) win = line[j] "\n" win
          if (win ~ /codex_mcp_context_mode_sentinel_dir/) continue
          printf "%s:%d\n", file, i
        }
      }' "$root/$f")"
    while IFS= read -r hit; do [[ -z "$hit" ]] || printf '%s\n' "$hit"; done <<< "$hits"
  done
  return 0
}

bad="$(scan_root "$root")"
[[ -z "$bad" ]] || { printf 'codex-plugins-off-lint.test.sh: codex run without -c features.plugins=false (CODEX_PLUGINS_OFF_ARGS):\n%s\n' "$bad" >&2; exit 1; }
context_mode_bad="$(scan_context_mode_root "$root")"
[[ -z "$context_mode_bad" ]] || { printf 'codex-plugins-off-lint.test.sh: codex run without a per-run context-mode sentinel directory:\n%s\n' "$context_mode_bad" >&2; exit 1; }

# Fixture repo: both launch linters name unguarded starts, then accept the shared helper/env.
fx="$test_env_root/codex-lint-fixture"
mkdir -p "$fx/engine/bin"
git -C "$fx" init -q
printf '%s\n' 'CODEX_ARGS=(exec --sandbox read-only --cd "$PROBE_DIR")' 'timeout 10m codex "${CODEX_ARGS[@]}" - <<< "$PROMPT"' > "$fx/engine/probe.sh"
printf '%s\n' '#!/usr/bin/env bash' 'codex exec --json "$@"' > "$fx/engine/bin/extless"
git -C "$fx" add -A
bad="$(scan_root "$fx")"
grep -qx 'engine/probe.sh:1' <<< "$bad" || fail "mixed-case CODEX_ARGS=(exec without flag not named file:line: $bad"
grep -qx 'engine/bin/extless:2' <<< "$bad" || fail "extensionless shell script not scanned: $bad"
context_mode_bad="$(scan_context_mode_root "$fx")"
grep -qx 'engine/probe.sh:2' <<< "$context_mode_bad" || fail "Codex array launch without context-mode helper not named: $context_mode_bad"
grep -qx 'engine/bin/extless:2' <<< "$context_mode_bad" || fail "extensionless Codex launch without context-mode helper not named: $context_mode_bad"

printf '%s\n' 'CODEX_ARGS=(exec "${CODEX_PLUGINS_OFF_ARGS[@]}" --sandbox read-only --cd "$PROBE_DIR")' 'codex_mcp_context_mode_sentinel_dir "$TMPDIR" && timeout 10m env "CONTEXT_MODE_MCP_SENTINEL_DIR=$CONTEXT_MODE_MCP_SENTINEL_DIR" codex "${CODEX_ARGS[@]}" - <<< "$PROMPT"' > "$fx/engine/probe.sh"
printf '%s\n' '#!/usr/bin/env bash' 'codex_mcp_context_mode_sentinel_dir "$TMPDIR" && env "CONTEXT_MODE_MCP_SENTINEL_DIR=$CONTEXT_MODE_MCP_SENTINEL_DIR" codex exec -c features.plugins=false --json "$@"' > "$fx/engine/bin/extless"
git -C "$fx" add -A
[[ -z "$(scan_root "$fx")" ]] || fail "flagged fixture still reported: $(scan_root "$fx")"
[[ -z "$(scan_context_mode_root "$fx")" ]] || fail "context-mode guarded fixture still reported: $(scan_context_mode_root "$fx")"

echo 'codex-plugins-off-lint.test.sh: all assertions passed'
