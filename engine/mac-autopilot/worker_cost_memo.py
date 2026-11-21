#!/usr/bin/env python3
"""Memo for worker_cost.run_rows: each worker log's measure() row, kept in the supervisor dir.

The dashboard and node-health views re-read every *.worker.log on every run (11k files, 4 GB on
the origin deployment), which pushed both past the 900 s view timeout and left node-health.json
stale. A finished log never changes, so its row is kept under a key of every input measure()
reads:

  name, size, mtime   the log itself: the file name carries kind, unit key and the start stamp,
                      the bytes carry the footer, the stream text and the usage snapshots, and
                      the mtime is the row's end. A file that kept all three is taken to be
                      unchanged -- the same trust gen_dashboard's .cost_cache.json already
                      places in size + mtime.
  worker digest       the whole workers.json record (unit, type, mode, the token_usage_start
                      baseline, rc/exit_code, backend_run_pid, model, provider, finished_at,
                      harvested); a trimmed row, no record at all, is its own key value.

One memo file per supervisor dir (.worker_cost_memo.json, beside gen_dashboard's
.cost_cache.json -- the root these views already keep their runtime state in). node_health.py
and gen_dashboard.py may scan concurrently, so a write goes to a pid-suffixed temp file in the
same directory and then os.replace: a lost update is acceptable, a torn file is not. The scan
flushes after every 500 newly measured logs or 60 s, whichever comes first, so a run killed by
the 900 s timeout keeps what it flushed and the next run goes on from there; a scan that
finishes also drops entries whose log it did not see, so deleted logs cannot grow the file.
Rows are the
direct measure() output -- _chain_baselines and the sort still run over the returned rows on
every call -- and every row handed out is a fresh object, so a caller's in-place edits cannot
leak into the file. An unreadable memo or an entry of the wrong shape is measured again and
rewritten, never raised.
"""
import glob
import hashlib
import json
import os
import sys
import time
from datetime import datetime, timezone

from usage_reader import Usage

MEMO_NAME = ".worker_cost_memo.json"
FLUSH_ROWS = 500
FLUSH_SECONDS = 60.0
BAD_SHAPE = (ValueError, TypeError, KeyError, AttributeError, OverflowError)


def _digest(worker):
    """Stable digest of the whole worker record; a missing record is its own value."""
    if worker is None:
        return ""
    payload = json.dumps(worker, sort_keys=True, separators=(",", ":"), default=str)
    return hashlib.md5(payload.encode("utf-8", "ignore"), usedforsecurity=False).hexdigest()


def _usage_out(usage):
    if usage is None:
        return None
    return {"input": usage.input, "cached": usage.cached, "output": usage.output,
            "incomplete": list(usage.incomplete_sessions),
            "reasoning": usage.reasoning, "cache_write": usage.cache_write}


def _usage_in(value):
    if not isinstance(value, dict) or type(value.get("input")) is not int or type(value.get("output")) is not int:
        raise ValueError("usage shape")
    for key in ("cached", "reasoning", "cache_write"):
        if value.get(key) is not None and type(value.get(key)) is not int:
            raise ValueError("usage shape")
    incomplete = value.get("incomplete") or []
    if not isinstance(incomplete, list) or any(not isinstance(item, str) for item in incomplete):
        raise ValueError("usage shape")
    return Usage(value["input"], value.get("cached"), value["output"], tuple(incomplete),
                 value.get("reasoning"), value.get("cache_write"))


def _stamp_in(value):
    at = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    if at.tzinfo is None:
        raise ValueError("naive datetime")
    return at.astimezone(timezone.utc)


def _row_out(row):
    """The measure() output as plain JSON: the datetimes and Usage values become data."""
    out = dict(row)
    out["start"], out["end"] = row["start"].isoformat(), row["end"].isoformat()
    out["finished_at"] = None if row["finished_at"] is None else row["finished_at"].isoformat()
    out["usage"], out["last"] = _usage_out(row["usage"]), _usage_out(row["last"])
    return out


def _row_in(entry, path):
    row = dict(entry)
    row["start"], row["end"] = _stamp_in(row["start"]), _stamp_in(row["end"])
    row["finished_at"] = None if row["finished_at"] is None else _stamp_in(row["finished_at"])
    row["usage"], row["last"] = (None if row["usage"] is None else _usage_in(row["usage"]),
                                 None if row["last"] is None else _usage_in(row["last"]))
    row["path"] = path  # the caller's own spelling, not the one that filled the memo
    return row


def _load(path):
    """(entries, file unreadable, malformed entries dropped). A wrong shape never raises here;
    a memo not yet written is the ordinary first scan, not an unreadable one."""
    try:
        with open(path, encoding="utf-8") as source:
            memo = json.load(source)
        entries = memo["entries"]
        if memo.get("version") != 1 or not isinstance(entries, dict):
            raise ValueError("memo version")
    except FileNotFoundError:
        return {}, False, 0
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        return {}, True, 0
    dropped = 0
    for name, entry in list(entries.items()):
        if not (isinstance(entry, dict) and isinstance(entry.get("row"), dict)
                and isinstance(entry["row"].get("log"), str) and isinstance(entry.get("worker"), str)
                and type(entry.get("size")) is int and type(entry.get("mtime_ns")) is int):
            del entries[name]
            dropped += 1
    return entries, False, dropped


class Memo:
    """One run_rows call's memo: a hit comes back as a fresh row object, a miss is measured and
    replaces its entry. The mid-scan flushes are what a timeout kill keeps."""

    def __init__(self, sup):
        self.path = os.path.join(sup, MEMO_NAME)
        self.entries, self.unreadable, self.bad = _load(self.path)
        self.files = self.hit = self.read = self.read_bytes = 0
        self.seen = set()
        self.dirty = False
        self.read_since_flush = 0
        self.last_flush = self.started = time.monotonic()
        self._sweep_stale_temps()

    def row(self, path, worker, measure):
        """The log's row: the memo's copy when the key matches, measure()'s when it does not."""
        self.files += 1
        name = os.path.basename(path)
        self.seen.add(name)
        stat = os.stat(path)
        digest = _digest(worker)
        entry = self.entries.get(name)
        if entry is not None and entry["size"] == stat.st_size \
                and entry["mtime_ns"] == stat.st_mtime_ns and entry["worker"] == digest:
            try:
                row = _row_in(entry["row"], path)
                self.hit += 1
                return row
            except BAD_SHAPE:  # a shape our writer never emits: measure again, rewrite
                del self.entries[name]
                self.bad += 1
                self.dirty = True
        row = measure(path, worker)
        self.read += 1
        self.read_since_flush += 1
        self.read_bytes += stat.st_size
        if row is not None:
            self.entries[name] = {"size": stat.st_size, "mtime_ns": stat.st_mtime_ns,
                                  "worker": digest, "row": _row_out(row)}
            self.dirty = True
        if self.read_since_flush >= FLUSH_ROWS or time.monotonic() - self.last_flush >= FLUSH_SECONDS:
            self.flush()
        return row

    def flush(self):
        self.read_since_flush, self.last_flush = 0, time.monotonic()
        if not self.dirty:
            return
        temporary = f"{self.path}.{os.getpid()}.tmp"
        try:
            with open(temporary, "w", encoding="utf-8") as out:
                json.dump({"version": 1, "entries": self.entries}, out,
                          ensure_ascii=False, separators=(",", ":"), default=str)
                out.write("\n")
            os.replace(temporary, self.path)
        except OSError:
            try:
                os.unlink(temporary)
            except OSError:
                pass
            return
        self.dirty = False

    def done(self):
        """End of the scan: entries whose log this scan did not see are dropped, so deleted logs
        cannot grow the file without bound (a killed scan never gets here, so what it flushed
        survives for the next run); then the remeasure line when something was unusable, the
        final flush, and the per-call report that counts the read volume on the live host."""
        stale = [name for name in self.entries if name not in self.seen]
        for name in stale:
            del self.entries[name]
        if stale:
            self.dirty = True
        rebuilt = self.bad + (self.files if self.unreadable else 0)
        if rebuilt:
            count, reason = (self.files, "unreadable memo file") if self.unreadable \
                else (self.bad, "malformed memo entries")
            print(f"worker-cost memo: {count} logs remeasured ({reason})", file=sys.stderr)
        self.flush()
        print(f"worker-cost memo: files={self.files} hit={self.hit} read={self.read} "
              f"read_mb={round(self.read_bytes / 1e6, 1)} rebuilt={rebuilt} "
              f"seconds={round(time.monotonic() - self.started, 1)}", file=sys.stderr)

    def _sweep_stale_temps(self):
        """A run killed mid-flush leaves its temp behind; one older than ten flush windows is dead."""
        try:
            now = time.time()
            for leftover in glob.glob(f"{self.path}.*.tmp"):
                if now - os.path.getmtime(leftover) > 600:
                    os.unlink(leftover)
        except OSError:
            pass
