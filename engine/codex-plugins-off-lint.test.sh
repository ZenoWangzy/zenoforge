#!/usr/bin/env bash
# Every engine script that starts a codex run passes -c features.plugins=false (CODEX_PLUGINS_OFF_ARGS), or each start
# re-downloads the remote plugin catalog (upstream openai/codex#47483). Sites were found by grep, not by audit: a new one must carry it too.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
engine="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(cd -- "$engine/.." && pwd -P)"
# Known launch sites still without the flag, each with its tracking issue. Only shrinks.
allowlist=(
  engine/eval/stage-call.sh # #1037
)
# worker-command.sh adds the flag to codex_config_args once; every codex_config_args launch in that file inherits it.
helper_line='codex_config_args+=("${CODEX_PLUGINS_OFF_ARGS[@]}")'
bad=""
while IFS= read -r f; do
  allowed=0
  for a in "${allowlist[@]}"; do [[ $a == "$f" ]] && allowed=1; done
  ((allowed)) && continue
  helper=0; grep -Fq "$helper_line" "$root/$f" && helper=1
  # Hit = a codex run or codex_args=(exec; its window is the line plus backslash continuations.
  hits="$(awk -v file="$f" -v helper="$helper" '
    { line[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        s = line[i]
        if (s ~ /^[[:space:]]*#/) continue
        if (s !~ /(^|[[:space:](])codex[[:space:]]+exec([[:space:]]|$)/ && s !~ /codex_args=\(exec/) continue
        win = s
        for (j = i; j < NR && line[j] ~ /\\[[:space:]]*$/; j++) win = win "\n" line[j + 1]
        if (win ~ /CODEX_PLUGINS_OFF_ARGS|features\.plugins=false/ || (helper && win ~ /codex_config_args/)) continue
        printf "%s:%d\n", file, i
      }
    }' "$root/$f")"
  [[ -z "$hits" ]] || bad+="$hits"$'\n'
done < <(git -C "$root" ls-files 'engine/*.sh' | grep -vE '\.test\.sh$|/fixtures?/')
[[ -z "$bad" ]] || { printf 'codex-plugins-off-lint.test.sh: codex run without -c features.plugins=false (CODEX_PLUGINS_OFF_ARGS):\n%s' "$bad" >&2; exit 1; }
echo 'codex-plugins-off-lint.test.sh: all assertions passed'
