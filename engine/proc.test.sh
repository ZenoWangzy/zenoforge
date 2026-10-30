#!/usr/bin/env bash
# proc.sh: pid_live, pid_start_id, host_boot_id, pids_with_cwd_under.
# Part 1 runs the native branch against real processes (Linux and macOS). On Linux it also checks the helpers against the
# inline /proc parsing they replace. Part 2 forces the macOS branch with fake ps, sysctl and lsof on PATH, so Linux CI covers it too.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
engine="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fail() { echo "proc.test.sh: $*" >&2; exit 1; }
t="$test_env_root/proc"
mkdir -p "$t/fakebin" "$t/ps"
source "$engine/platform-env.sh" # macOS: GNU date for pid_start_id; a no-op on Linux
source "$engine/proc.sh"
pids=()
trap 'kill "${pids[@]}" 2>/dev/null || true' EXIT
spawn() { "$@" & pids+=("$!"); }

# What the engine did inline before proc.sh (scheduler pid_start, unit loop pid_running); Linux only.
old_start() { sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $20}'; }
old_running() { local stat; read -r stat 2>/dev/null < "/proc/$1/stat" || return 1; stat="${stat##*) }"; [[ "${stat%% *}" != Z ]]; }

# ---- Part 1: native branch, real processes ----
spawn sleep 60; child=$!
pid_live $$ || fail 'own pid not live'
pid_live "$child" || fail 'sleeping child not live'
for bad in "" 0 abc -1 99999999; do ! pid_live "$bad" || fail "pid_live accepted '$bad'"; done
dead="$(sleep 0.1 & echo $!)"; sleep 0.3; ! pid_live "$dead" || fail 'dead pid is live'

# A zombie: the parent execs into sleep and never waits for its short-lived child.
spawn "$BASH" -c 'sleep 0.5 & echo $! > "$1"; exec sleep 60' _ "$t/zpid"; z=0
for _ in $(seq 50); do sleep 0.1; [[ -s $t/zpid ]] && z="$(cat "$t/zpid")" && [[ "$(ps -o stat= -p "$z" 2>/dev/null)" == Z* ]] && break; done
[[ "$(ps -o stat= -p "$z" 2>/dev/null)" == Z* ]] || fail 'could not make a zombie'
! pid_live "$z" || fail 'zombie reported live'

a="$(pid_start_id $$)"; b="$(pid_start_id "$child")"
[[ $a =~ ^[0-9]+$ && $b =~ ^[0-9]+$ ]] || fail "start ids not numeric: '$a' '$b'"
[[ "$(pid_start_id $$)" == "$a" ]] || fail 'start id of one pid changed between calls'
! pid_start_id "$dead" >/dev/null 2>&1 || fail 'start id of a dead pid succeeded'
[[ -z "$(pid_start_id "$dead" 2>&1 || true)" ]] || fail 'start id of a dead pid printed something'
sleep 1.1; spawn sleep 60
[[ "$(pid_start_id $!)" != "$b" ]] || fail 'two processes started 1s apart share a start id'

id="$(host_boot_id)"
[[ -n $id && "$(host_boot_id)" == "$id" ]] || fail 'boot id empty or unstable'

mkdir -p "$t/wt/a/b" "$t/wt/ab"; wt="$(cd "$t/wt" && pwd -P)"
spawn "$BASH" -c 'cd "$1" && exec sleep 60' _ "$wt/a/b"; inner=$!
spawn "$BASH" -c 'cd "$1" && exec sleep 60' _ "$wt/ab"; sibling=$!
has() { [[ " $(pids_with_cwd_under "$1" | tr '\n' ' ') " == *" $2 "* ]]; }
for _ in $(seq 50); do has "$wt" "$inner" && has "$wt" "$sibling" && break; sleep 0.1; done
has "$wt/a" "$inner" || fail 'process below DIR not found'
has "$wt/a/" "$inner" || fail 'trailing slash on DIR not accepted'
! has "$wt/a" "$sibling" || fail 'sibling dir with the same prefix matched'
[[ -z "$(pids_with_cwd_under "$wt/a/b/c")" ]] || fail 'a directory nobody sits in matched'
pids_with_cwd_under "$wt/nothing" || fail 'no match must still return 0'

if [[ -d /proc/$$ ]]; then
  [[ "$(host_boot_id)" == "$(cat /proc/sys/kernel/random/boot_id)" ]] || fail 'boot id differs from the file the engine read'
  # A comm holding ") " and spaces: the helpers must split after the LAST ") ".
  odd=; cp "$(type -P sleep)" "$t/a) 1 (b" && "$t/a) 1 (b" 0 2>/dev/null && { spawn "$t/a) 1 (b" 60; odd=$!; } # not for a multi-call sleep
  for p in $$ "$child" ${odd:+"$odd"} "$z"; do
    [[ "$(pid_start_id "$p")" == "$(old_start "$p")" ]] || fail "start id of $p differs from the old inline parse"
    if pid_live "$p"; then old_running "$p" || fail "pid_live and the old check disagree on $p"; else ! old_running "$p" || fail "pid_live and the old check disagree on $p"; fi
  done
  [[ -z $odd || "$(pid_start_id "$odd")" =~ ^[0-9]+$ ]] || fail 'odd comm broke the start id'
fi

# ---- Part 2: macOS branch forced on any OS, with fake ps, sysctl and lsof ----
cat > "$t/fakebin/ps" <<'EOF'
#!/usr/bin/env bash
# fake ps: ps -o FIELD= -p PID prints the contents of $FAKE_PS_DIR/PID.FIELD; unknown pid: no output, rc 1
[[ "$1" == -o && "$2" == *= && "$3" == -p ]] || { echo "fake ps: unexpected args: $*" >&2; exit 2; }
f="$FAKE_PS_DIR/$4.${2%=}"; [[ -f $f ]] || exit 1; cat "$f"
EOF
printf '#!/usr/bin/env bash\n[[ "$*" == "-n kern.bootsessionuuid" ]] || exit 2\necho 7B0C1D2E-0000-4000-8000-ABCDEF012345\n' > "$t/fakebin/sysctl"
printf '#!/usr/bin/env bash\n[[ "$*" == "-a -d cwd -Fpn" ]] || exit 2\ncat "$FAKE_LSOF_OUT"\n' > "$t/fakebin/lsof"
chmod +x "$t/fakebin/"*
cat > "$t/lsof.out" <<'EOF'
p101
n/work/a
p102
n/work/a/sub
p103
n/work/ab
p104
n/other
EOF
darwin() { # run a snippet with proc.sh sourced as on macOS and the fakes first on PATH
  env "PATH=$t/fakebin:$PATH" "FAKE_PS_DIR=$t/ps" "FAKE_LSOF_OUT=$t/lsof.out" TZ=UTC \
    "$BASH" -u -c 'OSTYPE=darwin24.0; source "$1/proc.sh"; eval "$2"' _ "$engine" "$1"
}
live=$$
printf 'S+\n' > "$t/ps/$live.stat"
darwin "pid_live $live" || fail 'macOS: S+ not live'
printf ' Ss  \n' > "$t/ps/$live.stat"
darwin "pid_live $live" || fail 'macOS: padded Ss not live'
for st in Z Z+; do printf '%s\n' "$st" > "$t/ps/$live.stat"; ! darwin "pid_live $live" || fail "macOS: $st reported live"; done
rm "$t/ps/$live.stat"
! darwin "pid_live $live" || fail 'macOS: pid ps does not know reported live'
printf 'S\n' > "$t/ps/$dead.stat"
! darwin "pid_live $dead" || fail 'macOS: dead pid reported live'
! darwin "pid_live abc" || fail 'macOS: non-numeric pid reported live'

printf 'Thu Oct 29 12:00:00 2026\n' > "$t/ps/$live.lstart"
[[ "$(darwin "pid_start_id $live")" == 1793275200 ]] || fail "macOS: start id of 12:00:00 UTC is '$(darwin "pid_start_id $live")', wanted 1793275200"
printf 'Sun Nov  1 08:05:09 2026\n' > "$t/ps/$live.lstart"
[[ "$(darwin "pid_start_id $live")" == 1793520309 ]] || fail 'macOS: single-digit day with two spaces not parsed'
rm "$t/ps/$live.lstart"
out="$(darwin "pid_start_id $live" || true)"; [[ -z $out ]] || fail 'macOS: unknown pid printed a start id'
! darwin "pid_start_id $live" || fail 'macOS: unknown pid start id succeeded'

[[ "$(darwin host_boot_id)" == 7B0C1D2E-0000-4000-8000-ABCDEF012345 ]] || fail 'macOS: boot id not from sysctl'

got() { darwin "pids_with_cwd_under $1" | tr '\n' ' '; }
[[ "$(got /work/a)" == '101 102 ' ]] || fail "macOS: /work/a -> '$(got /work/a)'"
[[ "$(got /work/a/)" == '101 102 ' ]] || fail 'macOS: trailing slash'
[[ "$(got /work)" == '101 102 103 ' ]] || fail 'macOS: /work'
[[ "$(got /)" == '101 102 103 104 ' ]] || fail 'macOS: /'
[[ -z "$(got /nope)" ]] || fail 'macOS: /nope matched'
darwin 'pids_with_cwd_under /nope' || fail 'macOS: no match must still return 0'

echo 'proc.test.sh: PASS'
