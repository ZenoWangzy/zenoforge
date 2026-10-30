#!/usr/bin/env python3
"""PreToolUse guard for observed diagnostic leaks; never echo command or values."""
import json
import os
from pathlib import Path
import re
import shlex
import sys

SECRET = re.compile(r"token|password|secret|api[_-]?key|authorization|credential|environment", re.I)
PRIVATE_FILE = re.compile(
    r"(?:^|/)(?:\.(?:bashrc|zshrc|bash_profile|bash_login|profile|zprofile|zshenv)|"
    r"(?:bash|zsh)rc|profile|\.env(?:[.\w-]*)|[\w.-]+\.env(?:[.\w-]*)|"
    r"credentials?(?:[.\w-]*)|env)(?:$|[\s'\"])")
SERVICE_CONFIG = re.compile(  # ZF_SECRET_CONFIG_NAMES default mirrors config.sh
    r"(?:^|/)(?:" + os.environ.get("ZF_SECRET_CONFIG_NAMES", "agent-runtime") +
    r"|config|[\w.-]*config|litellm[\w.-]*|docker-compose[\w.-]*)\.(?:json|ya?ml)$", re.I)
READERS = {"cat", "head", "tail", "sed", "awk", "grep", "rg", "less", "more", "bat"}
HINT = ("secret-dump-gate: refused secret-bearing diagnostic output. "
        "Read one non-secret field directly, or report only presence/length/fingerprint. "
        "Use bash scripts/ops/redacted-config-reader.sh presence --source file --path <env-file> --key KEY "
        "(or --source container --container NAME --key KEY; compose sources also supported). "
        "For JSON use jq '.path.token | length'; for systemd capture one property locally and print only its length.")


def private_file(path):
    return bool(PRIVATE_FILE.search(path))


def service_config(path, cwd):
    if SERVICE_CONFIG.search(path):
        return True
    if not re.search(r"\.(json|ya?ml)$", path, re.I):
        return False
    # Inspect key names in local files, never serialize values or errors.
    try:
        file = Path(cwd) / os.path.expanduser(path)
        if file.is_file() and file.stat().st_size <= 1_000_000:
            return bool(re.search(r"[\w-]*(?:token|password|secret|api[_-]?key)[\w-]*[\"']?\s*:", file.read_text(), re.I))
    except (OSError, UnicodeError, ValueError):
        pass
    return False


def summary(expression):
    # A summary must end in a value-free operation, not append it to a raw dump.
    return bool(re.fullmatch(r"\s*\.[\w.\[\]\"' -]+\s*\|\s*(?:length|has\([^)]*\)|type)\s*", expression))


def denied(command, cwd=".", depth=0, in_container=False):
    if depth > 8:
        return True
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|()\n")
        lexer.whitespace = " \t\r"
        tokens = list(lexer)
    except ValueError:
        return True
    groups, group = [], []
    for token in tokens + [";"]:
        if re.fullmatch(r"[;&|()\n]+", token):
            if group:
                groups.append(group)
            group = []
        else:
            group.append(token)
    for args in groups:
        names = [os.path.basename(arg) for arg in args]
        container_shell = in_container or ("docker" in names and "exec" in args)
        # Recurse only into executable shell/remote strings, not jq expressions or source literals.
        for i, name in enumerate(names):
            if name in {"bash", "sh", "zsh"}:
                for j in range(i + 1, len(args) - 1):
                    if args[j] in {"-c", "-lc", "-ic"} and denied(args[j + 1], cwd, depth + 1, container_shell):
                        return True
            if name == "ssh" and len(args) > i + 2 and any(c in args[-1] for c in " ;|\n"):
                if denied(args[-1], cwd, depth + 1, in_container):
                    return True
        for i, name in enumerate(names):
            rest = args[i + 1:]
            if in_container and name in {"env", "printenv"}:
                return True
            if name in READERS and any(private_file(a) or service_config(a, cwd) for a in rest):
                return True
            if name in {"jq", "yq"}:
                expressions = [a for a in rest if not a.startswith("-") and not re.search(r"\.(json|ya?ml)$", a)]
                if expressions and any(private_file(a) or service_config(a, cwd) for a in rest):
                    expression = expressions[0].strip()
                    if not summary(expression) and (re.search(r"(?<![\w])\.(?![\w])|to_entries|with_entries", expression) or SECRET.search(expression)
                                                    or re.search(r"\.(?:services|config|Config|headers)(?:\[\])?\s*$", expression)):
                        return True
            if name == "systemctl" and any(a in {"show", "cat"} for a in rest):
                if "cat" in rest:
                    return True
                properties = []
                for j, arg in enumerate(rest):
                    if arg in {"-p", "--property"} and j + 1 < len(rest):
                        properties.extend(rest[j + 1].split(","))
                    elif arg.startswith("--property="):
                        properties.extend(arg.split("=", 1)[1].split(","))
                    elif arg.startswith("-p") and len(arg) > 2:
                        properties.extend(arg[2:].split(","))
                if not properties or any(re.search(r"Exec|Environment", p, re.I) for p in properties):
                    return True
            if name == "docker":
                if "inspect" in rest:
                    formats = [rest[j + 1] for j, a in enumerate(rest[:-1]) if a in {"-f", "--format"}]
                    formats += [a.split("=", 1)[1] for a in rest if a.startswith("--format=")]
                    if not formats or any(not re.fullmatch(r"\{\{\s*\.(?:Id|Name|State\.(?:Running|Status)|Config\.Image)\s*\}\}", f) for f in formats):
                        return True
                if "exec" in rest and any(a in {"env", "printenv"} for a in rest):
                    return True
            if name in {"python", "python3", "node"}:
                script = " ".join(rest)
                paths = re.findall(r"[\w~$./-]+\.(?:json|ya?ml|env)\b|[\w~$./-]*\.(?:bashrc|zshrc|profile)\b", script)
                if any(private_file(p) or service_config(p, cwd) for p in paths) and re.search(r"print\(|console\.log|stdout\.write", script):
                    if re.search(r"json\.dumps|yaml\.dump|print\(\s*(?:data|config)\s*\)", script):
                        return True
    return False


def main():
    try:
        data = json.load(sys.stdin)
        if data.get("tool_name") not in {"Bash", "exec_command", "shell_command"}:
            return 0
        args = data.get("tool_input", {})
        command = args.get("command", args.get("cmd", ""))
        if not isinstance(command, str) or denied(command, args.get("workdir") or data.get("cwd") or "."):
            print(HINT, file=sys.stderr)
            return 2
        return 0
    except (ValueError, TypeError, AttributeError):
        print("secret-dump-gate: invalid hook input; command refused.", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
