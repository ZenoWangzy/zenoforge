#!/usr/bin/env bash
# Selection and apply logic of memory-check.py, on a temp dir with a stub worker. Never touches real memory.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)/test-env.sh"
mc="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/memory-check.py"
fx="$test_env_root/mc"; mem="$fx/projects/p1/memory"; state="$fx/state"
mkdir -p "$mem" "$state"
fail() { printf 'memory-check.test.sh: %s\n' "$*" >&2; exit 1; }
note() { printf -- '---\nname: %s\ndescription: d %s\n---\n\nbody %s\n\n**Why:** because %s 「quote」\n' "$1" "$1" "$2" "$1" > "$mem/$1.md"; }

# --- selection: oldest-checked pool of 2n, citing notes first inside it
sel=$(MC_MEMORY_GLOB="$fx/none" python3 - "$mc" "$mem" <<'PY'
import importlib.util, sys, os
spec = importlib.util.spec_from_file_location('mc', sys.argv[1]); mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
d = sys.argv[2]
for n, body in dict(a='plain words', b='see ~/x/y.sh', c='flag --force', d='calls foo()', e='plain').items():
    open(f'{d}/{n}.md', 'w').write(body)
p = lambda n: f'{d}/{n}.md'
ck = {p('a'): 0, p('d'): 1, p('b'): 5, p('c'): 9, p('e'): 100}
print(' '.join(os.path.basename(x) for x in mc.select([p(n) for n in 'abcde'], ck, 2)))
print(' '.join(os.path.basename(x) for x in mc.select([p(n) for n in 'abcde'], ck, 1)))
PY
)
[[ "$(sed -n 1p <<<"$sel")" == "d.md b.md" ]] || fail "selection n=2: $sel"
[[ "$(sed -n 2p <<<"$sel")" == "d.md" ]] || fail "selection n=1: $sel"
rm -f "$mem"/*.md

# --- apply: stub worker edits, deletes, collides with a peer write, breaks rules
for n in a b c d e f; do note "$n" 1; done
printf -- '- [a](a.md) — d a\n- [b](b.md) — d b\n- [c](c.md) — d c\n- [bb](bb.md) — keep, only exact filename b.md goes\n' > "$mem/MEMORY.md"
stub="$fx/worker"
cat > "$stub" <<'S'
#!/usr/bin/env bash
# worker <key> <cwd> <prompt-file>
key=$1; cwd=$2; n="$cwd/notes/p1"
[[ -f $3 ]] || exit 2
[[ ${STUB_RC:-0} == 0 ]] || { rm -f "$n/a.md"; exit "$STUB_RC"; }
echo "corrected" >> "$n/a.md"
rm -f "$n/b.md"
echo "worker rewrite" >> "$n/c.md"; sleep 0.05; echo peer >> "$MC_REAL_C"   # peer session writes the real c.md meanwhile
sed -i 's/^\*\*Why:\*\*.*/**Why:** rewritten/' "$n/d.md"
sed -i 's/^name: e/name: e2/' "$n/e.md"
printf -- '---\nname: good-way\ndescription: a thing that worked\n---\n\nrule\n' > "$cwd/new/good-way.md"
printf -- 'no frontmatter\n' > "$cwd/new/bad.md"
printf -- 'x\n' > "$cwd/new/third.md"
printf '{"note":"p1/a.md","action":"changed","evidence":"grep foo showed bar"}\n' > "$cwd/report.jsonl"
S
chmod +x "$stub"
export MC_MEMORY_GLOB="$fx/projects/*/memory" MC_STATE="$state" MC_WORKER="$stub" MC_NEW_DIR="$mem" MC_BATCH=10 MC_KEEP=2 MC_REAL_C="$mem/c.md"
export WORKER_SCRATCH_ROOT="$fx/ws"
mkdir -p "$state/backups"; touch "$state/backups/memory-20200101T000000Z.tar.gz" "$state/backups/memory-20200102T000000Z.tar.gz"
cp "$mem/f.md" "$fx/f.before"

# worker failure: nothing applied, nonzero rc
STUB_RC=1 python3 "$mc" && fail "failed worker must give nonzero rc"
grep -q corrected "$mem/a.md" && fail "failed worker changed a note"
[[ ! -e "$state/checked.json" ]] || fail "failed worker marked notes checked"

python3 "$mc" > "$fx/out" 2>&1 || { cat "$fx/out" >&2; fail "run failed"; }
log=$(cat "$state"/????-??-??.md)
grep -q corrected "$mem/a.md" || fail "a.md not changed"
[[ ! -e "$mem/b.md" ]] || fail "b.md not deleted"
grep -q '](b.md)' "$mem/MEMORY.md" && fail "b.md line left in MEMORY.md"
grep -q '](bb.md)' "$mem/MEMORY.md" || fail "bb.md line removed by non-exact match"
grep -q '](a.md)' "$mem/MEMORY.md" || fail "a.md line lost"
[[ "$(tail -n1 "$mem/c.md")" == peer ]] && ! grep -q 'worker rewrite' "$mem/c.md" || fail "peer write on c.md was overwritten"
grep -q 'because d 「quote」' "$mem/d.md" || fail "Why rewrite applied to d.md"
grep -q '^name: e$' "$mem/e.md" || fail "name change applied to e.md"
cmp -s "$mem/f.md" "$fx/f.before" || fail "untouched f.md differs"
[[ -f "$mem/good-way.md" ]] && grep -q '](good-way.md) — a thing that worked' "$mem/MEMORY.md" || fail "new note or its index line missing"
[[ ! -e "$mem/bad.md" && ! -e "$mem/third.md" ]] || fail "bad or third new note installed"
ls -A "$mem" | grep -q '^\.' && fail "temp file left in memory dir"
for want in 'changed: `p1/a.md` — grep foo showed bar' 'deleted: `p1/b.md`' 'skipped: `p1/c.md` — mtime changed' 'skipped: `p1/d.md` — rewrite rejected: Why line' 'skipped: `p1/e.md` — rewrite rejected: frontmatter name' 'checked: `p1/f.md`' 'skipped: `new/bad.md`' 'skipped: `new/third.md` — more than 2'; do
  grep -qF -- "$want" <<<"$log" || fail "log missing: $want"
done
python3 -c "import json,sys; c=json.load(open(sys.argv[1])); assert sys.argv[2] in c and sys.argv[3] not in c" "$state/checked.json" "$mem/a.md" "$mem/c.md" || fail "checked.json should hold a.md and not skipped c.md"
[[ $(ls "$state/backups" | wc -l) == 2 ]] || fail "backups not pruned to MC_KEEP=2: $(ls "$state/backups")"
tar -tzf "$(ls "$state"/backups/* | tail -1)" | grep -q 'p1/memory/a.md' || fail "backup lacks notes"
[[ -z $(ls -A "$state/scratch") ]] || fail "scratch dir not cleaned"

# --- second run must not start while the lock is held
exec 9>"$state/lock"; flock -n 9
python3 "$mc" | grep -q 'holds the lock' || fail "locked run did not exit early"
echo "PASS memory-check"
