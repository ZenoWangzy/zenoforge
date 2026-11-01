#!/usr/bin/env bash
DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
values=$(node - "$DIR/lib/config.cjs" <<'NODE'
const {config:c,expand} = require(process.argv[2]);
for (const [k,v] of Object.entries(c.watch)) { const x = Array.isArray(v) ? v.join(' ') : String(v); console.log('W_' + k + "='" + (x.startsWith('~/') ? expand(x) : x).replace(/'/g, "'\\''") + "'"); }
NODE
) || exit 1
eval "$values"
node - "$DIR/lib/config.cjs" <<'NODE'
const fs=require('fs'), path=require('path'); const {config:c,expand}=require(process.argv[2]); let bad=0;
for (const e of c.links) { const l=expand(e.link), target=path.resolve(expand(e.target)); let st; try { st=fs.lstatSync(l); } catch {}
 if (!st || !st.isSymbolicLink()) { console.log('LINK not-a-link '+e.link); bad++; continue; }
 const actual=fs.readlinkSync(l); if (path.resolve(path.dirname(l),actual)!==target) { console.log('LINK wrong-target '+e.link+' -> '+actual); bad++; continue; }
 if (!fs.existsSync(l)) { console.log('LINK dangling '+e.link); bad++; }
}
if (!bad) console.log('links ok ('+c.links.length+')');
NODE
clone=$(node -e 'const x=require(process.argv[1]);process.stdout.write(x.expand(x.config.rulings_clone))' "$DIR/lib/config.cjs")
status=$(git -C "$clone" status --porcelain 2>/dev/null)
count=$(printf '%s\n' "$status" | sed '/^$/d' | wc -l)
echo "RULINGS uncommitted: $count"
[ -z "$status" ] || printf '%s\n' "$status"
unset GH_TOKEN
now=$(date +%s)
prs=$(gh pr list --state open --search "$W_pr_search" --json number,updatedAt 2>/dev/null)
open=$(jq length <<<"$prs")
idle=$(jq -r --argjson threshold "$W_pr_idle" --argjson now "$now" '[.[] | select(($now - (.updatedAt | fromdateiso8601)) > $threshold) | "#\(.number)"] | join(" ")' <<<"$prs")
echo "$W_pr_label open PRs: $open (limit $W_pr_limit); idle >$((W_pr_idle / 60))m: ${idle:-none}"
cg=$W_cgroup
declare -A a
for d in "$cg"/$W_scope_glob; do [ -e "$d" ] && a[$d]=$(awk '/usage_usec/{print $2}' "$d/cpu.stat"); done
sleep "$W_interval"
hf=0 zf=0 idle_scopes=""
for d in "${!a[@]}"; do
  [ -e "$d/cpu.stat" ] || continue
  n=${d##*/}; n=${n#"$W_scope_prefix"}; n=${n%-*.scope}
  case $n in $W_lane_pattern) zf=$((zf+1));; *) hf=$((hf+1));; esac
  used=$(( $(awk '/usage_usec/{print $2}' "$d/cpu.stat") - a[$d] ))
  [ "$used" -lt "$W_cpu_idle" ] && idle_scopes+=" $n"
done
echo "worker scopes: ${W_lane_labels%% *}=$hf (limit $W_lane_limit) ${W_lane_labels##* }=$zf; idle ${W_interval}s:${idle_scopes:- none}"
body=$(gh issue view "$W_migration_issue" -R "$W_migration_repo" --json body -q .body 2>/dev/null)
echo "$W_migration_label DoD: $(grep -cE '^\s*- \[x\]' <<<"$body")/$(grep -cE '^\s*- \[[ x]\]' <<<"$body") boxes"
