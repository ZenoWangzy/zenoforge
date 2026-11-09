import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

import waste_report


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


if __name__ == "__main__":
    unittest.main()
