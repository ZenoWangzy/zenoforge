import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

import ledger_history
import waste_report


NOW = datetime(2026, 10, 30, 12, tzinfo=timezone.utc)


class SchedulerLogLinesTest(unittest.TestCase):
    def test_skips_and_counts_only_stamps_over_five_minutes_ahead(self):
        now = datetime.now(timezone.utc)
        future = f"[{now + timedelta(hours=8):%Y-%m-%dT%H:%M:%SZ}] worker cost type=implement\n"
        near_stamp = f"{now + timedelta(seconds=60):%Y-%m-%dT%H:%M:%SZ}"
        near_future = f"[{near_stamp}] tick done\n"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "scheduler.log"
            path.write_text(future + near_future)
            rows, future_stamped = waste_report.read_log(path)

        self.assertEqual(future_stamped, 1)
        self.assertEqual(rows, [(near_stamp, "tick done")])

    def test_helper_keeps_exact_boundary_and_reports_missing_file(self):
        boundary = f"[{NOW + timedelta(seconds=300):%Y-%m-%dT%H:%M:%SZ}] tick done\n"
        too_far = f"[{NOW + timedelta(seconds=301):%Y-%m-%dT%H:%M:%SZ}] tick done\n"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "scheduler.log"
            path.write_text(boundary + too_far)
            self.assertEqual(ledger_history.scheduler_log_lines(path, NOW), ([boundary], 1))
            self.assertEqual(ledger_history.scheduler_log_lines(Path(directory) / "missing.log", NOW), (None, 0))

    def test_release_acceptances_ignores_far_future_scheduler_rows(self):
        with tempfile.TemporaryDirectory() as directory:
            future = datetime.now(timezone.utc) + timedelta(minutes=10)
            (Path(directory) / "scheduler.log").write_text(f"[{future:%Y-%m-%dT%H:%M:%SZ}] release-closer: deployed=abc1234 closed=[101]\n")
            self.assertEqual(ledger_history.release_acceptances(directory), [])

    def test_release_acceptances_ignores_far_future_events_markdown_rows(self):
        future = NOW + timedelta(minutes=10)
        with tempfile.TemporaryDirectory() as directory:
            alerts = Path(directory) / "alerts"
            alerts.mkdir()
            (alerts / "events.md").write_text(
                f"[{future:%Y-%m-%dT%H:%M:%SZ}] release-closer: deployed=abc1234 closed=[101]\n")
            self.assertEqual(ledger_history.release_acceptances(directory, now=NOW), [])


if __name__ == "__main__":
    unittest.main()
