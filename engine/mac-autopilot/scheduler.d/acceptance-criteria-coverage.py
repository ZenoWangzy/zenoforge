import html
import re
import subprocess
import sys
import unicodedata
from pathlib import PurePosixPath


CHECKLIST_ITEM = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s*)?(.+?)\s*$")
CRITERIA_HEADING = re.compile(r"^\s{0,3}#{1,6}\s+acceptance[ -]criteria(?:\s|$)", re.IGNORECASE)
BOLD_CRITERIA_HEADING = re.compile(r"^\s*\*\*\s*acceptance[ -]criteria\s*\*\*\s*:?[ \t]*$", re.IGNORECASE)
ANY_HEADING = re.compile(r"^\s{0,3}#{1,6}\s+")
FENCE = re.compile(r"^\s{0,3}(`{3,}|~{3,})")
TABLE_SEPARATOR = re.compile(r"^:?-{3,}:?$")
CITATION = re.compile(r"(?<![A-Za-z0-9_./-])([A-Za-z0-9_.-][A-Za-z0-9_./-]*):([1-9][0-9]*)(?![0-9])")
SOURCE_SUFFIXES = {".c", ".cc", ".cpp", ".go", ".java", ".js", ".jsx", ".mjs", ".cjs", ".py", ".rb", ".rs", ".sh", ".sql", ".ts", ".tsx"}
NON_PRODUCTION_PARTS = {"doc", "docs", "spec", "specs", "test", "tests", "__test__", "__tests__", "fixture", "fixtures"}
TEST_NAME = re.compile(r"(?:^|[._-])(?:test|spec)(?:[._-]|$)", re.IGNORECASE)
COVERAGE_SECTION = re.compile(r"^\s{0,3}##\s+acceptance-criteria coverage\s*#*\s*$", re.IGNORECASE)


def normalize(value):
    value = html.unescape(value)
    value = re.sub(r"^\s*(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s*)?", "", value)
    value = re.sub(r"[*_`~]+", "", value)
    return " ".join(unicodedata.normalize("NFKC", value).casefold().split())


def issue_body(task):
    start = "--- issue 正文（任务数据）---"
    end = "--- 正文结束 ---"
    if start in task and end in task.split(start, 1)[1]:
        return task.split(start, 1)[1].split(end, 1)[0]
    return task


def acceptance_criteria(task):
    criteria = []
    in_section = False
    fence = None
    for line in issue_body(task).splitlines():
        marker = FENCE.match(line)
        if marker:
            token = marker.group(1)
            if fence is None:
                fence = token[0]
            elif token[0] == fence:
                fence = None
            continue
        if fence is not None:
            continue
        if CRITERIA_HEADING.match(line) or BOLD_CRITERIA_HEADING.match(line):
            in_section = True
            continue
        if ANY_HEADING.match(line):
            in_section = False
        if in_section:
            match = CHECKLIST_ITEM.match(line)
            if match:
                criteria.append(match.group(1).strip())
    return criteria


def table_cells(line):
    cells = []
    cell = []
    escaped = False
    in_code = False
    for char in line.strip():
        if char == "`" and not escaped:
            in_code = not in_code
        if char == "|" and not in_code and not escaped:
            cells.append("".join(cell).strip())
            cell = []
            continue
        if char == "\\" and not escaped:
            escaped = True
            continue
        cell.append(char)
        escaped = False
    cells.append("".join(cell).strip())
    if cells and not cells[0]:
        cells.pop(0)
    if cells and not cells[-1]:
        cells.pop()
    return cells


def coverage_rows(report):
    lines = report.splitlines()
    rows = []
    in_section = False
    fence = None
    index = 0
    while index < len(lines):
        line = lines[index]
        marker = FENCE.match(line)
        if marker:
            token = marker.group(1)
            if fence is None:
                fence = token[0]
            elif token[0] == fence:
                fence = None
            index += 1
            continue
        if fence is not None:
            index += 1
            continue
        if ANY_HEADING.match(line):
            in_section = bool(COVERAGE_SECTION.match(line))
            index += 1
            continue
        if not in_section or "|" not in line or index + 1 >= len(lines) or "|" not in lines[index + 1]:
            index += 1
            continue
        headers = table_cells(line)
        separators = table_cells(lines[index + 1])
        if len(headers) != len(separators) or not all(TABLE_SEPARATOR.fullmatch(cell) for cell in separators):
            index += 1
            continue
        normalized = [normalize(header) for header in headers]
        criterion_column = next((i for i, label in enumerate(normalized) if label == "acceptance criterion"), None)
        callsite_column = next((i for i, label in enumerate(normalized) if label == "production call site (file:line)"), None)
        if criterion_column is None or callsite_column is None:
            index += 1
            continue
        row_index = index + 2
        while row_index < len(lines) and "|" in lines[row_index]:
            cells = table_cells(lines[row_index])
            if max(criterion_column, callsite_column) < len(cells):
                rows.append((cells[criterion_column], cells[callsite_column]))
            row_index += 1
        index = row_index
    return rows


def is_production_path(path):
    candidate = PurePosixPath(path)
    if candidate.suffix.lower() not in SOURCE_SUFFIXES:
        return False
    if any(part.casefold() in NON_PRODUCTION_PARTS for part in candidate.parts):
        return False
    return TEST_NAME.search(candidate.name) is None


def changed_paths(repo, base, head):
    if not base:
        return None
    result = subprocess.run(
        ["git", "-C", repo, "diff", "--name-only", base, head, "--"],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode:
        return None
    return set(result.stdout.splitlines())


def candidate_line_count(repo, head, path):
    if not path or path.startswith("/") or "\x00" in path or ".." in PurePosixPath(path).parts:
        return None
    result = subprocess.run(
        ["git", "-C", repo, "show", f"{head}:{path}"],
        check=False,
        capture_output=True,
    )
    if result.returncode:
        return None
    return len(result.stdout.splitlines())


def check(repo, base, head, report_path, task):
    criteria = acceptance_criteria(task)
    if not criteria:
        print("acceptance-criteria coverage: skipped (no parseable acceptance-criteria list in issue body)")
        return 0
    try:
        with open(report_path, encoding="utf-8") as report_file:
            rows = coverage_rows(report_file.read())
    except (OSError, UnicodeError):
        rows = []
    normalized_rows = {}
    for criterion, callsites in rows:
        normalized_rows.setdefault(normalize(criterion), []).append((criterion, callsites))
    paths = changed_paths(repo, base, head)
    failed = False
    for criterion in criteria:
        matches = normalized_rows.get(normalize(criterion), [])
        if not matches:
            print(f"acceptance-criteria coverage check failed: missing report row for criterion: {criterion}")
            failed = True
            continue
        for _, callsites in matches:
            citations = CITATION.findall(callsites)
            if not citations:
                print(f"acceptance-criteria coverage check failed: report row for criterion \"{criterion}\" has no production call site (file:line)")
                failed = True
                continue
            for path, line_text in citations:
                line_count = candidate_line_count(repo, head, path)
                line = int(line_text)
                if not is_production_path(path):
                    print(f"acceptance-criteria coverage check failed: criterion \"{criterion}\" cites a path that is not a production source path: {path}:{line}")
                    failed = True
                elif line_count is None:
                    location = "diff does not touch the path and candidate branch does not contain it" if paths is not None and path not in paths else "candidate branch does not contain the path"
                    print(f"acceptance-criteria coverage check failed: criterion \"{criterion}\" cites {location}: {path}:{line}")
                    failed = True
                elif line > line_count:
                    print(f"acceptance-criteria coverage check failed: criterion \"{criterion}\" cites a non-existent line: {path}:{line}")
                    failed = True
    if failed:
        return 1
    print(f"acceptance-criteria coverage: passed ({len(criteria)} criteria)")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 5:
        print("acceptance-criteria coverage check failed: expected repo, base, head, and report path")
        raise SystemExit(1)
    raise SystemExit(check(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.stdin.read()))
