#!/usr/bin/env bash
# Every engine command that starts the configured release runner must hand it ZF_ENGINE_DIR explicitly: the runner
# fails loud without it, and an inherited value is only there when the service wrapper exported it. Callers that go
# through engine/run-release.sh (the dispatcher) are fine, because the dispatcher exports its own directory.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
fail=0
bad() { printf 'FAIL: %s\n' "$*" >&2; fail=1; }

# One logical command per output row, "<first line>:<text>", with backslash continuations joined and full-line
# comments dropped, so a multi-line systemd-run is checked as the one command that starts the runner.
logical() {
  awk '/^[[:space:]]*#/ { next }
       { l = $0; if (buf == "") start = NR
         if (l ~ /\\$/) { sub(/\\$/, "", l); buf = buf l " "; next }
         print start ":" buf l; buf = "" }' "$1"
}
# A use of the runner path that does not start it: a test, a message, or the lookup of a sibling helper.
not_a_start() {
  [[ $1 =~ ^[[:space:]]*(if[[:space:]]+)?(!?[[:space:]]*)?\[\[?[[:space:]] ]] \
    || [[ $1 =~ ^[[:space:]]*(echo|printf|record_env_fault)[[:space:]] ]] \
    || [[ $1 =~ dirname[[:space:]]+(--[[:space:]]+)?\"\$(\(zf_release_runner\)|[A-Za-z_][A-Za-z0-9_]*)\" ]]
}

mapfile -t files < <(cd "$root" && find engine -type f \( -name '*.sh' -o -name '*.service' \) \
  ! -name '*.test.sh' ! -path 'engine/tests/*' | LC_ALL=C sort)

# Engine code reaches the target runner only through zf_release_runner, never by its target path.
for f in "${files[@]}"; do
  while IFS= read -r hit; do bad "hard-coded target runner path: $f:$hit"; done \
    < <(grep -nE 'scripts/release/run-release\.sh' "$root/$f" | grep -vE '^[0-9]+:[[:space:]]*#')
done

starts=0
check_start() { # <file> <line> <command text>
  starts=$((starts + 1))
  [[ $3 == *'ZF_ENGINE_DIR='* ]] || bad "$1:$2 starts the release runner without ZF_ENGINE_DIR: $3"
}
for f in "${files[@]}"; do
  [[ $f == engine/config.sh ]] && continue
  mapfile -t cmds < <(logical "$root/$f")
  for i in "${!cmds[@]}"; do
    line=${cmds[$i]%%:*} text=${cmds[$i]#*:}
    [[ $text == *'zf_release_runner)'* ]] || continue
    if [[ $text =~ (^|[[:space:]])([A-Za-z_][A-Za-z0-9_]*)=\"\$\(zf_release_runner\)\" ]]; then
      var=${BASH_REMATCH[2]}
      # Every later use of "$var" up to the end of the enclosing function is either not a start or carries the env.
      for ((j = i + 1; j < ${#cmds[@]}; j++)); do
        use=${cmds[$j]#*:}
        [[ $use =~ ^\} ]] && break
        [[ $use == *"\"\$$var\""* || $use == *"\$$var "* || $use == *"\${$var}"* ]] || continue
        not_a_start "$use" || check_start "$f" "${cmds[$j]%%:*}" "$use"
      done
    elif not_a_start "$text"; then
      :
    else
      check_start "$f" "$line" "$text"
    fi
  done
done
((starts > 0)) || bad 'found no command that starts the release runner; the test lost track of the code'
((fail == 0)) || exit 1
echo "release-runner-callers.test.sh: PASS ($starts runner starts)"
