#!/usr/bin/env python3
"""usage_reader.py at its public seam: rollouts and review logs in, token numbers out.

Run through usage_reader.test.sh. Expected numbers are worked by hand from each fixture, never recomputed with the
reader's own formulas."""
import json
import os
import sys
import tempfile
import unittest
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import usage_reader as ur  # noqa: E402


def codex_event(input_tokens, cached, output, at="2026-10-20T12:00:00Z"):
    """One Codex token_count line. last_token_usage is deliberately unlike the cumulative totals."""
    return json.dumps({
        "timestamp": at, "type": "event_msg",
        "payload": {"type": "token_count", "info": {
            "last_token_usage": {"input_tokens": 1, "cached_input_tokens": 0, "output_tokens": 1, "total_tokens": 2},
            "total_token_usage": {"input_tokens": input_tokens, "cached_input_tokens": cached, "output_tokens": output,
                                  "total_tokens": input_tokens + output}}}})


def claude_event(message_id, plain, cache_read, cache_creation, output, at="2026-10-20T12:00:00.000Z"):
    """One assistant line of a Claude log. A response with several content blocks is written once per block."""
    return json.dumps({
        "type": "assistant", "timestamp": at, "sessionId": "s",
        "message": {"id": message_id, "model": "claude-haiku-5-5", "role": "assistant", "usage": {
            "input_tokens": plain, "cache_creation_input_tokens": cache_creation,
            "cache_read_input_tokens": cache_read, "output_tokens": output}}})


class Fixture(unittest.TestCase):
    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._dir.cleanup)
        self.root = self._dir.name

    def write(self, relative, lines, end="\n"):
        path = os.path.join(self.root, relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as out:
            out.write("\n".join(lines) + end)
        return path


class CodexSession(Fixture):
    def test_raw_and_fresh_are_separate_fields(self):
        path = self.write("s/rollout-x.jsonl", [codex_event(2_000_000, 1_000_000, 500_000)])
        usage = ur.codex_session_usage(path)
        self.assertEqual((usage.input, usage.cached, usage.output), (2_000_000, 1_000_000, 500_000))
        self.assertEqual(usage.raw, 2_500_000)    # input (cached included) plus output
        self.assertEqual(usage.fresh, 1_500_000)  # input minus cached, plus output

    def test_unreadable_counters_are_unavailable_never_zero(self):
        no_counters = self.write("s/none.jsonl", [json.dumps({"type": "turn_context", "payload": {}})])
        with self.assertRaises(ur.Unavailable):
            ur.codex_session_usage(no_counters)
        cached_above_input = self.write("s/bad.jsonl", [codex_event(100, 40, 10), codex_event(100, 120, 10)])
        with self.assertRaises(ur.Unavailable):
            ur.codex_session_usage(cached_above_input)


DAY = "2026-10-20"
ZONE = "America/Los_Angeles"  # UTC-7 on the fixture day: the local day starts at 07:00Z
DAY_START = datetime(2026, 10, 20, 7, 0, tzinfo=timezone.utc).timestamp()


class CodexWindow(Fixture):
    def window(self):
        return ur.Window.day(DAY, ZONE)

    def rollout(self, name, events, modified=DAY_START + 3600):
        path = self.write(f"codex/2026/10/20/{name}.jsonl", events)
        os.utime(path, (modified, modified))
        return path

    def test_a_day_counts_only_that_days_deltas_of_cumulative_counters(self):
        self.rollout("rollout-cross", [
            codex_event(100, 30, 20, "2026-10-20T06:59:00Z"),   # the previous local evening
            codex_event(150, 50, 35, "2026-10-20T07:01:00Z"),   # +50 +20 +15
            codex_event(150, 50, 35, "2026-10-20T07:02:00Z"),   # no change
            codex_event(180, 60, 40, "2026-10-20T07:03:00Z"),   # +30 +10 +5
        ])
        usage = ur.codex_window_usage(os.path.join(self.root, "codex"), self.window())
        self.assertEqual((usage.input, usage.cached, usage.output), (80, 30, 20))
        self.assertEqual((usage.raw, usage.fresh), (100, 70))

    def test_a_counter_reset_inside_the_day_is_unavailable_not_a_smaller_total(self):
        self.rollout("rollout-reset", [
            codex_event(150, 50, 35, "2026-10-20T07:01:00Z"),
            codex_event(90, 30, 20, "2026-10-20T07:02:00Z"),
        ])
        with self.assertRaises(ur.Unavailable):
            ur.codex_window_usage(os.path.join(self.root, "codex"), self.window())

    def test_parsed_usage_is_cached_by_file_identity_not_by_age(self):
        cache = os.path.join(self.root, "cache.json")
        sessions = os.path.join(self.root, "codex")
        path = self.rollout("rollout-a", [codex_event(1000, 400, 100, "2026-10-20T08:00:00Z")])
        before = os.stat(path)
        self.assertEqual(ur.codex_window_usage(sessions, self.window(), cache).input, 1000)

        # Same path, size and modification time: the cached result is trusted, the file is not read again.
        self.write("codex/2026/10/20/rollout-a.jsonl", [codex_event(2000, 400, 100, "2026-10-20T08:00:00Z")])
        os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns))
        self.assertEqual(ur.codex_window_usage(sessions, self.window(), cache).input, 1000)

        # A different size is a different identity: the changed log is read again.
        self.write("codex/2026/10/20/rollout-a.jsonl", [codex_event(20000, 400, 100, "2026-10-20T08:00:00Z")])
        os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns))
        self.assertEqual(ur.codex_window_usage(sessions, self.window(), cache).input, 20000)

    def test_consumption_already_observed_survives_the_log_being_removed(self):
        cache = os.path.join(self.root, "cache.json")
        sessions = os.path.join(self.root, "codex")
        done = self.rollout("rollout-done", [codex_event(1000, 400, 100, "2026-10-20T08:00:00Z")])
        self.rollout("rollout-live", [codex_event(300, 100, 50, "2026-10-20T09:00:00Z")])
        self.assertEqual(ur.codex_window_usage(sessions, self.window(), cache).raw, 1450)
        os.remove(done)
        self.rollout("rollout-live", [codex_event(300, 100, 50, "2026-10-20T09:00:00Z"),
                                      codex_event(700, 200, 90, "2026-10-20T09:30:00Z")])
        # the removed log's 1100 plus the live log's 790
        self.assertEqual(ur.codex_window_usage(sessions, self.window(), cache).raw, 1890)


def exec_turn_completed(input_tokens, cached, output):
    """One codex exec --json turn.completed line. Its usage is the thread's cumulative counter (the same
    total_token_usage the rollouts carry); cached=None omits the field — the schema shape that must leave fresh
    unavailable instead of inventing zero."""
    usage = {"input_tokens": input_tokens, "output_tokens": output}
    if cached is not None:
        usage["cached_input_tokens"] = cached
    return json.dumps({"type": "turn.completed", "usage": usage})


def exec_stream(session_id, *turns):
    """A codex exec --json worker log: thread.started, then one turn.started per turn with its completion.
    A turn of "started" alone is a turn that never completed (a killed worker's tail)."""
    lines = [json.dumps({"type": "thread.started", "thread_id": session_id})]
    for turn in turns:
        lines.append(json.dumps({"type": "turn.started"}))
        if turn != "started":
            lines.append(exec_turn_completed(*turn))
    return lines


class NativeTurnEvents(Fixture):
    """New sessions' turns arrive as native codex exec --json events, stored per provider/session/turn; the
    rollout parser no longer answers for them."""

    def ingest(self, events, at="2026-10-20T12:00:00Z", name="w.worker.log"):
        path = self.write(name, events)
        facts = ur.codex_stream_facts(path)
        store = ur.TurnEventStore(os.path.join(self.root, "budget-events.json"))
        store.ingest(facts["session_id"], facts["snapshots"], facts["complete"], at)
        store.save()
        return store

    def window(self):
        return ur.Window.day(DAY, ZONE)

    def test_repeated_turn_events_do_not_double_count(self):
        sid = "11111111-2222-3333-4444-555555555555"
        events = exec_stream(sid, (1000, 800, 50)) + [exec_turn_completed(1000, 800, 50)] + \
            exec_stream(sid, (2000, 1700, 80))[1:]  # one turn delivered twice, then a second turn
        store = self.ingest(events)                 # the harvest
        store = self.ingest(events)                 # the re-scan of the same finished worker
        turns = store.sessions[sid]["turns"]
        self.assertEqual(len(turns), 2)
        usage = store.session_usage(sid)
        self.assertEqual((usage.input, usage.cached, usage.output), (2000, 1700, 80))
        window = store.window_usage(self.window())
        self.assertEqual((window.raw, window.fresh), (2080, 380))

    def test_an_out_of_order_older_stream_is_absorbed_not_added(self):
        sid = "11111111-2222-3333-4444-555555555555"
        store = self.ingest(exec_stream(sid, (2000, 1700, 80)), at="2026-10-20T12:00:00Z")
        store = self.ingest(exec_stream(sid, (1000, 800, 50)), at="2026-10-20T11:00:00Z", name="late.worker.log")
        # the older invocation's counters are already inside the newer cumulative snapshot: absorbed, not summed
        self.assertEqual(len(store.sessions[sid]["turns"]), 1)
        self.assertEqual(store.session_usage(sid).input, 2000)
        self.assertEqual(store.window_usage(self.window()).input, 2000)

    def test_a_session_resumed_across_midnight_counts_only_the_new_days_delta(self):
        sid = "11111111-2222-3333-4444-555555555555"
        store = self.ingest(exec_stream(sid, (1000, 800, 50)), at="2026-10-19T18:00:00Z")  # the previous local day
        store = self.ingest(exec_stream(sid, (2000, 1700, 80)), at="2026-10-20T18:00:00Z")
        usage = store.window_usage(self.window())
        self.assertEqual((usage.input, usage.cached, usage.output), (1000, 900, 30))
        self.assertEqual((usage.raw, usage.fresh), (1030, 130))

    def test_a_schema_without_cached_counters_reports_fresh_unavailable(self):
        sid = "11111111-2222-3333-4444-555555555555"
        store = self.ingest(exec_stream(sid, (100, None, 30)))
        usage = store.session_usage(sid)
        self.assertEqual(usage.raw, 130)
        self.assertIsNone(usage.fresh)              # unavailable, never invented
        window = store.window_usage(self.window())
        self.assertEqual(window.raw, 130)
        self.assertIsNone(window.cached)

    def test_incomplete_session_keeps_completed_turns_and_marks_partial_coverage(self):
        sid = "11111111-2222-3333-4444-555555555555"
        store = self.ingest(exec_stream(sid, (1000, 800, 50), "started"))  # killed inside its second turn
        with self.assertRaises(ur.Unavailable):
            store.session_usage(sid)
        usage = store.window_usage(self.window())
        self.assertEqual((usage.input, usage.cached, usage.output), (1000, 800, 50))
        self.assertEqual(usage.incomplete_sessions, (sid,))

    def test_daily_record_reports_killed_and_in_flight_sessions_as_partial(self):
        sessions = os.path.join(self.root, "codex")
        os.makedirs(sessions, exist_ok=True)
        killed_sid = "11111111-2222-3333-4444-555555555555"
        live_sid = "22222222-3333-4444-5555-666666666666"
        self.ingest(exec_stream(killed_sid, (1000, 800, 50), "started"), name="killed.worker.log")
        self.ingest(exec_stream(live_sid, "started"), name="live.worker.log")
        output = os.path.join(self.root, "budget.json")
        history_path = os.path.join(self.root, "budget-history.json")
        with open(history_path, "w", encoding="utf-8") as history:
            json.dump({DAY: 999, "2026-10-19": 100}, history)
        result = ur._codex_day(sessions, DAY, ZONE, output, os.path.join(self.root, "budget-cache.json"))
        with open(output, encoding="utf-8") as source:
            record = json.load(source)
        self.assertEqual(result, 0)
        self.assertEqual(record["status"], "partial")
        self.assertEqual(record["incomplete_sessions"], sorted([killed_sid, live_sid]))
        self.assertEqual((record["in"], record["cached"], record["out"], record["total"]),
                         (1000, 800, 50, 1050))
        self.assertEqual(record["fresh"], 250)
        with open(history_path, encoding="utf-8") as history:
            self.assertEqual(json.load(history), {"2026-10-19": 100})

    def test_covered_sessions_answer_from_the_store_and_their_rollouts_are_not_parsed(self):
        sessions = os.path.join(self.root, "codex")
        cache = os.path.join(self.root, "cache.json")
        sid = "11111111-2222-3333-4444-555555555555"
        native_rollout = self.write(f"codex/2026/10/20/rollout-x-{sid}.jsonl", [codex_event(9999, 999, 999)])
        legacy = self.write("codex/2026/10/20/rollout-old-22222222-3333-4444-5555-666666666666.jsonl",
                            [codex_event(1000, 400, 100, "2026-10-20T08:00:00Z")])
        for path in (native_rollout, legacy):
            os.utime(path, (DAY_START + 3600, DAY_START + 3600))
        # before coverage the meter parsed the new session's rollout like any legacy file
        self.assertEqual(ur.codex_window_usage(sessions, self.window(), cache).raw, 10998 + 1100)
        store = self.ingest(exec_stream(sid, (100, 30, 20)))
        # covered: the store's turn and the legacy file count; the rollout is not parsed again and its cached
        # entry is dropped, so the session is not counted in both places
        usage = ur.codex_window_usage(sessions, self.window(), cache, os.path.join(self.root, "budget-events.json"))
        self.assertEqual((usage.input, usage.cached, usage.output), (1100, 430, 120))
        self.assertEqual((usage.raw, usage.fresh), (1220, 790))

    def test_a_legacy_session_resumed_under_json_counts_only_the_new_days_delta(self):
        sessions = os.path.join(self.root, "codex")
        cache = os.path.join(self.root, "cache.json")
        events = os.path.join(self.root, "budget-events.json")
        sid = "11111111-2222-3333-4444-555555555555"
        # the rollout parser counted the legacy session on the previous local day: raw 1100 (1000 in + 100 out)
        rollout = self.write(f"codex/2026/10/19/rollout-old-{sid}.jsonl",
                             [codex_event(1000, 400, 100, "2026-10-19T20:00:00Z"),
                              codex_event(1200, 500, 150, "2026-10-20T12:00:00Z")])
        os.utime(rollout, (DAY_START + 3600, DAY_START + 3600))
        # the same thread resumed under --json today: turn.completed repeats the thread's cumulative 1200/500/150
        self.ingest(exec_stream(sid, (1200, 500, 150)), at="2026-10-20T12:00:00Z")
        usage = ur.codex_window_usage(sessions, self.window(), cache, events)
        # today's delta is 1350 - 1100 = 250 raw (200 in, 100 cached, 50 out), not the whole 1350
        self.assertEqual((usage.input, usage.cached, usage.output), (200, 100, 50))
        self.assertEqual((usage.raw, usage.fresh), (250, 150))

    def test_the_8m_resume_boundary_reads_cumulative_raw_not_fresh(self):
        low = "11111111-2222-3333-4444-555555555555"
        high = "22222222-3333-4444-5555-666666666666"
        store = self.ingest(exec_stream(low, (7_899_999, 7_500_000, 100_000)))   # raw 7,999,999: resumes
        store = self.ingest(exec_stream(high, (8_700_000, 8_400_000, 300_000)), name="high.worker.log")
        self.assertEqual(store.session_usage(low).raw, 7_999_999)
        self.assertEqual(store.session_usage(high).raw, 9_000_000)  # fresh is only 0.6M: still a fresh dispatch
        self.assertEqual(store.session_usage(high).fresh, 600_000)

    def test_a_running_workers_partial_final_line_is_skipped(self):
        sid = "11111111-2222-3333-4444-555555555555"
        path = self.write("live.worker.log", exec_stream(sid, (1000, 800, 50)), end="")
        with open(path, "a", encoding="utf-8") as out:
            out.write('\n{"type":"turn.compl')
        facts = ur.codex_stream_facts(path)
        self.assertEqual(facts["session_id"], sid)
        self.assertEqual(facts["snapshots"], [ur.Usage(1000, 800, 50)])
        self.assertTrue(facts["complete"])

    def test_the_daily_record_reports_fresh_unavailable_when_the_schema_lacks_cached_counters(self):
        sessions = os.path.join(self.root, "codex")
        os.makedirs(sessions, exist_ok=True)
        self.ingest(exec_stream("11111111-2222-3333-4444-555555555555", (100, None, 30)))
        output = os.path.join(self.root, "budget.json")
        ur._codex_day(sessions, DAY, ZONE, output, os.path.join(self.root, "budget-cache.json"))
        with open(output, encoding="utf-8") as source:
            record = json.load(source)
        self.assertEqual(record["status"], "measured")
        self.assertEqual(record["raw"], 130)        # raw keeps its meaning beside the unavailable fresh
        self.assertIsNone(record["fresh"])
        self.assertIsNone(record["providers"]["codex"]["fresh"])
        self.assertFalse(os.path.exists(os.path.join(self.root, "budget-history.json")))


class ClaudeSession(Fixture):
    def test_a_response_logged_on_several_lines_counts_once_and_all_four_counters_are_kept(self):
        path = self.write("c/s.jsonl", [
            json.dumps({"type": "user", "message": {"role": "user", "content": "review pr 1"}}),
            claude_event("msg_A", 2, 4410, 8977, 742, "2026-10-20T12:00:01.000Z"),
            claude_event("msg_A", 2, 4410, 8977, 742, "2026-10-20T12:00:02.000Z"),  # second content block, same response
            claude_event("msg_A", 2, 4410, 8977, 742, "2026-10-20T12:00:03.000Z"),
            claude_event("msg_B", 5, 13387, 0, 120, "2026-10-20T12:00:09.000Z"),
        ])
        usage = ur.claude_session_usage(path)
        # input includes both cache counters: A 2+4410+8977, B 5+13387+0
        self.assertEqual((usage.input, usage.cached, usage.output), (26781, 17797, 862))
        self.assertEqual(usage.raw, 27643)   # 2+4410+8977+742 plus 5+13387+0+120: all four counters summed
        self.assertEqual(usage.fresh, 9846)  # uncached input 7, plus cache creation 8977, plus output 862

    def test_a_partial_final_line_is_tolerated(self):
        path = self.write("c/s.jsonl", [claude_event("msg_A", 2, 4410, 8977, 742)], end="\n")
        with open(path, "a", encoding="utf-8") as out:
            out.write('{"type":"assistant","timestamp":"2026-10-20T12:00:05.000Z","message":{"id":"msg_B","usa')
        usage = ur.claude_session_usage(path)
        self.assertEqual(usage.raw, 14131)

    def test_counters_that_cannot_be_read_are_unavailable_never_zero(self):
        path = self.write("c/s.jsonl", [claude_event("msg_A", 2, 4410, 8977, 742).replace('"output_tokens": 742', '"output_tokens": "lots"')])
        with self.assertRaises(ur.Unavailable):
            ur.claude_session_usage(path)


CLONES = "/home/u/.zenoforge/autopilot-wt"


class ClaudeWindow(Fixture):
    """Claude names a log directory after the working directory with every non-alphanumeric character as '-'."""

    def log(self, directory, name, events, modified=DAY_START + 3600):
        path = self.write(f"claude/{directory}/{name}.jsonl", events)
        os.utime(path, (modified, modified))
        return path

    def usage_by_unit(self, cache=None):
        return ur.claude_window_usage(os.path.join(self.root, "claude"), CLONES, ur.Window.day(DAY, ZONE), cache)

    def test_sessions_are_attributed_to_their_unit_from_the_clone_directory_name(self):
        self.log("-home-u--zenoforge-autopilot-wt-wt-pr-3863", "s1", [
            claude_event("msg_1", 1, 100, 10, 50, "2026-10-20T08:00:00.000Z"),
            claude_event("msg_1", 1, 100, 10, 50, "2026-10-20T08:00:01.000Z"),
            claude_event("msg_0", 9, 9, 9, 9, "2026-10-20T06:00:00.000Z"),   # before the local day began
        ])
        self.log("-home-u--zenoforge-autopilot-wt-wt-pr-3863", "s2", [claude_event("msg_2", 2, 200, 0, 30, "2026-10-20T09:00:00.000Z")])
        self.log("-home-u--zenoforge-autopilot-wt-wt-issue-2536", "s3", [claude_event("msg_3", 3, 0, 40, 5, "2026-10-20T10:00:00.000Z")])
        self.log("-home-u-project-example", "cto", [claude_event("msg_4", 999, 999, 999, 999, "2026-10-20T10:00:00.000Z")])
        by_unit = self.usage_by_unit()
        self.assertEqual(sorted(by_unit), ["issue-2536", "pr-3863"])
        # pr-3863: s1 1+100+10 in, 50 out; s2 2+200+0 in, 30 out
        self.assertEqual((by_unit["pr-3863"].input, by_unit["pr-3863"].cached, by_unit["pr-3863"].output), (313, 300, 80))
        self.assertEqual((by_unit["pr-3863"].raw, by_unit["pr-3863"].fresh), (393, 93))
        self.assertEqual((by_unit["issue-2536"].raw, by_unit["issue-2536"].fresh), (48, 48))

    def test_consumption_already_observed_survives_the_log_being_removed(self):
        cache = os.path.join(self.root, "claude-cache.json")
        done = self.log("-home-u--zenoforge-autopilot-wt-wt-pr-1", "done", [claude_event("msg_1", 1, 100, 10, 50, "2026-10-20T08:00:00.000Z")])
        self.log("-home-u--zenoforge-autopilot-wt-wt-pr-2", "live", [claude_event("msg_2", 2, 0, 0, 5, "2026-10-20T09:00:00.000Z")])
        self.assertEqual(self.usage_by_unit(cache)["pr-1"].raw, 161)
        os.remove(done)
        self.assertEqual(self.usage_by_unit(cache)["pr-1"].raw, 161)

    def test_a_missing_log_directory_is_unavailable_not_an_empty_day(self):
        with self.assertRaises(ur.Unavailable):
            ur.claude_window_usage(os.path.join(self.root, "nowhere"), CLONES, ur.Window.day(DAY, ZONE))


if __name__ == "__main__":
    unittest.main()
