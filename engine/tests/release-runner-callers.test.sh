#!/usr/bin/env bash
# Every engine line that starts the configured release runner must hand it ZF_ENGINE_DIR explicitly: the runner fails
# loud without it, and an inherited value is only there when the service wrapper exported it. Callers that go through
# engine/run-release.sh (the dispatcher) are fine, because the dispatcher exports its own directory.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
fail=0
bad() { printf 'FAIL: %s\n' "$*" >&2; fail=1; }

mapfile -t files < <(cd "$root" && find engine -type f \( -name '*.sh' -o -name '*.service' \) \
  ! -name '*.test.sh' ! -path 'engine/tests/*' | LC_ALL=C sort)

# Engine code reaches the target runner only through zf_release_runner, never by its target path.
for f in "${files[@]}"; do
  while IFS= read -r hit; do bad "hard-coded target runner path: $f:$hit"; done \
    < <(grep -nE 'scripts/release/run-release\.sh' "$root/$f" | grep -vE '^[0-9]+:\s*#')
done

callers=0
for f in "${files[@]}"; do
  [[ $f == engine/config.sh ]] && continue
  while IFS=: read -r line text; do
    callers=$((callers + 1))
    if [[ $text =~ (bash|exec|sh)[[:space:]]+\"\$\(zf_release_runner\)\" ]]; then
      # Direct run: ZF_ENGINE_DIR=... must be on the same command line.
      [[ $text == *'ZF_ENGINE_DIR='* ]] || bad "$f:$line runs the release runner without ZF_ENGINE_DIR: $text"
    elif [[ $text =~ ([A-Za-z_][A-Za-z0-9_]*)=\"\$\(zf_release_runner\)\" ]]; then
      var=${BASH_REMATCH[1]}
      # Up to the end of the enclosing function, each line that executes "$var" needs ZF_ENGINE_DIR= between the
      # assignment and that line.
      end=$(awk -v l="$line" 'NR > l && /^}/ { print NR; exit }' "$root/$f"); end=${end:-$(wc -l < "$root/$f")}
      while IFS=: read -r use _; do
        ((use > line && use <= end)) || continue
        sed -n "${line},${use}p" "$root/$f" | grep -q 'ZF_ENGINE_DIR=' \
          || bad "$f:$use runs \$$var (the release runner) without ZF_ENGINE_DIR"
      done < <(grep -nE "^[[:space:]]*((exec|bash|sh)[[:space:]]+)?\"\\\$$var\"([[:space:]]|$)|(bash|exec|sh)[[:space:]]+\"\\\$$var\"" "$root/$f")
    else
      bad "$f:$line uses zf_release_runner in a form this test does not know: $text"
    fi
  done < <(grep -nE 'zf_release_runner\)' "$root/$f" | grep -vE '^[0-9]+:\s*#')
done
((callers > 0)) || bad 'found no zf_release_runner callers; the test lost track of the code'
((fail == 0)) || exit 1
echo "release-runner-callers.test.sh: PASS ($callers callers)"
