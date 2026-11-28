#!/usr/bin/env python3
# Unattended /retro stage: select and validate candidates, then route each kept candidate.
# Usage: retro.py select <scratch-root> <n>            prints the chosen session keys, sorted
#        retro.py filter <scratch-root> <keys> <raw.json> <out.json>   writes kept candidates and drop counts
#        retro.py publish <scratch-root> <repo-root> <candidates.json> routes kept candidates
import datetime
import glob
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from collections import Counter

CATEGORIES = {"navigation", "automated-checks", "coding-standards", "global-agents-md",
              "tool-economy", "no-ops", "information-access"}
SEVERITIES = {"low", "medium", "high"}
NORMAL_SAMPLE_SIZE = 10


def select(root, n):
    done = []
    for d in glob.glob(os.path.join(root, "luna", "*")):
        key = os.path.basename(d)
        rc = os.path.join(d, "rc")
        # rc is written when a worker ends; a retro run is not an input to the next retro.
        if key.startswith("retro-") or not os.path.isfile(rc):
            continue
        done.append((os.path.getmtime(rc), key))
    done.sort(reverse=True)
    return sorted(key for _, key in done[:n])


def event_lines(root, key):
    path = os.path.join(root, "luna", key, "events.jsonl")
    if not os.path.isfile(path):
        return 0
    with open(path, encoding="utf-8", errors="replace") as f:
        return sum(1 for _ in f)


def filter_candidates(root, keys, raw):
    dropped = Counter()
    kept = []
    counts = {}
    for c in raw.get("candidates", []):
        if not isinstance(c, dict):
            dropped["malformed"] += 1
            continue
        key = c.get("session_key")
        line = c.get("event_line")
        if c.get("category") not in CATEGORIES:
            dropped["bad_category"] += 1
        elif c.get("severity") not in SEVERITIES:
            dropped["bad_severity"] += 1
        elif key not in keys:
            dropped["unknown_session"] += 1
        elif not isinstance(line, int) or isinstance(line, bool):
            dropped["no_event_position"] += 1
        else:
            if key not in counts:
                counts[key] = event_lines(root, key)
            if not 1 <= line <= counts[key]:
                dropped["event_line_out_of_range"] += 1
            elif not isinstance(c.get("proposal"), str) or not c["proposal"].strip():
                dropped["missing_proposal"] += 1
            else:
                kept.append(c)
    return {"candidates": kept, "dropped": dict(dropped), "total": len(kept) + sum(dropped.values())}


def event_at(root, candidate):
    session = candidate.get("session_key")
    line = candidate.get("event_line")
    if (not isinstance(session, str) or session in (".", "..") or
            os.path.basename(session) != session):
        raise ValueError("candidate has an invalid session_key")
    if not isinstance(line, int) or isinstance(line, bool) or line < 1:
        raise ValueError("candidate has an invalid event_line")
    path = os.path.join(root, "luna", session, "events.jsonl")
    with open(path, encoding="utf-8", errors="replace") as events:
        for number, event in enumerate(events, 1):
            if number == line:
                return event.rstrip("\r\n")
    raise ValueError(f"candidate event line is missing: {session}:{line}")


def source_event(candidate):
    return {"session_key": candidate["session_key"], "event_line": candidate["event_line"]}


def valid_lineage_id(value):
    return isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,159}", value) is not None


def known_lineage_ids(repo, out_dir):
    ids = set()
    rules_path = os.path.join(repo, "lessons", "RULES.md")
    if os.path.isfile(rules_path):
        with open(rules_path, encoding="utf-8", errors="replace") as rules:
            ids.update(re.findall(r"\*\*(V[A-Z0-9-]+)\*\*", rules.read()))
    for directory in ("full", "pending"):
        for path in glob.glob(os.path.join(repo, "lessons", directory, "*")):
            if os.path.isfile(path):
                ids.add(os.path.splitext(os.path.basename(path))[0])
    state = read_verify_state(out_dir)
    for change in state["changes"]:
        for key in ("lineage_id", "class", "lesson"):
            value = change.get(key)
            if valid_lineage_id(value):
                ids.add(value)
        issue = change.get("issue")
        if isinstance(issue, int) and not isinstance(issue, bool) and issue > 0:
            ids.add(f"issue:{issue}")
    return sorted(ids)


def lineage_context(repo, out_dir):
    ids = known_lineage_ids(repo, out_dir)
    return "Earlier lesson or candidate IDs for derived_from: " + (", ".join(ids) if ids else "none recorded")


def candidate_lineage(repo, out_dir, candidate):
    parents = candidate.get("derived_from", [])
    if not isinstance(parents, list) or any(not valid_lineage_id(parent) for parent in parents):
        return [], "derived_from must contain only valid earlier lesson or candidate ids"
    parents = list(dict.fromkeys(parents))
    unknown = sorted(set(parents) - set(known_lineage_ids(repo, out_dir)))
    if unknown:
        return parents, "unknown earlier lesson or candidate ids: " + ", ".join(unknown)
    return parents, None


def session_events(root, key):
    path = os.path.join(root, "luna", key, "events.jsonl")
    if not os.path.isfile(path):
        return None
    events = []
    try:
        with open(path, encoding="utf-8") as event_file:
            for line in event_file:
                if not line.strip():
                    continue
                event = json.loads(line)
                if not isinstance(event, dict):
                    return None
                events.append(event)
    except (OSError, json.JSONDecodeError):
        return None
    return events if events else None


def normal_session_samples(root, excluded):
    sessions = []
    for directory in glob.glob(os.path.join(root, "luna", "*")):
        key = os.path.basename(directory)
        rc_path = os.path.join(directory, "rc")
        if key.startswith("retro-") or key in excluded or not os.path.isfile(rc_path):
            continue
        try:
            with open(rc_path, encoding="utf-8") as rc_file:
                if rc_file.read().strip() != "0":
                    continue
            events = session_events(root, key)
        except OSError:
            continue
        if events is not None:
            sessions.append((os.path.getmtime(rc_path), key, events))
    sessions.sort(reverse=True)
    return sessions[:NORMAL_SAMPLE_SIZE]


def event_matches(event, matcher):
    if not isinstance(event, dict) or not isinstance(matcher, dict) or not matcher:
        return False
    for field, expected in matcher.items():
        if not isinstance(field, str) or not field or field not in event:
            return False
        actual = event[field]
        if isinstance(expected, dict):
            if not expected or not event_matches(actual, expected):
                return False
        elif actual != expected:
            return False
    return True


def measure_check(root, candidate):
    matcher = candidate.get("check")
    if not isinstance(matcher, dict) or not matcher:
        return None, "no check matcher was provided"
    try:
        event = json.loads(event_at(root, candidate))
    except (OSError, ValueError, json.JSONDecodeError):
        return None, "source event is not a readable JSON object"
    if not event_matches(event, matcher):
        return None, "check matcher did not fire on the source event"
    samples = normal_session_samples(root, {candidate["session_key"]})
    if len(samples) < NORMAL_SAMPLE_SIZE:
        return None, f"only {len(samples)} of {NORMAL_SAMPLE_SIZE} normal sessions is available"
    for _, key, events in samples:
        if any(event_matches(normal_event, matcher) for normal_event in events):
            return None, f"check matcher also fired on normal session {key}"
    return {
        "status": "passed",
        "source_match": True,
        "normal_sessions": [key for _, key, _ in samples],
        "matched_normal_events": 0,
    }, None


def measure_paired_eval(engine, candidate, candidate_id):
    pattern = r"[A-Za-z0-9][A-Za-z0-9._-]*"
    if not isinstance(candidate_id, str) or re.fullmatch(pattern, candidate_id) is None:
        return None, "candidate id cannot form paired eval labels"
    baseline = f"retro-base-{candidate_id}"
    candidate_label = f"retro-cand-{candidate_id}"
    runner = os.path.join(engine, "eval", "run-eval.mjs")
    eval_home = (os.environ.get("AGENT_HOME") or os.environ.get("ZF_HOME")
                 or os.path.join(os.path.expanduser("~"), ".zenoforge"))
    baseline_results = os.path.join(eval_home, "eval", baseline, "results.json")
    candidate_results = os.path.join(eval_home, "eval", candidate_label, "results.json")
    lesson_fragment = candidate["proposal"].strip()
    try:
        with tempfile.TemporaryDirectory(prefix="retro-eval-") as scratch:
            lesson_path = os.path.join(scratch, "lesson.md")
            with open(lesson_path, "w", encoding="utf-8") as lesson_file:
                lesson_file.write(lesson_fragment + "\n")
            for label, result_path, extra in (
                (baseline, baseline_results, []),
                (candidate_label, candidate_results, ["--lesson-fragment", lesson_path]),
            ):
                command = ["node", runner, "--label", label, "--no-route-fresh-agent-issues", *extra]
                if os.path.isfile(result_path):
                    command.append("--resume")
                result = subprocess.run(command, capture_output=True, text=True,
                                        encoding="utf-8", errors="replace")
                if result.returncode != 0:
                    detail = (result.stderr or result.stdout).strip()
                    return None, f"run-eval {label} failed: {detail[-600:]}"
            result = subprocess.run(
                ["node", runner, "--compare", baseline, candidate_label],
                capture_output=True, text=True, encoding="utf-8", errors="replace",
            )
    except OSError as exc:
        return None, f"run-eval could not start: {exc}"
    output = (result.stdout or "").strip()
    if result.returncode != 0:
        detail = (result.stderr or output).strip()
        return None, f"run-eval --compare failed: {detail[-600:]}"
    label_summary = re.compile(
        rf"^{re.escape(baseline)}: [0-9]+/[0-9]+; {re.escape(candidate_label)}: [0-9]+/[0-9]+$"
    )
    if not any(label_summary.fullmatch(line) for line in output.splitlines()):
        return None, "paired eval labels do not match candidate id"
    try:
        with open(baseline_results, encoding="utf-8") as results_file:
            baseline_data = json.load(results_file)
        with open(candidate_results, encoding="utf-8") as results_file:
            candidate_data = json.load(results_file)
    except (OSError, ValueError) as exc:
        return None, f"paired eval result labels are unreadable: {exc}"
    if not isinstance(baseline_data, dict) or not isinstance(candidate_data, dict):
        return None, "paired eval result labels are invalid"
    if (baseline_data.get("label") != baseline or candidate_data.get("label") != candidate_label
            or "lessonFragmentSha" not in baseline_data or baseline_data.get("lessonFragmentSha") is not None
            or candidate_data.get("lessonFragmentSha") != hashlib.sha256(lesson_fragment.encode("utf-8")).hexdigest()):
        return None, "paired eval labels do not match candidate id"
    try:
        live_revision = subprocess.run(
            ["git", "-C", engine, "rev-parse", "HEAD"],
            capture_output=True, text=True, encoding="utf-8", errors="replace",
        )
    except OSError as exc:
        return None, f"paired eval live engine revision could not be read: {exc}"
    if live_revision.returncode != 0 or not live_revision.stdout.strip():
        return None, "paired eval live engine revision could not be read"
    if (not isinstance(baseline_data.get("suiteSha"), str) or not baseline_data["suiteSha"]
            or baseline_data.get("suiteSha") != live_revision.stdout.strip()
            or baseline_data.get("suiteSha") != candidate_data.get("suiteSha")
            or not isinstance(baseline_data.get("caseSetSha"), str) or not baseline_data["caseSetSha"]
            or baseline_data.get("caseSetSha") != candidate_data.get("caseSetSha")
            or not isinstance(baseline_data.get("policy"), dict)
            or baseline_data.get("policy") != candidate_data.get("policy")
            or not isinstance(baseline_data.get("overrides"), list)
            or baseline_data.get("overrides") != candidate_data.get("overrides")):
        return None, "paired eval labels did not use the same engine and model policy"
    regressions = [line for line in output.splitlines() if line.startswith("REGRESSION pass→fail ")]
    if regressions:
        return None, f"paired eval {baseline} → {candidate_label} found pass-to-fail regression: " + "; ".join(regressions)
    unpaired = [line for line in output.splitlines() if line.startswith("UNPAIRED ")]
    if unpaired:
        return None, f"paired eval {baseline} → {candidate_label} has unpaired cases: " + "; ".join(unpaired)
    paired_line = next((line for line in output.splitlines() if line.startswith("compared in both labels: ")), None)
    if paired_line is None or paired_line.endswith(": none"):
        return None, "paired eval compared no frozen cases"
    if "pass→fail: none" not in output.splitlines():
        return None, "paired eval did not report a zero-regression comparison"
    paired_text = paired_line.split(": ", 1)[1]
    return {
        "status": "passed",
        "baseline": baseline,
        "candidate": candidate_label,
        "paired_cases": [case.strip() for case in paired_text.split(",")],
        "regressions": 0,
    }, None


def candidate_class(engine, category, event):
    helper = os.path.join(engine, "mac-autopilot", "incident-fingerprint.sh")
    script = 'source "$1"; fingerprint="$(incident_fingerprint "$3")"; incident_class "$2 $fingerprint"'
    # Keep the event category in the shared issue-upsert class key.
    result = subprocess.run(
        ["bash", "-c", script, "retro-class", helper, category, event],
        check=True, capture_output=True, text=True,
    )
    return result.stdout.strip()


def verify_state_path(out_dir):
    return os.path.join(out_dir, "retro-verify.json")


def read_verify_state(out_dir):
    path = verify_state_path(out_dir)
    if not os.path.isfile(path):
        return {"changes": [], "observations": [], "events": []}
    with open(path, encoding="utf-8") as state_file:
        state = json.load(state_file)
    if (not isinstance(state, dict) or not isinstance(state.get("changes"), list)
            or not isinstance(state.get("observations", []), list)
            or not isinstance(state.get("events", []), list)):
        raise ValueError(f"invalid retro verification state: {path}")
    state.setdefault("observations", [])
    state.setdefault("events", [])
    return state


def write_verify_state(out_dir, state):
    os.makedirs(out_dir, exist_ok=True)
    fd, temp_path = tempfile.mkstemp(prefix="retro-verify-", dir=out_dir)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as state_file:
            json.dump(state, state_file, ensure_ascii=False, indent=2)
            state_file.write("\n")
        os.replace(temp_path, verify_state_path(out_dir))
    finally:
        if os.path.exists(temp_path):
            os.unlink(temp_path)


def retro_out_dir():
    return os.environ.get(
        "RETRO_OUT_DIR", os.path.join(os.environ.get("HOME", "/tmp"), ".zenoforge", "retro")
    )


def merge_record_values(record, field, values):
    merged = record.get(field, [])
    for value in values:
        if value not in merged:
            merged.append(value)
    record[field] = merged


def record_observation(out_dir, candidate, key, parents, reason):
    state = read_verify_state(out_dir)
    source = source_event(candidate)
    identity = (key, source["session_key"], source["event_line"])
    observations = state["observations"]
    if not any((row.get("class"), row.get("source_event", {}).get("session_key"),
                row.get("source_event", {}).get("event_line")) == identity for row in observations):
        observations.append({
            "class": key,
            "lineage_id": key,
            "category": candidate["category"],
            "severity": candidate["severity"],
            "proposal": candidate["proposal"],
            "source_event": source,
            "derived_from": parents,
            "reason": reason,
            "observed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        })
        write_verify_state(out_dir, state)


def record_candidate_issue(out_dir, issue, category, key, candidate):
    state = read_verify_state(out_dir)
    change = next((row for row in state["changes"] if row.get("issue") == issue), None)
    if change is None:
        change = {
            "issue": issue,
            "category": category,
            "class": key,
            "lineage_id": key,
            "derived_from": candidate["derived_from"],
            "sources": [source_event(candidate)],
            "filed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        }
        state["changes"].append(change)
    else:
        merge_record_values(change, "sources", [source_event(candidate)])
        merge_record_values(change, "derived_from", candidate["derived_from"])
    write_verify_state(out_dir, state)


def record_lesson_change(out_dir, category, key, candidate, admission):
    state = read_verify_state(out_dir)
    change = next((row for row in state["changes"] if row.get("lesson") == key), None)
    if change is None:
        change = {
            "lesson": key,
            "category": category,
            "class": key,
            "lineage_id": key,
            "derived_from": candidate["derived_from"],
            "sources": [source_event(candidate)],
            "check": candidate["check"],
            "engine_version": candidate["engine_version"],
            "admission": admission,
            "verifiable": True,
            "reason": "measured event check is admitted as a lesson fragment and verified in its engine version around its admission window",
            "filed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        }
        state["changes"].append(change)
    else:
        merge_record_values(change, "sources", [source_event(candidate)])
        merge_record_values(change, "derived_from", candidate["derived_from"])
    write_verify_state(out_dir, state)


def session_engine_version(root, key):
    path = os.path.join(root, "luna", key, "engine-version")
    try:
        with open(path, encoding="utf-8") as version_file:
            version = version_file.read().strip()
    except OSError:
        return None
    return version if re.fullmatch(r"[A-Za-z0-9._-]{1,128}", version) else None


def withdrawn_lessons(out_dir):
    return {
        change["lesson"]
        for change in read_verify_state(out_dir)["changes"]
        if change.get("verdict") == "withdrawn" and isinstance(change.get("lesson"), str)
    }


def withdraw_lesson_fragment(repo, lesson_id):
    if not isinstance(lesson_id, str) or not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", lesson_id):
        raise ValueError("lesson ID cannot name a fragment")
    lesson_dir = os.path.join(repo, "lessons")
    removed = []
    for relative in (f"pending/{lesson_id}.json", f"full/{lesson_id}.md"):
        path = os.path.join(lesson_dir, relative)
        if os.path.isfile(path):
            os.unlink(path)
            removed.append(f"lessons/{relative}")
    marker = f'<a id="v-next-{lesson_id}"></a>'
    rules_path = os.path.join(lesson_dir, "RULES.md")
    if os.path.isfile(rules_path):
        with open(rules_path, encoding="utf-8") as rules_file:
            rules = rules_file.read()
        sections = rules.split("\n\n")
        kept = [section for section in sections if marker not in section]
        if len(kept) != len(sections):
            with open(rules_path, "w", encoding="utf-8") as rules_file:
                rules_file.write("\n\n".join(kept))
            removed.append("lessons/RULES.md")
    catalog_path = os.path.join(lesson_dir, "CATALOG.md")
    if os.path.isfile(catalog_path):
        with open(catalog_path, encoding="utf-8") as catalog_file:
            lines = catalog_file.readlines()
        kept = [line for line in lines if f"RULES.md#v-next-{lesson_id}" not in line]
        if len(kept) != len(lines):
            with open(catalog_path, "w", encoding="utf-8") as catalog_file:
                catalog_file.writelines(kept)
            removed.append("lessons/CATALOG.md")
    return removed


def write_lesson_fragment(repo, candidate, key, admission):
    lesson_id = key
    pending_dir = os.path.join(repo, "lessons", "pending")
    full_path = os.path.join(repo, "lessons", "full", f"{lesson_id}.md")
    pending_path = os.path.join(pending_dir, f"{lesson_id}.json")
    if os.path.exists(full_path) or os.path.exists(pending_path):
        return
    os.makedirs(pending_dir, exist_ok=True)
    os.makedirs(os.path.dirname(full_path), exist_ok=True)
    proposal = candidate["proposal"].strip()
    evidence = candidate.get("evidence", "")
    full_lesson = (
        f"# Retro proposal: {candidate['category']}\n\n"
        f"## Proposed check\n\n{proposal}\n\n"
        f"## Evidence\n\n"
        f"- Severity: {candidate['severity']}\n"
        f"- Session: {candidate['session_key']}\n"
        f"- Event line: {candidate['event_line']} in events.jsonl\n"
        f"- Engine version: {candidate['engine_version']}\n"
        f"- Derived from: {', '.join(candidate['derived_from']) or 'none recorded'}\n"
        f"- Matcher: `{json.dumps(candidate['check'], sort_keys=True)}`\n"
        f"- Admission: matched the source event and stayed silent in {len(admission['normal_sessions'])} normal sessions\n"
        f"- Paired evaluation: zero regressions across {len(admission['paired_eval']['paired_cases'])} frozen cases\n"
        f"- Observation: {evidence}\n\n"
        "The pending rule is [V-NEXT](../RULES.md#v-next).\n"
    )
    fragment = {
        "id": lesson_id,
        "category": candidate["category"],
        "rule": '<a id="v-next"></a>\n**V-NEXT** Add the deterministic check described in the full lesson.',
        "catalog_entry": f"Applies: [V-NEXT](RULES.md#v-next); full: ./full/{lesson_id}.md",
        "full_lesson_path": f"lessons/full/{lesson_id}.md",
        "engine_version": candidate["engine_version"],
        "source_event": source_event(candidate),
        "derived_from": candidate["derived_from"],
        "check": candidate["check"],
        "admission": admission,
    }
    with open(full_path, "w", encoding="utf-8") as full_file:
        full_file.write(full_lesson)
    with open(pending_path, "w", encoding="utf-8") as fragment_file:
        json.dump(fragment, fragment_file, ensure_ascii=False, indent=2)
        fragment_file.write("\n")


def file_intake_candidate(repo, engine, candidate, key):
    proposal = " ".join(candidate["proposal"].split())
    title = f"Retro: {proposal}"[:180]
    body = (
        "## Retro candidate\n\n"
        f"- Category: {candidate['category']}\n"
        f"- Severity: {candidate['severity']}\n"
        f"- Fingerprint: {key}\n"
        f"- Source: {candidate['session_key']} events.jsonl line {candidate['event_line']}\n"
        f"- Lineage ID: {key}\n"
        f"- Derived from: {', '.join(candidate['derived_from']) or 'none recorded'}\n"
        "- Activation gate: the existing paired eval must pass before changed instructions become live.\n\n"
        f"## Proposal\n\n{candidate['proposal']}\n\n"
        f"## Evidence\n\n{candidate.get('evidence', '')}\n"
    )
    fd, body_path = tempfile.mkstemp(prefix="retro-intake-", suffix=".md")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as body_file:
            body_file.write(body)
        env = os.environ.copy()
        env["ZF_REPO_DIR"] = repo
        env["ZF_ENGINE_DIR"] = engine
        result = subprocess.run(
            ["bash", os.path.join(engine, "pipeline-issue-upsert.sh"),
             "--lane", "product", "--class", key, "--title", title, "--body-file", body_path],
            check=True, stdout=subprocess.PIPE, text=True, env=env,
        )
        print(result.stdout, end="")
        match = re.search(r"(?:created \S+/issues/|commented issue #)([1-9][0-9]*)", result.stdout)
        if not match:
            raise ValueError("pipeline issue upsert returned no issue number")
        record_candidate_issue(retro_out_dir(), int(match.group(1)), candidate["category"], key, candidate)
    finally:
        os.unlink(body_path)


def publish_candidates(root, repo, candidates_path):
    engine = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    out_dir = retro_out_dir()
    with open(candidates_path, encoding="utf-8") as candidates_file:
        document = json.load(candidates_file)
    candidates = document.get("candidates") if isinstance(document, dict) else None
    if not isinstance(candidates, list):
        raise ValueError("candidate file has no candidates array")
    withdrawn = withdrawn_lessons(out_dir)
    for candidate in candidates:
        if (not isinstance(candidate, dict) or candidate.get("category") not in CATEGORIES
                or candidate.get("severity") not in SEVERITIES):
            raise ValueError("candidate file contains an invalid candidate")
        if (not isinstance(candidate.get("proposal"), str) or not candidate["proposal"].strip()
                or not isinstance(candidate.get("evidence"), str)):
            raise ValueError("candidate file contains an invalid proposal or evidence")
        event = event_at(root, candidate)
        key = candidate_class(engine, candidate["category"], event)
        candidate = dict(candidate)
        if candidate["category"] == "automated-checks" and key in withdrawn:
            print(f"retro.py: candidate {key} remains withdrawn")
            continue
        parents, lineage_error = candidate_lineage(repo, out_dir, candidate)
        candidate["derived_from"] = parents
        if lineage_error:
            record_observation(out_dir, candidate, key, parents, lineage_error)
            print(f"retro.py: candidate {key} kept as an observation: {lineage_error}")
            continue
        if candidate["category"] == "automated-checks":
            candidate["engine_version"] = session_engine_version(root, candidate["session_key"])
            if candidate["engine_version"] is None:
                record_observation(out_dir, candidate, key, parents, "source session has no recorded engine version")
                print(f"retro.py: candidate {key} kept as an observation: source session has no recorded engine version")
                continue
            admission, measurement_error = measure_check(root, candidate)
            if measurement_error:
                record_observation(out_dir, candidate, key, parents, measurement_error)
                print(f"retro.py: candidate {key} kept as an observation: {measurement_error}")
                continue
            paired_eval, eval_error = measure_paired_eval(engine, candidate, key)
            if eval_error:
                record_observation(out_dir, candidate, key, parents, eval_error)
                print(f"retro.py: candidate {key} kept as an observation: {eval_error}")
                continue
            admission["paired_eval"] = paired_eval
            write_lesson_fragment(repo, candidate, key, admission)
            record_lesson_change(out_dir, candidate["category"], key, candidate, admission)
        else:
            file_intake_candidate(repo, engine, candidate, key)


def main(argv):
    if len(argv) == 4 and argv[1] == "lineage":
        try:
            print(lineage_context(argv[2], argv[3]))
        except (OSError, ValueError) as exc:
            print(f"retro.py: lineage failed: {exc}", file=sys.stderr)
            return 1
        return 0
    if len(argv) >= 4 and argv[1] == "select":
        print("\n".join(select(argv[2], int(argv[3]))))
        return 0
    if len(argv) == 6 and argv[1] == "filter":
        root, keys_file, raw_file, out_file = argv[2:]
        with open(keys_file, encoding="utf-8") as f:
            keys = {k.strip() for k in f if k.strip()}
        with open(raw_file, encoding="utf-8") as f:
            raw = json.load(f)
        result = filter_candidates(root, keys, raw)
        with open(out_file, "w", encoding="utf-8") as f:
            json.dump(result, f, ensure_ascii=False, indent=2)
            f.write("\n")
        return 0
    if len(argv) == 5 and argv[1] == "publish":
        try:
            publish_candidates(*argv[2:])
        except (OSError, ValueError, subprocess.CalledProcessError) as exc:
            print(f"retro.py: publish failed: {exc}", file=sys.stderr)
            return 1
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
