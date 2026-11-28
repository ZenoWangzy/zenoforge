#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
FEEDER_SRC="$SCRIPT_DIR/feeder.sh"
WORKER_SCRATCH_ROOT="$ZF_AGENT_TEST_ROOT/scratch"
export WORKER_SCRATCH_ROOT
S="$WORKER_SCRATCH_ROOT"
F="$S/factory"
L="$S/luna"
mkdir -p "$F" "$L"
FAKE_BIN="$ZF_AGENT_TEST_ROOT/bin"
FAKE_GH_LOG="$ZF_AGENT_TEST_ROOT/gh.log"
mkdir -p "$FAKE_BIN"
export FAKE_GH_LOG
cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
case "$1 ${2:-}" in
  'issue list')
    printf '991021\tpipeline-system\tOpen PR fixture\n991022\tpipeline-system\tNo PR fixture\n'
    ;;
  'api search/issues')
    if [[ "$*" == *'Refs #991021'* ]]; then echo 1; else echo 0; fi
    ;;
  'issue edit') ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$FAKE_BIN/gh"
export PATH="$FAKE_BIN:$PATH"
gh() { "$FAKE_BIN/gh" "$@"; }
source <(sed '/^tick=0/,$d' "$FEEDER_SRC")
intake
grep -qx '991021 open PR' "$F/.intake-excluded"
grep -qx 'opt-i991022 991022 -' "$F/queue.txt"
grep -Fq 'api search/issues -X GET -f q=' "$FAKE_GH_LOG"
grep -Fq 'Refs #991021' "$FAKE_GH_LOG"
[[ "$(grep -c '^api search/issues ' "$FAKE_GH_LOG")" == 2 ]]
grep -Fq 'issue edit 991022 ' "$FAKE_GH_LOG"
! grep -Fq 'issue edit 991021 ' "$FAKE_GH_LOG"
! grep -Fq 'pr list --search' "$FAKE_GH_LOG"
echo 'feeder.test.sh: ok'
