#!/usr/bin/env bash
set -euo pipefail
# tools/main-red-revert.sh against a local bare origin and a fake gh that prints a fixture run list; no network.
# shellcheck disable=SC1091 # test-env.sh is repo-relative
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/engine/test-env.sh"
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
script=$here/main-red-revert.sh
tmp=$(mktemp -d "${TMPDIR:-/tmp}/main-red-revert-test.XXXXXX") # test-env removes its TMPDIR on exit
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
if [[ "$1 $2" == "pr list" ]]; then # the fixture holds the answer after --jq: a PR number, or nothing
  if [[ -f $PR_FIXTURE ]]; then cat "$PR_FIXTURE"; fi
  exit 0
fi
[[ "$1 $2" == "run list" ]] || { echo "fake gh: unexpected $*" >&2; exit 1; }
cat "$RUNS_JSON"
GH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"
failures=0

case_dir() { # <name>: fresh bare origin and a clone to run the script in
  local d=$tmp/$1
  mkdir -p "$d"
  git init -q --bare "$d/origin.git"
  git clone -q "$d/origin.git" "$d/work" 2>/dev/null
  git -C "$d/work" checkout -q -B main
  bare=$d/origin.git work=$d/work
  export RUNS_JSON=$d/runs.json PR_FIXTURE=$d/pr.txt ZF_MAIN_RED_REVERT_HOME=$d/home ZF_ALERTS_FILE=$d/alerts.log
}
put() { # <file> <content> <subject> -> pushes one commit to origin main, prints its sha
  printf '%s\n' "$2" >"$work/$1"
  git -C "$work" add -A
  git -C "$work" commit -q -m "$3"
  git -C "$work" push -q origin HEAD:main
  git -C "$work" rev-parse HEAD
}
runs() { # <sha:status:conclusion:id>..., oldest first; written newest first, as gh prints them
  local items=() a sha st cc id i=0
  for a in "$@"; do
    IFS=: read -r sha st cc id <<<"$a"
    i=$((i + 1))
    items=("{\"headSha\":\"$sha\",\"status\":\"$st\",\"conclusion\":\"$cc\",\"databaseId\":$id,\"createdAt\":\"2026-11-19T00:00:$(printf %02d "$i")Z\"}" "${items[@]}")
  done
  (IFS=,; printf '[%s]\n' "${items[*]}") >"$RUNS_JSON"
}
run() { # [script args] -> out, rc
  rc=0; out=$(cd "$work" && bash "$script" --repo test/zenoforge "$@" 2>&1) || rc=$?
}
origin_file_is() { [[ $(git -C "$bare" show "main:$1") == "$2" ]]; }
head_is() { [[ $(git -C "$bare" rev-parse main) == "$1" ]]; }
alert_has() { [[ -f $ZF_ALERTS_FILE ]] && grep -q " $1 " "$ZF_ALERTS_FILE"; }
no_alerts() { [[ ! -f $ZF_ALERTS_FILE ]]; }
subject_is() { [[ $(git -C "$bare" log -1 --format=%s main) == "$1" ]]; }
alert_count_is() { [[ $(wc -l <"$ZF_ALERTS_FILE") -eq $1 ]]; }
dry_left_nothing() { [[ ! -e $ZF_MAIN_RED_REVERT_HOME/main-red-revert.last ]] && no_alerts; }
exit_is() { [[ $rc -eq $1 ]]; }
check() { # <name> <command...>
  local name=$1; shift
  if "$@"; then echo "ok - $name"; else echo "not ok - $name"; while IFS= read -r l; do echo "    $l"; done <<<"$out"; failures=$((failures + 1)); fi
}

# (a) one red commit right after green: reverted, pushed, alert written
case_dir a
g=$(put a.txt good green); b=$(put a.txt bad "break the build")
runs "$g:completed:success:1" "$b:completed:failure:2"
run
check "(a) exit 0" exit_is 0
check "(a) origin main has the green content again" origin_file_is a.txt good
check "(a) revert commit has the Revert subject" subject_is 'Revert "break the build"'
check "(a) alert MAIN-CI-AUTO-REVERT written" alert_has MAIN-CI-AUTO-REVERT

# (b) two red commits: the older failed run is the culprit, the newer commit stays
case_dir b
g=$(put a.txt good green); b1=$(put a.txt bad "break a"); b2=$(put b.txt bad "break b")
runs "$g:completed:success:1" "$b1:completed:failure:2" "$b2:completed:failure:3"
run
check "(b) exit 0" exit_is 0
check "(b) older red commit reverted" origin_file_is a.txt good
check "(b) newer red commit kept" origin_file_is b.txt bad

# (c) a cancelled run between green and the failure: nothing pushed, no culprit
case_dir c
g=$(put a.txt good green); n=$(put notes.txt docs "docs only"); b=$(put a.txt bad "break")
runs "$g:completed:success:1" "$n:completed:cancelled:9" "$b:completed:failure:2"
run
check "(c) exit 0" exit_is 0
check "(c) nothing pushed" head_is "$b"
check "(c) alert MAIN-RED-NO-CULPRIT written" alert_has MAIN-RED-NO-CULPRIT

# (j) a candidate run still in progress: nothing decided; once it completes, the next run reverts the culprit
case_dir j
g=$(put a.txt good green); n=$(put notes.txt docs "docs only"); b=$(put a.txt bad "break")
runs "$g:completed:success:1" "$n:in_progress::2" "$b:completed:failure:3"
run
check "(j) first run exit 0" exit_is 0
check "(j) nothing pushed while waiting" head_is "$b"
check "(j) no alert and no state while waiting" dry_left_nothing
runs "$g:completed:success:1" "$n:completed:success:2" "$b:completed:failure:3"
run
check "(j) second run exit 0" exit_is 0
check "(j) culprit reverted after the run completed" origin_file_is a.txt good
check "(j) alert MAIN-CI-AUTO-REVERT written" alert_has MAIN-CI-AUTO-REVERT

# (d) HEAD run still in progress: nothing happens
case_dir d
g=$(put a.txt good green); b=$(put a.txt bad "break")
runs "$g:completed:success:1" "$b:in_progress::2"
run
check "(d) exit 0" exit_is 0
check "(d) nothing pushed" head_is "$b"
check "(d) no alert" no_alerts

# (e) the culprit is itself a revert: nothing pushed
case_dir e
g=$(put a.txt good green); r=$(put a.txt bad 'Revert "earlier change"')
runs "$g:completed:success:1" "$r:completed:failure:2"
run
check "(e) nothing pushed" head_is "$r"
check "(e) alert MAIN-RED-NO-CULPRIT written" alert_has MAIN-RED-NO-CULPRIT

# (f) the revert conflicts with a later failed commit: nothing pushed, conflict alert
case_dir f
g=$(put a.txt good green); b=$(put a.txt bad "break"); c=$(put a.txt later "touch again")
runs "$g:completed:success:1" "$b:completed:failure:2" "$c:completed:failure:3"
run
check "(f) nothing pushed" head_is "$c"
check "(f) alert MAIN-RED-REVERT-CONFLICT written" alert_has MAIN-RED-REVERT-CONFLICT

# (g) a second run on the same red HEAD does nothing
case_dir g
g=$(put a.txt good green); put notes.txt docs "docs only" >/dev/null; b=$(put a.txt bad "break")
runs "$g:completed:success:1" "$b:completed:failure:2"
run; run
check "(g) second run says already decided" grep -q 'already decided' <<<"$out"
check "(g) only one alert written for the two runs" alert_count_is 1

# (h) dry run prints the decision and changes nothing
case_dir h
g=$(put a.txt good green); b=$(put a.txt bad "break")
runs "$g:completed:success:1" "$b:completed:failure:2"
run --dry-run
check "(h) prints WOULD-REVERT with the culprit" grep -q "^WOULD-REVERT $b break\$" <<<"$out"
check "(h) nothing pushed" head_is "$b"
check "(h) no state file, no alert" dry_left_nothing

# (i) stop file present: exit 0, nothing happens
case_dir i
g=$(put a.txt good green); b=$(put a.txt bad "break")
runs "$g:completed:success:1" "$b:completed:failure:2"
mkdir -p "$ZF_MAIN_RED_REVERT_HOME"; touch "$ZF_MAIN_RED_REVERT_HOME/main-red-revert.stop"
run
check "(i) exit 0" exit_is 0
check "(i) nothing pushed" head_is "$b"
check "(i) no alert" no_alerts

# (k) a fresh claim on the culprit: alert names the claimer, nothing pushed, state written
case_dir k
g=$(put a.txt good green); b=$(put a.txt bad "break")
runs "$g:completed:success:1" "$b:completed:failure:2"
mkdir -p "$ZF_MAIN_RED_REVERT_HOME"; echo "${b:0:7} alice $(date +%s)" >"$ZF_MAIN_RED_REVERT_HOME/main-red-revert.hold"
run
check "(k) exit 0" exit_is 0
check "(k) nothing pushed" head_is "$b"
check "(k) alert MAIN-RED-FIX-IN-PROGRESS names the claimer" grep -q 'MAIN-RED-FIX-IN-PROGRESS .*being fixed by alice' "$ZF_ALERTS_FILE"
check "(k) state file written" test -f "$ZF_MAIN_RED_REVERT_HOME/main-red-revert.last"

# (l) an expired claim (3 h old): reverted as before
case_dir l
g=$(put a.txt good green); b=$(put a.txt bad "break")
runs "$g:completed:success:1" "$b:completed:failure:2"
mkdir -p "$ZF_MAIN_RED_REVERT_HOME"; echo "${b:0:7} alice $(($(date +%s) - 10800))" >"$ZF_MAIN_RED_REVERT_HOME/main-red-revert.hold"
run
check "(l) exit 0" exit_is 0
check "(l) expired claim: culprit reverted" origin_file_is a.txt good
check "(l) alert MAIN-CI-AUTO-REVERT written" alert_has MAIN-CI-AUTO-REVERT

# (m) a fresh claim for another sha: culprit reverted
case_dir m
g=$(put a.txt good green); b=$(put a.txt bad "break")
runs "$g:completed:success:1" "$b:completed:failure:2"
mkdir -p "$ZF_MAIN_RED_REVERT_HOME"; echo "${g:0:7} dave $(date +%s)" >"$ZF_MAIN_RED_REVERT_HOME/main-red-revert.hold"
run
check "(m) exit 0" exit_is 0
check "(m) claim for another sha: culprit reverted" origin_file_is a.txt good

# (n) an open PR found by the search holds the culprit
case_dir n
g=$(put a.txt good green); b=$(put a.txt bad "break")
runs "$g:completed:success:1" "$b:completed:failure:2"
echo 42 >"$PR_FIXTURE"
run
check "(n) exit 0" exit_is 0
check "(n) nothing pushed" head_is "$b"
check "(n) alert names PR #42" grep -q 'being fixed by PR #42' "$ZF_ALERTS_FILE"

# (o) dry run with a fresh claim prints WOULD-HOLD and changes nothing
case_dir o
g=$(put a.txt good green); b=$(put a.txt bad "break")
runs "$g:completed:success:1" "$b:completed:failure:2"
mkdir -p "$ZF_MAIN_RED_REVERT_HOME"; echo "${b:0:7} alice $(date +%s)" >"$ZF_MAIN_RED_REVERT_HOME/main-red-revert.hold"
run --dry-run
check "(o) prints WOULD-HOLD with the culprit and claimer" grep -q "^WOULD-HOLD $b alice\$" <<<"$out"
check "(o) nothing pushed" head_is "$b"
check "(o) no state file, no alert" dry_left_nothing

# (p) malformed claim lines (two fields, non-numeric epoch) are ignored, no crash
case_dir p
g=$(put a.txt good green); b=$(put a.txt bad "break")
runs "$g:completed:success:1" "$b:completed:failure:2"
mkdir -p "$ZF_MAIN_RED_REVERT_HOME"; printf '%s\n' "${b:0:7} erin" "${b:0:7} erin soon" >"$ZF_MAIN_RED_REVERT_HOME/main-red-revert.hold"
run
check "(p) exit 0" exit_is 0
check "(p) malformed claims ignored: culprit reverted" origin_file_is a.txt good

# (q) a fresh claim as the last line without a trailing newline still holds the culprit
case_dir q
g=$(put a.txt good green); b=$(put a.txt bad "break")
runs "$g:completed:success:1" "$b:completed:failure:2"
mkdir -p "$ZF_MAIN_RED_REVERT_HOME"; printf '%s %s %s' "${b:0:7}" alice "$(date +%s)" >"$ZF_MAIN_RED_REVERT_HOME/main-red-revert.hold"
run
check "(q) exit 0" exit_is 0
check "(q) nothing pushed" head_is "$b"
check "(q) alert MAIN-RED-FIX-IN-PROGRESS written" alert_has MAIN-RED-FIX-IN-PROGRESS

if ((failures)); then echo "main-red-revert.test.sh: $failures failed"; exit 1; fi
echo "main-red-revert.test.sh: all passed"
