#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'usage: cutover-gate.sh --baseline <version-dir> --out <file> [--suites <file>] | <engine-dir> <target-dir> [--baseline <file>] [--suites <file>] [--allow-undefined <file>]\n' >&2
  exit 2
}
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
mode=gate baseline='' suites='' out='' allow_undefined='' results_out=''
if [[ ${1:-} == --baseline ]]; then
  [[ $# -ge 2 ]] || usage
  mode=baseline; version_dir=$2; shift 2
else
  [[ $# -ge 2 ]] || usage
  engine_dir=$1; target_dir=$2; shift 2
fi
while (($#)); do
  case "$1" in
    --baseline) (($# >= 2)) || usage; baseline=$2; shift 2 ;;
    --out) (($# >= 2)) || usage; out=$2; shift 2 ;;
    --suites) (($# >= 2)) || usage; suites=$2; shift 2 ;;
    --results) (($# >= 2)) || usage; results_out=$2; shift 2 ;;
    --allow-undefined) (($# >= 2)) || usage; allow_undefined=$2; shift 2 ;;
    *) usage ;;
  esac
done
failures=0
fail() { printf 'cutover-gate: %s\n' "$1"; failures=$((failures + 1)); }
[[ -z $suites || -f $suites ]] || { fail "suite list is missing: $suites"; exit 1; }
[[ -z $allow_undefined || -f $allow_undefined ]] || { fail "undefined function allow-list is missing: $allow_undefined"; exit 1; }

run_suites() {
  local root=$1 results=$2 command_line suite_path status reason
  declare -A quarantine=()
  while IFS=$'\t' read -r suite_path reason; do
    [[ -n $suite_path && $suite_path != \#* ]] && quarantine["$suite_path"]=$reason
  done < "$repo_root/tools/quarantine.txt"
  : > "$results"
  if [[ -n $suites ]]; then
    suite_commands=$suites
  else
    suite_commands="$results.commands"
    (cd "$root" && find engine -type f \( -name '*.test.sh' -o -name '*.test.mjs' \) | sort) | while IFS= read -r suite_path; do
      case $suite_path in *.mjs) printf 'timeout -s KILL 600 node --test --test-concurrency=1 %s\n' "$suite_path" ;; *) printf 'timeout -s KILL 600 bash %s\n' "$suite_path" ;; esac
    done > "$suite_commands"
  fi
  while IFS= read -r command_line || [[ -n $command_line ]]; do
    command_line=${command_line%%#*}
    [[ -n ${command_line//[$'\t\r ']/} ]] || continue
    if [[ $command_line =~ (engine/[A-Za-z0-9_./-]+) ]]; then suite_path=${BASH_REMATCH[1]}; else fail "invalid suite command: $command_line"; continue; fi
    [[ -z ${quarantine[$suite_path]+x} ]] || continue
    status=PASS
    { (cd "$root" && bash -euo pipefail -c "$command_line") >/dev/null 2>&1; } 2>/dev/null || status=FAIL
    printf '%s\t%s\n' "$status" "$suite_path" >> "$results"
    printf 'cutover-gate: %s %s\n' "$status" "$suite_path" >&2
  done < "$suite_commands"
}
if [[ $mode == baseline ]]; then
  [[ -d $version_dir/engine ]] || { [[ -d $version_dir && ${version_dir##*/} == engine ]] && version_dir=$(dirname "$version_dir"); }
  [[ -n $out && -d $version_dir/engine ]] || usage
  scratch="$(mktemp -d "$repo_root/.git/cutover-baseline.XXXXXXXX")"
  # Copy the version, excluding deployment settings; never run tests in the live version.
  tar -C "$version_dir" --exclude='*.env' -cf - . | tar -C "$scratch" -xf -
  chmod -R u+w "$scratch"
  run_suites "$scratch" "$out"
  ((failures == 0)) || exit 1
  exit 0
fi
[[ -d $engine_dir ]] || { fail "engine directory is missing: $engine_dir"; exit 1; }
[[ -d $target_dir ]] || { fail "target directory is missing: $target_dir"; exit 1; }
engine_dir="$(cd -- "$engine_dir" && pwd -P)"
target_dir="$(cd -- "$target_dir" && pwd -P)"
[[ -z $baseline || -f $baseline ]] || { fail "baseline is missing: $baseline"; exit 1; }

scan_output=''
if ! scan_output="$(python3 - "$engine_dir" "$target_dir" "$allow_undefined" 2>&1 <<'PY'
import os
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

engine = Path(sys.argv[1])
target = Path(sys.argv[2])
allow_path = sys.argv[3]
allowed = {}
if allow_path:
    for line in Path(allow_path).read_text().splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        parts = line.split('\t', 2)
        if len(parts) != 3 or not parts[2].strip() or not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', parts[0]) or not parts[1].strip():
            raise ValueError('invalid undefined function allow-list entry')
        allowed[(parts[0], parts[1])] = parts[2]
source_suffixes = {'.sh', '.bash', '.mjs', '.cjs', '.js', '.py'}
ignored_parts = {'vendor', 'node_modules', 'test', 'tests', 'fixtures'}
files = []
for root, directories, names in os.walk(engine):
    directories[:] = [name for name in directories if name not in ignored_parts]
    for name in names:
        path = Path(root) / name
        if '.test.' in name or name.startswith('test-') or name.endswith('.test'):
            continue
        if path.suffix.lower() in source_suffixes:
            files.append(path)
        elif not path.suffix:
            try:
                with path.open('rb') as handle:
                    if handle.read(2) == b'#!':
                        files.append(path)
            except OSError:
                pass

def source(path):
    try:
        return path.read_text(encoding='utf-8')
    except (OSError, UnicodeError):
        return ''

sources = {path: source(path) for path in files}
failures = set()
reports = set()

def emit_failure(message):
    failures.add(message)

def emit_report(message):
    reports.add(message)

def inside(path, root):
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False

def candidate_exists(path):
    try:
        return path.exists()
    except OSError:
        return False

boundary_pattern = re.compile(r'(?P<base>\$\{?(?:ZF_REPO_DIR|ZF_CONFIG_ROOT)\}?)/(?P<path>[A-Za-z0-9_./@+-]+)')
relative_pattern = re.compile(r'(?<![A-Za-z0-9_])(?P<path>(?:\.\.?/)+[A-Za-z0-9_.@+-][A-Za-z0-9_./@+-]*)')
dynamic = re.compile(r'[$*?\[\]{}]')

for path, text in sources.items():
    relative_file = path.relative_to(engine).as_posix()
    for line in text.splitlines():
        stripped = line.lstrip()
        if (path.suffix in {'.sh', '.bash', '.py'} and stripped.startswith('#')) or stripped.startswith('//'):
            continue
        for match in boundary_pattern.finditer(line):
            raw = match.group('path').rstrip('/')
            if not raw or dynamic.search(raw):
                continue
            base_name = 'ZF_CONFIG_ROOT' if 'ZF_CONFIG_ROOT' in match.group('base') else 'ZF_REPO_DIR'
            if base_name == 'ZF_CONFIG_ROOT':
                resolved = (target / '.zenoforge' / raw).resolve()
                engine_default = (engine / raw).resolve()
                exists = candidate_exists(resolved) or candidate_exists(engine_default)
            else:
                resolved = (target / raw).resolve()
                exists = candidate_exists(resolved)
            if not exists:
                emit_failure(f'unresolved path: {relative_file}: ${base_name}/{raw}')

        for match in relative_pattern.finditer(line):
            raw = match.group('path').rstrip('.,;:)')
            if dynamic.search(raw):
                continue
            prefix = line[:match.start()]
            variable_base = re.search(r'\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?/$', prefix)
            if variable_base:
                variable = variable_base.group(1)
                if variable in {'SCRIPT_DIR', 'HERE'}:
                    base = path.parent
                elif variable in {'ENGINE_DIR', 'ZF_ENGINE_DIR'}:
                    base = engine
                else:
                    continue
            else:
                base = path.parent
            resolved = (base / raw).resolve()
            if inside(resolved, engine):
                continue
            if candidate_exists(resolved):
                continue
            target_relative = os.path.relpath(resolved, engine.parent)
            target_path = (target / target_relative).resolve()
            if not inside(target_path, target):
                exists = False
            else:
                exists = candidate_exists(target_path)
                config_prefix = '.zenoforge' + os.sep
                if not exists and target_relative.startswith(config_prefix):
                    exists = candidate_exists((engine / target_relative[len(config_prefix):]).resolve())
            if not exists:
                emit_failure(f'unresolved path: {relative_file}: {raw}')

# Environment reads without a code default or a deployment assignment are
# informational: operators can review this list without blocking a cutover.
deploy_names = set()
reads = set()
defaults = set()
shell_files = []
for path, text in sources.items():
    if path.suffix.lower() in {'.sh', '.bash'} or (not path.suffix and text.startswith('#!') and re.search(r'\b(?:ba)?sh\b', text[:100])):
        shell_files.append((path, text))
        defaults.update(re.findall(r'(?m)(?:^|[;\s])(?:export\s+|local\s+|readonly\s+|declare\s+)?([A-Z_][A-Z0-9_]*)\s*=(?!=)', text))
        defaults.update(re.findall(r'\b(?:local|declare|typeset)(?:\s+-[A-Za-z]+)*\s+([A-Z_][A-Z0-9_]*)\b', text))
        defaults.update(re.findall(r'\bfor\s+([A-Z_][A-Z0-9_]*)\s+in\b', text))
        for match in re.finditer(r'\$\{([A-Z_][A-Z0-9_]*)([^}]*)\}', text):
            name, suffix = match.groups()
            reads.add(name)
            if re.match(r':?[-+=?]', suffix):
                defaults.add(name)
        reads.update(re.findall(r'\$([A-Z_][A-Z0-9_]*)', text))

for path, text in sources.items():
    if path.suffix.lower() in {'.mjs', '.cjs', '.js'}:
        reads.update(re.findall(r'process\.env\.([A-Z_][A-Z0-9_]*)', text))
        defaults.update(re.findall(r'process\.env\.([A-Z_][A-Z0-9_]*)\s*(?:\?\?|\|\|)', text))
    if path.suffix.lower() == '.py':
        for match in re.finditer(r'os\.(?:environ\.get|getenv)\(\s*[\'\"]([A-Z_][A-Z0-9_]*)[\'\"]\s*(,|\))', text):
            reads.add(match.group(1))
            if match.group(2) == ',' or re.match(r'\s+or\b', text[match.end():]):
                defaults.add(match.group(1))
        reads.update(re.findall(r'os\.environ\[\s*[\'\"]([A-Z_][A-Z0-9_]*)[\'\"]\s*\]', text))

shell_specials = {
    'BASH', 'BASH_COMMAND', 'BASH_LINENO', 'BASH_REMATCH', 'BASH_SOURCE',
    'BASH_VERSINFO', 'BASH_VERSION', 'EPOCHREALTIME', 'EUID', 'FUNCNAME',
    'LINENO', 'OLDPWD', 'PIPESTATUS', 'PPID', 'PWD', 'RANDOM', 'SECONDS',
    'UID', 'IFS', 'OPTIND', 'SHELLOPTS', 'BASHOPTS', '_', '__',
}
reads.difference_update(shell_specials)

shell_builtins = set()
try:
    shell_builtins.update(subprocess.run(['bash', '-c', 'compgen -b'], check=True, capture_output=True, text=True).stdout.split())
except (OSError, subprocess.SubprocessError):
    pass
jq_builtins = {
    'ascii_downcase', 'ascii_upcase', 'from_entries', 'group_by', 'max_by',
    'min_by', 'sort_by', 'to_entries', 'unique_by', 'with_entries',
}
definitions = set()
shell_variables = set()
definition_pattern = re.compile(r'^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*(?:\(\s*\))?\s*(?:\{|\()')
for _, text in shell_files:
    definitions.update(m.group(1) for line in text.splitlines() if (m := definition_pattern.match(line)))
    shell_variables.update(re.findall(r'(?<![A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*)\s*(?:\+?=)', text))
    shell_variables.update(re.findall(r'\bfor\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\b', text))
    for declaration in re.finditer(r'\b(?:local|declare|typeset)\s+([^;\n]+)', text):
        shell_variables.update(re.findall(r'\b([A-Za-z_][A-Za-z0-9_]*)(?:=(?!=)|\b)', declaration.group(1)))
    for expression in re.findall(r'\$?\(\((.*?)\)\)|\[\[(.*?)\]\]', text, flags=re.S):
        shell_variables.update(re.findall(r'\b([A-Za-z_][A-Za-z0-9_]*)\b', ''.join(expression)))

def command_end(text, start):
    depth, quote, index = 1, '', start + 2
    while index < len(text):
        char = text[index]
        if quote:
            if char == '\\' and quote != "'":
                index += 2
                continue
            if char == quote:
                quote = ''
        elif char in "'\"`":
            quote = char
        elif char == '(':
            depth += 1
        elif char == ')':
            depth -= 1
            if depth == 0:
                return index
        index += 1
    return None

def has_open_command_substitution(text):
    quote, index = '', 0
    while index < len(text):
        char = text[index]
        if quote:
            if char == '\\' and quote != "'":
                index += 2
                continue
            if quote != "'" and text.startswith('$(', index):
                end = command_end(text, index)
                if end is None:
                    return True
                index = end + 1
                continue
            if char == quote:
                quote = ''
        elif char in "'\"`":
            quote = char
        elif text.startswith('$(', index):
            end = command_end(text, index)
            if end is None:
                return True
            index = end + 1
            continue
        index += 1
    return False

def shell_code_line(raw, starting_quote=''):
    code, substitutions, quote, index = [], [], starting_quote, 0
    while index < len(raw):
        char = raw[index]
        if quote:
            if char == '\\' and quote != "'":
                index += 2
                continue
            if quote != "'" and raw.startswith('$(', index):
                end = command_end(raw, index)
                substitutions.append(raw[index + 2:end])
                code.append(' ')
                index = end + 1
                continue
            if char == quote:
                quote = ''
                code.append(' ')
            index += 1
            continue
        if char == '#' and (index == 0 or raw[index - 1].isspace()):
            break
        if raw.startswith('$(', index):
            end = command_end(raw, index)
            substitutions.append(raw[index + 2:end])
            code.append(' ')
            index = end + 1
            continue
        if char == '`':
            end = raw.find('`', index + 1)
            if end >= 0:
                substitutions.append(raw[index + 1:end])
                code.append(' ')
                index = end + 1
                continue
        if char in "'\"`":
            quote = char
            code.append(' ')
            index += 1
            continue
        if char == '\\' and index + 1 < len(raw):
            code.append(raw[index + 1])
            index += 2
            continue
        code.append(char)
        index += 1
    return ''.join(code), quote, substitutions

def shell_code_lines(text, line_offset=0):
    quote, heredoc = '', ''
    lines, index = text.splitlines(), 0
    while index < len(lines):
        raw = lines[index]
        line_number = line_offset + index + 1
        if heredoc:
            if raw.strip() == heredoc:
                heredoc = ''
            index += 1
            continue
        while has_open_command_substitution(raw) and index + 1 < len(lines):
            index += 1
            raw += '\n' + lines[index]
        code, quote, substitutions = shell_code_line(raw, quote)
        if code.strip():
            yield line_number, code
        for substitution in substitutions:
            yield from shell_code_lines(substitution, line_number - 1)
        if not quote and '<<' in code:
            marker = re.search(r"(?<!<)<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1", raw)
            if marker:
                heredoc = marker.group(2)
        index += 1

def command_candidates(line):
    line = re.sub(r'\$?\(\(.*?\)\)', ' ', line)
    line = re.sub(r'\[\[.*?\]\]', ' ', line)
    try:
        lexer = shlex.shlex(line, posix=True, punctuation_chars=';&|()')
        lexer.whitespace_split = True
        lexer.commenters = '#'
        tokens = list(lexer)
    except ValueError:
        return
    segments, current = [], []
    case_mode = ''
    for token in tokens:
        if token == 'case':
            if current: segments.append(current); current = []
            case_mode = 'in'
            continue
        if case_mode == 'in':
            if token == 'in': case_mode = 'patterns'
            continue
        if case_mode == 'patterns':
            if ')' in token: case_mode = ''
            continue
        if token in {';', ';;', ';&', ';;&', '&&', '||', '|', '&', '(', ')'}:
            if current: segments.append(current); current = []
        elif token in {'if', 'then', 'elif', 'else', 'while', 'until', 'do', '!', 'time'}:
            if current: segments.append(current); current = []
        else:
            current.append(token)
    if current: segments.append(current)
    prefixes = {'command', 'builtin', 'exec', 'env', 'nice', 'nohup', 'setsid', 'timeout', 'sudo'}
    for segment in segments:
        index = 0
        while index < len(segment) and (re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', segment[index]) or segment[index].startswith(('>', '<'))):
            index += 1
            if index and segment[index - 1].startswith(('>', '<')) and index < len(segment):
                index += 1
        while index < len(segment) and segment[index] in prefixes:
            index += 1
            while index < len(segment) and (segment[index].startswith('-') or re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', segment[index])):
                index += 1
        if index >= len(segment):
            continue
        name = segment[index]
        if re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', name):
            yield name

undefined_functions = {}
for path, text in shell_files:
    relative_file = path.relative_to(engine).as_posix()
    for line_number, line in shell_code_lines(text):
        if re.match(r'^\s*[A-Za-z0-9_*?@!|.-]+\)\s*(?:;;|;&|;;&)?\s*$', line):
            continue
        declaration = definition_pattern.match(line)
        if declaration:
            line = line[declaration.end():]
        for name in command_candidates(line):
            if '_' not in name or not any(char.islower() for char in name) or name.startswith('_'):
                continue
            if name in definitions or name in shell_variables or name in shell_builtins or name in jq_builtins or shutil.which(name):
                continue
            undefined_functions.setdefault((name, relative_file), []).append(line_number)

for (name, relative_file), lines in undefined_functions.items():
    location = relative_file + ':' + ','.join(map(str, lines))
    if (name, relative_file) in allowed:
        emit_report(f'allowed undefined shell function: {name} (called in {location}): {allowed[name, relative_file]}')
    else:
        emit_failure(f'undefined shell function: {name} (called in {location})')

reads.difference_update(shell_variables)
for name in sorted(reads - defaults - deploy_names):
    emit_report(f'env has no default or deploy assignment (report only): {name}')
for message in sorted(failures):
    print(f'failure\t{message}')
for message in sorted(reports):
    print(f'report\t{message}')
PY
)"; then
  scan_output="${scan_output//$'\n'/ }"
  fail "reference scan could not run: $scan_output"
else
  while IFS=$'\t' read -r kind message; do
    [[ -n "$kind" ]] || continue
    case "$kind" in
      failure) fail "$message" ;;
      report) printf 'cutover-gate: %s\n' "$message" ;;
    esac
  done <<< "$scan_output"
fi

scratch_parent="$(dirname -- "$engine_dir")"
while [[ "$scratch_parent" != / && ! -w "$scratch_parent" ]]; do
  scratch_parent="$(dirname -- "$scratch_parent")"
done
history_dir="$scratch_parent/.cutover-gate-history.$BASHPID"
if ! mkdir -p "$history_dir"; then
  fail 'could not create incident history directory'
fi
cleanup() {
  chmod -R u+w "$history_dir" 2>/dev/null || true
  find "$history_dir" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT

audit_output=''
if [[ ! -f "$engine_dir/night/incident-guard-audit.mjs" ]]; then
  fail 'incident guard audit script is missing from engine'
elif ! audit_output="$(cd -- "$(dirname -- "$engine_dir")" && \
  ZF_PACK_REL="$(basename -- "$engine_dir")" ZF_PACK_ROOT="$(dirname -- "$engine_dir")" \
  ZF_REPO_DIR="$target_dir" ZF_CONFIG_ROOT="$target_dir/.zenoforge" \
  node "$engine_dir/night/incident-guard-audit.mjs" --repo "$target_dir" --history-dir "$history_dir" 2>&1)"; then
  audit_output="${audit_output//$'\n'/ }"
  fail "incident guard audit failed: $audit_output"
else
  if ! command -v jq >/dev/null 2>&1; then
    fail 'jq is required to read incident guard audit output'
  elif ! jq -e '.missingTargets | type == "array"' >/dev/null 2>&1 <<< "$audit_output"; then
    fail 'incident guard audit did not return missingTargets'
  else
    while IFS=$'\t' read -r guard target_path; do
      [[ -n "$guard" ]] || continue
      fail "incident guard $guard missing target $target_path"
    done < <(jq -r '.missingTargets[]? as $guard | $guard.targets[]? | [$guard.id, .target] | @tsv' <<< "$audit_output")
  fi
fi

if [[ -n $suites || -n $baseline ]]; then
  results=${results_out:-$(mktemp "$repo_root/.git/cutover-results.XXXXXXXX")}
  run_suites "$(dirname "$engine_dir")" "$results"
  declare -A previous=()
  if [[ -n $baseline ]]; then
    while IFS=$'\t' read -r status suite extra; do
      [[ ($status == PASS || $status == FAIL) && $suite == engine/* && -z ${extra:-} && -z ${previous[$suite]+x} ]] || { fail "invalid baseline entry: $status $suite"; continue; }
      previous[$suite]=$status
    done < "$baseline"
  fi
  declare -A seen=()
  while IFS=$'\t' read -r status suite; do
    seen[$suite]=1
    if [[ -n $baseline && -z ${previous[$suite]+x} ]]; then fail "suite missing from baseline: $suite"; continue; fi
    [[ $status != FAIL || ${previous[$suite]:-PASS} != PASS ]] || fail "suite failed: $suite"
  done < "$results"
  for suite in "${!previous[@]}"; do [[ -n ${seen[$suite]+x} ]] || fail "baseline suite missing from results: $suite"; done
fi

host_ops=${ZF_HOST_OPS_DIR:-$HOME/.vecta-agent/host-ops}
if [[ ! -f $host_ops/run-tests.sh ]]; then
  fail "host-ops runner is missing: $host_ops/run-tests.sh"
else
  host_scratch="$(mktemp -d "$repo_root/.git/cutover-host-ops.XXXXXXXX")"
  tar -C "$host_ops" --exclude='*.env' --exclude='./.tmp' -cf - . | tar -C "$host_scratch" -xf -
  host_output="$host_scratch/results.tsv"
  host_status=0
  ZF_ENGINE_DIR="$engine_dir" bash "$host_scratch/run-tests.sh" > "$host_output" 2>&1 || host_status=$?
  if [[ ! -f $host_scratch/BASELINE.tsv ]]; then fail 'host-ops baseline is missing'; else
    declare -A host_baseline=() host_seen=()
    host_failed=0
    while IFS=$'\t' read -r status suite extra; do
      [[ $status == result && $suite == test ]] && continue
      [[ ($status == PASS || $status == FAIL) && -n $suite && -z ${extra:-} && -z ${host_baseline[$suite]+x} ]] || { fail "invalid host-ops baseline entry: $status $suite"; continue; }
      host_baseline[$suite]=$status
    done < "$host_scratch/BASELINE.tsv"
    while IFS=$'\t' read -r status suite extra; do
      [[ $status == PASS || $status == FAIL ]] || continue
      host_seen[$suite]=1
      [[ $status != FAIL ]] || host_failed=1
      [[ $status != FAIL || ${host_baseline[$suite]:-PASS} != PASS ]] || fail "host-ops test failed: $suite"
    done < "$host_output"
    for suite in "${!host_baseline[@]}"; do [[ -n ${host_seen[$suite]+x} ]] || fail "host-ops test missing from results: $suite"; done
    [[ $host_status == 0 || $host_status == 1 ]] || fail "host-ops runner exited $host_status"
    [[ $host_status != 1 || $host_failed == 1 ]] || fail "host-ops runner failed without a failing test result"
    [[ $host_status != 0 || $host_failed == 0 ]] || fail "host-ops runner reported failures but exited 0"
  fi
fi
((failures == 0)) || exit 1
