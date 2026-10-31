#!/usr/bin/env bash
# health_report.py：窗口内各环节耗时/token/结果、失败计数、门禁停摆时长、需关注单元。
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fail() { echo "health_report.test.sh: $*" >&2; exit 1; }
a="$test_env_root/autopi"; mkdir -p "$a/alerts"
cat > "$a/units.json" <<'JSON'
{"units":[
 {"id":"pr-1","stage":"merged","history":[{"stage":"merged","at":"2026-10-19T10:30:00Z"}]},
 {"id":"pr-2","stage":"review-pending","history":[{"stage":"x","at":"2026-10-19T09:00:00Z"}]},
 {"id":"pr-3","stage":"supervisor-review","note":"NEEDS PRODUCT DECISION","history":[{"stage":"y","at":"2026-10-19T11:50:00Z"}]}
]}
JSON
cat > "$a/workers.json" <<'JSON'
{"workers":[
 {"pid":1,"unit":"pr-1","type":"review","started":"2026-10-19T10:00:00Z","harvested":true},
 {"pid":2,"unit":"pr-1","type":"repair","started":"2026-10-19T10:10:00Z","harvested":true},
 {"pid":3,"unit":"pr-2","type":"review","started":"2026-10-19T11:55:00Z"}
]}
JSON
cat > "$a/scheduler.log" <<'LOG'
[2026-10-19T05:00:00Z] harvest unit=old type=review verdict=APPROVE mode=fresh tokens=5 session_id=none
[2026-10-19T10:00:00Z] dispatch mode=fresh pid=1 type=review unit=pr-1
[2026-10-19T10:06:00Z] harvest unit=pr-1 type=review verdict=REQUEST-CHANGES mode=fresh tokens=1000 session_id=none
[2026-10-19T10:28:00Z] harvest unit=pr-1 type=repair verdict=none mode=fresh tokens=200000 session_id=none
[2026-10-19T10:28:00Z] WASTE zero-output pid=9 unit=pr-9
[2026-10-19T10:29:00Z] provider codex cooling down 30min: x
[2026-10-19T10:29:00Z] merge issued PR#1 merge=abc (batch 1/4)
[2026-10-19T10:30:00Z] unit pr-1 merged after Pipeline suites success on abc
[2026-10-19T10:31:00Z] merged PR#2 merge=def (product PR; no pipeline-suite wait)
[2026-10-19T10:30:00Z] tick done units=3 live=1
LOG
cat > "$a/alerts/gate.md" <<'G'
[2026-10-19T08:00:00Z] GATE main=a suites=success — merge lane open
[2026-10-19T10:00:00Z] GATE main=b suites=failure — merge lane held
[2026-10-19T11:00:00Z] GATE main=c suites=success — merge lane open
G
out="$(python3 "$script_dir/health_report.py" --runtime "$a" --hours 5 --now 2026-10-19T12:00:00Z)"
grep -Eq '^  review +1 +6/6 ' <<<"$out" || fail "review wall time wrong: $out"
grep -Eq '^  repair +1 +18/18 +200000 ' <<<"$out" || fail "repair stats wrong: $out"
grep -Fq 'no-output=1 provider-cooldowns=1' <<<"$out" || fail 'failure counts wrong'
grep -Fq 'merge: issued=1 merged=2 reverted=0' <<<"$out" || fail 'merge counts wrong'
grep -Fq 'gate: held 1.0h of 5h' <<<"$out" || fail "gate held time wrong: $out"
# 最后一个 hold 事件只在 scheduler 仍出 tick 时算「现在 held」；停摆后只算到最后一拍，不再无限增长。
cat > "$a/alerts/gate.md" <<'G'
[2026-10-19T08:00:00Z] GATE main=a suites=success — merge lane open
[2026-10-19T10:00:00Z] GATE main=b suites=failure; merge lane held for pipeline PRs
G
out="$(python3 "$script_dir/health_report.py" --runtime "$a" --hours 5 --now 2026-10-19T10:40:00Z)"
# 10:30 的 tick 仍在 30 分钟内，hold 算到 now：10:00 → 10:40 = 0.7h。
grep -Fq 'gate: held 0.7h of 5h (current)' <<<"$out" || fail "live hold not reported as current: $out"
out="$(python3 "$script_dir/health_report.py" --runtime "$a" --hours 5 --now 2026-10-19T12:00:00Z)"
grep -Fq 'gate: held 0.5h of 5h' <<<"$out" || fail "stale hold must end at the last tick: $out"
! grep -Fq '(current)' <<<"$out" || fail "stale hold reported as current: $out"
# PAUSE 期间 scheduler 仍出 tick 但不评估车道：暂停拍不能把旧 hold 续成 current。
cat > "$a/alerts/gate.md" <<'G'
[2026-10-19T10:00:00Z] GATE main=b suites=failure; merge lane held for pipeline PRs
G
cp "$a/scheduler.log" "$a/scheduler.log.keep"
printf '[2026-10-19T11:50:00Z] paused by /x/PAUSE: harvest/verify only, no dispatch or merge\n[2026-10-19T11:50:00Z] tick done units=3 live=0\n' >> "$a/scheduler.log"
out="$(python3 "$script_dir/health_report.py" --runtime "$a" --hours 5 --now 2026-10-19T12:00:00Z)"
grep -Fq 'gate: held 0.5h of 5h' <<<"$out" || fail "paused ticks must not extend a hold: $out"
! grep -Fq '(current)' <<<"$out" || fail "paused tick reported hold as current: $out"
mv "$a/scheduler.log.keep" "$a/scheduler.log"
# 非 hold 的 GATE 状态行（流水线 PR 照常合并）不算 held。
cat > "$a/alerts/gate.md" <<'G'
[2026-10-19T08:00:00Z] GATE main=a suites=success — merge lane open
[2026-10-19T09:00:00Z] GATE main=b status=in_progress — pipeline PRs merge; verified after merge
G
out="$(python3 "$script_dir/health_report.py" --runtime "$a" --hours 5 --now 2026-10-19T12:00:00Z)"
! grep -Fq 'gate: held' <<<"$out" || fail "non-hold GATE line counted as held: $out"
grep -Eq 'pr-2 +review-pending +180m' <<<"$out" || fail 'stuck pending unit not flagged'
grep -Fq 'NEEDS PRODUCT DECISION' <<<"$out" || fail 'escalated unit not listed'
grep -Fq "drift check: STRATEGY.md 'Maintainer intents'" <<<"$out" || fail 'drift check line missing'
grep -Fq 'unhealthy nodes:' <<<"$out" || fail "node health scorecard not appended: $out"
# 体检打分与 scheduler 同环境：runtime-env.sh 给的 PGTEST_URL 要传到打分进程（否则测试库误报不可达）
hr="$test_env_root/hr"; mkdir -p "$hr"; cp "$script_dir/health_report.py" "$script_dir/node_health.py" "$script_dir/config_paths.py" "$script_dir/usage_reader.py" "$script_dir/worker_cost.py" "$script_dir/workorder_cost.py" "$hr/"
scored="$(env -u PGTEST_URL python3 -c 'import socket,subprocess,sys; s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen()
open(sys.argv[1] + "/runtime-env.sh", "w").write("export PGTEST_URL=postgresql://example@127.0.0.1:%d/postgres\n" % s.getsockname()[1])
sys.exit(subprocess.run(sys.argv[2:]).returncode)' "$hr" python3 "$hr/health_report.py" --runtime "$a" --hours 5 --now 2026-10-19T12:00:00Z | grep -F 'PGTEST_URL')"
grep -Eq ' 1 .*OK$' <<<"$scored" || fail "health report scored without runtime env: $scored"
! grep -Fq 'unit=old' <<<"$out" || fail 'line outside the window counted'
echo 'health_report.test.sh: PASS'
