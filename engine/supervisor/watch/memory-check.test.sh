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

# --- apply: stub worker proposes edits in the shapes the first real run produced
w() { cat > "$mem/$1.md"; }   # note body from stdin
w tok <<'N'
---
name: tok
description: Run the old tool before saying live
---

Run `~/.old/bin/tool <sha>` before saying a merge is live.
Second line stays.

**Why:** a merge was named live too early 「先查再说」
**How to apply:** run the tool first.
N
w a2a-product <<'N'
---
name: a2a-product
description: pre-release A2A diff is release-blocking
---

Diff the A2A surface before each release.

**Why:** a release shipped without the A2A diff.
**How to apply:** run the pre-release A2A diff; a hit blocks the release.
N
w quoteonly <<'N'
---
name: quoteonly
description: founder said so
---

Founder: 「不要再删」 keep it.
N
w gone <<'N'
---
name: gone
description: plain stale fact
---

The helper lives at ~/nowhere/helper.sh.
N
w a2a-design <<'N'
---
name: a2a-design
description: never delete the A2A core; Hermes parity is a release blocker
---

Never delete the A2A core.
Hermes parity blocks the release.
N
w demo <<'N'
---
name: demo
description: demo script rules
---

Eight scripted scenes.
Gate rule: follow the live policy file.

**Why:** founder demo.
N
w chrome <<'N'
---
name: chrome
description: founder chrome bridge
---

The bridge uses port 9224.

**Why:** the bridge broke once.
**How to apply:** restart vecta-founder-chrome.service when the bridge hangs.
N
w auth <<'N'
---
name: auth
description: release is authorized
---

Line one has /path/one/alpha here.
Line two has /path/two/beta here.
Line three has /path/three/gamma here.
Line four has /path/four/delta here.

**Why:** founder authorized.
N
w ratio <<'N'
---
name: ratio
description: ratio shape
---

Gate rule: demo_loop decides.
N
w added <<'N'
---
name: added
description: added shape
---

One line.
N
w peer <<'N'
---
name: peer
description: peer writes this
---

Peer path /old/peer/file.sh here.
N
printf -- '- [tok](tok.md) — d\n- [gone](gone.md) — d gone\n- [a2a-product](a2a-product.md) — d\n- [gonee](gonee.md) — keep, only the exact filename gone.md goes\n' > "$mem/MEMORY.md"
stub="$fx/worker"
cat > "$stub" <<'S'
#!/usr/bin/env bash
# worker <key> <cwd> <prompt-file>
key=$1; cwd=$2; n="$cwd/notes/p1"
[[ -f $3 ]] || exit 2
[[ ${STUB_RC:-0} == 0 ]] || { rm -f "$n/tok.md"; exit "$STUB_RC"; }
sed -i 's#~/.old/bin/tool#~/.new/bin/tool#' "$n/tok.md"                      # small token fix: applied
rm -f "$n/a2a-product.md" "$n/quoteonly.md" "$n/gone.md"                    # first two refused, last deleted
sed -i 's/^description: .*/description: A2A core stays/; s/^Never delete the A2A core\./Prefer keeping the A2A core./' "$n/a2a-design.md"
sed -i 's/^Gate rule: follow the live policy file\./Gate rule: .zenoforge\/supervisor\/founder-policy.json says confirm each scene first, then record a receipt./' "$n/demo.md"
echo 'See .zenoforge/supervisor/founder-policy.json in the repo.' >> "$n/demo.md"
sed -i 's/^\*\*How to apply:\*\* restart vecta-founder-chrome.service/**How to apply:** run founder-chrome.sh/' "$n/chrome.md"
sed -i 's#/path/\([a-z]*\)/\([a-z]*\)#/path/\1/\2x#' "$n/auth.md"             # 4 lines, each close: over the 3-line cap
sed -i 's/^Gate rule: demo_loop decides\./Hold every scene until the founder types yes./' "$n/ratio.md"
echo 'A pointer line.' >> "$n/added.md"
sed -i 's#/old/peer/file.sh#/new/peer/file.sh#' "$n/peer.md"; sleep 0.05; echo peer >> "$MC_REAL_PEER"   # a peer session writes the real note meanwhile
printf -- '---\nname: good-way\ndescription: a thing that worked\n---\n\nrule\n' > "$cwd/new/good-way.md"
printf -- 'no frontmatter\n' > "$cwd/new/bad.md"
printf -- 'x\n' > "$cwd/new/third.md"
printf '{"note":"p1/tok.md","action":"changed","evidence":"grep tool showed new path"}\n' > "$cwd/report.jsonl"
S
chmod +x "$stub"
export MC_MEMORY_GLOB="$fx/projects/*/memory" MC_STATE="$state" MC_WORKER="$stub" MC_NEW_DIR="$mem" MC_BATCH=20 MC_KEEP=2 MC_REAL_PEER="$mem/peer.md"
export WORKER_SCRATCH_ROOT="$fx/ws"
mkdir -p "$state/backups"; touch "$state/backups/memory-20200101T000000Z.tar.gz" "$state/backups/memory-20200102T000000Z.tar.gz"
mkdir "$fx/before"; cp "$mem"/*.md "$fx/before/"

# worker failure: nothing applied, nonzero rc
STUB_RC=1 python3 "$mc" && fail "failed worker must give nonzero rc"
grep -q '.new/bin' "$mem/tok.md" && fail "failed worker changed a note"
[[ ! -e "$state/checked.json" ]] || fail "failed worker marked notes checked"

python3 "$mc" > "$fx/out" 2>&1 || { cat "$fx/out" >&2; fail "run failed"; }
log=$(cat "$state"/????-??-??.md); prop=$(cat "$state"/proposals/????-??-??.md)
unchanged() { cmp -s "$mem/$1.md" "$fx/before/$1.md" || fail "$1.md must stay unchanged: $2"; }
# applied: the small token fix only, and its diff is in the log
grep -q '~/.new/bin/tool' "$mem/tok.md" && grep -q '「先查再说」' "$mem/tok.md" || fail "token fix not applied"
for want in 'changed: `p1/tok.md` — grep tool showed new path' '-Run `~/.old/bin/tool <sha>`' '+Run `~/.new/bin/tool <sha>`'; do grep -qF -- "$want" <<<"$log" || fail "log missing: $want"; done
# 1 deletion: refused for Why/How and for a founder quote, allowed for a plain note
unchanged a2a-product "delete with Why/How"; unchanged quoteonly "delete with founder quote"
grep -q '](a2a-product.md)' "$mem/MEMORY.md" || fail "refused delete lost its index line"
grep -qF 'delete refused, file stays: note has a Why or How to apply block' <<<"$log" || fail "log: Why/How delete refusal"
grep -qF 'delete refused, file stays: note has a founder quote' <<<"$log" || fail "log: quote delete refusal"
[[ ! -e "$mem/gone.md" ]] || fail "plain note not deleted"
grep -q '](gone.md)' "$mem/MEMORY.md" && fail "gone.md line left in MEMORY.md"
grep -q '](gonee.md)' "$mem/MEMORY.md" || fail "gonee.md line removed by non-exact match"
# 2 rewrites: refused and proposed, note unchanged
unchanged a2a-design "softened never-delete and description"; unchanged demo "stale gate rule plus pointer line"
unchanged chrome "How to apply rewritten"; unchanged added "added line"; unchanged auth "4 changed lines"; unchanged ratio "dissimilar line"
for want in '## p1/a2a-design.md' 'refused: description, Why or How to apply block changed' '+description: A2A core stays' \
  '## p1/demo.md' '+See .zenoforge/supervisor/founder-policy.json in the repo.' '## p1/added.md' 'refused: lines added or removed' '## p1/chrome.md' '+**How to apply:** run founder-chrome.sh' \
  '## p1/auth.md' 'refused: 4 lines changed, limit 3' '## p1/ratio.md' 'refused: changed line too different'; do
  grep -qF -- "$want" <<<"$prop" || fail "proposals missing: $want"
done
grep -qF 'skipped: `p1/chrome.md` — rewrite refused, proposed' <<<"$log" || fail "log: refused rewrite"
# peer write wins
[[ "$(tail -n1 "$mem/peer.md")" == peer ]] && ! grep -q '/new/peer' "$mem/peer.md" || fail "peer write overwritten"
grep -qF 'skipped: `p1/peer.md` — mtime changed' <<<"$log" || fail "log: mtime skip"
# new notes
[[ -f "$mem/good-way.md" ]] && grep -q '](good-way.md) — a thing that worked' "$mem/MEMORY.md" || fail "new note or its index line missing"
[[ ! -e "$mem/bad.md" && ! -e "$mem/third.md" ]] || fail "bad or third new note installed"
grep -qF 'skipped: `new/bad.md`' <<<"$log" && grep -qF 'skipped: `new/third.md` — more than 2' <<<"$log" || fail "log: new note limits"
ls -A "$mem" | grep -q '^\.' && fail "temp file left in memory dir"
python3 -c "import json,sys; c=json.load(open(sys.argv[1])); assert sys.argv[2] in c and sys.argv[3] not in c" "$state/checked.json" "$mem/tok.md" "$mem/peer.md" || fail "checked.json should hold tok.md and not skipped peer.md"
[[ $(ls "$state/backups" | wc -l) == 2 ]] || fail "backups not pruned to MC_KEEP=2: $(ls "$state/backups")"
tar -tzf "$(ls "$state"/backups/* | tail -1)" | grep -q 'p1/memory/tok.md' || fail "backup lacks notes"
[[ -z $(ls -A "$state/scratch") ]] || fail "scratch dir not cleaned"

# --- second run must not start while the lock is held
exec 9>"$state/lock"; flock -n 9
python3 "$mc" | grep -q 'holds the lock' || fail "locked run did not exit early"
echo "PASS memory-check"
