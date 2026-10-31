#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../test-env.sh"
p=$(cd "$(dirname "$0")" && pwd); t=$(mktemp -d)
export AGENT_HOME=$t; f=$t/hf-demo-accept.jsonl
ago() { date -u -d "-$1 minutes" +%FT%TZ; }
line() { printf '{"at":"%s","rc":%s,"set":"demo","log":"x"}\n' "$(ago "$1")" "$2" >> "$f"; }
! "$p/hf-demo-gate.sh" >/dev/null                                  # no file
line 100 0; line 60 0; ! "$p/hf-demo-gate.sh" >/dev/null           # only two runs... plus stale
line 30 0; "$p/hf-demo-gate.sh" | grep -q READY                    # three greens, spaced, fresh
line 5 1; ! "$p/hf-demo-gate.sh" >/dev/null                        # newest failed
: > "$f"; line 50 0; line 40 0; line 30 0; ! "$p/hf-demo-gate.sh" >/dev/null   # 10 min apart
: > "$f"; line 300 0; line 250 0; line 200 0; ! "$p/hf-demo-gate.sh" >/dev/null # stale
echo 'not json' > "$f"; ! "$p/hf-demo-gate.sh" >/dev/null 2>&1
# only single-session demo runs count: full and demo-fresh records are ignored
: > "$f"; for m in 70 50 30; do printf '{"at":"%s","rc":0,"set":"full","log":"x"}\n' "$(ago $m)" >> "$f"; done; ! "$p/hf-demo-gate.sh" >/dev/null
: > "$f"; for m in 70 50 30; do printf '{"at":"%s","rc":0,"set":"demo-fresh","log":"x"}\n' "$(ago $m)" >> "$f"; done; ! "$p/hf-demo-gate.sh" >/dev/null
: > "$f"; line 70 0; line 50 0; printf '{"at":"%s","rc":1,"set":"demo-fresh","log":"x"}\n' "$(ago 40)" >> "$f"; line 30 0; "$p/hf-demo-gate.sh" | grep -q READY
