#!/usr/bin/env python3
"""Select the newest scheduler timestamp accepted by the shared log reader."""
from datetime import datetime, timezone
import sys

import ledger_history


if len(sys.argv) != 3:
    raise SystemExit("usage: scheduler_tick.py LOG_PATH NOW_EPOCH")

now = datetime.fromtimestamp(int(sys.argv[2]), timezone.utc)
print(ledger_history.latest_scheduler_tick(sys.argv[1], now))
