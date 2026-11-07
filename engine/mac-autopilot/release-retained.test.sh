#!/usr/bin/env bash
# release_retained.py: a `release-retained` line (deployed, acceptance failed) holds tickets until a later
# `release-closer` line closes them. It scores release.hours_acceptance_failed, zeroes release.hours_waiting for
# the batch it deployed, counts as one deploy out of the release station, and is ignored by every
# `release-closer` reader (node_health.release_acceptances feeds delivery.* and factory_trend).
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
R="$test_env_root/release-retained"; rm -rf "$R"; mkdir -p "$R/alerts"
python3 -I - "$here" "$R" <<'PY' || { echo "not ok - release-retained.test.sh: python checks failed" >&2; exit 1; }
import sys, os, re; sys.path.insert(0, sys.argv[1]); R = sys.argv[2]
from datetime import datetime, timedelta, timezone
import release_retained as RR, node_health as N, station_health as S
events = os.path.join(R, "alerts", "events.md")
now = datetime(2026, 11, 7, 12, 0, tzinfo=timezone.utc)
at = lambda h: (now - timedelta(hours=h)).strftime("%Y-%m-%dT%H:%M:%SZ")
sha = "a" * 40
def write(*lines): open(events, "w").write("".join(lines))
retained = lambda h, held, tracker="#9": f"[{at(h)}] release-retained: deployed={sha} tracker={tracker} held=[{held}]\n"
closer = lambda h, closed: f"[{at(h)}] release-closer: deployed={'b' * 40} closed=[{closed}] awaiting-release=[]\n"

# Missing file: no data, never 0.
m = {"release.hours_waiting": 5.0}; RR.collect(m, R, now)
assert m[RR.METRIC] is None and m["release.hours_waiting"] == 5.0, m

# One retained deploy 10 h ago holding 101,102; nothing closed.
write(retained(10, "101,102"), "[x] unrelated line\n", retained(2, "103", "#none"))
m = {"release.hours_waiting": 30.0}; RR.collect(m, R, now, N.ts(at(12)))
assert abs(m[RR.METRIC] - 10) < 1e-6, m
assert m["release.hours_waiting"] == 0, "batch deployed (retained after batch start): not 'waiting'"
m = {"release.hours_waiting": 3.0}; RR.collect(m, R, now, N.ts(at(1)))
assert m["release.hours_waiting"] == 3.0, "a batch started after the retained deploy still waits"
assert RR.held_at(R) == {101: at(10), 102: at(10), 103: at(2)}

# A later release-closer line resolves its tickets only; an earlier one does not.
write(closer(20, "101"), retained(10, "101,102"), closer(5, "102"))
assert set(RR.held_at(R)) == {101}, RR.held_at(R)
write(retained(10, "101"), closer(5, "101"))
m = {}; RR.collect(m, R, now); assert m[RR.METRIC] == 0.0, m

# Every release-closer reader ignores the retained line.
write(retained(10, "101,102"))
assert N.release_acceptances(R) == [], N.release_acceptances(R)
assert not S.RELEASE_RE.match(retained(10, "101")) and not N.RELEASE_CLOSER_RE.search(retained(10, "101"))
assert "release-closer: deployed=" not in retained(10, "101"), "mechanism-registry f3 pattern must not match"
# The release station counts it as one deploy out, not one per held ticket.
import tempfile
out = S.outs([], R, tempfile.mkdtemp())
assert [(t, n) for t, n in out["release"]] == [(S.ts(at(10)), 1)], out["release"]
write(retained(10, "101,102"), closer(3, "101,102"))
out = S.outs([], R, tempfile.mkdtemp())
assert [n for _, n in out["release"]] == [1, 2], out["release"]
print("release-retained: PASS")
PY
