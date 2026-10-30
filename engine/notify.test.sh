#!/usr/bin/env bash
# notify.test.sh — regression guard for the 2026-09-15 maintainer complaint
# (verbatim: [...]
# ). The live instance was run-implement.sh's old
# fail_attempt() body: [...]
#  — a founder-facing email handing back engineering
# work (go look at a diff, decide whether to fix it or merge it by hand)
# instead of the pipeline doing it or reaching a terminal on its own. See
# lessons/RULES.md V111.
#
# Static scan, same shape as run-implement.test.sh's literal-email-address
# guard: no gh/network/DRY_RUN plumbing, just grep every notify_email()/
# notify_email_everyone()/notify_founder()/notify_email_verbatim() call
# site's own argument text; routine changes go through the digest, while only
# founder-only decisions or production outages go out immediately.
# notify_reporter_question() deliberately never includes him, see notify.sh.
# Scan for a fixed list of banned asks: looking at something, debugging, rerunning, merging
# by hand, or a "which/where/how" confirmation that is really a diagnosis
# request in disguise.
#
# Extracting one call's full argument text needs real quote-state tracking
# (a call's body is routinely a multi-line, backslash-continued, or
# raw-newline-containing double-quoted string — see the fixtures below) that
# plain grep/awk can't do reliably; python3 is already a dependency this
# pipeline runs at every send (notify.sh's own MD_TO_HTML_PY), so it does
# the extraction here too rather than reinventing a shell-only parser.
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

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "ok - $desc"
  else
    echo "not ok - $desc"
    FAILED=1
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "ok - $desc"
  else
    echo "not ok - $desc"
    FAILED=1
  fi
}

# scan_file <path> — prints one "BAD <call-number> <pattern>" line per
# banned match found in that file's notify_email()/notify_email_everyone()/
# notify_founder()/notify_email_verbatim() call sites, nothing if the file
# is clean. Exit
# status is always 0 (this is a scanner, not the pass/fail judgement --
# callers decide that from the presence/absence of output, same as
# notify.sh's own notes_md_offending_matches()).
scan_file() {
  python3 - "$1" <<'PYEOF'
import re
import sys

fn = sys.argv[1]
with open(fn, encoding="utf-8") as f:
    lines = f.readlines()

# Banned asks: engineering work a founder-facing email must never hand
# back. Deliberately narrow phrases (not a bare "需要你", which also covers
# legitimate asks this suite keeps, like authorizing a production redeploy)
# -- see this file's header for the exact categories this mirrors.
BANNED = [
    r'看一(下|眼)',
    r'检查一下',
    r'查一下',
    r'排查',
    r'调试',
    r'[Dd]ebug',
    r'手动合并',
    r'手动发布',
    r'需要人工',
    r'需要有人',
    r'需要工程师',
    r'找工程师',
    r'人工介入',
    r'重新跑',
    r'重跑',
    r'[Rr]erun',
    r'确认.{0,10}(该|哪个|哪里|怎么)',
    r'请决定是否安排.{0,12}(负责人|owner)',
]

INTERNAL_DIAGNOSTIC_TERMS = re.compile(
    r'missing capability|control-surface|P2/L4|advisor round-trip|'
    r'risk[_-]class|expected_packages|touched paths|escalation ladder',
    re.IGNORECASE,
)
ASCII_WORD_RUN = re.compile(
    r"(?:^|[^A-Za-z])(?:[A-Za-z]+(?:'[A-Za-z]+)?[ \t\n]+){3}"
    r"[A-Za-z]+(?:'[A-Za-z]+)?(?:[^A-Za-z]|$)"
)

def maintainer_readable(text, enforce_length):
    if not re.search(r'[\u3400-\u9fff]', text):
        return False, 'missing-cjk'
    if ASCII_WORD_RUN.search(text):
        return False, 'english-word-run'
    if enforce_length and len(text) > 400:
        return False, 'too-long'
    if INTERNAL_DIAGNOSTIC_TERMS.search(text):
        return False, 'internal-diagnostic'
    return True, ''

# extract_quoted_block <lines> <start_index> -> (text, next_index) -- shared
# quote-parity walk: a call's own arguments AND a plain VAR="..." assignment
# both need the same "keep consuming lines until the quotes balance and this
# line isn't itself \-continued" logic (a body routinely spans several
# lines, either via multi-line double-quoted content with a real embedded
# newline -- e.g. lib.sh's pause_for_backoff -- or via \-continued separate
# arguments -- e.g. every run-release.sh call site).
def extract_quoted_block(all_lines, start):
    total = 0
    buf = []
    i = start
    while i < len(all_lines):
        line = all_lines[i]
        buf.append(line)
        total += line.count('"')
        closed = total > 0 and total % 2 == 0
        continues = line.rstrip("\n").endswith("\\")
        i += 1
        if closed and not continues:
            break
    return "".join(buf), i

# Some call sites (run-release.sh's DEPLOY_FAILED_* quartet) pass bare
# variable references as arguments instead of inline text -- the engineering-
# work ask then lives in a separate VAR="..." assignment earlier in the same
# file, invisible to a scan of the call's own literal text alone (and, for
# an if/else pair like DEPLOY_FAILED_ACTION, there can be TWO assignments to
# the same name -- both branches feed the one call after the `if`, so both
# must be checked, not just whichever textually comes last). Build a
# name -> list-of-every-assigned-text map for every simple top-level
# `VAR="..."` assignment in the file (single- or multi-line, same shape as a
# call's own arguments) so a bare "$VAR"/"${VAR}" argument can be resolved
# before the banned-phrase check runs. Deliberately simple: only the exact
# `VAR="` opener (no `${VAR}=`, no arrays, no `export`) -- the one shape
# this pipeline's email-body variables actually use.
assignments = {}
i = 0
while i < len(lines):
    m = re.match(r'^\s*([A-Za-z_][A-Za-z0-9_]*)="', lines[i])
    if m:
        text, nxt = extract_quoted_block(lines, i)
        assignments.setdefault(m.group(1), []).append(text)
        i = nxt
        continue
    i += 1

def resolve_bare_vars(call_text):
    # Finds every argument that is NOTHING but "$VAR" or "${VAR}" (an exact
    # quoted token -- the regex's own quotes anchor immediately around the
    # variable, so it never matches "$VAR" interpolated inside a larger
    # literal string, which the raw call text already covers directly), any
    # number of them per line (run-release.sh's DEPLOY_FAILED_* quartet
    # packs three onto one line). Every historical assignment to that name
    # is appended (not just the last), so an if/else pair that both feed
    # the same call are both checked.
    extra = []
    for m in re.finditer(r'"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"', call_text):
        extra.extend(assignments.get(m.group(1), []))
    return call_text + "\n" + "\n".join(extra)

def quoted_tokens(text):
    return [m.group(1) for m in re.finditer(r'"((?:\\.|[^"\\])*)"', text, re.S)]

def literal_assignment_value(assignment):
    # A command substitution is runtime/model data, not a literal that this
    # authoring-time guard can judge. Leave it to the runtime whitelist.
    if '$(' in assignment:
        return None
    # Same class: `VAR="$OTHER"` is an alias, not authored text. Whatever
    # $OTHER holds is judged at runtime by the same whitelist gate this
    # scanner mirrors -- it is not a literal this pass can read.
    if re.match(r'^\s*[A-Za-z_][A-Za-z0-9_]*="\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"\s*$', assignment, re.S):
        return None
    match = re.match(r'^\s*[A-Za-z_][A-Za-z0-9_]*="(.*)"\s*$', assignment, re.S)
    return match.group(1) if match else None

def field_texts(call_text, kind):
    tokens = quoted_tokens(call_text)
    starts = {'email': 2, 'email_everyone': 2, 'email_verbatim': 2, 'maintainer': 1}
    lengths = {'email': 3, 'email_everyone': 3, 'email_verbatim': 1, 'maintainer': 1}
    for token in tokens[starts[kind]:starts[kind] + lengths[kind]]:
        variable = re.fullmatch(r'\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?', token)
        if variable:
            values = assignments.get(variable.group(1), [])
            if not values:
                continue
            for assignment in values:
                value = literal_assignment_value(assignment)
                if value is not None:
                    yield value
            continue
        yield token

infunc = False
total_quotes = 0
buf = []
call_num = 0
for line in lines:
    kind_match = re.search(r'notify_(email_everyone|email_verbatim|email|maintainer)\s+"', line)
    if not infunc and kind_match and not line.lstrip().startswith('#'):
        infunc = True
        kind = kind_match.group(1)
        # The call can sit after a command prefix (`[ ... ] &&`) or inside
        # an assignment's command substitution (`OUT="$(notify_...)"`).
        # Start at the function name so quotes belonging to that prefix do
        # not corrupt the argument/token count.
        first_segment = line[kind_match.start():]
        # A command-substitution call may have the assignment's closing
        # double quote after the call's closing `)`. It belongs to the
        # surrounding assignment, not to this invocation's arguments.
        prefix = line[:kind_match.start()]
        if "$(" in prefix and first_segment.rstrip("\n").endswith('"'):
            first_segment = first_segment.rstrip("\n")[:-1] + "\n"
        total_quotes = first_segment.count('"')
        buf = [first_segment]
        if total_quotes > 0 and total_quotes % 2 == 0 and not first_segment.rstrip('\n').endswith('\\'):
            call_num += 1
            call_text = resolve_bare_vars("".join(buf))
            for pattern in BANNED:
                if re.search(pattern, call_text):
                    print(f"BAD {call_num} {pattern}")
            enforce_length = kind != 'maintainer'
            for field in field_texts("".join(buf), kind):
                passed, reason = maintainer_readable(field, enforce_length)
                if not passed:
                    print(f"BAD {call_num} whitelist:{reason}")
            infunc = False
            continue
        continue
    if infunc:
        buf.append(line)
        total_quotes += line.count('"')
        closed = total_quotes > 0 and total_quotes % 2 == 0
        continues = line.rstrip("\n").endswith("\\")
        if closed and not continues:
            call_num += 1
            call_text = resolve_bare_vars("".join(buf))
            for pattern in BANNED:
                if re.search(pattern, call_text):
                    print(f"BAD {call_num} {pattern}")
            enforce_length = kind != 'maintainer'
            for field in field_texts("".join(buf), kind):
                passed, reason = maintainer_readable(field, enforce_length)
                if not passed:
                    print(f"BAD {call_num} whitelist:{reason}")
            infunc = False
PYEOF
}

# --- meta-test: prove the scanner itself has teeth before trusting it -----
# A guard nobody has ever seen fail is not a guard, it's a comment. One
# fixture with a real banned ask (verbatim shape of the maintainer's own
# complaint), one clean fixture with the same multi-line/backslash-
# continued/raw-newline shapes every real call site above actually uses.
BAD_FIXTURE="$TMP_DIR/bad.sh"
cat > "$BAD_FIXTURE" <<'EOF'
fail_attempt() {
  notify_email "$n" "[example] #$n 需要你处理" \
"机器人跑完了。" \
"$NOTIFY_IMPACT_BLOCKED" \
"请决定是否安排该环节负责人接手，或由你去对应的改动里看一下测试为什么没过。"
}
EOF
CLEAN_FIXTURE="$TMP_DIR/clean.sh"
cat > "$CLEAN_FIXTURE" <<'EOF'
pause_for_backoff() {
  notify_founder "[example] 流水线暂停了" \
"调用失败了一次，先自动停了大概一小时。

想现在就恢复：删掉这个文件 -- $PAUSE_FILE"
  notify_email "$n" "[example] #$n 已经转给顾问了" \
"机器人已经尝试了几次，还是没能处理完，已经转给顾问（advisor）处理，不用你管。" \
"$NOTIFY_IMPACT_BLOCKED" \
"通常不用管；如果后续还有问题，issue 上会有记录。"
}
EOF

BAD_HITS="$(scan_file "$BAD_FIXTURE")"
CLEAN_HITS="$(scan_file "$CLEAN_FIXTURE")"
assert_eq "meta-test: a fixture that hands back engineering work is caught" \
  "1" "$([ -n "$BAD_HITS" ] && echo 1 || echo 0)"
assert_contains "meta-test: node-owner assignment ask is explicitly banned" \
  "$BAD_HITS" "请决定是否安排.{0,12}(负责人|owner)"
assert_eq "meta-test: a clean, multi-line/backslash-continued fixture (same shapes as real call sites) is NOT flagged" \
  "0" "$([ -n "$CLEAN_HITS" ] && echo 1 || echo 0)"

ENGLISH_FIXTURE="$TMP_DIR/english.sh"
cat > "$ENGLISH_FIXTURE" <<'EOF'
report() {
  notify_email "$n" "[example] 需要汇报" \
"The pipeline could not finish this issue because the review remains blocked." \
"用户暂时看不到变化。" \
"不用。"
}
EOF
ENGLISH_HITS="$(scan_file "$ENGLISH_FIXTURE")"
assert_eq "meta-test: a literal English report field is rejected by the whitelist" \
  "1" "$([ -n "$ENGLISH_HITS" ] && echo 1 || echo 0)"

# --- the real regression guard: every notify_email()/notify_email_everyone()/
# notify_founder()/notify_email_verbatim() call site in engine,
# whichever file it lives in. Not a fixed file list: a new leg script that
# starts sending founder-facing mail is covered automatically, the same way
# run-implement.test.sh's email-address guard covers a re-edit of that one
# file without anyone remembering to update the test.
ANY_REAL_HIT=0
for f in "$SCRIPT_DIR"/*.sh; do
  case "$f" in
    *.test.sh) continue ;;
  esac
  HITS="$(scan_file "$f")"
  if [ -n "$HITS" ]; then
    ANY_REAL_HIT=1
    echo "not ok - $(basename "$f") asks the maintainer to do engineering work:"
    echo "$HITS" | sed 's/^/    /'
    FAILED=1
  fi
done
if [ "$ANY_REAL_HIT" -eq 0 ]; then
  echo "ok - no notify_email()/notify_founder()/notify_email_verbatim() call site in engine/*.sh asks the maintainer to do engineering work"
fi

# --- #1256 regression: internal diagnostics must not survive
# build_report_body's 你要不要做什么 rendering ------------------------------
# The static scan_file() guard above only ever sees SOURCE TEXT at a call
# site. #1256's leak was RUNTIME content: lib.sh's conclude_run() (its
# generic report path for the pr-open/not-completed outcomes, ~line
# 1336-1341) splices whatever $needs_md some other script built straight
# into notify_email()'s $action argument --
#   "不用现在就做什么；${needs_md:-这条 issue 的评论里有完整记录}。"
# -- and $needs_md itself is built one file away, in run-implement.sh
# (e.g. line 1234's NEEDS_MD=... for the P2/L4-after-4-attempts case that
# actually fired for #1256). No grep over engine/*.sh's literal
# text can ever see that string -- it exists only once the pipeline
# actually runs $(state_attempts "$N") and interpolates it in. So this
# section calls the real renderer (build_report_body(), sourced from this
# directory's notify.sh) with the REAL producer text and inspects its
# OUTPUT instead of the source.
#
# REAL_NEEDS_MD below is reconstructed verbatim from the two real
# producers that built and sent this exact email on 2026-09-16 04:14 UTC
# for issue #1256 (both out of scope for this change -- see this repo's
# delivery rules for why -- so copied here as a frozen fixture rather than
# sourced live; if either producer's wording ever changes, that is this
# test doing its job, not drift to silently tolerate):
#   run-implement.sh:1234 (NEEDS_MD="The implementation keeps touching a
#     P2/L4 path even after $(state_attempts "$N") implement attempts
#     (including at least one advisor round-trip). Missing capability: a
#     recut or guarded admission that actually resolves this class of hit.
#     Touched paths:\n$RISK_CLASS_SUMMARY")
#   lib.sh:1336-1341 (conclude_run()'s generic not-completed/pr-open
#     report -- the "不用现在就做什么；${needs_md:-...}。" wrapping)
# notify.sh (RECIPIENTS_FILE, the credential-alert marker) reads AGENT_HOME
# unconditionally at source time -- give it a scratch dir of its own,
# same pattern as run-advisor-batch.test.sh/run-recut.test.sh.
export AGENT_HOME="$TMP_DIR"
DRY_RUN=0
export DRY_RUN
source "$SCRIPT_DIR/lib.sh"

# 2026-10-04: blocked/missing/deferred check conclusions send no mail; the maintainer contract refused every
# attempt and each refusal flipped mail-credential BROKEN. The issue comment carries the status.
if sed -n '/blocked|missing|deferred)/,/return 0/p' "$SCRIPT_DIR/lib.sh" | grep -q 'notify_'; then
  echo 'not ok - blocked/missing/deferred check conclusions send no mail' >&2
  exit 1
fi
echo 'ok - blocked/missing/deferred check conclusions send no mail'

GMAIL_PROBE_BIN="$TMP_DIR/gmail-probe-bin"
mkdir -p "$GMAIL_PROBE_BIN"
cat >"$GMAIL_PROBE_BIN/gcloud" <<'EOF'
#!/usr/bin/env bash
printf '%s' "$FAKE_GCLOUD_STDERR" >&2
printf '%s' "$FAKE_GCLOUD_TOKEN"
exit "$FAKE_GCLOUD_EXIT"
EOF
cat >"$GMAIL_PROBE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s' "$FAKE_CURL_CODE"
exit "$FAKE_CURL_EXIT"
EOF
chmod +x "$GMAIL_PROBE_BIN/gcloud" "$GMAIL_PROBE_BIN/curl"
GMAIL_PROBE_OLD_PATH="$PATH"
GMAIL_PROBE_OLD_DRY_RUN="$DRY_RUN"
PATH="$GMAIL_PROBE_BIN:$PATH"
DRY_RUN=0
export PATH ZF_GCLOUD_BIN="$GMAIL_PROBE_BIN/gcloud" DRY_RUN
export FAKE_GCLOUD_EXIT=1 FAKE_GCLOUD_STDERR="Could not connect to proxy: connection timed out"
export FAKE_GCLOUD_TOKEN=probe-token FAKE_CURL_EXIT=0 FAKE_CURL_CODE=200
assert_eq "a proxy failure during token refresh is transient" \
  "transient" "$(gmail_credential_probe)"

export FAKE_GCLOUD_STDERR="OAuth refresh failed: invalid_grant"
assert_eq "an explicit invalid_grant is classified separately" \
  "invalid_grant" "$(gmail_credential_probe)"

export FAKE_GCLOUD_EXIT=0 FAKE_GCLOUD_STDERR="" FAKE_CURL_EXIT=7 FAKE_CURL_CODE=000
assert_eq "a Gmail API transport failure is transient" \
  "transient" "$(gmail_credential_probe)"

export FAKE_CURL_EXIT=0 FAKE_CURL_CODE=503
assert_eq "a Gmail API server failure is transient" \
  "transient" "$(gmail_credential_probe)"

export FAKE_CURL_CODE=200
assert_eq "successful Gmail profile probe is healthy" \
  "ok" "$(gmail_credential_probe)"

PATH="$GMAIL_PROBE_OLD_PATH"
DRY_RUN="$GMAIL_PROBE_OLD_DRY_RUN"
export PATH
export DRY_RUN
unset ZF_GCLOUD_BIN FAKE_GCLOUD_EXIT FAKE_GCLOUD_STDERR FAKE_GCLOUD_TOKEN FAKE_CURL_EXIT FAKE_CURL_CODE

GMAIL_COUNT_BIN="$TMP_DIR/gmail-count-bin"
mkdir -p "$GMAIL_COUNT_BIN"
cat >"$GMAIL_COUNT_BIN/gcloud" <<'EOF'
#!/usr/bin/env bash
printf 'count-token'
EOF
cat >"$GMAIL_COUNT_BIN/curl" <<'EOF'
#!/usr/bin/env bash
valid_query=0
for arg in "$@"; do
  [ "$arg" = 'q=in:sent to:maintainer@example.test after:999 before:2000' ] && valid_query=1
done
[ "$valid_query" -eq 1 ] || exit 88
case " $* " in
  *'pageToken=next-page'*) printf '%s\n200' '{"resultSizeEstimate":1,"messages":[{"id":"c"}]}' ;;
  *) printf '%s\n200' '{"resultSizeEstimate":3,"messages":[{"id":"a"},{"id":"b"}],"nextPageToken":"next-page"}' ;;
esac
EOF
chmod +x "$GMAIL_COUNT_BIN/gcloud" "$GMAIL_COUNT_BIN/curl"
ZF_GCLOUD_BIN="$GMAIL_COUNT_BIN/gcloud"
GMAIL_MESSAGES_URL='https://gmail.example.test/messages'
GMAIL_COUNT_OLD_PATH="$PATH"
PATH="$GMAIL_COUNT_BIN:$PATH"
export PATH
assert_eq "SENT count uses maintainer and UTC bounds and follows every Gmail page" \
  "3" "$(gmail_sent_message_count maintainer@example.test 1000 2000)"
PATH="$GMAIL_COUNT_OLD_PATH"
export PATH
unset ZF_GCLOUD_BIN GMAIL_MESSAGES_URL

GMAIL_CONFIRMATION_OUTPUT="$(AGENT_HOME="$TMP_DIR/gmail-confirmation" bash -c '
  set -euo pipefail
  mkdir -p "$AGENT_HOME"
  source "$1/notify.sh"
  DRY_RUN=0
  CRED_STATE_JSON="{\"attempts\":0}"
  state_read() { printf "%s\n" "$CRED_STATE_JSON"; }
  state_merge() { CRED_STATE_JSON="$status_json"; }
  gmail_credential_probe() { printf "%s\n" "$FAKE_PROBE_STATUS"; }
  notify_founder() { printf "%s\n" "$1" >> "$AGENT_HOME/mails"; }
  FAKE_PROBE_STATUS=invalid_grant
  check_gmail_credential
  first_status="$(jq -r .status <<< "$CRED_STATE_JSON")"
  first_count="$(jq -r .invalid_grant_checks <<< "$CRED_STATE_JSON")"
  first_reason="$(jq -r .reason <<< "$CRED_STATE_JSON")"
  first_mails=0
  [ ! -f "$AGENT_HOME/mails" ] || first_mails="$(wc -l < "$AGENT_HOME/mails")"
  check_gmail_credential
  second_status="$(jq -r .status <<< "$CRED_STATE_JSON")"
  second_count="$(jq -r .invalid_grant_checks <<< "$CRED_STATE_JSON")"
  second_reason="$(jq -r .reason <<< "$CRED_STATE_JSON")"
  second_mails=0
  [ ! -f "$AGENT_HOME/mails" ] || second_mails="$(wc -l < "$AGENT_HOME/mails")"
  FAKE_PROBE_STATUS=transient
  check_gmail_credential
  third_status="$(jq -r .status <<< "$CRED_STATE_JSON")"
  third_count="$(jq -r .invalid_grant_checks <<< "$CRED_STATE_JSON")"
  third_reason="$(jq -r .reason <<< "$CRED_STATE_JSON")"
  third_mails=0
  [ ! -f "$AGENT_HOME/mails" ] || third_mails="$(wc -l < "$AGENT_HOME/mails")"
  [ -z "$first_reason" ] && first_reason=empty || first_reason=present
  [ -n "$second_reason" ] && second_reason=present || second_reason=empty
  [ -z "$third_reason" ] && third_reason=empty || third_reason=present
  printf "%s|%s|%s|%s;%s|%s|%s|%s;%s|%s|%s|%s\n" \
    "$first_status" "$first_count" "$first_reason" "$first_mails" \
    "$second_status" "$second_count" "$second_reason" "$second_mails" \
    "$third_status" "$third_count" "$third_reason" "$third_mails"
' _ "$SCRIPT_DIR")"
assert_eq "credential status and reason stay local; transient failure resets confirmation" \
  "unconfirmed|1|empty|0;broken|2|present|0;transient|0|empty|0" "$GMAIL_CONFIRMATION_OUTPUT"

HEALTH_ROW_BODY="$(cat <<'EOF'
做了什么：夜间巡检发现顾问队列仍未恢复。
对用户有什么影响：待处理的问题可能延迟。
你要不要做什么：系统会自动派发负责人；恢复后停止提醒，无需你操作。
HEALTH 行：advisor BROKEN 58 queued, no ruling ever recorded
EOF
)"
assert_eq "maintainer-readable gate preserves one structured HEALTH row" "true" \
  "$(if looks_like_maintainer_readable "$HEALTH_ROW_BODY" 0; then echo true; else echo false; fi)"
assert_eq "maintainer-readable gate rejects malformed HEALTH rows" "false" \
  "$(if looks_like_maintainer_readable "${HEALTH_ROW_BODY/HEALTH 行：advisor BROKEN 58 queued, no ruling ever recorded/HEALTH 行：broken}" 0; then echo true; else echo false; fi)"
assert_eq "maintainer-readable gate rejects repeated HEALTH rows" "false" \
  "$(if looks_like_maintainer_readable "$HEALTH_ROW_BODY
HEALTH 行：advisor BROKEN 58 queued, no ruling ever recorded" 0; then echo true; else echo false; fi)"
assert_eq "maintainer-readable gate still rejects English outside HEALTH row" "false" \
  "$(if looks_like_maintainer_readable "The pipeline needs owner action now.
$HEALTH_ROW_BODY" 0; then echo true; else echo false; fi)"

REAL_NEEDS_MD="The implementation keeps touching a P2/L4 path even after 4 implement attempts (including at least one advisor round-trip). Missing capability: a recut or guarded admission that actually resolves this class of hit. Touched paths:
- engine/run-implement.test.sh (control-surface)"
REAL_ACTION="不用现在就做什么；${REAL_NEEDS_MD}。"

RENDERED_1256_BODY="$(build_report_body "1256" \
  "管线在评论和失败原因里打印 Git 提交 ID，违反项目级哈希禁令" \
  "example-maintainer" \
  "机器人这次没能把票带到合并——这是一份报告，不是在问你要怎么办。" \
  "这个问题目前还没有解决，用户暂时不会看到变化。" \
  "$REAL_ACTION")"

echo "----- rendered #1256 email body (from the current code) -----"
echo "$RENDERED_1256_BODY"
echo "---------------------------------------------------------------"

# Mechanical, allow-list-shaped check: these terms of art may NEVER appear
# in a human-facing section. This is not the same property as "no banned
# Chinese ask" above -- it is checked against build_report_body()'s
# RENDERED OUTPUT for the real #1256 input, so a future author cannot
# satisfy it by rephrasing $needs_md's Chinese wrapper (the leak was never
# in the Chinese) or by moving the English into a different producer file:
# every not-completed/pr-open report in this pipeline funnels through this
# same renderer.
for term in "P2/L4" "control-surface" "advisor round-trip" "Missing capability" "Touched paths"; do
  if echo "$RENDERED_1256_BODY" | grep -qF "$term"; then
    echo "not ok - #1256 rendered body leaks internal term-of-art: $term"
    FAILED=1
  else
    echo "ok - #1256 rendered body does not leak: $term"
  fi
done

# Positive requirement, not just an absence: when the real producer's text
# is an internal diagnostic, 你要不要做什么 says there's nothing to do, in
# one short honest line, and stops -- not silence, not a partial edit of
# the diagnostic, not a Chinese paraphrase of "control-surface".
EXPECTED_ACTION_BLOCK="你要不要做什么：
不用。细节在这条 issue 里。"
# Bash substring test (`[[ == *pattern* ]]`), not grep: the block being
# checked spans two lines, and grep treats an embedded newline in its own
# PATTERN argument as two independent single-line patterns (each counted
# separately), which would pass even if the two lines never landed next to
# each other -- exactly the false confidence this guard must not have.
if [[ "$RENDERED_1256_BODY" == *"$EXPECTED_ACTION_BLOCK"* ]]; then
  ACTION_BLOCK_HIT=1
else
  ACTION_BLOCK_HIT=0
fi
assert_eq "#1256: 你要不要做什么 collapses to the one honest 'nothing to do' line" \
  "1" "$ACTION_BLOCK_HIT"

# meta-test: prove the maintainer-readable gate has teeth in both directions --
# a genuinely clean, human-authored action (same shape as every other real
# notify_email() call site's action text, e.g. run-release.sh:65) must
# survive untouched, not just get lucky by having no English at all.
CLEAN_ACTION_RENDERED="$(build_report_body "1256" "t" "r" "w" "i" \
  "不用你现在动手改代码；等确认线上已经没问题、可以继续发布了，删掉这个文件就行，流水线会自动恢复发布：$HOME/.zenoforge/state/deploy-blocked")"
assert_eq "meta-test: a genuinely clean action (with a bare file path, no jargon) passes through unedited" \
  "1" "$(echo "$CLEAN_ACTION_RENDERED" | grep -cF "删掉这个文件就行，流水线会自动恢复发布：$HOME/.zenoforge/state/deploy-blocked")"

# --- positive whitelist coverage for every report field --------------------
ENGLISH_DIAGNOSTIC="The pipeline could not finish this issue because the review remains blocked."
WHAT_DIAGNOSTIC_BODY="$(build_report_body "1254" "连接器账号状态可读探测" "example-maintainer" \
  "$ENGLISH_DIAGNOSTIC" "问题还在，用户暂时看不到变化。" "不用。")"
assert_eq "whitelist: English 做了什么 is replaced as a whole field" \
  "1" "$(echo "$WHAT_DIAGNOSTIC_BODY" | grep -cF "这一轮没能改完。")"
assert_not_contains "whitelist: English 做了什么 does not survive" \
  "$WHAT_DIAGNOSTIC_BODY" "$ENGLISH_DIAGNOSTIC"

IMPACT_DIAGNOSTIC_BODY="$(build_report_body "1254" "连接器账号状态可读探测" "example-maintainer" \
  "本轮没能改完。" "$ENGLISH_DIAGNOSTIC" "不用。")"
assert_eq "whitelist: English 对用户有什么影响 is replaced as a whole field" \
  "1" "$(echo "$IMPACT_DIAGNOSTIC_BODY" | grep -cF "问题还在，用户暂时看不到变化。")"
assert_not_contains "whitelist: English 对用户有什么影响 does not survive" \
  "$IMPACT_DIAGNOSTIC_BODY" "$ENGLISH_DIAGNOSTIC"

ACTION_DIAGNOSTIC_BODY="$(build_report_body "1254" "连接器账号状态可读探测" "example-maintainer" \
  "本轮没能改完。" "问题还在，用户暂时看不到变化。" "$ENGLISH_DIAGNOSTIC")"
assert_eq "whitelist: English 你要不要做什么 is replaced as a whole field" \
  "1" "$(echo "$ACTION_DIAGNOSTIC_BODY" | grep -cF "不用。细节在这条 issue 里。")"
assert_not_contains "whitelist: English 你要不要做什么 does not survive" \
  "$ACTION_DIAGNOSTIC_BODY" "$ENGLISH_DIAGNOSTIC"

NORMAL_CHINESE_LINE="本轮已完成，明天发布。"
NORMAL_CHINESE_BODY="$(build_report_body "1254" "连接器账号状态可读探测" "example-maintainer" \
  "本轮没能改完。" "问题还在，用户暂时看不到变化。" "$NORMAL_CHINESE_LINE")"
assert_eq "whitelist: a normal short Chinese line passes untouched" \
  "1" "$(echo "$NORMAL_CHINESE_BODY" | grep -cF "$NORMAL_CHINESE_LINE")"

CHINESE_WALL="$(printf '中%.0s' {1..500})"
CHINESE_WALL_BODY="$(build_report_body "1254" "连接器账号状态可读探测" "example-maintainer" \
  "$CHINESE_WALL" "问题还在，用户暂时看不到变化。" "不用。")"
assert_eq "whitelist: a 500-character Chinese wall is replaced as a whole field" \
  "1" "$(echo "$CHINESE_WALL_BODY" | grep -cF "这一轮没能改完。")"
assert_not_contains "whitelist: a 500-character Chinese wall does not survive" \
  "$CHINESE_WALL_BODY" "$CHINESE_WALL"

IDENTITY_LINE="已经合并 PR #123，CI 会继续发布：https://github.com/example-maintainer/example-repo/issues/123"
IDENTITY_BODY="$(build_report_body "1254" "连接器账号状态可读探测" "example-maintainer" \
  "本轮没能改完。" "问题还在，用户暂时看不到变化。" "$IDENTITY_LINE")"
assert_eq "whitelist: PR/CI and a URL remain in a short Chinese field" \
  "1" "$(echo "$IDENTITY_BODY" | grep -cF "$IDENTITY_LINE")"

# --- wrapper coverage -------------------------------------------------------
REPO="example-maintainer/example-repo"
gh() {
  echo '{"author":{"login":"reporter"}}'
}
_reporter_email_only() { echo "reporter@notify-fixture.invalid"; }
LAST_SEND_BODY=""
LAST_SEND_SUBJECT=""
LAST_SEND_KIND=""
LAST_SEND_RECIPIENTS=()
send_email() {
  LAST_SEND_SUBJECT="$1"
  LAST_SEND_BODY="$2"
  local _marker="$3"; shift 3
  LAST_SEND_KIND="${1:-} ${2:-}"
  if [[ "$LAST_SEND_KIND" == "--founder-kind "* ]]; then shift 2; fi
  LAST_SEND_RECIPIENTS=("$@")
  echo "fixture-thread"
}
VERBATIM_BODY='客户/公司：客户甲
问题：是否应保留次日送达？
用户动作：客户选择了次日送达。
结果：当前仓库无法承诺该时效。
A）改为普通配送；影响：预计晚一天送达。
B）保留次日送达；影响：需要承担加急配送成本。
建议：A
请回复“A”'
notify_email_verbatim "1254" "客户甲配送方式需要确认" "$VERBATIM_BODY" > "$TMP_DIR/verbatim-thread"
VERBATIM_THREAD="$(cat "$TMP_DIR/verbatim-thread")"
VERBATIM_CAPTURE="$LAST_SEND_BODY"
assert_eq "decision wrapper returns Gmail thread id" "fixture-thread" "$VERBATIM_THREAD"
assert_eq "decision wrapper uses the reporter as the only recipient" \
  "reporter@notify-fixture.invalid" "$(printf '%s\n' "${LAST_SEND_RECIPIENTS[@]}")"
assert_eq "decision wrapper marks the structured mail kind" "--founder-kind decision" "$LAST_SEND_KIND"
assert_eq "decision wrapper keeps exact reply instruction last" "请回复“A”" "$(printf '%s\n' "$VERBATIM_CAPTURE" | sed '/^[[:space:]]*$/d' | tail -n1)"
assert_contains "decision wrapper puts issue link inside message" \
  "$VERBATIM_CAPTURE" "https://github.com/example-maintainer/example-repo/issues/1254"

# The legacy generic wrapper has no eligible mail class; the central
# pre-send gate rejects it and emits no machine-log fallback template.
source "$SCRIPT_DIR/notify.sh"
_maintainer_email() { echo "maintainer@notify-fixture.invalid"; }
MAINTAINER_REJECTION="$(notify_founder "普通运行提醒" "运行状态已记录。" 2>&1)"
assert_contains "generic maintainer notices are rejected by the mail contract" \
  "$MAINTAINER_REJECTION" "rejected by contract"
assert_not_contains "generic rejection contains no machine-log fallback text" \
  "$MAINTAINER_REJECTION" "详情在机器上的日志里"

# --- 2026-09-18 maintainer ruling, verbatim: [...]
#  -- notify_email_everyone()/resolve_recipients_everyone()
# audience coverage. Re-source notify.sh first: the wrapper-coverage block
# above stubbed resolve_recipients() to a no-op for its own
# notify_email_verbatim() check -- undo that here so this section exercises
# the REAL resolvers against a fixture roster, never the live
# ~/.zenoforge/recipients.json (AGENT_HOME is already this file's own
# $TMP_DIR, a mktemp -d -- see this file's own AGENT_HOME export above).
# scrub_closing_keywords() is stubbed as a passthrough purely so
# notify_email()/notify_email_everyone() (both call it on the issue title
# via _send_report_email) don't add cleanup behavior to this resolver test.
source "$SCRIPT_DIR/notify.sh"
scrub_closing_keywords() { cat; }

AUDIENCE_ROSTER="$TMP_DIR/audience-recipients.json"
cat > "$AUDIENCE_ROSTER" <<'JSON'
{
  "founder_login": "fixture-maintainer",
  "recipients": {
    "fixture-maintainer": "maintainer@notify-fixture.invalid",
    "fixture-reporter": "reporter@notify-fixture.invalid",
    "fixture-teammate": "teammate@notify-fixture.invalid"
  }
}
JSON
RECIPIENTS_FILE="$AUDIENCE_ROSTER"
ALL_ROSTER_ADDRESSES="$(printf 'maintainer@notify-fixture.invalid\nreporter@notify-fixture.invalid\nteammate@notify-fixture.invalid')"
NONMAINTAINER_ROSTER_ADDRESSES="$(printf 'reporter@notify-fixture.invalid\nteammate@notify-fixture.invalid')"

# --- resolve_recipients_everyone(): pure function, fixture roster only ----
assert_eq "resolve_recipients_everyone: a known reporter still reaches every roster address, not just their own + maintainer" \
  "$ALL_ROSTER_ADDRESSES" \
  "$(resolve_recipients_everyone "fixture-reporter" "$AUDIENCE_ROSTER" | grep -v '^NOTE:')"

assert_eq "resolve_recipients_everyone: an unknown login still reaches every roster address (not narrowed to the maintainer alone)" \
  "$ALL_ROSTER_ADDRESSES" \
  "$(resolve_recipients_everyone "someone-unmapped" "$AUDIENCE_ROSTER" | grep -v '^NOTE:')"

assert_eq "resolve_recipients_everyone: an unknown login still produces the NOTE: diagnostic" \
  "1" "$(resolve_recipients_everyone "someone-unmapped" "$AUDIENCE_ROSTER" | grep -c "^NOTE:.*someone-unmapped")"

# --- end-to-end: notify_email_everyone() vs notify_email() vs
# notify_reporter_question(), all against the SAME fixture roster ----------
REPO="example-maintainer/example-repo"
gh() {
  echo '{"author":{"login":"fixture-reporter"},"title":"fixture issue"}'
}
LAST_SEND_RECIPIENTS=()
send_email() {
  local _subject="$1" _body="$2" _marker="$3"; shift 3
  LAST_SEND_SUBJECT="$_subject"
  LAST_SEND_BODY="$_body"
  LAST_SEND_KIND=""
  if [[ "${1:-}" == "--founder-kind" ]]; then
    LAST_SEND_KIND="${1:-} ${2:-}"
    shift 2
  fi
  LAST_SEND_RECIPIENTS=("$@")
  [ "$_subject" != "产品预期需要确认" ] || echo "fixture-thread"
}

notify_email_everyone "9001" "[example] fixture 已发布上线" "done" "impact" "no action needed"
assert_eq "notify_email_everyone: a fix report reaches every teammate" \
  "$NONMAINTAINER_ROSTER_ADDRESSES" \
  "$(printf '%s\n' "${LAST_SEND_RECIPIENTS[@]}")"

LAST_SEND_RECIPIENTS=()
notify_email "9001" "[example] fixture 被拦住了" "blocked" "impact" "no action needed"
assert_eq "notify_email: blocked report reaches reporter; maintainer copy is queued" \
  'reporter@notify-fixture.invalid' \
  "$(printf '%s\n' "${LAST_SEND_RECIPIENTS[@]}")"
assert_contains "notify_email: maintainer copy is stored in incremental ledger" \
  "$(cat "$AGENT_HOME/night/founder-health-mail.json")" 'report:9001:[example] fixture 被拦住了'

gh() {
  echo '{"author":{"login":"someone-unmapped"},"title":"fixture issue"}'
}
LAST_SEND_RECIPIENTS=()
notify_email_everyone "9002" "[example] fixture 已发布上线" "done" "impact" "no action needed"
assert_eq "notify_email_everyone: an unmapped reporter login still reaches every teammate" \
  "$NONMAINTAINER_ROSTER_ADDRESSES" \
  "$(printf '%s\n' "${LAST_SEND_RECIPIENTS[@]}")"
assert_contains "notify_email_everyone: an unmapped reporter login's NOTE diagnostic still lands in the email body" \
  "$LAST_SEND_BODY" "someone-unmapped"

gh() {
  echo '{"author":{"login":"fixture-reporter"}}'
}
LAST_SEND_RECIPIENTS=()
notify_reporter_question "9003" "[example] 需要你决定" "有个问题要你确认一下"
assert_eq "notify_reporter_question: still reaches only the reporter, never the maintainer or the rest of the roster" \
  "reporter@notify-fixture.invalid" \
  "$(printf '%s\n' "${LAST_SEND_RECIPIENTS[@]}")"

gh() {
  echo '{"author":{"login":"fixture-maintainer"},"title":"客户甲的配送时效选择"}'
}
_reporter_email_only() {
  jq -r --arg login "$1" '.recipients[$login] // empty' "$AUDIENCE_ROSTER"
}
LAST_SEND_SUBJECT=""
LAST_SEND_BODY=""
LAST_SEND_KIND=""
LAST_SEND_RECIPIENTS=()
notify_reporter_question "9004" "[example] #9004 需要确认产品预期" "产品预期还需要补充。" > "$TMP_DIR/maintainer-thread"
MAINTAINER_THREAD="$(cat "$TMP_DIR/maintainer-thread")"
assert_eq "founder-authored product question returns no email thread" "" "$MAINTAINER_THREAD"
assert_eq "founder-authored product question sends no direct mail" "" "$LAST_SEND_SUBJECT"
assert_eq "founder-authored product question has no recipients" "" \
  "$(printf '%s\n' "${LAST_SEND_RECIPIENTS[@]}")"

LAST_SEND_RECIPIENTS=()
LAST_SEND_KIND=""
gh() { echo '{"author":{"login":"fixture-maintainer"}}'; }
notify_email_verbatim 9006 '是否保留次日送达' '客户事实与两个选项。' >/dev/null
assert_eq 'founder-only decision sends immediately to maintainer' \
  'maintainer@notify-fixture.invalid' "$(printf '%s\n' "${LAST_SEND_RECIPIENTS[@]}")"
assert_eq 'founder-only decision keeps decision mail kind' '--founder-kind decision' "$LAST_SEND_KIND"
assert_eq 'founder-only decision enters four-hour reminder ledger' '1' \
  "$(jq '[.important_items[] | select(.kind == "decision" and .issue == "9006" and .status == "open")] | length' \
    "$AGENT_HOME/night/founder-health-mail.json")"

# --- send_email_strict() (#1442) ------------------------------------------
# config-watchdog.sh's whole reason for needing a separate entry point: it
# must never record "alert sent" on a send that gcloud/curl only pretended
# to attempt. Fakes gcloud and curl (real network/credentials never touch
# this test) so every failure mode in the issue's acceptance table is
# exercised: no credentials, no recipient, auth failure, non-success
# response, and the success path returning a real message id — plus proof
# that the OLD best-effort send_email() is unchanged by this addition.
#
# The "wrapper coverage" / "end-to-end" sections above both redefined
# send_email() as a test spy (most recently at line ~566) -- restore the
# REAL implementation before touching either function, or these tests would
# silently exercise the spy instead of the code #1442 actually changed.
source "$SCRIPT_DIR/notify.sh"

# Give-up notice remains Chinese and reporter-only, with a local audit row.
# DRY_RUN stubs delivery.
RECIPIENTS_FILE="$AUDIENCE_ROSTER"
DRY_RUN=1
NOTIFY_LOG_FILE="$TMP_DIR/conclusion-notify.log"
DIAGNOSIS=$'Missing capability: fixture rehearsal environment\nRetry after runner recovers.'
CONCLUSION_MAIL="$({
  gh() { echo '{"author":{"login":"fixture-reporter"},"title":"The pipeline detects failures but recovers from none of them: build exception handling"}'; }
  notify_email_reporter 9004 '[example] 这一轮未能完成' \
    '这一轮已经结束，原因如下。' '问题还在，用户暂时看不到变化。' \
    '不用现在操作；处理原因已记录在问题进展中。'
} 2>&1)"
assert_contains "internal English issue title is replaced before maintainer gate" \
  "$CONCLUSION_MAIL" '问题：#9004 本次处理事项'
assert_not_contains "internal English issue title does not reject reporter notice" \
  "$CONCLUSION_MAIL" 'rejected by contract'
assert_not_contains "reporter notice omits internal English diagnosis" \
  "$CONCLUSION_MAIL" "$DIAGNOSIS"
assert_contains "conclusion notice goes only to a rostered reporter" \
  "$CONCLUSION_MAIL" 'to reporter@notify-fixture.invalid:'
assert_not_contains "conclusion notice never includes maintainer" \
  "$CONCLUSION_MAIL" 'maintainer@notify-fixture.invalid'
assert_contains "conclusion audit records reporter only" \
  "$(cat "$NOTIFY_LOG_FILE" 2>/dev/null || true)" $'recipients=reporter@notify-fixture.invalid\tsubject=[example] 这一轮未能完成\tissue=9004\tmode=best-effort\treason=none\tresult=attempted'
assert_eq "founder-authored conclusion has no reporter recipient" '' \
  "$(resolve_recipients_reporter maintainer "$AUDIENCE_ROSTER")"
assert_eq "unmapped conclusion reporter has no fallback recipient" '' \
  "$(resolve_recipients_reporter unknown-login "$AUDIENCE_ROSTER")"
UNMAPPED_CONCLUSION_MAIL="$(
  gh() { echo '{"author":{"login":"unknown-login"},"title":"未映射提交者"}'; }
  notify_email_reporter 9005 '[example] 这一轮未能完成' \
    '这一轮已经结束。' '问题还在，用户暂时看不到变化。' '无需现在操作。' 2>&1
)"
assert_contains "unmapped reporter conclusion does not fall back to maintainer" \
  "$UNMAPPED_CONCLUSION_MAIL" 'to <none resolved>'
assert_not_contains "unmapped reporter conclusion never names maintainer" \
  "$UNMAPPED_CONCLUSION_MAIL" 'maintainer@notify-fixture.invalid'
assert_contains "conclude_run uses reporter-only notification path" \
  "$(sed -n '/notify_email_reporter "\$n"/,/|| true/p' "$SCRIPT_DIR/lib.sh")" \
  'notify_email_reporter "$n"'
INCIDENT_MAIL="$(notify_founder '[example] 模型调用暂不可用' \
  $'用户目前看到：相关处理暂缓约一小时。\n我们正在：自动等待并重新尝试。\n下次更新：2026-09-27 12:00 UTC 后如再次失败会提醒。' incident 2>&1)"
assert_contains "backoff notice reaches maintainer only" \
  "$INCIDENT_MAIL" 'to maintainer@notify-fixture.invalid:'
assert_contains "backoff notice keeps founder-only notification audit" \
  "$(cat "$NOTIFY_LOG_FILE")" $'recipients=maintainer@notify-fixture.invalid\tsubject=[example] 模型调用暂不可用\tissue=none\tmode=best-effort\treason=none\tresult=attempted'
DRY_RUN=0

# Every outbound Gmail API request must pass through one logged transport;
# recipient helpers and read-side Gmail code are not mail senders.
if python3 - "$SCRIPT_DIR" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
sources = [p for p in root.rglob("*.sh") if not p.name.endswith(".test.sh")]
api_refs = [p for p in sources if re.search(r"gmail\.googleapis\.com|users/me/messages/send|GMAIL_SEND_URL", p.read_text())]
send_calls = [
    (p, number, line)
    for p in sources
    for number, line in enumerate(p.read_text().splitlines(), 1)
    if re.search(r"\b(?:gmail_)?curl\b", line) and re.search(r"GMAIL_SEND_URL|gmail\.googleapis\.com|users/me/messages/send", line)
]
notify = root / "notify.sh"
source = notify.read_text()
send_url = "https://gmail.googleapis.com/gmail/v1/users/me/messages/send"

def function(name):
    match = re.search(rf"(?m)^{re.escape(name)}\(\) \{{", source)
    if not match:
        raise AssertionError(f"missing function {name}()")
    start = match.start()
    close = re.search(r"(?m)^\}", source[match.end():])
    if not close:
        raise AssertionError(f"unterminated function {name}()")
    end = match.end() + close.start()
    return source[start:end]

try:
    transport = function("_send_email_logged")
    curl_at = transport.index("curl ")
    log_at = transport.index("notify_log_send")
    curl_lines = [line for line in transport.splitlines() if "curl " in line and "GMAIL_SEND_URL" in line]
    assert api_refs == [notify], f"Gmail API send references outside notify.sh: {api_refs}"
    assert len(send_calls) == 1 and send_calls[0][0] == notify, f"unshared Gmail sender found: {send_calls}"
    assert sum(p.read_text().count(send_url) for p in sources) == 1, "new Gmail send URL was added"
    assert source.count("GMAIL_SEND_URL") == 2, "Gmail send URL is used outside its definition and shared sender"
    assert len(curl_lines) == 1, f"expected one Gmail HTTP sender, got {len(curl_lines)}"
    assert log_at < curl_at, "Gmail send happens before notify.log attempt"
    for name in ("send_email", "send_email_strict"):
        wrapper = function(name)
        assert "_send_email_logged" in wrapper, f"{name} bypasses the shared logged transport"
        assert "curl " not in wrapper, f"{name} contains a separate network send"
except (AssertionError, ValueError) as exc:
    print(f"FAILED: {exc}", file=sys.stderr)
    sys.exit(1)
PY
then
  echo "ok - one logged transport owns every Gmail API send path"
else
  echo "not ok - Gmail send path bypasses shared logging"
  FAILED=1
fi

STRICT_BIN="$TMP_DIR/strictbin"
mkdir -p "$STRICT_BIN"

cat > "$STRICT_BIN/gcloud" <<'EOF'
#!/usr/bin/env bash
if [ "$1 $2 $3" = "auth application-default print-access-token" ]; then
  printf '%s' "${FAKE_GCLOUD_STDERR:-}" >&2
  if [ "${FAKE_GCLOUD_FAIL:-0}" = "1" ]; then
    exit 1
  fi
  echo "fake-access-token"
  exit 0
fi
exit 1
EOF
chmod +x "$STRICT_BIN/gcloud"

cat > "$STRICT_BIN/curl" <<'EOF'
#!/usr/bin/env bash
if [ -n "${FAKE_CURL_CALLS_FILE:-}" ]; then printf 'called\n' >> "$FAKE_CURL_CALLS_FILE"; fi
if [ "${FAKE_CURL_FAIL:-0}" = "1" ]; then
  printf '\n000\n'
  exit 28
fi
if [ -n "${FAKE_CURL_BODY:-}" ]; then
  printf '%s\n' "$FAKE_CURL_BODY"
else
  printf '{}\n'
fi
printf '%s\n' "${FAKE_CURL_HTTP_CODE:-200}"
exit 0
EOF
chmod +x "$STRICT_BIN/curl"

export PATH="$STRICT_BIN:$PATH"
export DRY_RUN=0
# gcloud/curl are real SUBPROCESSES the fakes above run as -- these must be
# exported (not plain shell variables) or the fakes never see them and
# silently fall back to their own defaults, which would make every test
# below "pass" for the wrong reason. Reset to empty rather than `unset`
# between cases so the exported attribute survives (`unset` would drop it,
# and a later bare `VAR=x` re-assignment would silently stop being
# exported); `${VAR:-default}` in the fakes treats empty the same as unset.
export FAKE_GCLOUD_FAIL="" FAKE_GCLOUD_STDERR="" FAKE_CURL_FAIL="" FAKE_CURL_BODY="" FAKE_CURL_HTTP_CODE=""
NOTIFY_LOG_FILE="$TMP_DIR/strict-notify.log"
export NOTIFY_LOG_FILE
FAKE_CURL_CALLS_FILE="$TMP_DIR/fake-curl-calls.log"
export FAKE_CURL_CALLS_FILE
: > "$FAKE_CURL_CALLS_FILE"

STRICT_OUT=""
STRICT_STATUS=0

STRICT_STDERR_FILE="$TMP_DIR/strict-stderr.log"
run_strict() {
  STRICT_STATUS=0
  STRICT_OUT="$(send_email_strict "$@" 2>"$STRICT_STDERR_FILE")" || STRICT_STATUS=$?
  STRICT_ERR="$(cat "$STRICT_STDERR_FILE")"
}

# no recipients
ZF_GCLOUD_BIN="$STRICT_BIN/gcloud"
export ZF_GCLOUD_BIN
: > "$NOTIFY_LOG_FILE"
run_strict "[example] watchdog test" "body"
assert_eq "send_email_strict: no recipients fails (status 1)" "1" "$STRICT_STATUS"
assert_eq "send_email_strict: no recipients prints nothing on stdout" "" "$STRICT_OUT"
assert_contains "send_email_strict: no-recipient failure is classified" \
  "$(cat "$NOTIFY_LOG_FILE")" $'reason=no-recipients\tresult=failed'
assert_contains "send_email_strict: failure audit identifies strict mode" \
  "$(cat "$NOTIFY_LOG_FILE")" $'mode=strict\treason=no-recipients\tresult=failed'

# no credentials (gcloud binary missing/not executable)
ZF_GCLOUD_BIN="$STRICT_BIN/no-such-gcloud-binary"
run_strict "[example] watchdog test" "body" "a@b.invalid"
assert_eq "send_email_strict: missing gcloud binary fails" "1" "$STRICT_STATUS"
ZF_GCLOUD_BIN="$STRICT_BIN/gcloud"

# auth failure
FAKE_GCLOUD_FAIL=1
FAKE_GCLOUD_STDERR='OAuth refresh failed: invalid_grant'
: > "$NOTIFY_LOG_FILE"
run_strict "[example] watchdog test" "body" "a@b.invalid"
assert_eq "send_email_strict: gcloud auth failure fails, no message id fabricated" "1" "$STRICT_STATUS"
assert_eq "send_email_strict: gcloud auth failure prints nothing on stdout" "" "$STRICT_OUT"
assert_contains "send_email_strict: invalid_grant failure is classified without exposing provider text" \
  "$(cat "$NOTIFY_LOG_FILE")" $'reason=credential-expired\tresult=failed'
assert_not_contains "send_email_strict: notify.log omits credential failure details" \
  "$(cat "$NOTIFY_LOG_FILE")" 'invalid_grant'
FAKE_GCLOUD_FAIL=""
FAKE_GCLOUD_STDERR=""

# A token-mint proxy failure proves Gmail never received a POST, so the
# scheduled health digest may safely release its slot for a later tick.
FAKE_GCLOUD_FAIL=1
FAKE_GCLOUD_STDERR='proxy failure access_token=proxy-secret-123'
: > "$NOTIFY_LOG_FILE"
curl_calls_before="$(wc -l < "$FAKE_CURL_CALLS_FILE" | tr -d '[:space:]')"
run_strict "[example] watchdog test" "body-secret-proxy" "a@b.invalid"
proxy_audit="$(cat "$NOTIFY_LOG_FILE")"
assert_eq "send_email_strict: token-mint proxy failure does not send POST" \
  "$curl_calls_before" "$(wc -l < "$FAKE_CURL_CALLS_FILE" | tr -d '[:space:]')"
assert_contains "send_email_strict: proxy failure audit names token-mint stage" \
  "$proxy_audit" $'stage=token-mint'
assert_not_contains "send_email_strict: proxy failure audit hides stderr credentials and body" \
  "$proxy_audit" 'proxy-secret-123'
assert_not_contains "send_email_strict: proxy failure audit hides message body" \
  "$proxy_audit" 'body-secret-proxy'
NOTIFY_LAST_SEND_RETRY_SAFE=0
send_email_strict "[example] watchdog test" "body-secret-proxy" "a@b.invalid" >/dev/null 2>&1 || true
assert_eq "send_email_strict: pre-POST token failure is retry-safe" "1" "$NOTIFY_LAST_SEND_RETRY_SAFE"
FAKE_GCLOUD_FAIL=""
FAKE_GCLOUD_STDERR=""

# curl-level failure (timeout/network)
FAKE_CURL_FAIL=1
: > "$NOTIFY_LOG_FILE"
run_strict "[example] watchdog test" "body" "a@b.invalid"
assert_eq "send_email_strict: curl/timeout failure fails" "1" "$STRICT_STATUS"
timeout_audit="$(cat "$NOTIFY_LOG_FILE")"
assert_contains "send_email_strict: transport failure is classified" \
  "$timeout_audit" $'reason=transport\tresult=failed'
assert_contains "send_email_strict: timeout audit identifies Gmail API stage and curl exit" \
  "$timeout_audit" $'stage=gmail-api-send\tcurl_exit=28'
assert_not_contains "send_email_strict: timeout audit omits unavailable HTTP status" \
  "$timeout_audit" 'http_status='
NOTIFY_LAST_SEND_RETRY_SAFE=1
send_email_strict "[example] watchdog test" body a@b.invalid >/dev/null 2>&1 || true
assert_eq "send_email_strict: uncertain POST timeout is not retry-safe" "0" "$NOTIFY_LAST_SEND_RETRY_SAFE"
FAKE_CURL_FAIL=""

# non-success HTTP response
FAKE_CURL_HTTP_CODE=503
: > "$NOTIFY_LOG_FILE"
FAKE_CURL_BODY='{"error":"internal","secret":"private response"}'
run_strict "[example] watchdog test" "body" "a@b.invalid"
assert_eq "send_email_strict: non-2xx response fails, does not write 已告警" "1" "$STRICT_STATUS"
http_audit="$(cat "$NOTIFY_LOG_FILE")"
assert_contains "send_email_strict: HTTP failure is classified" \
  "$http_audit" $'reason=transport\tresult=failed'
assert_contains "send_email_strict: HTTP 503 audit records stage, curl exit and status" \
  "$http_audit" $'stage=gmail-api-send\tcurl_exit=0\thttp_status=503'
assert_not_contains "send_email_strict: HTTP response body stays out of audit" \
  "$http_audit" 'private response'
assert_not_contains "send_email_strict: response body stays out of stderr" "$STRICT_ERR" 'private response'
NOTIFY_LAST_SEND_RETRY_SAFE=1
send_email_strict "[example] watchdog test" body a@b.invalid >/dev/null 2>&1 || true
assert_eq "send_email_strict: HTTP error POST is not retry-safe" "0" "$NOTIFY_LAST_SEND_RETRY_SAFE"
FAKE_CURL_HTTP_CODE="" FAKE_CURL_BODY=""

# 2xx response but no message id in body -- still a failure, not a guess
FAKE_CURL_HTTP_CODE=200
FAKE_CURL_BODY='{"threadId":"thread-only-no-id","secret":"uncertain-response-secret"}'
: > "$NOTIFY_LOG_FILE"
run_strict "[example] watchdog test" "body" "a@b.invalid"
assert_eq "send_email_strict: 2xx with no message id still fails" "1" "$STRICT_STATUS"
uncertain_audit="$(cat "$NOTIFY_LOG_FILE")"
assert_contains "send_email_strict: uncertain send audit records HTTP response" \
  "$uncertain_audit" $'stage=gmail-api-send\tcurl_exit=0\thttp_status=200'
assert_not_contains "send_email_strict: uncertain response body stays out of audit" \
  "$uncertain_audit" 'uncertain-response-secret'
NOTIFY_LAST_SEND_RETRY_SAFE=1
send_email_strict "[example] watchdog test" body a@b.invalid >/dev/null 2>&1 || true
assert_eq "send_email_strict: uncertain successful POST is not retry-safe" "0" "$NOTIFY_LAST_SEND_RETRY_SAFE"
FAKE_CURL_HTTP_CODE="" FAKE_CURL_BODY=""

# success: real message id returned and printed
FAKE_CURL_HTTP_CODE=200
FAKE_CURL_BODY='{"id":"msg-strict-123","threadId":"thread-strict-1"}'
run_strict "[example] watchdog test" "body" "a@b.invalid"
assert_eq "send_email_strict: success returns 0" "0" "$STRICT_STATUS"
assert_eq "send_email_strict: success prints the real Gmail message id" "msg-strict-123" "$STRICT_OUT"
FAKE_CURL_HTTP_CODE="" FAKE_CURL_BODY=""

# DRY_RUN never fabricates a success
DRY_RUN=1
run_strict "[example] watchdog test" "body" "a@b.invalid"
assert_eq "send_email_strict: DRY_RUN reports failure, not a fabricated success" "1" "$STRICT_STATUS"
assert_eq "send_email_strict: DRY_RUN prints nothing on stdout" "" "$STRICT_OUT"
DRY_RUN=0

# #3155's two empty-recipient rows are an attempt and a failed result, not
# two deliveries. Exercise real mode with fixture transport, including retry.
RECIPIENTS_FILE="$AUDIENCE_ROSTER"
for conclusion_login in fixture-maintainer unknown-login; do
  : > "$NOTIFY_LOG_FILE"
  : > "$FAKE_CURL_CALLS_FILE"
  SEND_EMAIL_STATUS=0
  SEND_EMAIL_OUT="$(
    gh() { printf '{"author":{"login":"%s"},"title":"收货回归"}\n' "$conclusion_login"; }
    for attempt in 1 2; do
      notify_email_reporter 9005 '[example] 这一轮未能完成' \
        '这一轮已经结束。' '问题还在，用户暂时看不到变化。' '无需现在操作。'
    done 2>"$TMP_DIR/empty-conclusion.stderr"
  )" || SEND_EMAIL_STATUS=$?
  empty_audit="$(cat "$NOTIFY_LOG_FILE")"
  assert_eq "$conclusion_login conclusion: best-effort preserves pipeline status" '0' "$SEND_EMAIL_STATUS"
  assert_eq "$conclusion_login conclusion: no Gmail thread fabricated" '' "$SEND_EMAIL_OUT"
  assert_eq "$conclusion_login conclusion: initial call and retry send no POST" '' "$(cat "$FAKE_CURL_CALLS_FILE")"
  assert_eq "$conclusion_login conclusion: one attempt audit per invocation" '2' \
    "$(grep -c $'reason=none\tresult=attempted' "$NOTIFY_LOG_FILE")"
  assert_eq "$conclusion_login conclusion: one no-recipient result per invocation" '2' \
    "$(grep -c $'mode=best-effort\treason=no-recipients\tresult=failed' "$NOTIFY_LOG_FILE")"
  assert_not_contains "$conclusion_login conclusion: never reports sent" "$empty_audit" 'result=sent'
  assert_not_contains "$conclusion_login conclusion: never falls back to maintainer" \
    "$empty_audit" 'maintainer@notify-fixture.invalid'
  assert_contains "$conclusion_login conclusion: omission remains visible locally" \
    "$(cat "$TMP_DIR/empty-conclusion.stderr")" 'no recipients resolved -- skipping send'
done

# --- old best-effort send_email() is unchanged by this addition -----------
# Same fixtures, but the ORIGINAL function: always returns 0, and surfaces
# threadId (not the message id) on success.
DRY_RUN=0
SEND_EMAIL_OUT=""
SEND_EMAIL_STATUS=0
FAKE_CURL_HTTP_CODE=200
FAKE_CURL_BODY='{"id":"msg-besteffort-1","threadId":"thread-besteffort-1"}'
SEND_EMAIL_OUT="$(send_email "[example] watchdog test" "body" "" "a@b.invalid")" || SEND_EMAIL_STATUS=$?
assert_eq "send_email (best-effort): still returns 0 on success (unchanged)" "0" "$SEND_EMAIL_STATUS"
assert_eq "send_email (best-effort): still surfaces threadId, not the message id (unchanged)" "thread-besteffort-1" "$SEND_EMAIL_OUT"
FAKE_CURL_HTTP_CODE="" FAKE_CURL_BODY=""

SEND_EMAIL_STATUS=0
FAKE_CURL_HTTP_CODE=500
FAKE_CURL_BODY='{"error":"internal"}'
SEND_EMAIL_OUT="$(send_email "[example] watchdog test" "body" "" "a@b.invalid")" || SEND_EMAIL_STATUS=$?
assert_eq "send_email (best-effort): still returns 0 even when the send failed (unchanged, so existing set -e callers never break)" "0" "$SEND_EMAIL_STATUS"
assert_eq "send_email (best-effort): failure path still prints nothing on stdout (unchanged)" "" "$SEND_EMAIL_OUT"
FAKE_CURL_HTTP_CODE="" FAKE_CURL_BODY=""

# An unwritable audit path must stop both send modes before Gmail is called.
printf 'blocked\n' > "$TMP_DIR/not-a-directory"
NOTIFY_LOG_FILE="$TMP_DIR/not-a-directory/notify.log"
export NOTIFY_LOG_FILE
: > "$FAKE_CURL_CALLS_FILE"
SEND_EMAIL_STATUS=0
SEND_EMAIL_OUT="$(send_email '[example] log failure' 'body' '' 'a@b.invalid' 2>"$TMP_DIR/log-failure.stderr")" || SEND_EMAIL_STATUS=$?
assert_eq 'send_email keeps best-effort status on log failure' '0' "$SEND_EMAIL_STATUS"
assert_eq 'send_email sends nothing when notify.log cannot be written' '' "$(cat "$FAKE_CURL_CALLS_FILE")"
run_strict '[example] log failure' 'body' 'a@b.invalid'
assert_eq 'send_email_strict fails on log failure' '1' "$STRICT_STATUS"
assert_eq 'send_email_strict sends nothing when notify.log cannot be written' '' "$(cat "$FAKE_CURL_CALLS_FILE")"

# Restore writable audit path before the remaining contract and transport cases.
NOTIFY_LOG_FILE="$TMP_DIR/notify.log"
export NOTIFY_LOG_FILE
: > "$NOTIFY_LOG_FILE"
FAKE_CURL_CALLS_FILE=""
export FAKE_CURL_CALLS_FILE

# #1608: every send gets an attempt and, after success, a result line; neither
# records body/token/credential values.
# values. Use both best-effort and strict entry points against the fakes above.
NOTIFY_LOG_FILE="$TMP_DIR/notify.log"
export NOTIFY_LOG_FILE
: > "$NOTIFY_LOG_FILE"
FAKE_CURL_HTTP_CODE=200
FAKE_CURL_BODY='{"id":"msg-audit-1","threadId":"thread-audit-1"}'
send_email "[example] 审计测试" "正文不写入本地审计" "1608" "audit@notify-fixture.invalid"
send_email_strict "[example] 严格审计测试" "正文不写入本地审计" "1608" "audit@notify-fixture.invalid" >/dev/null || true
NOTIFY_LOG_CONTENT="$(cat "$NOTIFY_LOG_FILE" 2>/dev/null || true)"
NOTIFY_LOG_LINES="$(wc -l < "$NOTIFY_LOG_FILE" 2>/dev/null || true)"
assert_eq "#1608: notify.log records one attempt and one success per send" "4" "$NOTIFY_LOG_LINES"
assert_eq "#1608: both completed sends record result=sent" "2" "$(grep -Ec $'result=sent(\t|$)' "$NOTIFY_LOG_FILE")"
assert_eq "#1608: each send has unique pipeline mailer ID, shared by attempt and result" "2" "$(grep -oE 'mailer_id=[0-9]+-[0-9]+-[0-9]+' "$NOTIFY_LOG_FILE" | sort -u | wc -l | tr -d ' ')"
assert_eq "#1608: notify.log correlates all four rows with mailer IDs" "4" "$(grep -Ec $'\tmailer_id=[0-9]+-[0-9]+-[0-9]+$' "$NOTIFY_LOG_FILE")"
assert_contains "#1608: notify.log records recipients" "$NOTIFY_LOG_CONTENT" "recipients=audit@notify-fixture.invalid"
assert_contains "#1608: notify.log records issue number" "$NOTIFY_LOG_CONTENT" "issue=1608"
assert_contains "#1608: notify.log records subjects" "$NOTIFY_LOG_CONTENT" "subject=[example] 审计测试"
assert_not_contains "#1608: notify.log never records an access token" "$NOTIFY_LOG_CONTENT" "fake-access-token"
FAKE_CURL_HTTP_CODE="" FAKE_CURL_BODY=""

# --- founder-mail pre-send contract --------------------------------------
DECISION_SUBJECT='订单发货方式需要确认'
DECISION_BODY='客户/公司：客户甲
问题：是否应保留次日送达？
用户动作：客户选择了次日送达。
结果：当前仓库无法承诺该时效。
A）改为普通配送；影响：预计晚一天送达。
B）保留次日送达；影响：需要承担加急配送成本。
建议：A
请回复“A”'
OUTCOME_SUBJECT='库存表格现已支持批量下载'
OUTCOME_BODY='生产环境近期上线了以下改进，用户现在可以：

- 库存表格批量下载
  https://github.com/example-maintainer/example-repo/issues/9001'
INCIDENT_SUBJECT='部分客户暂时无法完成付款'
INCIDENT_BODY='用户目前看到：提交订单后无法完成付款。
我们正在：恢复付款服务并核对受影响订单。
下次更新：2026-09-23 18:30（协调世界时）'
HEALTH_SUBJECT='流水线运行近况'
HEALTH_BODY='**结论：** 本次有 3 项新变化。

**发布进度**
- 员工可批量下载订单清单

**事项完成：** 2 项
- #9001 订单查询

**需要你决定的**
- 暂无'
RECIPIENTS_FILE="$AUDIENCE_ROSTER"
HEALTH_MAINTAINER_ADDRESS="$(_maintainer_email)"

assert_eq 'maintainer mail accepts a complete decision' '' \
  "$(founder_mail_rejection_reason decision "$DECISION_SUBJECT" "$DECISION_BODY")"
assert_eq 'maintainer mail accepts a linked production outcome' '' \
  "$(founder_mail_rejection_reason outcome "$OUTCOME_SUBJECT" "$OUTCOME_BODY")"
assert_eq 'maintainer mail rejects an outcome without a named user change' 'outcome-content' \
  "$(founder_mail_rejection_reason outcome "$OUTCOME_SUBJECT" '生产环境现已上线，用户现在可以查看结果。https://github.com/example-maintainer/example-repo/issues/9001')"
assert_eq 'maintainer mail accepts an active incident with next-update time' '' \
  "$(founder_mail_rejection_reason incident "$INCIDENT_SUBJECT" "$INCIDENT_BODY")"
RESOLUTION_SUBJECT='线上服务已恢复'
RESOLUTION_BODY='问题：线上服务
发生了什么：此前告警来自已修复的验收步骤问题。
用户影响：这是误报，不是用户可见的服务中断，生产服务一直正常。
处理结果：恢复确认已完成，无需处理。'
assert_eq 'maintainer mail accepts an incident resolution with no next-update promise' '' \
  "$(founder_mail_rejection_reason resolution "$RESOLUTION_SUBJECT" "$RESOLUTION_BODY")"
assert_eq 'maintainer mail rejects a resolution that promises another update' 'resolution-next-update' \
  "$(founder_mail_rejection_reason resolution "$RESOLUTION_SUBJECT" "$RESOLUTION_BODY
下次更新：2026-09-28 12:00 UTC")"
capture_incident_mail() {
  local capture_path="$TMP_DIR/founder-mail-capture.json" kind="$1"
  (
    _send_email_logged() {
      jq -cn --arg mode "$1" --arg subject "$2" --arg body "$3" --arg issue "$4" \
        --arg mail_kind "$5" --arg recipient "${6:-}" \
        '{mode:$mode,subject:$subject,body:$body,issue:$issue,kind:$mail_kind,recipient:$recipient}' > "$capture_path"
      return 0
    }
    if [ "$kind" = incident ]; then
      notify_founder_incident 9001 "$INCIDENT_SUBJECT" '发布检查没有通过。' \
        '部分线上功能恢复情况尚未确认。' '继续确认生产服务状态。' 1790582400
    else
      notify_founder_resolution 9001 "$RESOLUTION_SUBJECT" '这是误报。' \
        '这是误报，不是用户可见的服务中断，生产服务一直正常。' '恢复确认已完成，无需处理。'
    fi
  )
  cat "$capture_path"
}
INCIDENT_SEND="$(capture_incident_mail incident)"
assert_eq 'incident sender uses strict founder-only incident contract' 'strict|incident|9001' \
  "$(jq -r '[.mode,.kind,.issue] | join("|")' <<< "$INCIDENT_SEND")"
assert_eq 'incident sender output passes the next-update contract' '' \
  "$(founder_mail_rejection_reason incident "$(jq -r '.subject' <<< "$INCIDENT_SEND")" "$(jq -r '.body' <<< "$INCIDENT_SEND")")"
RESOLUTION_SEND="$(capture_incident_mail resolution)"
assert_eq 'resolution sender uses strict founder-only resolution contract' 'strict|resolution|9001' \
  "$(jq -r '[.mode,.kind,.issue] | join("|")' <<< "$RESOLUTION_SEND")"
assert_eq 'resolution sender output passes contract without next-update promise' '' \
  "$(founder_mail_rejection_reason resolution "$(jq -r '.subject' <<< "$RESOLUTION_SEND")" "$(jq -r '.body' <<< "$RESOLUTION_SEND")")"
assert_contains 'resolution sender states false alarm caused no user-facing outage' \
  "$(jq -r '.body' <<< "$RESOLUTION_SEND")" '不是用户可见的服务中断'
assert_eq 'maintainer mail accepts a complete health digest with pipeline subject' '' \
  "$(founder_mail_rejection_reason health "$HEALTH_SUBJECT" "$HEALTH_BODY")"
HEALTH_BODY_WITH_PIPELINE="$HEALTH_BODY

**流水线效率**
- 最慢环节：排队到开始开发，均值 1小时；前一日缩短50%。"
assert_eq 'maintainer health mail accepts the requested efficiency section' '' \
  "$(founder_mail_rejection_reason health "$HEALTH_SUBJECT" "$HEALTH_BODY_WITH_PIPELINE")"
HEALTH_BODY_WITH_CHANGE="${HEALTH_BODY/发布进度/处理变化}"
assert_eq 'maintainer health mail accepts a change section' '' \
  "$(founder_mail_rejection_reason health "$HEALTH_SUBJECT" "$HEALTH_BODY_WITH_CHANGE")"
assert_eq 'maintainer health mail rejects an empty digest' 'health-sections' \
  "$(founder_mail_rejection_reason health "$HEALTH_SUBJECT" '**结论：** 本次有 0 项新变化。')"
assert_eq 'maintainer health mail rejects a missing change section' 'health-sections' \
  "$(founder_mail_rejection_reason health "$HEALTH_SUBJECT" '**结论：** 本次有 1 项新变化。')"
assert_eq 'maintainer health mail rejects missing required sections' 'health-sections' \
  "$(founder_mail_rejection_reason health "$HEALTH_SUBJECT" '一句话结论：运行正常')"
assert_eq 'maintainer health mail rejects environment names' 'body-internal' \
  "$(founder_mail_rejection_reason health "$HEALTH_SUBJECT" "$HEALTH_BODY
ZF_HOME")"
assert_eq 'maintainer health mail rejects file paths' 'body-internal' \
  "$(founder_mail_rejection_reason health "$HEALTH_SUBJECT" "$HEALTH_BODY
$HOME/private.log")"
assert_eq 'maintainer health mail rejects long SHAs' 'body-internal' \
  "$(founder_mail_rejection_reason health "$HEALTH_SUBJECT" "$HEALTH_BODY
版本：b454fd00fa")"
assert_eq 'maintainer health mail rejects raw log rows' 'body-internal' \
  "$(founder_mail_rejection_reason health "$HEALTH_SUBJECT" "$HEALTH_BODY
2026-09-26T03:00:00Z deploy STUCK detail=x=y")"
assert_eq 'maintainer health mail rejects raw node status rows' 'body-internal' \
  "$(founder_mail_rejection_reason health "$HEALTH_SUBJECT" "$HEALTH_BODY
deploy STUCK 2 pending")"
assert_eq 'maintainer health mail rejects a roster recipient' 'health-recipient' \
  "$(_pre_send_mail_rejection_for_recipients health "$HEALTH_SUBJECT" "$HEALTH_BODY" reporter@fixture.invalid)"
assert_eq 'maintainer health mail accepts only the maintainer recipient' '' \
  "$(_pre_send_mail_rejection_for_recipients health "$HEALTH_SUBJECT" "$HEALTH_BODY" "$HEALTH_MAINTAINER_ADDRESS")"
FAKE_CURL_CALLS_FILE="$TMP_DIR/fake-curl-calls.log"
export FAKE_CURL_CALLS_FILE
: > "$FAKE_CURL_CALLS_FILE"
FAKE_GCLOUD_FAIL=1
FAKE_GCLOUD_STDERR='proxy failure access_token=health-proxy-secret'
: > "$NOTIFY_LOG_FILE"
NOTIFY_LAST_SEND_RETRY_SAFE=0
if notify_founder_health "$HEALTH_SUBJECT" "$HEALTH_BODY"; then
  health_send_status=0
else
  health_send_status=$?
fi
assert_eq 'health send reports token-mint failure' '1' "$health_send_status"
assert_eq 'health send preserves pre-POST retry safety from strict sender' '1' "$NOTIFY_LAST_SEND_RETRY_SAFE"
health_proxy_audit="$(cat "$NOTIFY_LOG_FILE")"
assert_contains 'health send audit identifies token-mint proxy failure' \
  "$health_proxy_audit" $'stage=token-mint'
assert_not_contains 'health send audit excludes proxy credentials' \
  "$health_proxy_audit" 'health-proxy-secret'
assert_not_contains 'health send audit excludes health body' \
  "$health_proxy_audit" '员工可批量下载订单清单'
assert_eq 'health send does not call Gmail after token-mint failure' \
  '0' "$(wc -l < "$FAKE_CURL_CALLS_FILE" | tr -d '[:space:]')"
FAKE_GCLOUD_FAIL=""
FAKE_GCLOUD_STDERR=""
assert_eq 'maintainer mail rejects unknown kind' 'kind' \
  "$(founder_mail_rejection_reason operational "$DECISION_SUBJECT" "$DECISION_BODY")"
assert_eq 'maintainer mail rejects retired conclusion kind' 'kind' \
  "$(founder_mail_rejection_reason conclusion '[example] 这一轮未能完成' '这一轮已经结束。')"
assert_eq 'maintainer mail rejects English subject' 'subject-language' \
  "$(founder_mail_rejection_reason decision 'Production issue' "$DECISION_BODY")"
assert_eq 'maintainer mail accepts a Chinese subject that names the product' '' \
  "$(founder_mail_rejection_reason decision '需要你确认：the product 的发布节奏' "$DECISION_BODY")"
assert_eq 'maintainer mail rejects subject over 40 characters' 'subject-length' \
  "$(founder_mail_rejection_reason decision "$(printf '中%.0s' {1..41})" "$DECISION_BODY")"
assert_eq 'maintainer mail rejects issue-number subject' 'subject-issue-number' \
  "$(founder_mail_rejection_reason decision '订单处理需要确认 #1678' "$DECISION_BODY")"
assert_eq 'maintainer mail rejects machine-log pointers' 'body-internal' \
  "$(founder_mail_rejection_reason incident "$INCIDENT_SUBJECT" $'用户目前看到：付款失败。\n我们正在：排查问题，详情在机器上的日志里。\n下次更新：2026-09-23 18:30（协调世界时）')"
assert_eq 'maintainer mail rejects internal terminology' 'body-internal' \
  "$(founder_mail_rejection_reason decision "$DECISION_SUBJECT" $'客户/公司：客户甲\n用户动作：选择次日送达\n结果：lot master-data candidate 未通过 advisor 判断\nA）继续；影响：无。\nB）停止；影响：延迟。\n建议：A\n请回复“A”')"
assert_eq 'maintainer mail rejects untranslated English prose' 'body-language' \
  "$(founder_mail_rejection_reason decision "$DECISION_SUBJECT" $'客户/公司：客户甲\n用户动作：客户昨天付了款\n结果：The customer paid yesterday and has not received the order.\nA）继续；影响：延迟。\nB）停止；影响：安全。\n建议：A\n请回复“A”')"
assert_eq 'maintainer mail rejects decision without concrete customer facts' 'decision-situation' \
  "$(founder_mail_rejection_reason decision "$DECISION_SUBJECT" $'A）选项；影响：无。\nB）选项；影响：无。\n建议：A\n请回复“A”')"
assert_eq 'maintainer mail rejects decision with one option' 'decision-options' \
  "$(founder_mail_rejection_reason decision "$DECISION_SUBJECT" $'客户/公司：客户甲\n用户动作：选择送达\n结果：无法承诺\nA）普通配送；影响：晚一天。\n建议：A\n请回复“A”')"
assert_eq 'maintainer mail rejects decision missing consequences' 'decision-consequence' \
  "$(founder_mail_rejection_reason decision "$DECISION_SUBJECT" $'客户/公司：客户甲\n用户动作：选择送达\n结果：无法承诺\nA）普通配送\nB）加急配送；影响：增加成本。\n建议：A\n请回复“A”')"
assert_eq 'maintainer mail rejects empty option consequence' 'decision-consequence' \
  "$(founder_mail_rejection_reason decision "$DECISION_SUBJECT" $'客户/公司：客户甲\n用户动作：选择送达\n结果：无法承诺\nA）普通配送；影响：。\nB）加急配送；影响：增加成本。\n建议：A\n请回复“A”')"
assert_eq 'maintainer mail rejects decision without exact reply instruction' 'decision-reply' \
  "$(founder_mail_rejection_reason decision "$DECISION_SUBJECT" "${DECISION_BODY%请回复*}请告诉我选择")"
assert_eq 'maintainer mail rejects a decision that omits the actual question' 'decision-question' \
  "$(founder_mail_rejection_reason decision "$DECISION_SUBJECT" "${DECISION_BODY/问题：是否应保留次日送达？$'\n'/}")"
assert_contains 'single-ticket advisor prompt requires the real decision question' \
  "$(cat "$SCRIPT_DIR/prompts/advisor.md")" 'unanswered product/business question as a direct question'
assert_contains 'advisor schema requires the real decision question' \
  "$(cat "$SCRIPT_DIR/prompts/advisor.schema.json")" 'actual unanswered product/business question from the issue'
assert_eq 'maintainer mail rejects outcome without production list link' 'outcome-content' \
  "$(founder_mail_rejection_reason outcome "$OUTCOME_SUBJECT" '用户现在可以下载库存表格。')"
assert_eq 'maintainer mail rejects incident without an exact next-update time' 'incident-next-update' \
  "$(founder_mail_rejection_reason incident "$INCIDENT_SUBJECT" $'用户目前看到：付款失败。\n我们正在：恢复服务。\n下次更新：稍后')"

# --- maintainer health-mail schedule and incident state ---------------------
source "$SCRIPT_DIR/night/founder-health-mail.sh"
assert_eq 'health digest uses six-hour UTC slots' \
  '20260926T00Z' "$(founder_health_mail_slot_key 1790391000)"
assert_eq 'health digest advances at the next UTC interval' \
  '20260926T06Z' "$(founder_health_mail_slot_key 1790402400)"
HEALTH_MAIL_LEDGER="$TMP_DIR/founder-health-mail.json"
founder_health_mail_ensure_ledger "$HEALTH_MAIL_LEDGER" 1000
HEALTH_MAIL_CLAIM_EVENTS='[{"key":"fixture:1","created_at":1000}]'
assert_eq 'health digest slot can be reserved once' 'reserved' \
  "$(founder_health_mail_claim_digest "$HEALTH_MAIL_LEDGER" 20260926T00Z 1000 "$HEALTH_MAIL_CLAIM_EVENTS")"
assert_eq 'health digest reservation survives restart' 'duplicate' \
  "$(founder_health_mail_claim_digest "$HEALTH_MAIL_LEDGER" 20260926T00Z 1001 "$HEALTH_MAIL_CLAIM_EVENTS")"
assert_eq 'health-mail node stays OK before cadence grace expires' 'OK' \
  "$(founder_health_mail_node_status "$HEALTH_MAIL_LEDGER" 22899)"
assert_eq 'health-mail node goes SLOW at cadence plus five-minute grace' 'SLOW' \
  "$(founder_health_mail_node_status "$HEALTH_MAIL_LEDGER" 22900)"
assert_eq 'health-mail node goes STUCK after cadence plus two hours' 'STUCK' \
  "$(founder_health_mail_node_status "$HEALTH_MAIL_LEDGER" 29800)"
HEALTH_MAIL_FIXTURE="$TMP_DIR/health-mail-fixture"
export HEALTH_MAIL_FIXTURE
mkdir -p "$HEALTH_MAIL_FIXTURE/night" "$HEALTH_MAIL_FIXTURE/state" \
  "$HEALTH_MAIL_FIXTURE/logs" "$HEALTH_MAIL_FIXTURE/spend" "$HEALTH_MAIL_FIXTURE/repo/engine/state"
HEALTH_MAIL_NOW="$(date -u -d '2026-09-26 05:03:00Z' +%s)"
HEALTH_MAIL_AT='2026-09-26T04:00:00Z'
jq -n --arg at "$HEALTH_MAIL_AT" \
  '{state:"concluded",closed_by_pipeline:true,released:true,deploy_state:"deployed",deployed_sha:"73ed7da83abcdef01234567890123456789012345",run:{outcome:"merged",concluded_at:$at,merged_at:$at,evidence:{pr_number:"78"}}}' \
  > "$HEALTH_MAIL_FIXTURE/state/56.json"
jq -n --arg at '2026-09-26T05:04:00Z' \
  '{state:"awaiting-release",run:{outcome:"merged",merged_at:$at,evidence:{pr_number:"79"}}}' \
  > "$HEALTH_MAIL_FIXTURE/state/54.json"
jq -n --arg at '2026-09-25T03:00:00Z' \
  '{state:"concluded",closed_by_pipeline:true,released:true,deploy_state:"deployed",deployed_sha:"c13d8c4a5a111111111111111111111111111111",deployed_at:$at,run:{outcome:"merged",concluded_at:$at,merged_at:"2026-09-26T04:30:00Z",evidence:{}}}' \
  > "$HEALTH_MAIL_FIXTURE/state/55.json"
jq -n --arg at '2026-09-26T00:30:00Z' \
  '{state:"awaiting-release",run:{outcome:"merged",merged_at:$at,evidence:{pr_number:"80"}}}' \
  > "$HEALTH_MAIL_FIXTURE/state/53.json"
jq -n --arg at '2026-09-26T04:15:00Z' \
  '{state:"awaiting-release",run:{outcome:"merged",merged_at:$at,evidence:{pr_number:"not-a-number"}}}' \
  > "$HEALTH_MAIL_FIXTURE/state/52.json"
jq -n --arg at '2026-09-26T04:20:00Z' \
  '{state:"concluded",run:{outcome:"not-completed",concluded_at:$at}}' \
  > "$HEALTH_MAIL_FIXTURE/state/57.json"
jq -n --arg at '2026-09-26T04:30:00Z' \
  '{state:"concluded",run:{outcome:"not-completed",concluded_at:$at}}' \
  > "$HEALTH_MAIL_FIXTURE/state/58.json"
jq -n --arg at '2026-09-26T04:40:00Z' \
  '{state:"concluded",run:{outcome:"not-completed",concluded_at:$at}}' \
  > "$HEALTH_MAIL_FIXTURE/state/60.json"
jq -n --arg at '2026-09-26T00:30:00Z' \
  '{state:"concluded",run:{outcome:"not-completed",concluded_at:$at}}' \
  > "$HEALTH_MAIL_FIXTURE/state/59.json"
printf '%s\n' '73ed7da83abcdef01234567890123456789012345' > "$HEALTH_MAIL_FIXTURE/last-deployed-sha"
jq -n '{founder_login:"maintainer",recipients:{maintainer:"maintainer@example.invalid",tester_a:"a@example.invalid",tester_b:"b@example.invalid",tester_c:"c@example.invalid"}}' \
  > "$HEALTH_MAIL_FIXTURE/recipients.json"
jq -n '[
  {number:1831,author:{login:"tester_a"},assignees:[],labels:[]},
  {number:1832,author:{login:"tester_b"},assignees:[],labels:[]},
  {number:1833,author:{login:"tester_c"},assignees:[],labels:[]},
  {number:1834,author:{login:"maintainer"},assignees:[],labels:[]},
  {number:1835,author:{login:"other"},assignees:[],labels:[]},
  {number:57,author:{login:"fixture-reporter"},assignees:[],labels:[{name:"needs-recut"}]},
  {number:58,author:{login:"fixture-reporter"},assignees:[],labels:[]}
]' > "$HEALTH_MAIL_FIXTURE/open-issues.json"
jq -n '{incidents:[
  {id:"recurrence-one",date:"2026-09-22",class:"mail-credential-health",recurs_of:"founder-digest-refused-internal-ids"},
  {id:"recurrence-old",date:"2026-09-18",class:"过期类别",recurs_of:"original-old"}
]}' > "$HEALTH_MAIL_FIXTURE/repo/engine/state/incident-guards.json"
cat > "$HEALTH_MAIL_FIXTURE/logs/supervisor-wakes.log" <<'EOF'
2026-09-25T05:10:00Z node-stuck-30min episode=1
2026-09-25T06:00:00Z hand-agent-failed episode=2
2026-09-25T05:02:00Z too-old episode=3
EOF
printf '1790395500\timplement\t%s\t56\t\t1500\n1790395600\treview\t%s\t56\t\t1500\n' \
  "$MODEL_POLICY_TEST_WORK_IDENTITY" "$MODEL_POLICY_TEST_WORK_IDENTITY" \
  > "$HEALTH_MAIL_FIXTURE/spend/2026-09-26.log"
touch "$HEALTH_MAIL_FIXTURE/logs/release-e2e-56-20260926T010000Z.fixture.log"
touch "$HEALTH_MAIL_FIXTURE/logs/release-e2e-56-20260926T020000Z.retry.log"
touch "$HEALTH_MAIL_FIXTURE/logs/release-e2e-61-20260926T030000Z.fixture.log"
touch "$HEALTH_MAIL_FIXTURE/logs/release-e2e-62-20260925T230000Z.fixture.log"
REPO='example-maintainer/example-repo'
AGENT_INCIDENT_GUARDS_FILE="$HEALTH_MAIL_FIXTURE/repo/engine/state/incident-guards.json"
export AGENT_INCIDENT_GUARDS_FILE
HEALTH_MAIL_ORIGINAL_PATH="$PATH"
HEALTH_MAIL_BIN="$TMP_DIR/health-mail-bin"
mkdir -p "$HEALTH_MAIL_BIN"
cat > "$HEALTH_MAIL_BIN/gh" <<'EOF'
#!/usr/bin/env bash
[ "${HEALTH_MAIL_ISSUES_FAIL:-0}" = 1 ] && exit 1
[ "${1:-} ${2:-}" = 'issue list' ] || exit 1
cat "$HEALTH_MAIL_FIXTURE/open-issues.json"
EOF
chmod +x "$HEALTH_MAIL_BIN/gh"
PATH="$HEALTH_MAIL_BIN:$PATH"
HEALTH_MAIL_EVENTS='[
  {"key":"deploy:56:73ed7da83","section":"发布进度","text":"现在可以：员工可批量下载订单清单；9月26日 09:00 上线的版本。","kind":"deploy","highlight":false,"created_at":1790395500},
  {"key":"closed:1831:1","section":"事项完成","text":"修好了：订单查询 #1831 4b7c032e0。","kind":"closed","highlight":true,"created_at":1790395600},
  {"key":"node:build:1","section":"处理变化","text":"构建环节持续异常，后续由负责人继续处理。","kind":"node","highlight":false,"created_at":1790395700},
  {"key":"daily:2026-09-26","section":"今日汇总","text":"今日发布 2 次。","kind":"daily","highlight":false,"created_at":1790395800}
]'
HEALTH_MAIL_BUILT="$(founder_health_mail_build_body "$HEALTH_MAIL_EVENTS")"
assert_contains 'incremental digest lists user-visible release outcome' "$HEALTH_MAIL_BUILT" '员工可批量下载订单清单'
assert_contains 'incremental digest counts closed tickets and highlights focus tickets' "$HEALTH_MAIL_BUILT" '**事项完成：** 1 项'
assert_contains 'incremental digest keeps the focus ticket headline without ID' "$HEALTH_MAIL_BUILT" '- 修好了：订单查询'
assert_contains 'incremental digest folds node alert into change section' "$HEALTH_MAIL_BUILT" '构建环节持续异常'
assert_contains 'daily report rides under 今日汇总' "$HEALTH_MAIL_BUILT" '**今日汇总**'
assert_eq 'incremental digest passes maintainer mail contract' '' \
  "$(_pre_send_mail_rejection_for_recipients health "$HEALTH_SUBJECT" "$HEALTH_MAIL_BUILT" "$HEALTH_MAINTAINER_ADDRESS")"

HEALTH_MAIL_NO_WAKE_LOG="$TMP_DIR/health-mail-no-wake-log"
mkdir -p "$HEALTH_MAIL_NO_WAKE_LOG"
HEALTH_MAIL_NO_WAKE_LINES="$(founder_health_mail_metric_lines "$HEALTH_MAIL_NO_WAKE_LOG" "$HEALTH_MAIL_NOW")"
assert_contains 'health metrics mark an absent wake log as pending' "$HEALTH_MAIL_NO_WAKE_LINES" \
  '过去24小时自动唤醒监督程序：待统计'
assert_contains 'health metrics average daily tokens per released issue' \
  "$(founder_health_mail_metric_lines "$HEALTH_MAIL_FIXTURE" "$HEALTH_MAIL_NOW")" '今日每张交付票平均消耗模型令牌：3000'
jq -n '{incidents:[{id:"untracked",date:"2026-09-26",class:"尚未登记复发字段"}]}' \
  > "$HEALTH_MAIL_FIXTURE/repo/engine/state/incident-guards-untracked.json"
HEALTH_MAIL_UNTRACKED="$(AGENT_INCIDENT_GUARDS_FILE="$HEALTH_MAIL_FIXTURE/repo/engine/state/incident-guards-untracked.json" \
  founder_health_mail_metric_lines "$HEALTH_MAIL_FIXTURE" "$HEALTH_MAIL_NOW")"
assert_contains 'health metrics mark recurrence tracking as pending before tracking exists' "$HEALTH_MAIL_UNTRACKED" \
  '本周同类问题复发：待统计'

NOTIFY_LOG_FILE="$TMP_DIR/health-contract.log"
: > "$NOTIFY_LOG_FILE"
if _send_email_logged strict "$HEALTH_SUBJECT" "${HEALTH_MAIL_BUILT}"$'\n内部类别：mail-credential-health' '' health "$HEALTH_MAINTAINER_ADDRESS"; then
  HEALTH_REJECTION_STATUS=0
else
  HEALTH_REJECTION_STATUS=$?
fi
assert_eq 'health send refuses a contract-breaking digest body' '1' "$HEALTH_REJECTION_STATUS"
assert_contains 'health rejection audit records exact safe contract reason' "$(cat "$NOTIFY_LOG_FILE")" \
  $'reason=contract-rejected\tresult=failed\tcontract_reason=body-internal'
assert_not_contains 'health rejection audit never records the rejected body' "$(cat "$NOTIFY_LOG_FILE")" 'mail-credential-health'
PATH="$HEALTH_MAIL_ORIGINAL_PATH"

NOTIFY_LOG_FILE="$TMP_DIR/maintainer-contract.log"
: > "$NOTIFY_LOG_FILE"
RECIPIENTS_FILE="$AUDIENCE_ROSTER"
FAKE_CURL_CALLS_FILE="$TMP_DIR/fake-curl-calls.log"
export FAKE_CURL_CALLS_FILE
: > "$FAKE_CURL_CALLS_FILE"
FAKE_CURL_BODY='{"id":"msg-contract-1","threadId":"thread-contract-1"}'
SEND_EMAIL_OUT="$(send_email "$DECISION_SUBJECT" "$DECISION_BODY" 9001 --founder-kind decision maintainer@notify-fixture.invalid 2>"$TMP_DIR/maintainer-contract.stderr")"
assert_eq 'send boundary sends valid classified maintainer mail' 'thread-contract-1' "$SEND_EMAIL_OUT"
: > "$FAKE_CURL_CALLS_FILE"
SEND_EMAIL_OUT="$(send_email "$INCIDENT_SUBJECT" "$INCIDENT_BODY" '' maintainer@notify-fixture.invalid 2>"$TMP_DIR/maintainer-contract.stderr")"
assert_eq 'send boundary rejects unclassified maintainer mail' '' "$SEND_EMAIL_OUT"
assert_contains 'send boundary logs the rejection reason without body' "$(cat "$NOTIFY_LOG_FILE")" $'reason=contract-rejected\tresult=failed'
assert_contains 'send boundary audit records exact safe contract reason' "$(cat "$NOTIFY_LOG_FILE")" \
  $'reason=contract-rejected\tresult=failed\tcontract_reason=kind'
assert_not_contains 'send boundary log does not contain rejected body' "$(cat "$NOTIFY_LOG_FILE")" '用户目前看到'
assert_eq 'send boundary does not transmit rejected maintainer mail' '' "$(cat "$FAKE_CURL_CALLS_FILE")"
SEND_EMAIL_OUT="$(send_email "$DECISION_SUBJECT" '选项 A 或 B？' 9001 --founder-kind decision reporter@notify-fixture.invalid 2>"$TMP_DIR/reporter-contract.stderr")"
assert_eq 'send boundary rejects malformed reporter-routed decision mail' '' "$SEND_EMAIL_OUT"
assert_contains 'reporter-routed decision rejection is audited' "$(cat "$NOTIFY_LOG_FILE")" $'reason=contract-rejected\tresult=failed'
SEND_EMAIL_OUT="$(send_email "$DECISION_SUBJECT" "$DECISION_BODY" 9001 --founder-kind decision reporter@notify-fixture.invalid 2>"$TMP_DIR/reporter-contract.stderr")"
assert_eq 'send boundary accepts valid reporter-routed decision mail' 'thread-contract-1' "$SEND_EMAIL_OUT"
: > "$FAKE_CURL_CALLS_FILE"
run_strict "$INCIDENT_SUBJECT" "$INCIDENT_BODY" --founder-kind operational maintainer@notify-fixture.invalid
assert_eq 'strict send boundary rejects unclassified maintainer mail' '1' "$STRICT_STATUS"
assert_contains 'strict send boundary reports contract rejection' "$STRICT_ERR" 'rejected maintainer mail by contract (kind)'
assert_contains 'strict send boundary audits rejected maintainer mail' "$(cat "$NOTIFY_LOG_FILE")" $'reason=contract-rejected\tresult=failed'
assert_eq 'strict send boundary does not transmit rejected maintainer mail' '' "$(cat "$FAKE_CURL_CALLS_FILE")"
FAKE_CURL_BODY=''

# --- production outcomes queue into one hourly digest ---------------------
OUTCOME_HOME="$TMP_DIR/outcome"
mkdir -p "$OUTCOME_HOME"
AGENT_HOME="$OUTCOME_HOME"
REPO='example-maintainer/example-repo'
RECIPIENTS_FILE="$OUTCOME_HOME/recipients.json"
OUTCOME_SEND_LOG="$OUTCOME_HOME/sends.log"
cat > "$RECIPIENTS_FILE" <<'JSON'
{"founder_login":"maintainer","recipients":{"maintainer":"maintainer@fixture.invalid","reporter":"reporter@fixture.invalid"}}
JSON
: > "$OUTCOME_SEND_LOG"
OUTCOME_COMMENT_DIR="$OUTCOME_HOME/generated-comments"
OUTCOME_MODEL_PROMPTS="$OUTCOME_HOME/model-prompts"
OUTCOME_PR_VIEW_LOG="$OUTCOME_HOME/pr-views.log"
mkdir -p "$OUTCOME_COMMENT_DIR"
FAKE_CLOSED_ISSUES_JSON='[]'
OUTCOME_MODEL_REPLY=''
model_policy() { printf '%s\n' 'fixture:work-model'; }
run_model_json() {
  cat "$5" >> "$OUTCOME_MODEL_PROMPTS"
  if [ "$OUTCOME_MODEL_REPLY" = 'NONE' ]; then
    printf '{"is_error":false,"structured_output":{"user_outcome":"NONE"},"tokens_used":"1"}\n'
    return 0
  fi
  jq -cn --arg outcome "${OUTCOME_MODEL_REPLY:-员工可以在工作台查看处理状态。}" \
    '{is_error:false,structured_output:{user_outcome:$outcome},tokens_used:"1"}'
}
record_premium_spend() { :; }
model_cost_usd() { echo 0; }
guarded_issue_comment() { printf '%s\n' "$2" > "$OUTCOME_COMMENT_DIR/$1"; }
gh() {
  local issue_num issue_json pr_num
  if [ "${1:-} ${2:-}" = 'issue list' ]; then
    printf '%s\n' "$FAKE_CLOSED_ISSUES_JSON"
    return 0
  fi
  if [ "${1:-} ${2:-}" = 'pr view' ]; then
    pr_num="${3:-}"
    printf '%s\n' "$pr_num" >> "$OUTCOME_PR_VIEW_LOG"
    if [[ " $* " == *' --jq '* ]]; then
      git rev-parse HEAD
    else
      jq -cn --arg number "$pr_num" \
        '{title:("PR " + $number + " scoped title"),body:("PR " + $number + " scoped body"),url:("https://github.com/example-maintainer/example-repo/pull/" + $number)}'
    fi
    return 0
  fi
  if [ "${1:-} ${2:-}" = 'pr diff' ]; then
    printf 'PR-only diff for #%s\n' "${3:-}"
    return 0
  fi
  [ "${1:-} ${2:-}" = 'issue view' ] || return 1
  issue_num="${3:-}"
  case "$issue_num" in
    9001) issue_json='{"title":"批量下载订单清单","body":"","comments":[{"body":"**User outcome:** 员工可以批量下载订单清单。"}],"labels":[]}' ;;
    9002) issue_json='{"title":"付款页面查看付款状态","body":"","comments":[{"body":"**User outcome:** 员工可以在付款页面查看付款状态。"}],"labels":[]}' ;;
    9003) issue_json='{"title":"预计送达时间查询","body":"","comments":[{"body":"**User outcome:** 客户可以在下单页面查询预计送达时间。"}],"labels":[]}' ;;
    9004) issue_json='{"title":"库存批次信息查看","body":"","comments":[{"body":"**User outcome:** 员工可以在库存页面查看批次信息。"}],"labels":[]}' ;;
    9005) issue_json='{"title":"订单状态查询","body":"","comments":[{"body":"**User outcome:** 客户可以在订单页面查询订单状态。"}],"labels":[]}' ;;
    9006) issue_json='{"title":"工作台处理状态查看","body":"Issue body for #9006. Implementation PR: https://github.com/example-maintainer/example-repo/pull/19006","comments":[],"labels":[]}' ;;
    9007) issue_json='{"title":"聊天成果文件权限查看","body":"","comments":[{"body":"**User outcome:** 员工在聊天里能看到自己有权限的成果文件"}],"labels":[]}' ;;
    9008) issue_json='{"title":"工作台处理状态缓存","body":"Implementation PR: https://github.com/example-maintainer/example-repo/pull/19008","comments":[{"body":"**User outcome:** None"}],"labels":[]}' ;;
    9009) issue_json='{"title":"工作台订单处理状态查看","body":"Implementation PR: https://github.com/example-maintainer/example-repo/pull/19009","comments":[{"body":"**User outcome:** 员工可以查看订单。还可以导出订单。"}],"labels":[]}' ;;
    9011) issue_json='{"title":"库存批次信息查看","body":"","comments":[{"body":"**User outcome:** 员工可以在库存页面查看批次信息。"}],"labels":[]}' ;;
    9013) issue_json='{"title":"Outcome generation failure fixture","body":"Implementation PR: https://github.com/example-maintainer/example-repo/pull/19013","comments":[{"body":"**User outcome:** None"}]}' ;;
    9020) issue_json='{"title":"项目维护者回收工作空间","body":"","comments":[{"body":"**User outcome:** 项目维护者现在可以回收长期闲置的工作空间。"}],"labels":[]}' ;;
    9021) issue_json='{"title":"智能体任务状态查看","body":"","comments":[{"body":"**User outcome:** 智能体现在可以继续处理任务。"}],"labels":[]}' ;;
    9022) issue_json='{"title":"工作树清理","body":"","comments":[{"body":"**User outcome:** 工作树中的未完成任务现在可以继续运行。"}],"labels":[]}' ;;
    9023) issue_json='{"title":"CI 构建状态查看","body":"","comments":[{"body":"**User outcome:** CI 已通过，改动现在可以合并。"}],"labels":[]}' ;;
    9024) issue_json='{"title":"流水线运行状态","body":"","comments":[{"body":"**User outcome:** 流水线现在会自动恢复处理。"}],"labels":[]}' ;;
    9025) issue_json='{"title":"库存批次信息查看","body":"","comments":[{"body":"**User outcome:** 员工可以在库存页面查看批次信息。"}],"labels":[{"name":"pipeline-system"}]}' ;;
    9026) issue_json='{"title":"订单状态查询","body":"","comments":[{"body":"**User outcome:** 客户可以在订单页面查询订单状态。"}],"labels":[]}' ;;
    9027) issue_json='{"title":"迁移新增表的检查","body":"","comments":[{"body":"**User outcome:** 开发者现在可以在 PR 检查中发现迁移与集成测试预期不一致并及时修正。"}],"labels":[]}' ;;
    9028) issue_json='{"title":"Feature X 发布状态查看","body":"","comments":[{"body":"**User outcome:** Feature X 发布运维人员可在发布页查看服务状态。"}],"labels":[]}' ;;
    *) return 1 ;;
  esac
  if [ -f "$OUTCOME_COMMENT_DIR/$issue_num" ]; then
    issue_json="$(jq --arg body "$(cat "$OUTCOME_COMMENT_DIR/$issue_num")" '.comments += [{body:$body,createdAt:"2026-09-25T00:00:00Z"}]' <<< "$issue_json")"
  fi
  printf '%s\n' "$issue_json"
}
send_email_strict() {
  local subject="$1" body="$2" kind='' rejection
  shift 2
  if [ "${1:-}" = '--founder-kind' ]; then
    shift
    kind="$1"
    shift
  fi
  [ "$kind" = 'outcome' ] || return 1
  rejection="$(founder_mail_rejection_reason "$kind" "$subject" "$body")"
  [ -z "$rejection" ] || return 1
  printf 'subject=%s\nbody=%s\nrecipients=%s\n' "$subject" "$body" "$*" >> "$OUTCOME_SEND_LOG"
  [ "${FAKE_OUTCOME_SEND_FAIL:-0}" != '1' ] || return 1
  echo 'fixture-message-id'
}
queue_maintainer_outcome 9001 sha-9001
queue_maintainer_outcome 9002 sha-9002
queue_maintainer_outcome 9001 sha-9001
assert_eq 'outcome queue deduplicates the same delivered revision' '2' \
  "$(jq -r '.pending | length' "$OUTCOME_HOME/night/founder-outcomes.json")"

FAKE_OUTCOME_SEND_FAIL=1
flush_founder_outcome_digest 1000 || true
assert_eq 'failed outcome digest remains queued for retry' '2' \
  "$(jq -r '.pending | length' "$OUTCOME_HOME/night/founder-outcomes.json")"
assert_eq 'failed send does not advance the hourly window' '0' \
  "$(jq -r '.last_sent_at' "$OUTCOME_HOME/night/founder-outcomes.json")"

FAKE_OUTCOME_SEND_FAIL=0
flush_founder_outcome_digest 1001
assert_eq 'successful digest clears pending outcomes' '0' \
  "$(jq -r '.pending | length' "$OUTCOME_HOME/night/founder-outcomes.json")"
assert_eq 'successful digest records its send time' '1001' \
  "$(jq -r '.last_sent_at' "$OUTCOME_HOME/night/founder-outcomes.json")"
assert_eq 'successful release digest records item-level health history' '2' \
  "$(jq -s 'length' "$OUTCOME_HOME/night/founder-health-outcomes.jsonl")"
assert_contains 'health history stores user-visible outcomes without re-reading GitHub' \
  "$(cat "$OUTCOME_HOME/night/founder-health-outcomes.jsonl")" '员工可以批量下载订单清单。'
OUTCOME_FIRST_SEND="$(tail -n 9 "$OUTCOME_SEND_LOG")"
assert_contains 'digest subject names the first user outcome' "$OUTCOME_FIRST_SEND" 'subject=员工可以批量下载订单清单等2项改进已上线'
assert_eq 'digest subject keeps product words' '有权限的用户现在可以在 WebUI 或聊天会话中查看报表原文' \
  "$(maintainer_digest_subject_title '有权限的用户现在可以在 WebUI 或聊天会话中查看报表原文。另有说明' 34)"
assert_eq 'digest subject cuts at a clause boundary' '工作区管理员可在权限管理中为成员或角色授予权限、创建审批规则' \
  "$(maintainer_digest_subject_title '工作区管理员可在权限管理中为成员或角色授予权限、创建审批规则，并在日志页查看记录' 34)"
assert_eq 'digest subject drops issue refs' '修复报表导出' "$(maintainer_digest_subject_title '修复报表导出 #1588' 34)"
assert_eq 'digest subject falls back to the count when the outcome is mostly Latin' '3项改进已上线' \
  "$(maintainer_digest_subject 'Feature X 用户现在可在 WebUI `/chat/` 按需生成报表' 3)"
assert_eq 'fallback digest subject passes the founder-mail subject contract' '' \
  "$(founder_mail_rejection_reason outcome "$(maintainer_digest_subject 'Feature X 用户现在可在 WebUI `/chat/` 按需生成报表' 3)" x | grep -E '^subject-' || true)"
assert_eq 'digest subject keeps a Chinese outcome title' '员工可以批量下载订单清单等2项改进已上线' \
  "$(maintainer_digest_subject '员工可以批量下载订单清单。' 2)"
assert_not_contains 'digest subject omits issue numbers' "$(sed -n 's/^subject=//p' "$OUTCOME_SEND_LOG")" '9001'
assert_eq 'digest bullets preserve user outcome lines verbatim' \
  $'- 员工可以批量下载订单清单。\n- 员工可以在付款页面查看付款状态。' \
  "$(grep '^- ' <<< "$OUTCOME_FIRST_SEND")"
assert_not_contains 'digest does not expose engineering ticket titles' "$OUTCOME_FIRST_SEND" '成果卡只读数据接口'
assert_contains 'digest body links each outcome' "$OUTCOME_FIRST_SEND" 'https://github.com/example-maintainer/example-repo/issues/9001'
assert_contains 'outcome mail reaches teammates, not maintainer' "$OUTCOME_FIRST_SEND" 'reporter@fixture.invalid'
assert_not_contains 'maintainer receives release result through incremental ledger' "$OUTCOME_FIRST_SEND" 'maintainer@fixture.invalid'
assert_eq 'release results queue in maintainer digest ledger' '2' \
  "$(jq '.pending_events | length' "$OUTCOME_HOME/night/founder-health-mail.json")"
queue_maintainer_outcome 9001 sha-9001
assert_eq 'an outcome already mailed for the same deploy is not queued again' '0' \
  "$(jq -r '.pending | length' "$OUTCOME_HOME/night/founder-outcomes.json")"

queue_maintainer_outcome 9003 sha-9003
flush_founder_outcome_digest 4600
assert_eq 'digest is not resent before one hour' '2' \
  "$(grep -c '^subject=' "$OUTCOME_SEND_LOG")"
flush_founder_outcome_digest 4601
assert_eq 'digest sends at the one-hour boundary' '3' \
  "$(grep -c '^subject=' "$OUTCOME_SEND_LOG")"

queue_maintainer_outcome 9004 sha-9004
queue_maintainer_outcome 9005 sha-9005
queue_maintainer_outcome 9006 sha-9006
queue_maintainer_outcome 9007 sha-9007
queue_maintainer_outcome 9008 sha-9008
queue_maintainer_outcome 9009 sha-9009
flush_founder_outcome_digest 29801
assert_eq 'missing outcomes are generated instead of dropped' '0' \
  "$(jq -r '.pending | length' "$OUTCOME_HOME/night/founder-outcomes.json")"
assert_eq 'digest sends user outcomes despite engineering titles' '4' \
  "$(grep -c '^subject=' "$OUTCOME_SEND_LOG")"
OUTCOME_LAST_SEND="$(awk 'BEGIN { send=0 } /^subject=/ { send++ } send == 4 { print }' "$OUTCOME_SEND_LOG")"
assert_eq 'digest includes available and generated user outcomes exactly' \
  $'- 员工可以在库存页面查看批次信息。\n- 客户可以在订单页面查询订单状态。\n- 员工可以在工作台查看处理状态。\n- 员工在聊天里能看到自己有权限的成果文件\n- 员工可以在工作台查看处理状态。\n- 员工可以在工作台查看处理状态。' \
  "$(grep '^- ' <<< "$OUTCOME_LAST_SEND")"
assert_not_contains 'title-only ticket produces no maintainer bullet' "$OUTCOME_SEND_LOG" '成果卡只读数据接口（真实文件权限过滤）'
assert_contains 'digest includes generated outcome for title-only ticket' "$OUTCOME_LAST_SEND" '/issues/9006'
assert_contains 'digest replaces explicit None with generated outcome' "$OUTCOME_LAST_SEND" '/issues/9008'
assert_contains 'digest replaces unreadable multi-sentence outcome' "$OUTCOME_LAST_SEND" '/issues/9009'
assert_contains 'model receives issue title and body' "$(cat "$OUTCOME_MODEL_PROMPTS")" '工作台处理状态查看'
assert_contains 'model receives issue body' "$(cat "$OUTCOME_MODEL_PROMPTS")" 'Issue body for #9006'
assert_contains 'model receives only referenced PR title/body and diff' "$(cat "$OUTCOME_MODEL_PROMPTS")" 'PR 19006 scoped body'
assert_contains 'model receives the referenced PR diff' "$(cat "$OUTCOME_MODEL_PROMPTS")" 'PR-only diff for #19006'
assert_not_contains 'model prompt excludes broad merged-commit context' "$(cat "$OUTCOME_MODEL_PROMPTS")" 'Merged change:'
assert_eq 'outcome generation reads merged PR for all missing outcomes' $'19006\n19008\n19009' "$(cat "$OUTCOME_PR_VIEW_LOG")"
assert_contains 'generated outcome is persisted back to the issue' \
  "$(cat "$OUTCOME_COMMENT_DIR/9006")" '**User outcome:** 员工可以在工作台查看处理状态。'
assert_not_contains 'generated outcomes do not enter supervisor inbox' \
  "$(cat "$OUTCOME_HOME/supervisor-inbox" 2>/dev/null || true)" 'issue=#9006'

mkdir -p "$OUTCOME_HOME/state"
cat > "$OUTCOME_HOME/state/9011.json" <<'JSON'
{"released":true,"deployed_sha":"sha-9011","run":{"evidence":{"pr_number":"19011"}}}
JSON
FAKE_CLOSED_ISSUES_JSON='[{"number":9011,"closedAt":"1970-01-01T08:16:42Z","labels":[{"name":"priority:top"},{"name":"released"}]},{"number":9012,"closedAt":"1970-01-01T08:16:43Z","labels":[{"name":"priority:top"}]}]'
flush_founder_outcome_digest 33400
assert_eq 'close sweep queues deployed issue before hourly send window' '1' \
  "$(jq -r '.pending | length' "$OUTCOME_HOME/night/founder-outcomes.json")"
assert_eq 'close sweep does not send before hourly boundary' '4' \
  "$(grep -c '^subject=' "$OUTCOME_SEND_LOG")"
flush_founder_outcome_digest 33401
assert_eq 'close sweep sends at hourly boundary' '5' \
  "$(grep -c '^subject=' "$OUTCOME_SEND_LOG")"
assert_contains 'close sweep includes shipped closed issue' "$(cat "$OUTCOME_SEND_LOG")" '/issues/9011'
assert_not_contains 'close sweep excludes closed issue without release evidence' "$(cat "$OUTCOME_SEND_LOG")" '/issues/9012'
FAKE_CLOSED_ISSUES_JSON='[]'
OUTCOME_MODEL_REPLY='NONE'
queue_maintainer_outcome 9013 sha-9013
flush_founder_outcome_digest 37001
assert_eq 'model refusal keeps deployed issue queued' '1' \
  "$(jq -r '.pending | length' "$OUTCOME_HOME/night/founder-outcomes.json")"
assert_eq 'model refusal does not send an incomplete digest' '5' \
  "$(grep -c '^subject=' "$OUTCOME_SEND_LOG")"
assert_contains 'model refusal alerts supervisor once' \
  "$(cat "$OUTCOME_HOME/supervisor-inbox")" 'founder-outcome-missing issue=#9013'
flush_founder_outcome_digest 37002
assert_eq 'repeated model refusal does not duplicate supervisor inbox alert' '1' \
  "$(grep -c 'founder-outcome-missing issue=#9013' "$OUTCOME_HOME/supervisor-inbox")"
assert_eq 'repeated model refusal retains the deployed issue' '1' \
  "$(jq -r '.pending | length' "$OUTCOME_HOME/night/founder-outcomes.json")"
OUTCOME_MODEL_REPLY=''

# Maintainer digest must omit internal outcomes and pipeline-system tickets. The
# first queued items are internal so subject selection must start at the
# first user-facing result instead.
FILTER_HOME="$TMP_DIR/outcome-filter"
mkdir -p "$FILTER_HOME"
AGENT_HOME="$FILTER_HOME"
OUTCOME_HOME="$FILTER_HOME"
RECIPIENTS_FILE="$FILTER_HOME/recipients.json"
OUTCOME_SEND_LOG="$FILTER_HOME/sends.log"
OUTCOME_COMMENT_DIR="$FILTER_HOME/generated-comments"
OUTCOME_PR_VIEW_LOG="$FILTER_HOME/pr-views.log"
OUTCOME_MODEL_PROMPTS="$FILTER_HOME/model-prompts"
mkdir -p "$OUTCOME_COMMENT_DIR"
: > "$OUTCOME_MODEL_PROMPTS"
cat > "$RECIPIENTS_FILE" <<'JSON'
{"founder_login":"maintainer","recipients":{"maintainer":"maintainer@fixture.invalid","reporter":"reporter@fixture.invalid"}}
JSON
: > "$OUTCOME_SEND_LOG"
: > "$OUTCOME_PR_VIEW_LOG"
FAKE_CLOSED_ISSUES_JSON='[]'
queue_maintainer_outcome 9020 sha-9020
queue_maintainer_outcome 9021 sha-9021
queue_maintainer_outcome 9022 sha-9022
queue_maintainer_outcome 9023 sha-9023
queue_maintainer_outcome 9024 sha-9024
queue_maintainer_outcome 9025 sha-9025
queue_maintainer_outcome 9026 sha-9026
# 2026-09-25: developer-facing #1502 made the whole-body gate reject the
# digest; ops-facing #1814 was not recognized by the shared internal pattern.
queue_maintainer_outcome 9027 sha-9027
queue_maintainer_outcome 9028 sha-9028
for ops_outcome in \
  'Feature X 发布值班工程师可在页面查看批次。' \
  'SRE 查看 Feature X 批次状态。' \
  'Ops 查看 Feature X 批次状态。' \
  'Operations team 查看 Feature X 批次状态.'; do
  if maintainer_user_outcome_is_internal "$ops_outcome"; then
    echo "ok - ops-facing wording is classified internal: $ops_outcome"
  else
    echo "not ok - ops-facing wording was not classified internal: $ops_outcome"
    FAILED=1
  fi
done
flush_founder_outcome_digest 1000
FILTER_SEND="$(cat "$OUTCOME_SEND_LOG")"
assert_eq 'digest subject starts with first user-facing outcome' \
  'subject=客户可以在订单页面查询订单状态已上线' \
  "$(sed -n 's/^subject=/subject=/p' <<< "$FILTER_SEND")"
assert_eq 'digest contains only the user-facing outcome' \
  '- 客户可以在订单页面查询订单状态。' "$(grep '^- ' <<< "$FILTER_SEND")"
for internal_term in '项目维护者' '智能体' '工作树' 'CI 已通过' '流水线' '运维人员' '/issues/9025' '/issues/9028'; do
  assert_not_contains "digest excludes internal result: $internal_term" "$FILTER_SEND" "$internal_term"
done
assert_eq 'internal outcomes are removed and pipeline-system ticket stays deferred' '1' \
  "$(jq -r '.pending | length' "$OUTCOME_HOME/night/founder-outcomes.json")"
assert_eq 'only pipeline-system ticket remains queued' '9025' \
  "$(jq -r '.pending[].issue | tostring' "$OUTCOME_HOME/night/founder-outcomes.json")"
assert_contains 'ops-facing outcome is durably classified as internal' \
  "$(cat "$OUTCOME_HOME/night/founder-outcomes-internal" 2>/dev/null || true)" '9028 sha-9028'
assert_not_contains 'internal outcome is not marked as sent' \
  "$(cat "$OUTCOME_HOME/night/founder-outcomes-sent" 2>/dev/null || true)" '9028 sha-9028'
assert_contains 'mailed result stays in sent ledger' \
  "$(cat "$OUTCOME_HOME/night/founder-outcomes-sent")" '9026 sha-9026'
queue_maintainer_outcome 9028 sha-9028
queue_maintainer_outcome 9026 sha-9026
assert_eq 'internal and already-sent revisions do not re-enter queue' '1' \
  "$(jq -r '.pending | length' "$OUTCOME_HOME/night/founder-outcomes.json")"
mkdir -p "$OUTCOME_HOME/state"
printf '{"released":true,"deployed_sha":"sha-9028"}\n' > "$OUTCOME_HOME/state/9028.json"
FAKE_CLOSED_ISSUES_JSON='[{"number":9028,"closedAt":"1970-01-01T00:17:30Z","labels":[{"name":"priority:top"},{"name":"released"}]}]'
sweep_closed_maintainer_outcomes
assert_eq 'close sweep does not requeue an internally classified revision' '1' \
  "$(jq -r '.pending | length' "$OUTCOME_HOME/night/founder-outcomes.json")"
FAKE_CLOSED_ISSUES_JSON='[]'
assert_eq 'digest filtering never requests an outcome for an excluded item' '' \
  "$(cat "$OUTCOME_PR_VIEW_LOG")"

# A release-time fallback asks the work model once, then saves its answer on
# the issue as a reviewable comment. Matching stored outcomes stay authoritative.
RELEASE_ISSUE_JSON='{"title":"聊天成果文件权限查看","body":"聊天中可以查看有权限的成果文件。","comments":[],"labels":[]}'
RELEASE_MODEL_OUTCOME='员工在聊天里能看到自己有权限的成果文件。'
RELEASE_MODEL_CALLS_FILE="$OUTCOME_HOME/model-calls"
: > "$RELEASE_MODEL_CALLS_FILE"
RELEASE_ISSUE_COMMENT=''
gh() {
  if [ "${1:-} ${2:-}" = 'pr view' ]; then
    printf '{"title":"PR %s scoped title","body":"PR %s scoped body","url":"https://github.com/example-maintainer/example-repo/pull/%s"}\n' "$3" "$3" "$3"
    return 0
  fi
  if [ "${1:-} ${2:-}" = 'pr diff' ]; then
    printf 'PR-only diff for #%s\n' "$3"
    return 0
  fi
  [ "${1:-} ${2:-}" = 'issue view' ] || return 1
  printf '%s\n' "$RELEASE_ISSUE_JSON"
}
model_policy() {
  local action="${1:-}" role="${2:-}" identity="${3:-}"
  case "$action $role" in
    'resolve work')
      [ "$identity" = AGENT_MODEL ] || return 64
      if [ "${FAKE_OUTCOME_CODEX:-0}" = 1 ]; then
        printf 'codex:%s:%s\n' "$MODEL_POLICY_TEST_WORK_MODEL" "$MODEL_POLICY_TEST_WORK_EFFORT"
      else
        printf '%s\n' "$MODEL_POLICY_TEST_WORK_IDENTITY"
      fi
      ;;
    'dispatch-identity work')
      [[ "$identity" == codex:* ]] || return 64
      printf '%s\n' "$identity"
      ;;
    *) return 64 ;;
  esac
}
codex_budget_reserve() { [ "${FAKE_OUTCOME_BUDGET_REFUSE:-0}" != 1 ]; }
codex_budget_release() { :; }
RELEASE_MODEL_CALLS=0
RELEASE_MODEL_FIRST_OUTCOME=''
RELEASE_MODEL_SECOND_OUTCOME=''
run_model_json() {
  local call_number generated
  call_number="$(($(wc -l < "$RELEASE_MODEL_CALLS_FILE") + 1))"
  printf '%s\n' "$2" >> "$RELEASE_MODEL_CALLS_FILE"
  cat "$5" >> "$OUTCOME_MODEL_PROMPTS"
  generated="$RELEASE_MODEL_OUTCOME"
  [ "$call_number" -ne 1 ] || generated="${RELEASE_MODEL_FIRST_OUTCOME:-$generated}"
  [ "$call_number" -lt 2 ] || generated="${RELEASE_MODEL_SECOND_OUTCOME:-$generated}"
  jq -cn --arg outcome "$generated" \
    '{is_error:false,structured_output:{user_outcome:$outcome},tokens_used:"1"}'
}
record_premium_spend() { :; }
model_cost_usd() { echo 0; }
guarded_issue_comment() { RELEASE_ISSUE_COMMENT="$2"; }
if declare -F ensure_founder_user_outcome >/dev/null 2>&1; then
  ensure_founder_user_outcome 9008 HEAD
  assert_eq 'release fallback uses work model once' '1' "$(wc -l < "$RELEASE_MODEL_CALLS_FILE" | tr -d '[:space:]')"
  assert_eq 'release fallback resolves work role through model policy' \
    "$MODEL_POLICY_TEST_WORK_IDENTITY" "$(cat "$RELEASE_MODEL_CALLS_FILE")"
  assert_contains 'release fallback stores model outcome on ticket' \
    "$RELEASE_ISSUE_COMMENT" '**User outcome:** 员工在聊天里能看到自己有权限的成果文件'

  RELEASE_ISSUE_JSON='{"title":"聊天成果文件权限查看","body":"","comments":[{"body":"**User outcome:** 员工可以在聊天里查看有权限的成果文件。"}],"labels":[]}'
  RELEASE_ISSUE_COMMENT=''
  ensure_founder_user_outcome 9009 HEAD
  assert_eq 'release preserves existing brief outcome without another model call' '1' \
    "$(wc -l < "$RELEASE_MODEL_CALLS_FILE" | tr -d '[:space:]')"
  assert_eq 'release does not write a duplicate outcome comment' '' "$RELEASE_ISSUE_COMMENT"

  RELEASE_ISSUE_JSON='{"title":"工作台处理状态查看","body":"工作台现在显示处理状态。","comments":[],"labels":[]}'
  RELEASE_MODEL_OUTCOME='NONE'
  RELEASE_ISSUE_COMMENT=''
  ensure_founder_user_outcome 9010 HEAD
  assert_eq 'release asks model to classify an outcome-free ticket' '2' \
    "$(wc -l < "$RELEASE_MODEL_CALLS_FILE" | tr -d '[:space:]')"
  assert_eq 'release does not persist NONE as a user outcome' '' "$RELEASE_ISSUE_COMMENT"

  RELEASE_ISSUE_JSON='{"title":"工作台处理状态查看","body":"工作台现在显示处理状态。","comments":[{"body":"**User outcome:** None"}],"labels":[]}'
  RELEASE_ISSUE_COMMENT=''
  ensure_founder_user_outcome 9010 HEAD-retry
  assert_eq 'release retries an unreadable None outcome' '3' \
    "$(wc -l < "$RELEASE_MODEL_CALLS_FILE" | tr -d '[:space:]')"
  assert_eq 'retry still does not persist NONE' '' "$RELEASE_ISSUE_COMMENT"

  RELEASE_ISSUE_JSON='{"title":"Feature X original document evidence","body":"Feature X capture now retains original document evidence. Implementation PR: https://github.com/example-maintainer/example-repo/pull/19010","comments":[{"body":"**User outcome:** 项目维护者现在可以回收长期闲置的工作空间。"}],"labels":[]}'
  RELEASE_MODEL_FIRST_OUTCOME='项目维护者现在可以回收长期闲置的工作空间。'
  RELEASE_MODEL_SECOND_OUTCOME='Feature X 条目录入现在会保留原件，并让凭证关联到记录。'
  RELEASE_MODEL_CALLS=0
  : > "$RELEASE_MODEL_CALLS_FILE"
  RELEASE_ISSUE_COMMENT=''
  ensure_founder_user_outcome 9010 HEAD-mismatch
  assert_eq 'mismatched stored outcome is rejected and regenerated once' '2' \
    "$(wc -l < "$RELEASE_MODEL_CALLS_FILE" | tr -d '[:space:]')"
  assert_eq 'regenerated outcome shares Feature X issue subject' \
    '**User outcome:** Feature X 条目录入现在会保留原件，并让凭证关联到记录。' \
    "$(sed -n 's/^.*\(\*\*User outcome:\*\*.*\)$/\1/p' <<< "$RELEASE_ISSUE_COMMENT")"
  assert_contains 'generation prompt includes issue-owned body and linked PR details' \
    "$(cat "$OUTCOME_MODEL_PROMPTS")" 'PR 19010 scoped body'
  assert_contains 'generation prompt includes linked PR diff' \
    "$(cat "$OUTCOME_MODEL_PROMPTS")" 'PR-only diff for #19010'
  assert_not_contains 'generation prompt excludes broad release-range commit text' \
    "$(cat "$OUTCOME_MODEL_PROMPTS")" 'Merged change:'

  # 2026-10-07: issue 2313 has an English title and a Chinese body. The
  # readability gate demands plain Chinese, which shares no term with the
  # English title, so every digest tick paid for two fresh generations for 6
  # hours. The issue's own Chinese body now stands in for an English title,
  # an off-topic sentence still fails, and one issue/SHA gets one generation.
  ENGLISH_TITLE='All report confirmation cards readable on a phone: one shared layout for every report type'
  ENGLISH_BODY='所有的报表导出和用户确认的时候尽量是手机屏方便阅读，有排版有重点。'
  assert_eq 'Chinese outcome for an English title matches through the issue body' 0 \
    "$(maintainer_user_outcome_matches_title "$ENGLISH_TITLE" '员工导出报表后，手机上的确认卡有排版、有重点，一眼能看清。' "$ENGLISH_BODY" && echo 0 || echo 1)"
  assert_eq 'off-topic Chinese outcome for an English title is still rejected' 1 \
    "$(maintainer_user_outcome_matches_title "$ENGLISH_TITLE" '项目维护者现在可以回收长期闲置的工作空间。' "$ENGLISH_BODY" && echo 0 || echo 1)"
  assert_eq 'Chinese outcome without the body cannot match an English title' 1 \
    "$(maintainer_user_outcome_matches_title "$ENGLISH_TITLE" '员工导出报表后，手机上的确认卡有排版、有重点，一眼能看清。' && echo 0 || echo 1)"
  # 2026-10-09: issues 1598 and 2852 have English titles and English-only bodies,
  # so no Chinese wording exists to borrow; one title product name kept verbatim
  # is the only way a readable sentence can match.
  ENGLISH_ONLY_TITLE='nightly-sync plugin sends a malformed tools message; Assistant connect fails with CancelledError'
  ENGLISH_ONLY_OUTCOME='员工的 Assistant 现在能正常连上夜间同步工具，不再间歇报错。'
  assert_eq 'English-only issue matches an outcome that keeps one title product name' 0 \
    "$(maintainer_user_outcome_matches_title "$ENGLISH_ONLY_TITLE" "$ENGLISH_ONLY_OUTCOME" 'Every Assistant session logs an error.' && echo 0 || echo 1)"
  assert_eq 'that outcome passes the readability gate' 0 \
    "$(maintainer_user_outcome_is_readable "$ENGLISH_ONLY_OUTCOME" && echo 0 || echo 1)"
  assert_contains 'generation prompt tells the model to keep a title product name when the body has no Chinese' \
    "$(sed -n '/^Write exactly one Chinese sentence/,/^PROMPT$/p' "$SCRIPT_DIR/notify.sh")" 'keep one product or component name'
  RELEASE_ISSUE_JSON="$(jq -cn --arg title "$ENGLISH_TITLE" --arg body "$ENGLISH_BODY" '{title:$title,body:$body,comments:[],labels:[]}')"
  RELEASE_MODEL_FIRST_OUTCOME=''
  RELEASE_MODEL_SECOND_OUTCOME=''
  RELEASE_MODEL_OUTCOME='员工导出报表后，手机上的确认卡有排版、有重点，一眼能看清。'
  : > "$RELEASE_MODEL_CALLS_FILE"
  RELEASE_ISSUE_COMMENT=''
  ensure_founder_user_outcome 9029 sha-9029
  assert_eq 'English-title issue accepts the first Chinese generation' '1' \
    "$(wc -l < "$RELEASE_MODEL_CALLS_FILE" | tr -d '[:space:]')"
  assert_contains 'English-title issue stores the Chinese outcome' \
    "$RELEASE_ISSUE_COMMENT" '**User outcome:** 员工导出报表'
  RELEASE_MODEL_OUTCOME='项目维护者现在可以回收长期闲置的工作空间。'
  : > "$RELEASE_MODEL_CALLS_FILE"
  RELEASE_ISSUE_COMMENT=''
  for tick in 1 2 3 4 5; do
    ensure_founder_user_outcome 9030 sha-9030
  done
  assert_eq 'a rejected outcome costs at most two model calls per issue/SHA across five ticks' '2' \
    "$(wc -l < "$RELEASE_MODEL_CALLS_FILE" | tr -d '[:space:]')"
  assert_eq 'a rejected off-topic outcome is never stored' '' "$RELEASE_ISSUE_COMMENT"
  ensure_founder_user_outcome 9030 sha-9030-next
  assert_eq 'a new deployed SHA gets its own generation' '4' \
    "$(wc -l < "$RELEASE_MODEL_CALLS_FILE" | tr -d '[:space:]')"

  # A budget refusal must leave the one-generation ledger clear so later
  # release ticks can generate the user outcome after quota resets.
  FAKE_OUTCOME_CODEX=1 FAKE_OUTCOME_BUDGET_REFUSE=1
  RELEASE_ISSUE_JSON='{"title":"聊天成果文件权限查看","body":"聊天中可以查看有权限的成果文件。","comments":[],"labels":[]}'
  : > "$RELEASE_MODEL_CALLS_FILE"
  set +e
  OUTCOME_BUDGET_OUTPUT="$(ensure_founder_user_outcome 9031 sha-budget 2>&1)"
  OUTCOME_BUDGET_STATUS=$?
  set -e
  assert_eq 'budget-refused release outcome exits cleanly' 0 "$OUTCOME_BUDGET_STATUS"
  assert_contains 'budget-refused release outcome is deferred' "$OUTCOME_BUDGET_OUTPUT" 'Codex budget/provider hold'
  assert_eq 'budget-refused release outcome never calls Codex' 0 \
    "$(wc -l < "$RELEASE_MODEL_CALLS_FILE" | tr -d '[:space:]')"
  assert_eq 'budget-refused release outcome keeps generation ledger clear' '' \
    "$(grep -F '9031 sha-budget' "$AGENT_HOME/night/founder-outcome-generated" 2>/dev/null || true)"
  unset FAKE_OUTCOME_CODEX FAKE_OUTCOME_BUDGET_REFUSE
else
  assert_eq 'release fallback helper exists' 'function' "$(type -t ensure_founder_user_outcome || true)"
fi

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
