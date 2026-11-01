#!/usr/bin/env bash
set -uo pipefail
[ "$#" -eq 4 ] || { echo 'usage: parity.sh <old-hooks-dir> <new-hooks-dir> <config> <fixtures-dir>' >&2; exit 1; }
old=$(realpath "$1"); new=$(realpath "$2"); config=$(realpath "$3"); fixtures=$(realpath "$4")
work=$(mktemp -d "${TMPDIR:-/tmp}/supervisor-parity.XXXXXXXX")
failed=0
for spec in "$fixtures"/*.hook; do
 [ -f "$spec" ] || continue
 name=${spec##*/}; name=${name%.hook}; hook=$(cat "$spec")
 target=$(node - "$config" "$hook" <<'NODE'
const c=require(process.argv[2]), p=require('path'); const e=c.links.find(x=>p.basename(x.link)===process.argv[3]); if (!e) process.exit(1); process.stdout.write(p.basename(e.target));
NODE
 ) || { echo "PARITY DIFF $name (no mapping)"; failed=1; continue; }
 home="$work/home-$name"; mkdir -p "$home"
 [ ! -d "$fixtures/$name.home" ] || cp -a "$fixtures/$name.home/." "$home/"
 sed "s|@HOME@|$home|g" "$fixtures/$name.stdin" > "$work/input"
 for variant in old new; do
  # Restore the fixture at the same HOME so absolute paths and mtimes match.
  if [ "$variant" = new ]; then
   [ ! -e "$home" ] || mv "$home" "$work/old-home-$name"
   mkdir -p "$home"; [ ! -d "$fixtures/$name.home" ] || cp -a "$fixtures/$name.home/." "$home/"
  fi
  script="$old/$hook"; [ "$variant" = old ] || script="$new/$target"
  (
   export HOME="$home" ZF_SUPERVISOR_CONFIG="$config"
   if [ -f "$fixtures/$name.env" ]; then set -a; . "$fixtures/$name.env"; set +a; fi
   if [ -f "$fixtures/$name.vars" ]; then set -a; . "$fixtures/$name.vars"; set +a; fi
   node "$script" < "$work/input" > "$work/$variant.out" 2> "$work/$variant.err"
  ); echo "$?" > "$work/$variant.status"
 done
 if cmp -s "$work/old.out" "$work/new.out" && cmp -s "$work/old.err" "$work/new.err" && cmp -s "$work/old.status" "$work/new.status"; then echo "PARITY ok $name"; else echo "PARITY DIFF $name"; failed=1; fi
done
exit "$failed"
