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
# What counts as "known-unbounded": a curated name list (the actual bash
# variable names this codebase's real incidents put through --arg/
# --argjson: an issue/PR JSON blob, a prior state record, an advisor's
# reasoning/decision/notes/brief/merge_conditions/founder_question, a MIME
# payload, a gate-log/transcript tail, an env-fault detail, a fail reason)
# plus a blanket rule for anything named `*_md` -- this codebase's own
# convention for markdown prose fields (brief_md, decision_md, notes_md,
# needs_md, recut_md, review_report_md, ...), all of them model output or
# accumulated narrative with no size cap. Deliberately a name list, not a
# byte-size heuristic: a static scanner can't know a value's runtime size,
# only that this codebase already learned (three times) which NAMES carry
# unbounded content. Like the two guards this is modeled on, it is not
# exhaustive -- it catches a REGRESSION back to a name this convention
# already flags, not every conceivable new unbounded variable under a new
# name.
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

# scan_file <path...> — prints one "BAD <line> <varname> <matched-text>" line
# per --arg/--argjson call site that binds a known-unbounded bash variable,
# nothing if files are clean. Exit status is always 0 (a scanner, not the
# judgement -- same contract as notify.test.sh's own scan_file).
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
    "encoded", "detail", "tail", "reason", "recut_reason", "reset_reason", "what", "body", "pr",
    "material", "convergence_material",
    # 2026-10-11: the roadmap tree and open-issue list overflowed the per-argument limit.
    "flat", "tree", "open_issues", "candidates",
    # Closed-tracker dependency resolution also consumes unbounded GitHub payloads.
    "native_json", "open_issues_json", "closing_body",
    # Fastlane stage snapshots contain every issue body and comment.
    "all_rows", "issue_rows",
}

def is_banned(name):
    n = name.lower()
    return n in BANNED_EXACT or n.endswith("_md")

# Matches jq's own --arg NAME "$var" / --argjson NAME "${var}" -- an exact
# quoted variable REFERENCE, not a var interpolated inside a larger literal
# (which --arg/--argjson never bind directly anyway; only a bare "$x"/
# "${x}" token is a size-unbounded passthrough of x's own value).
ARG_RE = re.compile(r'--arg(?:json)?\s+[A-Za-z_][A-Za-z0-9_]*\s+"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"')

for fn in files:
    with open(fn, encoding="utf-8") as f:
        lines = f.readlines()
    for lineno, line in enumerate(lines, 1):
        # Skip comment lines: this file's own docstrings (jq_arg_file() in
        # lib.sh, the historical-pattern callout in state_merge()'s comment)
        # quote the exact banned shape (`--arg b "$new_brief"`) as an example of
        # what NOT to do -- a scanner that can't tell a worked example from a
        # live call site would need every comment rewritten to dodge its own
        # guard, which is backwards.
        if line.lstrip().startswith("#"):
            continue
        for m in ARG_RE.finditer(line):
            name = m.group(1)
            if is_banned(name):
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
BAD_CENSUS_FIXTURE="$TMP_DIR/bad_census.sh"
cat > "$BAD_CENSUS_FIXTURE" <<'EOF'
merge_census() {
  jq -cn --argjson all "$all_rows" --argjson next "$issue_rows" '$all + $next'
}
EOF
BAD_CENSUS_HITS="$(scan_file "$BAD_CENSUS_FIXTURE")"
assert_eq "meta-test: both unbounded fastlane census snapshots are caught" \
  "2" "$(printf '%s\n' "$BAD_CENSUS_HITS" | sed '/^$/d' | wc -l | tr -d ' ')"
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

# --- the real regression guard. With no arguments, scan top-level scripts;
# preflight passes changed paths so nested scripts are checked too.
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
  for f in "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/lib.d/*.sh; do
    [[ "$f" == *.test.sh ]] || REAL_SCRIPTS+=("$f")
  done
fi
REAL_HITS="$(scan_files "${REAL_SCRIPTS[@]}")"
if [ -n "$REAL_HITS" ]; then
  echo "not ok - engine shell files pass known-unbounded variables to jq via --arg/--argjson:"
  echo "$REAL_HITS" | sed 's/^/    /'
  FAILED=1
else
  echo "ok - no jq call site in scanned engine shell files passes a known-unbounded variable through --arg/--argjson"
fi

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
