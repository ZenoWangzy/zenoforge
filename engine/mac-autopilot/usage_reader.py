#!/usr/bin/env python3
"""One reader for the model tokens a pipeline agent session used.

Four adapters feed one Usage: native codex exec --json turn events (new sessions), Codex rollouts (legacy
sessions, kept only while a real caller exists), Claude review logs (one record per API response) and zcode
CLI result lines (one {"type":"result"} closes one invocation). The daily meter, the resume threshold and the
worker cost ledger all read through here, so they cannot disagree about what a session used.

Usage keeps raw and fresh as separate named fields, never one field with two meanings:
  input   prompt tokens including the cached ones
  cached  prompt tokens served from the cache
  output  generated tokens
  raw     input + output       (Codex: input + output; Claude: all four counters summed)
  fresh   input - cached + output  (Codex: uncached input + output; Claude: uncached input + cache creation + output)
Cached input costs about a tenth of fresh input, so fresh is the number to manage and raw the secondary view. The
resume threshold stays on raw.

Unreadable or inconsistent counters raise Unavailable. A failure is never reported as zero tokens.
"""
import glob
import json
import os
import re
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

SESSION_RE = re.compile(r"^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$")
SCOPED_DOCUMENT_PATHS = (
    "docs/agents/issue-tracker.md",
    "docs/agents/branch-delivery-preflight.md",
    ".agents/skills/ask-matt/SKILL.md",
    "docs/agents/development-flow.md",
    "docs/agents/issue-pipeline.md",
)
SHELL_WRITE_RE = re.compile(
    r"(?:^|[;&|]\s*)(?:tee|cp|mv|install|touch|truncate|dd|rm)\b"
    r"|(?:^|\s)(?:sed|perl)\b[^\n;]*?(?:\s-i(?:\s|$)|--in-place)"
    r"|\.write_(?:text|bytes)\s*\(|\bopen\s*\([^\n)]*,\s*['\"](?:w|a|x)"
)
# A redirect counts only outside quotes, so `rg '=>'` and `grep -- '->'` are reads.
QUOTED_RE = re.compile(r"'[^']*'|\"(?:[^\"\\]|\\.)*\"")
SHELL_REDIRECT_RE = re.compile(r"(?<![-=>])(?:>>?|[0-9]>>?)\s*(?!&)(?!/dev/null\b)\S")


class Unavailable(Exception):
    """The counters cannot be read or are inconsistent: the caller must treat usage as unknown, not zero."""


@dataclass(frozen=True)
class Usage:
    input: int
    cached: int | None
    output: int
    incomplete_sessions: tuple[str, ...] = ()
    reasoning: int | None = None
    cache_write: int | None = None

    def _empty(self):
        return self.input == 0 and self.cached in (None, 0) and self.output == 0 and not self.incomplete_sessions

    def __add__(self, other):
        cached = None if self.cached is None or other.cached is None else self.cached + other.cached
        incomplete = tuple(sorted(set(self.incomplete_sessions) | set(other.incomplete_sessions)))
        if self._empty():
            reasoning, cache_write = other.reasoning, other.cache_write
        elif other._empty():
            reasoning, cache_write = self.reasoning, self.cache_write
        else:
            reasoning = None if self.reasoning is None or other.reasoning is None else self.reasoning + other.reasoning
            cache_write = None if self.cache_write is None or other.cache_write is None else self.cache_write + other.cache_write
        return Usage(self.input + other.input, cached, self.output + other.output, incomplete, reasoning, cache_write)

    @property
    def raw(self):
        return self.input + self.output

    @property
    def fresh(self):
        """None when the cached counter was never supplied: fresh stays unavailable, never invented."""
        return None if self.cached is None else self.input - self.cached + self.output

    def ledger_fields(self):
        """The counter names the unit ledger's worker records already use, plus raw and fresh."""
        return {"input_tokens": self.input, "cached_input_tokens": self.cached, "output_tokens": self.output,
                "reasoning_tokens": self.reasoning, "cache_write_input_tokens": self.cache_write,
                "raw": self.raw, "fresh": self.fresh}


def _records(path):
    """Decoded JSON objects of a JSONL file. A running worker may have an incomplete final line: skip it."""
    with open(path, encoding="utf-8", errors="ignore") as source:
        for line in source:
            try:
                record = json.loads(line)
            except ValueError:
                continue
            if isinstance(record, dict):
                yield record


# ---------- Codex rollouts: cumulative counters ----------

def _codex_totals(record):
    """The cumulative counters of a token_count event (never last_token_usage or the context-normalized
    total_tokens), or None for any other record."""
    payload = record.get("payload") or {}
    if record.get("type") != "event_msg" or not isinstance(payload, dict) or payload.get("type") != "token_count":
        return None
    info = payload.get("info")
    totals = info.get("total_token_usage") if isinstance(info, dict) else None
    return totals if isinstance(totals, dict) else None


def _codex_usage(totals):
    values = [totals.get(name) for name in ("input_tokens", "cached_input_tokens", "output_tokens")]
    if any(type(value) is not int or value < 0 for value in values) or values[1] > values[0]:
        raise ValueError("invalid cumulative token counters")
    reasoning = totals.get("reasoning_output_tokens")
    cache_write = totals.get("cache_write_input_tokens")
    return Usage(*values, reasoning=reasoning if _is_count(reasoning) else None,
                 cache_write=cache_write if _is_count(cache_write) else None)


def find_codex_session_file(sessions_root, session_id):
    """The rollout file of a session id under <root>/YYYY/MM/DD/, or None."""
    if not SESSION_RE.match(session_id):
        return None
    pattern = "/".join([glob.escape(sessions_root), "*", "*", "*", f"*-{session_id}.jsonl"])
    return next((path for path in sorted(glob.glob(pattern)) if os.path.isfile(path)), None)


def codex_session_usage(path):
    """Cumulative usage as of the session's last token_count event."""
    usage = None
    try:
        for record in _records(path):
            totals = _codex_totals(record)
            if totals is None:
                continue
            try:
                usage = _codex_usage(totals)
            except ValueError:
                usage = None
    except OSError as error:
        raise Unavailable(f"cannot read {path}: {error}") from error
    if usage is None:
        raise Unavailable(f"no valid cumulative token counters in {path}")
    return usage


# ---------- native codex exec --json events: new sessions' turns ----------

def codex_stream_facts(path):
    """What one codex exec --json worker log carries: its session, its turns' cumulative usage snapshots, the
    last agent message, and whether every started turn completed.

    turn.completed usage is the thread's cumulative counter (the same total_token_usage the rollouts carry),
    so each event is a snapshot, not an increment. The stream has no per-event timestamps; the caller stamps the
    whole invocation. A partial final line is skipped: a running worker's log ends mid-write.
    """
    session_id, snapshots, message = None, [], ""
    started = completed = 0
    complete = True
    for record in _records(path):
        kind = record.get("type")
        if kind == "thread.started":
            if SESSION_RE.match(record.get("thread_id") or ""):
                session_id = record["thread_id"]
        elif kind == "turn.started":
            started += 1
        elif kind == "turn.completed":
            usage = record.get("usage")
            if isinstance(usage, dict) and _is_count(usage.get("input_tokens")) and _is_count(usage.get("output_tokens")):
                cached = usage.get("cached_input_tokens")
                # The documented schema carries cached_input_tokens; without it fresh stays unavailable
                # (cached=None) rather than being invented as zero.
                if not (_is_count(cached) and cached <= usage["input_tokens"]):
                    cached = None
                reasoning = usage.get("reasoning_output_tokens")
                cache_write = usage.get("cache_write_input_tokens")
                snapshot = Usage(usage["input_tokens"], cached, usage["output_tokens"],
                                 reasoning=reasoning if _is_count(reasoning) else None,
                                 cache_write=cache_write if _is_count(cache_write) else None)
                # A re-delivered completion repeats the same cumulative counters (a real turn always grows
                # input): it is the same turn, not a second one.
                if not snapshots or snapshot != snapshots[-1]:
                    snapshots.append(snapshot)
                    completed += 1
            else:
                complete = False  # a completion whose counters cannot be read is not a measured turn
        elif kind == "item.completed":
            item = record.get("item")
            if isinstance(item, dict) and item.get("type") == "agent_message" and item.get("text"):
                message = item["text"]
        elif kind in ("turn.failed", "error"):
            complete = False
    return {"session_id": session_id, "snapshots": snapshots, "message": message,
            "complete": complete and started == completed}


def _is_count(value):
    return type(value) is int and value >= 0


class TurnEventStore:
    """Native turn events keyed by provider, session and turn: the durable input of the daily record.

    Every session's turns append in arrival order, each a cumulative snapshot. Because the counters are
    cumulative, re-delivering a stream changes nothing: a snapshot is stored only when its input grows past the
    session's last stored one, so duplicate events, retried harvests and out-of-order re-scans are absorbed
    instead of counted twice. A session whose last ingested invocation ended without completion events stays
    unavailable to session-level spend checks. Daily windows include its completed snapshots and list the session
    as incomplete, so its unobserved tail is never presented as a complete daily total. Tickets 16 and 21 move
    these keys to PostgreSQL unchanged when a second host arrives.
    """

    VERSION = 1

    def __init__(self, path):
        self.path, self.sessions = path, {}
        if not path:
            return
        try:
            with open(path, encoding="utf-8") as source:
                saved = json.load(source)
            if saved.get("version") == self.VERSION and isinstance(saved.get("sessions"), dict):
                self.sessions = saved["sessions"]
        except (OSError, ValueError, AttributeError):
            pass

    def save(self):
        if self.path:
            _write_json(self.path, {"version": self.VERSION, "provider": "codex", "sessions": self.sessions},
                        ensure_ascii=False)

    def ingest(self, session_id, snapshots, complete, at):
        """Merge one finished invocation's snapshots, stamped with the invocation's start."""
        session = self.sessions.setdefault(session_id, {"turns": [], "incomplete": False, "last_at": at})
        for usage in snapshots:
            last = session["turns"][-1] if session["turns"] else None
            if last is not None:
                if usage.input <= last["in"]:
                    continue  # already stored, or absorbed by a newer snapshot: never counted twice
                if usage.output < last["out"] or (
                        usage.cached is not None and last["cached"] is not None and usage.cached < last["cached"]):
                    complete = False  # the stream contradicts the stored counters; stop trusting its tail
                    break
            session["turns"].append({"in": usage.input, "cached": usage.cached, "out": usage.output, "ts": at})
        session["incomplete"] = not complete
        session["last_at"] = at

    def session_usage(self, session_id):
        """The session's cumulative usage as of its last stored snapshot; None when not covered."""
        session = self.sessions.get(session_id)
        if session is None:
            return None
        turns = session.get("turns") or []
        if not turns or session.get("incomplete"):
            raise Unavailable(f"codex session {session_id} has turns without a completion event")
        last = turns[-1]
        return Usage(last["in"], last["cached"], last["out"])

    def window_usage(self, window, legacy_baseline=None):
        """Every covered session's delta inside the window: the last snapshot of the window minus the newest
        snapshot before it began. Unreadable cached counters leave fresh unavailable (cached=None).

        Incomplete sessions contribute only their completed snapshots and are returned in
        Usage.incomplete_sessions; the window remains usable with explicit partial coverage.

        A session with no stored snapshot before the window may be a legacy one resumed under --json: its
        thread counters already include what the rollout reader counted earlier, so legacy_baseline(session_id)
        supplies the rollout's cumulative counters as of the window start (None when there is no earlier history)."""
        total = Usage(0, 0, 0)
        incomplete_sessions = []
        for session_id, session in sorted(self.sessions.items()):
            if session.get("incomplete") and window.contains(_event_time(session.get("last_at"))):
                incomplete_sessions.append(session_id)
            inside = baseline = None
            for turn in session.get("turns") or []:
                stamp = _event_time(turn["ts"])
                if window.contains(stamp):
                    inside = turn                    # later snapshots of the same invocation win
                elif stamp.timestamp() < window.starts_at:
                    baseline = turn
            if inside is None:
                continue
            if baseline is None and legacy_baseline is not None:
                earlier = legacy_baseline(session_id)
                if earlier is not None:
                    baseline = {"in": earlier.input, "cached": earlier.cached, "out": earlier.output}
            if baseline is None:
                baseline = {"in": 0, "cached": None if inside["cached"] is None else 0, "out": 0}
            cached = None if inside["cached"] is None or baseline["cached"] is None \
                else inside["cached"] - baseline["cached"]
            total = total + Usage(inside["in"] - baseline["in"], cached, inside["out"] - baseline["out"])
        return Usage(total.input, total.cached, total.output, tuple(incomplete_sessions),
                     total.reasoning, total.cache_write)


# ---------- zcode CLI streams: the result line ----------

def zcode_stream_usage(path):
    """Usage of one zcode CLI invocation: the usage object of its last {"type":"result"} line.

    The result line closes one invocation, so its counters are that run's own total, never a
    cumulative thread snapshot. Counters follow the Anthropic shape (plain input, cache read,
    cache creation, output); a provider reporting Codex-style cached_input_tokens maps directly.
    Missing or invalid counters raise Unavailable: the run still counts as unknown, not zero."""
    usage = None
    try:
        for record in _records(path):
            if record.get("type") == "result" and isinstance(record.get("usage"), dict):
                usage = record["usage"]
    except OSError as error:
        raise Unavailable(f"cannot read {path}: {error}") from error
    if usage is None:
        raise Unavailable(f'no result line with usage in {path}')
    if not (_is_count(usage.get("input_tokens")) and _is_count(usage.get("output_tokens"))):
        raise Unavailable(f"invalid usage counters in the result line of {path}")
    cached = usage.get("cached_input_tokens")
    reasoning = usage.get("reasoningTokens", usage.get("reasoning_tokens", usage.get("reasoning_output_tokens")))
    cache_write = usage.get("cache_write_input_tokens")
    if _is_count(cached) and cached <= usage["input_tokens"]:
        return Usage(usage["input_tokens"], cached, usage["output_tokens"],
                     reasoning=reasoning if _is_count(reasoning) else None,
                     cache_write=cache_write if _is_count(cache_write) else None)  # Codex-style subset
    if _is_count(usage.get("cache_read_input_tokens")) and _is_count(usage.get("cache_creation_input_tokens")):
        # Anthropic style: cache read and cache creation are input-side tokens beside input_tokens
        return Usage(usage["input_tokens"] + usage["cache_read_input_tokens"] + usage["cache_creation_input_tokens"],
                     usage["cache_read_input_tokens"], usage["output_tokens"],
                     reasoning=reasoning if _is_count(reasoning) else None,
                     cache_write=usage["cache_creation_input_tokens"])
    return Usage(usage["input_tokens"], None, usage["output_tokens"],
                 reasoning=reasoning if _is_count(reasoning) else None,
                 cache_write=cache_write if _is_count(cache_write) else None)


# ---------- Claude review logs: one record per API response ----------

def _claude_responses(path):
    """(timestamp, Usage) of each API response in a Claude log. A response with several content blocks is logged on
    several lines carrying the same message id and the same counters; it counts once."""
    seen = set()
    for record in _records(path):
        if record.get("type") != "assistant":
            continue
        message = record["message"]
        if message["id"] in seen:
            continue
        seen.add(message["id"])
        values = [message["usage"][name] for name in (
            "input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens")]
        if any(type(value) is not int or value < 0 for value in values):
            raise ValueError("invalid token counters")
        plain, cache_read, cache_creation, output = values
        reasoning = message["usage"].get("reasoning_output_tokens")
        yield record["timestamp"], Usage(plain + cache_read + cache_creation, cache_read, output,
                                          reasoning=reasoning if _is_count(reasoning) else None,
                                          cache_write=cache_creation)


def claude_session_usage(path):
    """Usage of one Claude session log."""
    try:
        return sum((usage for _, usage in _claude_responses(path)), Usage(0, 0, 0))
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise Unavailable(f"Cannot account for Claude session file: {path}: {error}") from error


def claude_unit_responses(projects_root, clone_root, unit):
    """Timestamped Claude responses for one worker worktree, for per-log attribution."""
    if not os.path.isdir(projects_root):
        raise Unavailable("Claude projects directory is unavailable")
    directory = _claude_directory_name(clone_root.rstrip("/") + "/wt-" + str(unit))
    project = os.path.join(projects_root, directory)
    responses = []
    for path in sorted(glob.glob("/".join([glob.escape(project), "*.jsonl"]))):
        try:
            responses.extend(_claude_responses(path))
        except (OSError, ValueError, KeyError, TypeError):
            continue
    return responses


# ---------- per-session reads for the report (read-only, no cache) ----------

def _last_call_usage(payload):
    info = payload.get("info") or {}
    last = info.get("last_token_usage") if isinstance(info, dict) else None
    if not isinstance(last, dict):
        return None
    values = [last.get(name) for name in ("input_tokens", "cached_input_tokens", "output_tokens")]
    if any(type(value) is not int or value < 0 for value in values) or values[1] > values[0]:
        return None
    reasoning = last.get("reasoning_output_tokens")
    cache_write = last.get("cache_write_input_tokens")
    return Usage(*values, reasoning=reasoning if _is_count(reasoning) else None,
                 cache_write=cache_write if _is_count(cache_write) else None)


def _function_call(payload):
    if not isinstance(payload, dict) or payload.get("type") not in ("function_call", "custom_tool_call"):
        return None
    arguments = payload.get("arguments", payload.get("input", {}))
    if isinstance(arguments, str):
        try:
            arguments = json.loads(arguments)
        except ValueError:
            arguments = {"text": arguments}
    return payload.get("name") or "", arguments if isinstance(arguments, dict) else {}, payload.get("call_id")


def _empty_stdin_call(name, arguments):
    if name.rsplit(".", 1)[-1] != "write_stdin" or not isinstance(arguments, dict):
        return False
    return arguments.get("chars", "") in ("", None)


def _document_reads(name, arguments):
    """Scoped process documents read/search calls observed in the same rollout records as token usage."""
    leaf = name.rsplit(".", 1)[-1].lower()
    text = json.dumps(arguments, ensure_ascii=False) if not isinstance(arguments, str) else arguments
    normalized = text.replace("\\/", "/")
    direct_reader = leaf in {"read", "read_file", "read_text", "cat", "sed", "head", "tail", "awk", "grep", "rg"} \
        or "read_file" in leaf or "read_text" in leaf
    shell_reader = leaf in {"exec", "exec_command", "bash", "shell"} and re.search(
        r"(?<![A-Za-z0-9_])(?:cat|sed|head|tail|awk|grep|rg|less|more|bat)\s", normalized
    ) is not None
    return {path for path in SCOPED_DOCUMENT_PATHS if path in normalized and (direct_reader or shell_reader)}


def _shell_write_call(name, arguments):
    """Recognize common shell file-writing commands in the recorded tool input."""
    if name.rsplit(".", 1)[-1].lower() not in {"exec", "exec_command", "shell", "bash"}:
        return False
    command = arguments.get("cmd") or arguments.get("command") or ""
    if isinstance(command, list):
        command = " ".join(str(part) for part in command)
    if not isinstance(command, str):
        return False
    return SHELL_WRITE_RE.search(command) is not None or (
        ">" in command and SHELL_REDIRECT_RE.search(QUOTED_RE.sub(" ", command)) is not None)


def _event_millis(value):
    if not isinstance(value, str):
        return None
    try:
        stamp = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return round(stamp.timestamp() * 1000)


def _tool_output(payload):
    if not isinstance(payload, dict) or payload.get("type") not in ("function_call_output", "custom_tool_call_output"):
        return None
    return payload.get("call_id"), payload.get("output")


def _output_details(value):
    if isinstance(value, dict):
        body = value.get("output", "")
        text = body if isinstance(body, str) else json.dumps(body, ensure_ascii=False)
        running = value.get("is_running") is True or value.get("running") is True \
            or (value.get("session_id") is not None and value.get("exit_code") is None)
        return text, running
    if isinstance(value, list):
        text = "\n".join(str(part.get("text", "")) for part in value if isinstance(part, dict))
    else:
        text = str(value or "")
    running = "Process running with session ID" in text
    if re.fullmatch(r"Process running with session ID(?: \S+)?", text.strip()):
        text = ""
    return text, running

def codex_session_stats(path):
    """One rollout's usage and report facts: turn actions, first-call input, polls, and scoped document reads."""
    started, turns, usage, first_input, awaiting = None, 0, None, [], False
    polls, polls_by_call, document_reads = [], {}, set()
    turn_facts, current_turn = [], None
    latest_call_usage = pending_poll_usage = None
    try:
        for record in _records(path):
            started = started or record.get("timestamp")
            payload = record.get("payload") or {}
            if record.get("type") == "event_msg" and isinstance(payload, dict) and payload.get("type") == "task_started":
                turns += 1
                awaiting = True
                latest_call_usage = pending_poll_usage = None
                current_turn = {"usage": Usage(0, 0, 0), "usage_seen": False, "usage_complete": True,
                                "patch_calls": 0, "shell_write_calls": 0}
                turn_facts.append(current_turn)
                continue
            totals = _codex_totals(record)
            if totals is not None:
                try:
                    usage = _codex_usage(totals)
                except ValueError:
                    continue
                last = (payload.get("info") or {}).get("last_token_usage")
                if awaiting and isinstance(last, dict) and type(last.get("input_tokens")) is int:
                    first_input.append(last["input_tokens"])
                    awaiting = False
                call_usage = _last_call_usage(payload)
                if current_turn is not None:
                    if call_usage is not None:
                        current_turn["usage"] += call_usage
                        current_turn["usage_seen"] = True
                    else:
                        current_turn["usage_complete"] = False
                if call_usage is not None:
                    if pending_poll_usage is not None:
                        pending_poll_usage["usage"] = call_usage
                        pending_poll_usage = None
                    else:
                        latest_call_usage = call_usage
                    continue

            if record.get("type") != "response_item":
                continue
            if call := _function_call(payload):
                name, arguments, call_id = call
                document_reads.update(_document_reads(name, arguments))
                if current_turn is not None:
                    leaf = name.rsplit(".", 1)[-1].lower()
                    if leaf == "apply_patch":
                        current_turn["patch_calls"] += 1
                    if _shell_write_call(name, arguments):
                        current_turn["shell_write_calls"] += 1
                if _empty_stdin_call(name, arguments):
                    yield_ms = arguments.get("yield_time_ms")
                    if type(yield_ms) is not int or yield_ms < 0:
                        yield_ms = None
                    poll = {
                        "yield_time_ms": yield_ms,
                        "session_id": str(arguments.get("session_id")) if arguments.get("session_id") is not None else None,
                        "called_at_ms": _event_millis(record.get("timestamp")),
                        "returned_at_ms": None,
                        "full_wait": False,
                        "usage": latest_call_usage,
                    }
                    latest_call_usage = None
                    polls.append(poll)
                    if call_id is not None:
                        polls_by_call[str(call_id)] = poll
                    if poll["usage"] is None:
                        pending_poll_usage = poll
                else:
                    latest_call_usage = None
                    pending_poll_usage = None
                continue

            if result := _tool_output(payload):
                call_id, output = result
                poll = polls_by_call.get(str(call_id)) if call_id is not None else None
                if poll is None:
                    continue
                poll["returned_at_ms"] = _event_millis(record.get("timestamp"))
                text, running = _output_details(output)
                yield_ms = poll["yield_time_ms"]
                called_at, returned_at = poll["called_at_ms"], poll["returned_at_ms"]
                elapsed_ms = returned_at - called_at if called_at is not None and returned_at is not None else None
                poll["full_wait"] = yield_ms is not None and yield_ms > 0 and yield_ms < 30_000 and (
                    (elapsed_ms is not None and elapsed_ms >= yield_ms) or (elapsed_ms is None and running and not text.strip())
                )
                if pending_poll_usage is poll:
                    pending_poll_usage = None
    except OSError as error:
        raise Unavailable(f"cannot read {path}: {error}") from error
    if usage is None:
        raise Unavailable(f"no valid cumulative token counters in {path}")
    public_turns = [{"usage": turn["usage"] if turn["usage_seen"] and turn["usage_complete"] else None,
                     "patch_calls": turn["patch_calls"], "shell_write_calls": turn["shell_write_calls"]}
                    for turn in turn_facts]
    return {"started": started, "turns": turns, "usage": usage, "first_input": first_input,
            "polls": polls, "document_reads": sorted(document_reads), "turn_facts": public_turns}


def _rollout_session_id(path):
    match = re.search(r"-([0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12})\.jsonl$", path)
    return match.group(1) if match else None


def codex_sessions_between(sessions_root, since, until):
    """{session_id: stats} of every rollout whose first record lies in [since, until] (ISO Z text). A rollout with no
    readable counters is skipped, not counted as zero."""
    found = {}
    pattern = "/".join([glob.escape(sessions_root), "*", "*", "*", "*.jsonl"])
    for path in sorted(glob.glob(pattern)):
        session_id = _rollout_session_id(path)
        if not session_id:
            continue
        try:
            stats = codex_session_stats(path)
        except Unavailable:
            continue
        if stats["started"] and since <= stats["started"][:19] + "Z" <= until:
            found[session_id] = stats
    return found


def claude_unit_sessions(projects_root, clone_root, since, until):
    """[(unit, Usage)] per Claude review-worker log, counting only responses inside [since, until] (ISO Z text)."""
    if not os.path.isdir(projects_root):
        raise Unavailable("Claude projects directory is unavailable")
    prefix = _claude_directory_name(clone_root.rstrip("/") + "/wt-")
    sessions = []
    for directory in sorted(os.listdir(projects_root)):
        if not directory.startswith(prefix):
            continue
        for path in sorted(glob.glob("/".join([glob.escape(projects_root), glob.escape(directory), "*.jsonl"]))):
            try:
                total = sum((u for stamp, u in _claude_responses(path) if since <= stamp[:19] + "Z" <= until), Usage(0, 0, 0))
            except (OSError, ValueError, KeyError, TypeError):
                continue
            if total.raw:
                sessions.append((directory[len(prefix):], total))
    return sessions


# ---------- windows and the identity cache ----------

class Window:
    """The span of time to count. Today: one local calendar day, which is what the daily meter measures."""

    def __init__(self, day, timezone_name):
        try:
            self._zone = ZoneInfo(timezone_name)
        except (ValueError, KeyError):
            raise Unavailable("Codex accounting timezone is unavailable") from None
        self.day_text, self.timezone_name = day, timezone_name
        self.starts_at = datetime.fromisoformat(day).replace(tzinfo=self._zone).timestamp()

    @classmethod
    def day(cls, day, timezone_name):
        return cls(day, timezone_name)

    def contains(self, stamp):
        return stamp.astimezone(self._zone).date().isoformat() == self.day_text


class IdentityCache:
    """Per-file usage inside one window, keyed by file identity (path, size, modification time), never by age.

    An unchanged log is not read again; a changed one is never trusted stale. Entries stay after a completed log
    is removed, so consumption already observed is not forgotten. The on-disk shape is the daily meter's version 2.
    """
    VERSION = 2

    def __init__(self, path, window):
        self.path, self.window = path, window
        self.entries = {}
        if not path:
            return
        try:
            with open(path, encoding="utf-8") as source:
                saved = json.load(source)
            if (saved.get("date"), saved.get("timezone"), saved.get("version")) == (
                    window.day_text, window.timezone_name, self.VERSION) and isinstance(saved.get("files"), dict):
                self.entries = saved["files"]
        except (OSError, ValueError, AttributeError):
            pass

    def refresh(self, file_path, parse):
        stat = os.stat(file_path)
        known = self.entries.get(file_path)
        if known and known.get("mtime_ns") == stat.st_mtime_ns and known.get("size") == stat.st_size:
            return
        if not known and stat.st_mtime < self.window.starts_at:
            # Not touched since before the window began, so it cannot hold an event inside it. A cross-day resume
            # updates the modification time of its original file, which is why only today's logs need reading.
            usage = Usage(0, 0, 0)
        else:
            usage = parse(file_path)
        self.entries[file_path] = {"mtime_ns": stat.st_mtime_ns, "size": stat.st_size,
                                   "in": usage.input, "cached": usage.cached, "out": usage.output}

    def total(self):
        return sum((Usage(item["in"], item["cached"], item["out"]) for item in self.entries.values()), Usage(0, 0, 0))

    def save(self):
        if self.path:
            _write_json(self.path, {"version": self.VERSION, "date": self.window.day_text,
                                    "timezone": self.window.timezone_name, "files": self.entries}, ensure_ascii=False)


def _event_time(text):
    stamp = datetime.fromisoformat(text.replace("Z", "+00:00"))
    if stamp.tzinfo is None:
        raise ValueError("token event timestamp has no timezone")
    return stamp


def _write_json(path, value, ensure_ascii):
    with open(path + ".tmp", "w", encoding="utf-8") as output:
        json.dump(value, output, ensure_ascii=ensure_ascii, separators=(",", ":"))
        output.write("\n")
    os.replace(path + ".tmp", path)


def _codex_file_window_usage(path, window):
    """The deltas of one rollout's cumulative counters that fall inside the window."""
    inside, last = Usage(0, 0, 0), Usage(0, 0, 0)
    for record in _records(path):
        totals = _codex_totals(record)
        if totals is None:
            continue
        counters = _codex_usage(totals)
        if window.contains(_event_time(record["timestamp"])):
            delta = Usage(counters.input - last.input, counters.cached - last.cached, counters.output - last.output)
            if min(delta.input, delta.cached, delta.output) < 0 or delta.cached > delta.input:
                raise ValueError("cumulative token counter reset within accounting day")
            inside += delta
        last = counters
    return inside


def _codex_file_usage_before(path, window):
    """The rollout's cumulative counters as of the window start; None when it has no earlier counters."""
    before = None
    for record in _records(path):
        totals = _codex_totals(record)
        if totals is not None and _event_time(record["timestamp"]).timestamp() < window.starts_at:
            before = _codex_usage(totals)
    return before


def _refresh(cache, paths, parse, label):
    for path in paths:
        try:
            cache.refresh(path, parse)
        except (OSError, ValueError, KeyError, TypeError) as error:
            raise Unavailable(f"Cannot account for {label} session file: {path}: {error}") from error


def codex_window_usage(sessions_root, window, cache_path=None, events_path=None):
    """Usage of every Codex session inside the window: native turn events for the sessions the store covers,
    rollout parsing only for legacy sessions the store has never seen."""
    if not os.path.isdir(sessions_root):
        raise Unavailable("Codex sessions directory is unavailable")
    store = TurnEventStore(events_path) if events_path else None
    covered = set(store.sessions) if store else set()
    cache = IdentityCache(cache_path, window)
    paths = sorted(glob.glob("/".join([glob.escape(sessions_root), "*", "*", "*", "*.jsonl"])))
    _refresh(cache, (path for path in paths if _rollout_session_id(path) not in covered),
             lambda path: _codex_file_window_usage(path, window), "Codex")
    for stale in [path for path in cache.entries if _rollout_session_id(path) in covered]:
        # The store now owns this session (first seen mid-run, harvested since); keep its tokens out of both
        # places — the store's snapshots include every turn the cached entry held.
        del cache.entries[stale]
    cache.save()
    total = cache.total()
    if store:
        rollouts = {_rollout_session_id(path): path for path in paths}

        def legacy_baseline(session_id):
            path = rollouts.get(session_id)
            try:
                return _codex_file_usage_before(path, window) if path else None
            except (OSError, ValueError, KeyError, TypeError) as error:
                raise Unavailable(f"Cannot account for Codex session file: {path}: {error}") from error

        total = total + store.window_usage(window, legacy_baseline)
    return total


def _claude_file_window_usage(path, window):
    return sum((usage for stamp, usage in _claude_responses(path) if window.contains(_event_time(stamp))),
               Usage(0, 0, 0))


def claude_window_usage(projects_root, clone_root, window, cache_path=None):
    """Usage of the review workers' Claude logs inside the window, as {unit: Usage}.

    Claude keeps one log directory per working directory, named after it with every non-alphanumeric character
    replaced by '-'. A worker runs in <clone_root>/wt-<unit>, so the directory name carries the unit. Logs of any
    other working directory (the CTO and supervisor sessions) are not covered.
    """
    if not os.path.isdir(projects_root):
        raise Unavailable("Claude projects directory is unavailable")
    prefix = _claude_directory_name(clone_root.rstrip("/") + "/wt-")
    cache = IdentityCache(cache_path, window)
    paths = []
    for directory in sorted(os.listdir(projects_root)):
        if directory.startswith(prefix):
            paths += sorted(glob.glob("/".join([glob.escape(projects_root), glob.escape(directory), "*.jsonl"])))
    _refresh(cache, paths, lambda path: _claude_file_window_usage(path, window), "Claude")
    cache.save()
    by_unit = {}
    for path, entry in cache.entries.items():
        directory = os.path.basename(os.path.dirname(path))
        if directory.startswith(prefix):
            unit = directory[len(prefix):]
            by_unit[unit] = by_unit.get(unit, Usage(0, 0, 0)) + Usage(entry["in"], entry["cached"], entry["out"])
    return by_unit


def _claude_directory_name(working_directory):
    return re.sub(r"[^A-Za-z0-9]", "-", working_directory)


# ---------- command line, for the scheduler ----------

def _print_json(value):
    print(json.dumps(value, separators=(",", ":")))


PROVISIONAL_DAYS = 7


def daily_bound(history, day):
    """Healthy near p50 x 1.5 and unhealthy near p90 x 2 of the fresh totals of the days before `day`. Provisional
    until PROVISIONAL_DAYS completed days exist; None when there is no completed day to measure."""
    days = sorted(value for date, value in history.items() if date < day and type(value) is int and value >= 0)
    if not days:
        return None

    def percentile(fraction):
        return days[min(len(days) - 1, int(fraction * len(days)))]
    return {"healthy": int(percentile(0.5) * 1.5), "unhealthy": int(percentile(0.9) * 2), "days": len(days),
            "provisional": len(days) < PROVISIONAL_DAYS}


def _provider_fields(usage, sessions):
    return {"fresh": usage.fresh, "raw": usage.raw, "in": usage.input, "cached": usage.cached, "out": usage.output,
            "sessions": sessions}


def _codex_day(sessions_root, day, timezone_name, output_path, cache_path, claude_projects="", clone_root=""):
    """The daily meter's record. Cached input is a subset of input, not a third additive component.

    total/in/cached/out keep their meaning (Codex raw). fresh and raw are fleet-wide (Codex plus worker Claude);
    providers splits them. New Codex sessions are keyed by provider/session/turn in the native event store next
    to this record, legacy ones by log file in the identity caches, so a retry or a re-scan replaces an entry and
    cannot inflate a total. CTO and supervisor Claude sessions are outside the meter."""
    window = Window.day(day, timezone_name)
    events_path = (os.path.join(os.path.dirname(cache_path) or ".", "budget-events.json")
                   if cache_path else None)  # the same file the scheduler's harvest ingests into
    try:
        usage = codex_window_usage(sessions_root, window, cache_path, events_path)
        providers = {"codex": _provider_fields(usage, None)}
        if claude_projects and clone_root:
            claude_cache = (cache_path + ".claude") if cache_path else None
            by_unit = claude_window_usage(claude_projects, clone_root, window, claude_cache)
            claude = sum(by_unit.values(), Usage(0, 0, 0))
            providers["claude"] = _provider_fields(claude, len(by_unit))
    except Unavailable as error:
        _write_json(output_path, {"date": day, "status": "unavailable", "total": None, "in": None, "cached": None,
                                  "out": None, "error": str(error)}, ensure_ascii=True)
        print(error, file=sys.stderr)
        return 1
    # A provider whose cached counters never arrived reports fresh as unavailable (None), never a partial sum.
    fresh = sum(item["fresh"] for item in providers.values()) \
        if all(type(item["fresh"]) is int for item in providers.values()) else None
    raw = sum(item["raw"] for item in providers.values())
    history_path = os.path.join(os.path.dirname(output_path) or ".", "budget-history.json")
    try:
        with open(history_path, encoding="utf-8") as source:
            history = json.load(source)
        if not isinstance(history, dict):
            history = {}
    except (OSError, ValueError):
        history = {}
    bound = daily_bound(history, day)
    history_changed = False
    if type(fresh) is int and not usage.incomplete_sessions:
        history[day] = fresh
        history_changed = True
    elif usage.incomplete_sessions and day in history:
        del history[day]
        history_changed = True
    if history_changed:
        _write_json(history_path, history, ensure_ascii=False)
    status = "partial" if usage.incomplete_sessions else "measured"
    record = {"date": day, "status": status, "total": usage.raw,
              "in": usage.input, "cached": usage.cached, "out": usage.output,
              "fresh": fresh, "raw": raw, "providers": providers, "bound": bound,
              "outside_meter": "CTO and supervisor Claude sessions"}
    if usage.incomplete_sessions:
        record["incomplete_sessions"] = list(usage.incomplete_sessions)
    _write_json(output_path, record, ensure_ascii=False)
    print(json.dumps(record, ensure_ascii=False, separators=(",", ":")))
    return 0


def main(argv):
    command, args = argv[0], argv[1:]
    if command == "codex-session-file":
        path = find_codex_session_file(*args)
        if path:
            print(path)
        return 0
    if command == "codex-session-usage":
        sessions_root, session_id, *rest = args
        events_path = rest[0] if rest else None
        try:
            usage = None
            store = TurnEventStore(events_path) if events_path else None
            if store is not None:
                usage = store.session_usage(session_id)  # None when only legacy rollout parsing can answer
            if usage is None:
                path = find_codex_session_file(sessions_root, session_id)
                usage = codex_session_usage(path) if path else None
            _print_json(usage.ledger_fields() if usage is not None else None)
        except Unavailable:
            _print_json(None)
        return 0
    if command == "codex-stream":
        facts = codex_stream_facts(args[0])
        last = facts["snapshots"][-1] if facts["snapshots"] else None
        _print_json({"session_id": facts["session_id"], "fresh": last.fresh if last else None,
                     "complete": facts["complete"], "message": facts["message"]})
        return 0
    if command == "codex-ingest":
        log_path, fallback_session_id, started_at, events_path = args[:4]
        in_flight = len(args) > 4 and args[4] == "in-flight"
        facts = codex_stream_facts(log_path)
        session_id = facts["session_id"] or fallback_session_id
        if not session_id or not SESSION_RE.match(session_id):
            return 0  # a legacy-format log: the rollout reader still measures its session
        if not facts["snapshots"] and facts["complete"] and not in_flight:
            return 0  # nothing was consumed; there is no turn to record
        try:
            _event_time(started_at)
        except ValueError:
            started_at = datetime.fromtimestamp(os.path.getmtime(log_path), timezone.utc) \
                .isoformat().replace("+00:00", "Z")
        store = TurnEventStore(events_path)
        store.ingest(session_id, facts["snapshots"], facts["complete"] and not in_flight, started_at)
        store.save()
        return 0
    if command == "codex-day":
        return _codex_day(*args)
    print(f"usage_reader.py: unknown command {command}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
