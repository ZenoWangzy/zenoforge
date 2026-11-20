#!/usr/bin/env python3
# Unattended /retro stage: select and validate candidates, then route each kept candidate.
# Usage: retro.py select <scratch-root> <n>            prints the chosen session keys, sorted
#        retro.py filter <scratch-root> <keys> <raw.json> <out.json>   writes kept candidates and drop counts
#        retro.py publish <scratch-root> <repo-root> <candidates.json> routes kept candidates
import glob
import json
import os
import subprocess
import sys
import tempfile
from collections import Counter

CATEGORIES = {"navigation", "automated-checks", "coding-standards", "global-agents-md",
              "tool-economy", "no-ops", "information-access"}
SEVERITIES = {"low", "medium", "high"}


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


def candidate_class(engine, category, event):
    helper = os.path.join(engine, "mac-autopilot", "incident-fingerprint.sh")
    script = 'source "$1"; fingerprint="$(incident_fingerprint "$3")"; incident_class "$2 $fingerprint"'
    # Keep the event category in the shared issue-upsert class key.
    result = subprocess.run(
        ["bash", "-c", script, "retro-class", helper, category, event],
        check=True, capture_output=True, text=True,
    )
    return result.stdout.strip()


def write_lesson_fragment(repo, candidate, key):
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
        f"- Observation: {evidence}\n\n"
        "The pending rule is [V-NEXT](../RULES.md#v-next).\n"
    )
    fragment = {
        "id": lesson_id,
        "rule": '<a id="v-next"></a>\n**V-NEXT** Add the deterministic check described in the full lesson.',
        "catalog_entry": f"Applies: [V-NEXT](RULES.md#v-next); full: ./full/{lesson_id}.md",
        "full_lesson_path": f"lessons/full/{lesson_id}.md",
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
        f"- Source: {candidate['session_key']} events.jsonl line {candidate['event_line']}\n\n"
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
        subprocess.run(
            ["bash", os.path.join(engine, "pipeline-issue-upsert.sh"),
             "--lane", "product", "--class", key, "--title", title, "--body-file", body_path],
            check=True, env=env,
        )
    finally:
        os.unlink(body_path)


def publish_candidates(root, repo, candidates_path):
    engine = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    with open(candidates_path, encoding="utf-8") as candidates_file:
        document = json.load(candidates_file)
    candidates = document.get("candidates") if isinstance(document, dict) else None
    if not isinstance(candidates, list):
        raise ValueError("candidate file has no candidates array")
    for candidate in candidates:
        if (not isinstance(candidate, dict) or candidate.get("category") not in CATEGORIES
                or candidate.get("severity") not in SEVERITIES):
            raise ValueError("candidate file contains an invalid candidate")
        if (not isinstance(candidate.get("proposal"), str) or not candidate["proposal"].strip()
                or not isinstance(candidate.get("evidence"), str)):
            raise ValueError("candidate file contains an invalid proposal or evidence")
        event = event_at(root, candidate)
        key = candidate_class(engine, candidate["category"], event)
        if candidate["category"] == "automated-checks":
            write_lesson_fragment(repo, candidate, key)
        else:
            file_intake_candidate(repo, engine, candidate, key)


def main(argv):
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
