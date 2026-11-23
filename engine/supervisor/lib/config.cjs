const fs = require('fs');
const os = require('os');
const path = require('path');
const expand = p => p === '~' ? os.homedir() : p.startsWith('~/') ? path.join(os.homedir(), p.slice(2)) : p;
const file = expand(process.env.ZF_SUPERVISOR_CONFIG || '~/.zenoforge/supervisor/config.json');
let config;
try { config = JSON.parse(fs.readFileSync(file, 'utf8')); }
catch (error) { process.stderr.write(`zenoforge supervisor: config unavailable: ${file} (${error.message.replace(/\s*\n\s*/g, ' ')})\n`); process.exit(1); }
const watchDefaults = {
  ready_stuck_minutes: 60,
  no_output_hours: 3,
};
const watch = {
  ...watchDefaults,
  ...(config.watch && typeof config.watch === 'object' && !Array.isArray(config.watch) ? config.watch : {}),
};
for (const [key, fallback] of Object.entries(watchDefaults)) {
  const raw = watch[key];
  const value = typeof raw === 'number' || (typeof raw === 'string' && raw.trim() !== '') ? Number(raw) : NaN;
  watch[key] = Number.isFinite(value) && value >= 0 ? value : fallback;
}
config.watch = watch;
const fail = message => { process.stderr.write(`zenoforge supervisor: ${message}\n`); process.exit(1); };
let defaults;
try { defaults = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'supervisors.default.json'), 'utf8')); }
catch (error) { fail(`supervisors defaults unavailable: ${error.message.replace(/\s*\n\s*/g, ' ')}`); }
const target = config.supervisors === undefined ? {} : config.supervisors;
if (!target || typeof target !== 'object' || Array.isArray(target)) fail('supervisors must be an object');
const supervisors = {};
for (const name of new Set([...Object.keys(defaults), ...Object.keys(target)])) {
  const entry = { ...defaults[name], ...target[name] };
  if (!['active', 'closed'].includes(entry.state)) fail(`supervisor ${name}: state must be active or closed`);
  supervisors[name] = entry;
}
config.supervisors = supervisors;
module.exports = { config, expand };
