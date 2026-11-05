import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from datetime import datetime, timedelta, timezone
from io import StringIO

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import codex_pacing


UTC = timezone.utc
NOW = datetime.now(UTC).replace(microsecond=0)


def event(at, used, **reset):
    return {
        "timestamp": at.isoformat().replace("+00:00", "Z"),
        "type": "event_msg",
        "payload": {
            "type": "token_count",
            "info": {"rate_limits": {"primary": {"used_percent": used, **reset}}},
        },
    }


class CodexPacingTests(unittest.TestCase):
    def setUp(self):
        self.snapshot = {
            "used_percent": 60,
            "resets_at": (NOW + timedelta(hours=10)).isoformat().replace("+00:00", "Z"),
            "observed_at": NOW.isoformat().replace("+00:00", "Z"),
            "burn_rate_percent_per_hour": 5,
        }

    def test_projection_over_100_holds_normal_but_exempts_hotfix(self):
        decision = codex_pacing.evaluate_snapshot(
            self.snapshot, now=NOW, max_age_seconds=900, threshold_percent=100
        )
        self.assertEqual(decision["projected_percent"], 110)
        self.assertTrue(codex_pacing.should_hold_dispatch(decision, {"id": "normal"}, "codex"))
        self.assertFalse(
            codex_pacing.should_hold_dispatch(
                decision, {"id": "hotfix", "hotpatch": True}, "codex"
            )
        )

    def test_projection_under_100_does_not_hold(self):
        self.snapshot["used_percent"] = 40
        decision = codex_pacing.evaluate_snapshot(
            self.snapshot, now=NOW, max_age_seconds=900, threshold_percent=100
        )
        self.assertEqual(decision["projected_percent"], 90)
        self.assertFalse(codex_pacing.should_hold_dispatch(decision, {"id": "normal"}, "codex"))

    def test_stale_snapshot_is_unknown_and_does_not_hold(self):
        self.snapshot["observed_at"] = (NOW - timedelta(seconds=901)).isoformat().replace("+00:00", "Z")
        decision = codex_pacing.evaluate_snapshot(
            self.snapshot, now=NOW, max_age_seconds=900, threshold_percent=100
        )
        self.assertEqual(decision["status"], "unknown")
        self.assertFalse(decision["hold"])
        self.assertFalse(codex_pacing.should_hold_dispatch(decision, {"id": "normal"}, "codex"))

    def test_resets_at_is_parsed_as_absolute_time(self):
        parsed = codex_pacing.parse_quota_event(
            event(NOW, 32, resets_at="2026-11-09T17:33:00Z")
        )
        self.assertEqual(parsed["resets_at"], datetime(2026, 11, 9, 17, 33, tzinfo=UTC))

    def test_resets_in_seconds_is_relative_to_event_timestamp(self):
        parsed = codex_pacing.parse_quota_event(event(NOW, 32, resets_in_seconds=3600))
        self.assertEqual(parsed["resets_at"], NOW + timedelta(hours=1))

    def test_snapshot_uses_latest_event_and_burn_rate_in_configured_window(self):
        reset = NOW + timedelta(days=6, hours=5, minutes=33)
        rows = [
            event(NOW - timedelta(hours=4), 16, resets_at=reset.isoformat().replace("+00:00", "Z")),
            event(NOW, 32, resets_in_seconds=6 * 24 * 3600 + 5 * 3600 + 33 * 60),
        ]
        snapshot = codex_pacing.build_snapshot(rows, window_hours=6, captured_at=NOW)
        self.assertEqual(snapshot["used_percent"], 32)
        self.assertEqual(snapshot["observed_at"], NOW.isoformat().replace("+00:00", "Z"))
        self.assertEqual(snapshot["burn_window_hours"], 6)
        self.assertEqual(snapshot["burn_rate_percent_per_hour"], 4)

    def test_snapshot_reader_reads_only_token_count_quota_events(self):
        with tempfile.TemporaryDirectory() as td:
            path = os.path.join(td, "session.jsonl")
            with open(path, "w", encoding="utf-8") as output:
                output.write(json.dumps(event(NOW, 32, resets_in_seconds=3600)) + "\n")
            rows = list(codex_pacing.read_session_events(td, now=NOW, window_hours=6, max_age_seconds=900))
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["used_percent"], 32)

    def test_snapshot_command_persists_quota_and_observation_fields(self):
        with tempfile.TemporaryDirectory() as td:
            sessions = os.path.join(td, "sessions")
            os.makedirs(sessions)
            with open(os.path.join(sessions, "session.jsonl"), "w", encoding="utf-8") as output:
                output.write(json.dumps(event(NOW, 32, resets_in_seconds=3600)) + "\n")
            snapshot_path = os.path.join(td, "codex-quota.json")
            with redirect_stdout(StringIO()):
                status = codex_pacing.main(
                    [
                        "snapshot",
                        "--sessions-dir",
                        sessions,
                        "--output",
                        snapshot_path,
                        "--window-hours",
                        "6",
                        "--max-age-seconds",
                        "900",
                        "--threshold-percent",
                        "100",
                        "--now",
                        str(NOW.timestamp()),
                    ]
                )
            with open(snapshot_path, encoding="utf-8") as source:
                snapshot = json.load(source)
        self.assertEqual(status, 0)
        self.assertEqual(snapshot["used_percent"], 32)
        self.assertEqual(snapshot["observed_at"], NOW.isoformat().replace("+00:00", "Z"))
        self.assertEqual(snapshot["resets_at"], (NOW + timedelta(hours=1)).isoformat().replace("+00:00", "Z"))
        self.assertIn("burn_rate_percent_per_hour", snapshot)


if __name__ == "__main__":
    unittest.main(verbosity=2)
