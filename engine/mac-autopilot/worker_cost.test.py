#!/usr/bin/env python3
"""worker_cost.py at its public seam: worker event streams in, per-unit/ticket/phase/backend
cost rows and totals out.

Run through worker_cost.test.sh. Expected numbers are worked by hand from each fixture, never
recomputed with the module's own formulas."""
import json
import os
import sys
import tempfile
import unittest
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import worker_cost as wc  # noqa: E402


def write(path, lines, end="2026-10-20T12:30:00Z"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as out:
        out.write("\n".join(lines) + "\n")
    stamp = datetime.fromisoformat(end.replace("Z", "+00:00")).timestamp()
    os.utime(path, (stamp, stamp))
    return path


def codex_json_stream(session, snapshots):
    lines = [json.dumps({"type": "thread.started", "thread_id": session})]
    for usage in snapshots:
        lines.append(json.dumps({"type": "turn.started"}))
        lines.append(json.dumps({"type": "turn.completed", "usage": usage}))
    return lines


class Ledger(unittest.TestCase):
    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._dir.cleanup)
        self.root = self._dir.name
        self.sup = os.path.join(self.root, "sup")
        os.makedirs(os.path.join(self.sup, "autopi"))
        self.now = datetime(2026, 10, 20, 13, 0, tzinfo=timezone.utc)

    def log(self, name, lines, end="2026-10-20T12:30:00Z"):
        return write(os.path.join(self.sup, name), lines, end)

    def workers(self, rows):
        with open(os.path.join(self.sup, "autopi", "workers.json"), "w", encoding="utf-8") as out:
            json.dump({"workers": rows}, out)

    # ---------- both stream formats parse ----------

    def test_codex_json_stream_counts_the_invocations_own_tokens(self):
        self.workers([{"log": "impl-issue-5-20261020T120000Z.worker.log", "unit": "issue-5",
                       "type": "implement", "model": "gpt-6-luna", "mode": "fresh"}])
        self.log("impl-issue-5-20261020T120000Z.worker.log", codex_json_stream(
            "aaaaaaaa-0000-0000-0000-000000000001",
            [{"input_tokens": 200_000, "cached_input_tokens": 150_000, "output_tokens": 20_000},
             {"input_tokens": 300_000, "cached_input_tokens": 200_000, "output_tokens": 30_000}]))
        row = wc.run_rows(self.sup)[0]
        self.assertEqual((row["usage"].input, row["usage"].cached, row["usage"].output),
                         (300_000, 200_000, 30_000))  # last snapshot: fresh session counters start at zero
        self.assertEqual((row["phase"], row["unit"], row["backend"]), ("implement", "issue-5", "codex"))
        self.assertEqual(row["minutes"], 30.0)

    def test_markerless_json_log_without_a_ledger_row_stays_unknown(self):
        # A trimmed ledger row cannot tell fresh from resume: the counters are not invented.
        self.log("impl-issue-5-20261020T120000Z.worker.log", codex_json_stream(
            "aaaaaaaa-0000-0000-0000-000000000001",
            [{"input_tokens": 300_000, "cached_input_tokens": 200_000, "output_tokens": 30_000}]))
        row = wc.run_rows(self.sup)[0]
        self.assertIsNone(row["usage"])

    def test_codex_resume_subtracts_the_dispatch_baseline(self):
        self.workers([{"log": "impl-11-fix-20261020T120000Z.worker.log", "unit": "pr-11",
                       "type": "repair", "model": "gpt-6-luna",
                       "token_usage_start": {"input_tokens": 1_000_000, "cached_input_tokens": 900_000,
                                             "output_tokens": 100_000}}])
        self.log("impl-11-fix-20261020T120000Z.worker.log",
                 [json.dumps({"type": "pipeline.execution", "mode": "resume", "reason": "same-provider-model"})]
                 + codex_json_stream("aaaaaaaa-0000-0000-0000-000000000002",
                                     [{"input_tokens": 1_100_000, "cached_input_tokens": 950_000,
                                       "output_tokens": 120_000}]))
        row = wc.run_rows(self.sup)[0]
        self.assertEqual((row["usage"].input, row["usage"].cached, row["usage"].output),
                         (100_000, 50_000, 20_000))

    def test_zcode_result_line_parses_both_counter_shapes(self):
        for name, usage, expected in (
            ("review-77-20261020T120000Z.worker.log",
             {"input_tokens": 100_000, "cache_read_input_tokens": 40_000,
              "cache_creation_input_tokens": 10_000, "output_tokens": 5_000},
             (150_000, 40_000, 5_000)),  # Anthropic style: cache read and creation are input side
            ("review-78-20261020T120500Z.worker.log",
             {"input_tokens": 100_000, "cached_input_tokens": 60_000, "output_tokens": 5_000},
             (100_000, 60_000, 5_000)),  # Codex style: cached is a subset of input
        ):
            with self.subTest(log=name):
                self.log(name, [json.dumps({"type": "event"}), json.dumps({"type": "result", "usage": usage})])
                row = next(r for r in wc.run_rows(self.sup) if r["log"] == name)
                self.assertEqual((row["usage"].input, row["usage"].cached, row["usage"].output), expected)
                self.assertEqual(row["backend"], "zcode")
                self.assertEqual(row["phase"], "review")

    def test_legacy_footer_and_unknown_never_invent_a_split(self):
        self.log("impl-issue-6-20261020T120000Z.worker.log", ["codex", "tokens used", "12,345", "done"])
        self.log("impl-issue-7-20261020T120100Z.worker.log", ["codex", "died before any usage"])
        rows = {r["log"]: r for r in wc.run_rows(self.sup)}
        self.assertEqual((rows["impl-issue-6-20261020T120000Z.worker.log"]["footer_tokens"],
                          rows["impl-issue-6-20261020T120000Z.worker.log"]["usage"]), (12_345, None))
        self.assertIsNone(rows["impl-issue-7-20261020T120100Z.worker.log"]["usage"])
        self.assertIsNone(rows["impl-issue-7-20261020T120100Z.worker.log"]["footer_tokens"])

    # ---------- failover: an overwritten stream is counted exactly once ----------

    def test_stream_overwritten_after_failed_resume_counts_only_the_cold_run(self):
        # The dispatch row still carries the resumed session's cumulative baseline, but
        # codex-repair-run.sh truncated the log and rewrote the marker: the cold run's
        # counters start at zero, so subtracting the stale baseline would undercount and the
        # truncated resume attempt must not add anything.
        self.workers([{"log": "impl-11-fix-20261020T120000Z.worker.log", "unit": "pr-11",
                       "type": "repair", "model": "gpt-6-luna",
                       "token_usage_start": {"input_tokens": 1_000_000, "cached_input_tokens": 900_000,
                                             "output_tokens": 100_000}}])
        self.log("impl-11-fix-20261020T120000Z.worker.log",
                 [json.dumps({"type": "pipeline.execution", "mode": "fresh",
                              "reason": "resume-startup-failed", "resume_exit": 1,
                              "resume_session_id": "aaaaaaaa-0000-0000-0000-000000000002"})]
                 + codex_json_stream("bbbbbbbb-0000-0000-0000-000000000003",
                                     [{"input_tokens": 20_000, "cached_input_tokens": 5_000,
                                       "output_tokens": 3_000}]))
        row = wc.run_rows(self.sup)[0]
        self.assertEqual((row["usage"].input, row["usage"].cached, row["usage"].output), (20_000, 5_000, 3_000))
        self.assertTrue(row["failover"])

    def test_reread_is_stateless_and_cannot_double_count(self):
        self.workers([{"log": "impl-11-fix-20261020T120000Z.worker.log", "unit": "pr-11", "type": "repair",
                       "model": "gpt-6-luna",
                       "token_usage_start": {"input_tokens": 1_000_000, "cached_input_tokens": 900_000,
                                             "output_tokens": 100_000}},
                      {"log": "impl-11-20261020T110000Z.worker.log", "unit": "pr-11", "type": "implement",
                       "model": "gpt-6-luna"}])
        self.log("impl-11-fix-20261020T120000Z.worker.log",
                 [json.dumps({"type": "pipeline.execution", "mode": "resume", "reason": "same-provider-model"})]
                 + codex_json_stream("aaaaaaaa-0000-0000-0000-000000000002",
                                     [{"input_tokens": 1_100_000, "cached_input_tokens": 950_000,
                                       "output_tokens": 120_000}]))
        self.log("impl-11-20261020T110000Z.worker.log",
                 codex_json_stream("cccccccc-0000-0000-0000-000000000004",
                                   [{"input_tokens": 400_000, "cached_input_tokens": 100_000,
                                     "output_tokens": 40_000}]), end="2026-10-20T11:40:00Z")
        units = [{"id": "pr-11", "issue": 4365, "stage": "repair-pending"}]
        first = wc.aggregate(wc.run_rows(self.sup), units, self.now.timestamp())
        second = wc.aggregate(wc.run_rows(self.sup), units, self.now.timestamp())
        self.assertEqual(first["by_unit"], second["by_unit"])  # a re-scan replaces, never accumulates
        pr11 = next(u for u in first["by_unit"] if u["unit"] == "pr-11")
        self.assertEqual(pr11["runs"], 2)                       # implement + repair, each exactly once
        self.assertEqual((pr11["in"], pr11["out"]), (500_000, 60_000))   # 400k + 100k in; 40k + (120k-100k) out
        self.assertEqual(pr11["uncached"], 500_000 - 150_000)   # cached 100k + (950k-900k)
        self.assertEqual(pr11["wall_min"], 30.0 + 40.0)

    # ---------- aggregation: unit, ticket, phase, backend, 24h ----------

    def test_aggregate_groups_by_unit_ticket_phase_and_backend_with_24h_window(self):
        self.workers([
            {"log": "impl-issue-5-20261020T120000Z.worker.log", "unit": "pr-5", "type": "implement",
             "model": "gpt-6-luna"},
            {"log": "review-issue-5-20261020T123000Z.worker.log", "unit": "pr-5", "type": "rereview",
             "model": "claude-haiku-5-5"}])
        self.log("impl-issue-5-20261020T120000Z.worker.log",
                 codex_json_stream("aaaaaaaa-0000-0000-0000-000000000001",
                                   [{"input_tokens": 200_000, "cached_input_tokens": 50_000,
                                     "output_tokens": 20_000}]))
        self.log("review-issue-5-20261020T123000Z.worker.log",
                 ['{"type":"assistant","message":{"id":"m1"}}'], end="2026-10-20T12:36:00Z")
        self.log("review-77-20261020T090000Z.worker.log",
                 [json.dumps({"type": "result", "usage": {"input_tokens": 100_000,
                                                          "cache_read_input_tokens": 40_000,
                                                          "cache_creation_input_tokens": 10_000,
                                                          "output_tokens": 5_000}})], end="2026-10-20T09:20:00Z")
        units = [{"id": "pr-5", "issue": 4355, "stage": "review"},
                 {"id": "pr-77", "issue": 4366, "stage": "merged"}]
        out = wc.aggregate(wc.run_rows(self.sup), units, self.now.timestamp())
        ticket = next(t for t in out["by_ticket"] if t["ticket"] == 4355)
        self.assertEqual((ticket["in"], ticket["out"], ticket["tokens"], ticket["runs"]),
                         (200_000, 20_000, 220_000, 2))
        # the claude rereview has no usage in its worker log: it shows as an unknown run and
        # leaves the counted runs' split intact
        self.assertEqual(ticket["cached_known"], True)
        self.assertEqual(ticket["fresh"], 170_000)
        self.assertEqual(ticket["unknown_runs"], 1)
        zc = next(t for t in out["by_ticket"] if t["ticket"] == 4366)
        self.assertEqual((zc["in"], zc["cached"], zc["uncached"], zc["fresh"]),
                         (150_000, 40_000, 110_000, 115_000))
        self.assertEqual(out["by_phase"]["implement"]["raw"], 220_000)
        self.assertEqual(out["by_phase"]["rereview"]["unknown_runs"], 1)
        self.assertEqual(out["by_backend"]["zcode"]["raw"], 155_000)
        self.assertEqual(out["by_backend"]["codex"]["raw"], 220_000)
        self.assertEqual(out["by_backend"]["claude"]["unknown_runs"], 1)
        # 24h window at 13:00 covers all three runs (the oldest ended 09:20, under 4 h back)
        self.assertEqual((out["last_24h"]["runs"], out["last_24h"]["raw"]), (3, 375_000))
        unit5 = next(u for u in out["by_unit"] if u["unit"] == "pr-5")
        self.assertEqual(unit5["phases"], ["implement", "rereview"])

    def test_trimmed_worker_row_is_attributed_from_the_file_name(self):
        self.log("impl-11-fix-20261020T120000Z.worker.log",
                 [json.dumps({"type": "pipeline.execution", "mode": "fresh", "reason": "initial"})]
                 + codex_json_stream("aaaaaaaa-0000-0000-0000-000000000001",
                                     [{"input_tokens": 10_000, "cached_input_tokens": 0,
                                       "output_tokens": 1_000}]))
        self.log("review-11-r-20261020T121000Z.worker.log",
                 [json.dumps({"type": "result", "usage": {"input_tokens": 1_000, "cached_input_tokens": 0,
                                                          "output_tokens": 100}})])
        rows = {r["log"]: r for r in wc.run_rows(self.sup)}
        self.assertEqual((rows["impl-11-fix-20261020T120000Z.worker.log"]["phase"],
                          rows["impl-11-fix-20261020T120000Z.worker.log"]["unit"]),
                         ("repair", "11"))  # repair from the -fix suffix, PR key from the name
        self.assertEqual(rows["review-11-r-20261020T121000Z.worker.log"]["phase"], "rereview")

    def test_ticket_spend_closes_tickets_on_merged_history_and_bounds_from_history(self):
        self.log("impl-issue-5-20261020T120000Z.worker.log",
                 codex_json_stream("aaaaaaaa-0000-0000-0000-000000000001",
                                   [{"input_tokens": 200_000, "cached_input_tokens": 50_000,
                                     "output_tokens": 20_000}]))
        units = [{"id": "issue-5", "issue": 5, "stage": "merged",
                  "history": [{"stage": "merged", "at": "2026-10-20T12:20:00Z"}]}]
        spend = wc.ticket_spend(wc.run_rows(self.sup), units)
        self.assertEqual(spend[0]["ticket"], 5)
        self.assertEqual(spend[0]["closed_at"], "2026-10-20T12:20:00Z")
        self.assertFalse(spend[0]["open"])
        bound = wc.ticket_bound([100, 200, 300, 400, 500, 600, 700, 800])
        # p50 = 500 (int(0.5*8)th value, daily_bound's convention; x1.5 -> 750), p90 = 800 (x2 -> 1600)
        self.assertEqual((bound["healthy"], bound["unhealthy"], bound["provisional"]), (750, 1600, False))
        self.assertIsNone(wc.ticket_bound([]))


class Eval(unittest.TestCase):
    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._dir.cleanup)
        self.root = self._dir.name
        self.now = datetime(2026, 10, 20, 13, 0, tzinfo=timezone.utc).timestamp()

    def results(self, label, rows, mtime):
        path = os.path.join(self.root, "eval", label, "results.json")
        write(path, [json.dumps({"label": label, "results": rows})], end=mtime)
        return path

    def test_eval_tokens_and_wall_read_from_the_runners_results(self):
        self.results("fresh-label", [
            {"tokens": 1000, "wallSeconds": 60.5, "modelWallSeconds": 40.25},
            {"tokens": 2000, "wallSeconds": 30.0, "modelWallSeconds": 20.0}], "2026-10-20T12:00:00Z")
        self.results("unknown-label", [
            {"tokens": None, "wallSeconds": 10.0, "modelWallSeconds": 5.0}], "2026-10-20T12:30:00Z")
        self.results("stale-label", [
            {"tokens": 999_999, "wallSeconds": 9.0, "modelWallSeconds": 9.0}], "2026-10-19T10:00:00Z")
        out = wc.eval_costs(os.path.join(self.root, "eval"), self.now)
        fresh = next(l for l in out["labels"] if l["label"] == "fresh-label")
        self.assertEqual((fresh["tokens"], fresh["runs"], fresh["wall_seconds"],
                          fresh["model_wall_seconds"]), (3000, 2, 90.5, 60.2))  # 40.25 rounds half-to-even
        unknown = next(l for l in out["labels"] if l["label"] == "unknown-label")
        self.assertIsNone(unknown["tokens"])  # one unknown row keeps the label's sum unknown
        self.assertEqual(unknown["unknown_tokens"], 1)
        window = out["last_24h"]
        self.assertEqual(window["labels"], 2)  # stale-label (25 h old) is outside
        self.assertIsNone(window["tokens"])    # the unknown label keeps the 24 h sum unknown too
        self.assertEqual(window["model_wall_seconds"], 65.2)


if __name__ == "__main__":
    unittest.main()
