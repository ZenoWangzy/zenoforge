#!/usr/bin/env bash
# jq-arg-safety.test.sh — static guard for the 2026-09-16 defect class: this
# codebase's jq call sites routinely handed caller DATA (an issue body, a
# model's brief_md/decision_md, a whole ISSUE_JSON/prior-state object, a
# base64 MIME email) to jq via --arg/--argjson, i.e. through jq's own argv.
# Once a single value crossed Linux's MAX_ARG_STRLEN (128KiB per argv
# element -- separate from, and much smaller than, ARG_MAX), `execve`
# refused to even start jq: exit 126, "Argument list too long". Found THREE
# times in one day: state_merge()'s own $filter (fixed in 89e205846, jq -f
# from a temp file), then run-advisor-batch.sh's per-ticket $ISSUE_JSON
# (this same session, jq_arg_file()+--slurpfile), then a further ~10 sibling
# call sites across lib.sh/run-advisor.sh/run-implement.sh/run-triage.sh/
# notify.sh that never got the first fix because it only touched one
# function. jq_arg_file() (lib.sh) is the shared seam every one of those
# was converted to use; this is the guard that stops a FOURTH from
# appearing unnoticed.
#
# Static scan, same shape as run-implement.test.sh's literal-email-address
# guard (one grep, one file) and notify.test.sh's maintainer-engineering-work
# scanner (a python3 scan over every engine/*.sh call site, plus a
# meta-test proving the scanner has teeth): grep/awk can't reliably pick
# jq's own --arg/--argjson flag apart from an --arg mentioned in a comment
# or a --rawfile/--slurpfile call site that already fixed the same spot, so
# python3 (already a dependency this pipeline runs elsewhere, e.g. notify.
# sh's own MD_TO_HTML_PY) does the extraction here too.
#
# The name list preserves the prior incident cases. The loop scan adds a
# structural check: variables appended/rebuilt from themselves inside a
# while-read/for loop are unbounded by the unit count. It also follows a
# variable assigned from a function that returns a GitHub list census (for
# example tick_prs), so a list fed into jq from a loop's process substitution
# is covered. This runs recursively across engine shell sources, including
# scheduler.d where the original scan did not look.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/." && pwd -P)/test-env.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FAILED=0
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok - $desc"
  else
    echo "not ok - $desc (expected [$expected], got [$actual])"
    FAILED=1
  fi
}

# scan_file <path...> — prints one "BAD <file>:<line> <varname> <matched-text>"
# line per known-unbounded or loop-grown --arg/--argjson value. Exit status is
# always 0; the test below is the judgement.
scan_files() {
python3 - "$@" <<'PYEOF'
import re
import sys

files = sys.argv[1:]

# Exact (case-insensitive) names this codebase's own real call sites put
# through --arg/--argjson before the 2026-09-16 fix: an issue/PR/prior-state
# JSON blob, an advisor's reasoning/decision/notes/brief/merge_conditions/
# founder_question/ruling text, a MIME payload, a gate-log/transcript tail,
# an env-fault detail, a fail reason, stored recut/reset reasons, a generic body. Plus: anything named
# *_md (brief_md, decision_md, notes_md, needs_md, recut_md,
# review_report_md, ...) -- this codebase's own convention for unbounded
# markdown prose, verified against every existing *_md/*_MD variable name
# in engine/*.sh before this rule was written (none of them are
# short/bounded).
BANNED_EXACT = {
    "issue_json", "prior", "prior_state",
    "reasoning", "decision", "notes", "brief", "new_brief", "old_brief",
    "stored_brief", "merge_conditions", "founder_question", "ruling",
    "encoded", "detail", "tail", "reason", "recut_reason", "reset_reason", "what", "body",
    "material", "convergence_material",
    # 2026-10-11: the roadmap tree and open-issue list overflowed the per-argument limit.
    "flat", "tree", "open_issues", "candidates",
    # Closed-tracker dependency resolution also consumes unbounded GitHub payloads.
    "native_json", "open_issues_json", "closing_body",
    # Fastlane stage snapshots contain every issue body and comment.
    "all_rows", "issue_rows", "rows",
}

def is_banned(name):
    n = name.lower()
    return n in BANNED_EXACT or n.endswith("_md")

# Matches jq's own --arg NAME "$var" / --argjson NAME "${var}" -- an exact
# quoted variable REFERENCE, not a var interpolated inside a larger literal
# (which --arg/--argjson never bind directly anyway; only a bare "$x"/
# "${x}" token is a size-unbounded passthrough of x's own value).
ARG_RE = re.compile(r'--arg(?:json)?\s+[A-Za-z_][A-Za-z0-9_]*\s+"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"')
FUNCTION_RE = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{')
ASSIGN_RE = re.compile(r'(?:^|;)\s*(?:local\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*(\+?=)\s*([^;]*)')
# Includes completed run lists: 100 runs crossed the limit and stopped main-red-bisect for 39 hours, through a main_gh wrapper.
COLLECTION_COMMAND_RE = re.compile(r'\bgh\s+(?:pr|issue|run)\s+list\b|gh\s+api\b[^;]*/actions/[^;]*/runs\?')
PAGINATED_API_RE = re.compile(r'\bgh\s+api\b[^;]*--paginate')

def code_only(line):
    return "" if line.lstrip().startswith("#") else line

def function_blocks(lines):
    # Shell files often define functions and then run top-level code. Ending a
    # block at the next function declaration incorrectly attributes that
    # top-level code to the last function. In this repo function bodies close
    # with an unindented `}`; retain top-level ranges as separate scopes.
    functions = []
    i = 0
    while i < len(lines):
        match = FUNCTION_RE.match(code_only(lines[i]))
        if not match:
            i += 1
            continue
        start, name = i, match.group(1)
        end = len(lines) - 1
        for j in range(start + 1, len(lines)):
            if re.match(r'^}\s*(?:#.*)?$', code_only(lines[j])):
                end = j
                break
        functions.append((name, start, end + 1))
        i = end + 1
    blocks = []
    cursor = 0
    top_index = 0
    for name, start, end in functions:
        if cursor < start:
            blocks.append((f"<top-level-{top_index}>", cursor, start))
            top_index += 1
        blocks.append((name, start, end))
        cursor = end
    if cursor < len(lines):
        blocks.append((f"<top-level-{top_index}>", cursor, len(lines)))
    return blocks or [("<top-level-0>", 0, len(lines))]

def growing_variables(lines, growable_functions):
    growing = set()
    loop_depth = 0
    for raw in lines:
        line = code_only(raw)
        in_loop = loop_depth > 0
        for match in ASSIGN_RE.finditer(line):
            name, op, rhs = match.groups()
            shell_ref = re.search(r'\$' + re.escape(name) + r'(?![A-Za-z0-9_])|\$\{' + re.escape(name) + r'\}', rhs)
            jq_json_append = False
            for arg_name in re.findall(r'--argjson\s+([A-Za-z_][A-Za-z0-9_]*)\s+"\$' + re.escape(name) + r'"', rhs):
                if re.search(r'\$' + re.escape(arg_name) + r'\s*\+\s*[\[{]', rhs):
                    jq_json_append = True
            jq_input_append = shell_ref and re.search(r"(?:'|\")\s*\.\s*\+\s*[\[{]", rhs)
            # A plain self-reference can be a bounded normalization (for
            # example ${fragment_id%.json}); only treat it as growth when the
            # old value is extended with additional shell text.
            shell_append = False
            if shell_ref:
                ref_end = shell_ref.end()
                if rhs[ref_end:].lstrip().startswith(("\"", "'", "}")):
                    tail = rhs[ref_end:].lstrip()
                    shell_append = bool(re.match(r'[^\"\']+[^\"\']*[\"\']', tail))
                elif not rhs[max(0, shell_ref.start() - 2):shell_ref.start()].endswith("%"):
                    shell_append = bool(rhs[ref_end:].strip())
            if op == "+=" or (in_loop and (jq_json_append or jq_input_append or shell_append)):
                growing.add(name)
            calls = re.findall(r'\$\(\s*([A-Za-z_][A-Za-z0-9_]*)\b', rhs)
            if COLLECTION_COMMAND_RE.search(rhs) or PAGINATED_API_RE.search(rhs) \
                    or re.search(r'\bgh_api\b', rhs) \
                    or any(call in growable_functions for call in calls):
                growing.add(name)
        opens = len(re.findall(r'\b(?:while|for)\b.*?\bdo\b', line))
        closes = len(re.findall(r'\bdone\b', line))
        loop_depth = max(0, loop_depth + opens - closes)
    return growing

all_sources = {}
for fn in files:
    try:
        with open(fn, encoding="utf-8") as f:
            all_sources[fn] = f.readlines()
    except OSError:
        continue
growable_functions = set()
for lines in all_sources.values():
    for name, start, end in function_blocks(lines):
        if not name.startswith("<top-level-") and COLLECTION_COMMAND_RE.search("".join(map(code_only, lines[start:end]))):
            growable_functions.add(name)

for fn, lines in all_sources.items():
    blocks = function_blocks(lines)
    by_line = {}
    line_to_function = {}
    for function, start, end in blocks:
        growth = growing_variables(lines[start:end], growable_functions)
        for var in growth:
            by_line.setdefault(function, set()).add(var)
        for i in range(start, end):
            line_to_function[i] = function
    for lineno, line in enumerate(lines, 1):
        # Skip comment lines: this file's own docstrings (jq_arg_file() in
        # lib.sh, the historical-pattern callout in state_merge()'s comment)
        # quote the exact banned shape (`--arg b "$new_brief"`) as an example of
        # what NOT to do -- a scanner that can't tell a worked example from a
        # live call site would need every comment rewritten to dodge its own
        # guard, which is backwards.
        for m in ARG_RE.finditer(code_only(line)):
            name = m.group(1)
            function = line_to_function.get(lineno - 1, "<top-level>")
            if is_banned(name) or name in by_line.get(function, set()):
                print(f"{fn}:{lineno}: BAD {name} {m.group(0)}")
PYEOF
}

scan_file() {
  scan_files "$@"
}

# --- meta-test: prove the scanner itself has teeth before trusting it -----
# One fixture with a real violation (the exact shape run-advisor-batch.sh's
# own #1204-class incident had: a brief_md-bound value routed through
# --arg), one with the *_md suffix rule specifically, one clean fixture
# using the FIXED pattern (jq_arg_file()/--rawfile) on the SAME source
# variable name plus a comment that mentions the banned shape in prose --
# neither should be flagged.
BAD_FIXTURE="$TMP_DIR/bad.sh"
cat > "$BAD_FIXTURE" <<'EOF'
apply_one_ruling() {
  local new_brief patch
  new_brief="$(advisor_superseded_brief "$stored_brief" "$risk" "$level" "$conditions")"
  patch="$(jq -n --arg b "$new_brief" --arg r "$risk_class" '{brief_md: $b, risk_class: $r}')"
  state_merge "$n" ". + $patch"
}
EOF
BAD_MD_SUFFIX_FIXTURE="$TMP_DIR/bad_md.sh"
cat > "$BAD_MD_SUFFIX_FIXTURE" <<'EOF'
some_func() {
  local review_report_md patch
  review_report_md="$(echo "$REVIEW_OUTPUT" | jq -r '.structured_output.report_md')"
  patch="$(jq -n --arg t "$review_report_md" '{last_failure_tail: $t}')"
}
EOF
BAD_RECUT_REASON_FIXTURE="$TMP_DIR/bad_recut_reason.sh"
cat > "$BAD_RECUT_REASON_FIXTURE" <<'EOF'
recover_refusal() {
  local recut_reason reset_reason patch
  patch="$(jq -n --arg reason "$recut_reason" '{recut_refused_reason: $reason}')"
  patch="$(jq -n --arg reason "$reset_reason" '{recovery_reason: $reason}')"
}
EOF
BAD_MATERIAL_FIXTURE="$TMP_DIR/bad_material.sh"
cat > "$BAD_MATERIAL_FIXTURE" <<'EOF'
persist_verdict() {
  local material CONVERGENCE_MATERIAL patch
  patch="$(jq -n --argjson material "$material" '{advisor_last_verdict: {material: $material}}')"
  patch="$(jq -n --argjson material "$CONVERGENCE_MATERIAL" '{advisor_last_verdict: {material: $material}}')"
}
EOF
CLEAN_FIXTURE="$TMP_DIR/clean.sh"
BAD_CHILDREN_FIXTURE="$TMP_DIR/bad_children.sh"
cat > "$BAD_CHILDREN_FIXTURE" <<'EOF'
resolve_children() {
  jq -cn --argjson native "$native_json" --argjson open "$open_issues_json" --arg closing "$closing_body" '{}'
}
EOF
cat > "$CLEAN_FIXTURE" <<'EOF'
# 2026-09-16: state_merge's own $filter had to stop going through argv
# (see the incident this fixed: `jq -n --arg b "$new_brief" '{...}'` used to
# risk MAX_ARG_STRLEN). Converted call sites below use jq_arg_file()
# instead.
apply_one_ruling() {
  local new_brief patch brief_file
  new_brief="$(advisor_superseded_brief "$stored_brief" "$risk" "$level" "$conditions")"
  brief_file="$(jq_arg_file "$new_brief")"
  patch="$(jq -n --rawfile b "$brief_file" --arg r "$risk_class" '{brief_md: $b, risk_class: $r}')"
  rm -f "$brief_file"
  state_merge "$n" ". + $patch"
}

bounded_example() {
  local pr_number patch
  patch="$(jq -n --arg p "$pr_number" '{pr_number: $p}')"
}
EOF

BAD_HITS="$(scan_file "$BAD_FIXTURE")"
BAD_MD_HITS="$(scan_file "$BAD_MD_SUFFIX_FIXTURE")"
BAD_RECUT_REASON_HITS="$(scan_file "$BAD_RECUT_REASON_FIXTURE")"
BAD_MATERIAL_HITS="$(scan_file "$BAD_MATERIAL_FIXTURE")"
CLEAN_HITS="$(scan_file "$CLEAN_FIXTURE")"
BAD_CHILDREN_HITS="$(scan_file "$BAD_CHILDREN_FIXTURE")"
BAD_RUNS_FIXTURE="$TMP_DIR/bad_runs.sh"
cat > "$BAD_RUNS_FIXTURE" <<'EOF'
completed_runs() {
  main_gh api "repos/$REPO/actions/workflows/ci.yml/runs?branch=main&per_page=50"
}
red_runs() {
  local first
  first="$(completed_runs)"
  jq -cn --argjson first "$first" '$first'
}
EOF
assert_eq "meta-test: a completed run list reached through a wrapper is caught" \
  "1" "$(scan_file "$BAD_RUNS_FIXTURE" | sed '/^$/d' | wc -l | tr -d ' ')"

BAD_CENSUS_FIXTURE="$TMP_DIR/bad_census.sh"
cat > "$BAD_CENSUS_FIXTURE" <<'EOF'
merge_census() {
  jq -cn --argjson all "$all_rows" --argjson next "$issue_rows" '$all + $next'
}
EOF
BAD_CENSUS_HITS="$(scan_file "$BAD_CENSUS_FIXTURE")"
BAD_ROWS_FIXTURE="$TMP_DIR/bad_rows.sh"
cat > "$BAD_ROWS_FIXTURE" <<'EOF'
cache_rows() {
  local rows patch
  patch="$(jq -cn --arg rows "$rows" '{rows:$rows}')"
}
EOF
BAD_ROWS_HITS="$(scan_file "$BAD_ROWS_FIXTURE")"
BAD_LOOP_FIXTURE="$TMP_DIR/bad_loop_growth.sh"
cat > "$BAD_LOOP_FIXTURE" <<'EOF'
intake_footprint_snapshot() {
  local owners unit
  owners='[]'
  while IFS= read -r unit; do
    owners="$(jqf -cn --argjson owners "$owners" --argjson entry "$unit" '$owners + [$entry]')"
  done < units.json
}
tick_prs() {
  gh pr list --state open --json number,body
}
ci_slot_starve_watch() {
  local prs
  prs="$(tick_prs)"
  while IFS= read -r id; do :; done < <(jqf -r --argjson prs "$prs" '.units[]' units.json)
}
EOF
BAD_LOOP_HITS="$(scan_file "$BAD_LOOP_FIXTURE")"
assert_eq "meta-test: both unbounded fastlane census snapshots are caught" \
  "2" "$(printf '%s\n' "$BAD_CENSUS_HITS" | sed '/^$/d' | wc -l | tr -d ' ')"
assert_eq "meta-test: an unbounded rows value passed through --arg is caught" \
  "1" "$(printf '%s\n' "$BAD_ROWS_HITS" | sed '/^$/d' | wc -l | tr -d ' ')"
assert_eq "meta-test: loop-grown owners and GitHub census values are caught with file:line" \
  "2" "$(printf '%s\n' "$BAD_LOOP_HITS" | sed '/^$/d' | wc -l | tr -d ' ')"
assert_eq "meta-test: all closed-tracker dependency payloads are caught" \
  "3" "$(printf '%s\n' "$BAD_CHILDREN_HITS" | sed '/^$/d' | wc -l | tr -d ' ')"
assert_eq "meta-test: --arg binding a known-unbounded exact name (new_brief) is caught" \
  "1" "$([ -n "$BAD_HITS" ] && echo 1 || echo 0)"
assert_eq "meta-test: --arg binding a *_md-suffixed name (review_report_md) is caught by the suffix rule" \
  "1" "$([ -n "$BAD_MD_HITS" ] && echo 1 || echo 0)"
assert_eq "meta-test: --arg bindings of stored recut and recovery reasons are caught" \
  "2" "$(printf '%s\n' "$BAD_RECUT_REASON_HITS" | sed '/^$/d' | wc -l | tr -d ' ')"
assert_eq "meta-test: --argjson binding of unbounded verdict material is caught" \
  "2" "$(printf '%s\n' "$BAD_MATERIAL_HITS" | sed '/^$/d' | wc -l | tr -d ' ')"
assert_eq "meta-test: the FIXED pattern (jq_arg_file()/--rawfile on the same source variable) plus a comment quoting the banned shape in prose are NOT flagged" \
  "0" "$([ -n "$CLEAN_HITS" ] && echo 1 || echo 0)"

# --- the real regression guard. With no arguments, scan engine shell sources
# recursively; preflight passes changed paths so nested scripts are checked too.
REAL_SCRIPTS=()
if (($#)); then
  REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
  for f in "$@"; do
    case "$f" in engine/*.sh) ;; *) continue ;; esac
    [[ "$f" == *.test.sh ]] && continue
    [[ "$f" == /* ]] || f="$REPO_ROOT/$f"
    [[ -f "$f" ]] && REAL_SCRIPTS+=("$f")
  done
else
  while IFS= read -r -d '' f; do REAL_SCRIPTS+=("$f"); done \
    < <(find "$SCRIPT_DIR" -type f -name '*.sh' ! -name '*.test.sh' ! -path "$SCRIPT_DIR/vendor/*" -print0)
fi
REAL_HITS="$(scan_files "${REAL_SCRIPTS[@]}")"
if [ -n "$REAL_HITS" ]; then
  echo "not ok - engine shell files pass known-unbounded or loop-grown variables to jq via --arg/--argjson:"
  echo "$REAL_HITS" | sed 's/^/    /'
  FAILED=1
else
  echo "ok - no engine shell jq call passes a known-unbounded or loop-grown variable through --arg/--argjson"
fi

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
