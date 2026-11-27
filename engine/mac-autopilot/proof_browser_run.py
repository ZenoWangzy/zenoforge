#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

SAMPLES_FILE = "proof-browser-runs.jsonl"


def metrics_path():
    configured = os.environ.get("ZF_CDP_BROWSER_LEASE_METRICS_FILE")
    runtime = os.environ.get("MAC_AUTOPILOT_RUNTIME_DIR")
    agent_home = os.environ.get("AGENT_HOME") or os.environ.get("ZF_HOME")
    if configured:
        return Path(configured)
    if runtime:
        return Path(runtime) / SAMPLES_FILE
    if agent_home:
        return Path(agent_home) / "logs" / SAMPLES_FILE
    return Path.home() / ".zenoforge" / "logs" / SAMPLES_FILE


def write_proof(path, fields):
    try:
        proof = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError) as error:
        print(f"proof metrics JSON update failed: {error}", file=sys.stderr)
        return
    if not isinstance(proof, dict):
        return
    proof.update(fields)
    target = Path(path)
    temporary = None
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=target.parent,
                                         prefix=target.name + ".", suffix=".tmp", delete=False) as stream:
            temporary = stream.name
            json.dump(proof, stream, ensure_ascii=False, separators=(",", ":"))
            stream.write("\n")
        os.replace(temporary, target)
    except OSError as error:
        if temporary:
            try:
                os.unlink(temporary)
            except OSError:
                pass
        print(f"proof metrics JSON update failed: {error}", file=sys.stderr)


def append_sample(path, record):
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        descriptor = os.open(path, os.O_CREAT | os.O_APPEND | os.O_WRONLY, 0o600)
        try:
            payload = (json.dumps(record, separators=(",", ":")) + "\n").encode("utf-8")
            if os.write(descriptor, payload) != len(payload):
                raise OSError("short write")
        finally:
            os.close(descriptor)
    except OSError as error:
        print(f"proof browser metrics write failed: {error}", file=sys.stderr)


def parse_command(values):
    return values[1:] if values[:1] == ["--"] else values


def record_run(started_ns, proof_path, sample_path, command):
    lock_wait_ms = round(max(0, time.monotonic_ns() - started_ns) / 1_000_000, 3)
    run_started_ns = time.monotonic_ns()
    try:
        exit_code = subprocess.run(command, check=False).returncode
    except OSError as error:
        print(str(error), file=sys.stderr)
        exit_code = 127
    run_ms = round(max(0, time.monotonic_ns() - run_started_ns) / 1_000_000, 3)
    completed_at = datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    record = {"completed_at": completed_at, "lock_wait_ms": lock_wait_ms, "run_ms": run_ms}
    write_proof(proof_path, {"lock_wait_ms": lock_wait_ms, "run_ms": run_ms})
    append_sample(Path(sample_path), record)
    return exit_code


def main(argv):
    if argv[:1] == ["--record"]:
        parser = argparse.ArgumentParser(add_help=False)
        parser.add_argument("--started-ns", type=int, required=True)
        parser.add_argument("--json", required=True)
        parser.add_argument("--metrics-file", required=True)
        parser.add_argument("command", nargs=argparse.REMAINDER)
        args = parser.parse_args(argv[1:])
        command = parse_command(args.command)
        if not command:
            return 64
        return record_run(args.started_ns, args.json, args.metrics_file, command)
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", required=True)
    parser.add_argument("--metrics-file")
    parser.add_argument("--lease-script")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    command = parse_command(args.command)
    if not command:
        parser.error("a proof command is required after --")
    lease_script = args.lease_script or os.environ.get("ZF_CDP_BROWSER_LEASE_SCRIPT")
    if not lease_script:
        parser.error("ZF_CDP_BROWSER_LEASE_SCRIPT or --lease-script is required")
    sample_path = args.metrics_file or os.fspath(metrics_path())
    started_ns = time.monotonic_ns()
    recorder = [sys.executable, os.fspath(Path(__file__).resolve()), "--record",
                "--started-ns", str(started_ns), "--json", args.json,
                "--metrics-file", sample_path, "--", *command]
    try:
        return subprocess.run([lease_script, "--", *recorder], check=False).returncode
    except OSError as error:
        print(str(error), file=sys.stderr)
        return 127


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
