#!/usr/bin/env bash
set -euo pipefail
apply=0 config=''
while (($#)); do case "$1" in --apply) apply=1; shift;; --config) config=${2:?}; shift 2;; *) echo "unknown argument: $1" >&2; exit 1;; esac; done
[ -n "$config" ] || { echo 'usage: install.sh [--apply] --config <path>' >&2; exit 1; }
config=$(realpath "$config")
export ZF_SUPERVISOR_CONFIG="$config"
export ZF_SUPERVISOR_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/config.cjs"
node - "$apply" <<'NODE'
const fs = require('fs'), path = require('path'), cp = require('child_process');
const {config, expand} = require(process.env.ZF_SUPERVISOR_LIB);
const apply = process.argv[2] === '1';
const home = process.env.HOME;
const backup = path.join(home, '.zenoforge/backups/supervisor-' + new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, ''));
const entries = [...config.links, {link:'~/.zenoforge/supervisor/config.json', target:process.env.ZF_SUPERVISOR_CONFIG}];
for (const entry of entries) {
 const link = expand(entry.link), target = expand(entry.target);
 if (fs.existsSync(link) || fs.lstatSync(link, {throwIfNoEntry:false})) {
  const st = fs.lstatSync(link);
  if (st.isSymbolicLink() && path.resolve(path.dirname(link), fs.readlinkSync(link)) === path.resolve(target)) continue;
  if (!st.isSymbolicLink()) {
   const rel = path.relative(home, link);
   if (rel.startsWith('..') || path.isAbsolute(rel)) throw Error('link outside HOME: ' + link);
   const dest = path.join(backup, rel);
   console.log(`backup ${link} -> ${dest}`);
   if (apply) { fs.mkdirSync(path.dirname(dest), {recursive:true}); fs.renameSync(link, dest); }
  }
 }
 console.log(`link ${link} -> ${target}`);
 if (apply) {
  fs.mkdirSync(path.dirname(link), {recursive:true});
  const tmp = path.join(path.dirname(link), `.supervisor-${process.pid}-${Math.random().toString(16).slice(2)}`);
  fs.symlinkSync(target, tmp); fs.renameSync(tmp, link);
 }
}
NODE
