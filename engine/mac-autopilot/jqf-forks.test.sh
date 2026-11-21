#!/usr/bin/env bash
set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/jqf-forks"
A="$fixture/autopi"
LOG="$A/scheduler.log"
STAMP=JQF-FORKS-TEST
mkdir -p "$A"
: > "$LOG"
source "$script_dir/scheduler.d/core.sh"

fail() { printf 'jqf-forks.test.sh: %s\n' "$*" >&2; exit 1; }

main() {
  local original_path real_mktemp real_rm real_head stub_dir stub_calls i child_scope
  local expected_rc rc expected_first jqf_line count refusal_rc large_value expected
  original_path="$PATH"
  real_mktemp="$(command -v mktemp)"
  real_rm="$(command -v rm)"
  real_head="$(command -v head)"
  stub_dir="$fixture/path-stubs"
  stub_calls="$fixture/path-stub-calls"
  mkdir -p "$stub_dir"
  export JQF_STUB_CALLS="$stub_calls" JQF_REAL_MKTEMP="$real_mktemp" JQF_REAL_RM="$real_rm" JQF_REAL_HEAD="$real_head"
  for name in mktemp rm head; do
    cat > "$stub_dir/$name" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
tool="${0##*/}"
printf '%s\n' "$tool" >> "$JQF_STUB_CALLS"
case "$tool" in
  mktemp) exec "$JQF_REAL_MKTEMP" "$@" ;;
  rm) exec "$JQF_REAL_RM" "$@" ;;
  head) exec "$JQF_REAL_HEAD" "$@" ;;
esac
STUB
    chmod +x "$stub_dir/$name"
  done
  PATH="$stub_dir:$PATH"
  export PATH
  hash -r
  for ((i = 0; i < 100; i++)); do jqf -n '1' >/dev/null; done
  [[ ! -s "$stub_calls" ]] || fail "100 successful calls used a stubbed fork: $(cat "$stub_calls")"
  PATH="$original_path"
  export PATH
  hash -r
  printf 'ok - 100 successful jqf calls skip mktemp, rm, and head\n'

  (
    source "$script_dir/scheduler.d/core.sh"
    GH_ETAG_DIR="$fixture/gh-etags"
    mkdir -p "$GH_ETAG_DIR"
    tick_rest_usage_begin() { :; }
    _JQF_ERR_SCOPE="$BASHPID"
    local stale_file="$A/.jqf-stderr.previous.$BASHPID"
    local active_file="$A/.jqf-stderr.$_JQF_ERR_SCOPE.$BASHPID"
    : > "$stale_file"
    : > "$active_file"
    tick_gh_calls_begin
    [[ ! -e "$stale_file" ]] || fail 'tick-start cleanup kept an earlier scope file'
    [[ -e "$active_file" ]] || fail 'tick-start cleanup removed the active scope file'
    jqf -n '1' >/dev/null
    [[ -e "$active_file" ]] || fail 'successful jqf removed the active scope file before exit'
    printf '%s\n' "$BASHPID" > "$fixture/jqf-child-scope"
  ) || fail 'tick-start stderr cleanup failed'
  IFS= read -r child_scope < "$fixture/jqf-child-scope"
  [[ ! -e "$A/.jqf-stderr.$child_scope.$child_scope" ]] || fail 'active scope stderr file survived shell exit'
  printf 'ok - tick start clears stale scopes and shell exit clears its own scope\n'

  expected_rc=0
  if LC_ALL=C jq -e . <<< '{bad' >/dev/null 2>"$fixture/jq.err"; then
    fail 'malformed JSON unexpectedly passed jq'
  else
    expected_rc=$?
  fi
  [[ "$expected_rc" != 0 ]] || fail 'raw jq failure returned zero'
  expected_first=''
  IFS= read -r expected_first <"$fixture/jq.err" || :
  : > "$LOG"
  for _ in 1 2; do
    rc=0
    if jqf -e . <<< '{bad' >/dev/null 2>/dev/null; then :; else rc=$?; fi
    [[ "$rc" == "$expected_rc" ]] || fail "jqf changed jq rc from $expected_rc to $rc"
  done
  jqf_line="[$STAMP] jqf error (rc=$expected_rc) in main: $expected_first"
  count="$(grep -Fxc -- "$jqf_line" "$LOG")"
  [[ "$count" == 1 ]] || fail "expected one caller diagnostic for STAMP, found $count"
  printf 'ok - jqf logs the first error once per STAMP and returns jq rc\n'

  : > "$LOG"
  trap '' PIPE
  jqf -c -n 'range(0; 200000)' | head -20 >/dev/null || :
  [[ ! -s "$LOG" ]] || fail 'Broken pipe was logged as a jqf error'
  printf 'ok - jqf suppresses the Broken pipe diagnostic\n'

  : > "$LOG"
  printf -v large_value '%070000d' 0
  refusal_rc=0
  if jqf -n --arg payload "$large_value" '$payload' >/dev/null 2>"$fixture/argv.err"; then :; else refusal_rc=$?; fi
  expected='jqf: argv value payload is 70000 bytes > 65536; pass it via stdin or --slurpfile'
  [[ "$refusal_rc" == 126 ]] || fail "oversized argv returned rc=$refusal_rc, expected 126"
  grep -Fxq -- "$expected" "$fixture/argv.err" || fail 'oversized argv diagnostic changed'
  grep -Fxq -- "[$STAMP] jqf error (rc=126) in main: $expected" "$LOG" || fail 'oversized argv refusal was not logged'
  printf 'ok - jqf keeps the 65536-byte argv refusal\n'
}

main "$@"
