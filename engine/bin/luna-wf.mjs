#!/usr/bin/env node
// Run one of this session's Workflow scripts on Codex luna instead of Claude subagents.
// Agents already completed in the Claude journal (matched by label) replay from it; the rest run through
// .scratch/bin/luna. Usage: node luna-wf.mjs <script.js> <claude-journal.jsonl|-> <args.json|-> <outdir> [maxParallel]
import { readFileSync, writeFileSync, mkdirSync, existsSync, appendFileSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { join } from 'node:path';

const [scriptPath, journalPath, argsPath, outdir, maxArg] = process.argv.slice(2);
const ROOT = '$HOME/src/target-repo';
const LUNA = `${ROOT}/.scratch/bin/luna`;
const max = Number(maxArg || 4);
mkdirSync(outdir, { recursive: true });
const ownJournal = join(outdir, 'journal.jsonl');

const cached = new Map();
const loadJournal = (path, labelOf) => {
  if (!path || path === '-' || !existsSync(path)) return;
  const labels = new Map();
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    if (!line.trim()) continue;
    let o; try { o = JSON.parse(line); } catch { continue; }
    if (o.type === 'started') labels.set(o.key, o.label);
    if (o.type === 'result') { const label = labelOf(o, labels); if (label) cached.set(label, o.result); }
  }
};
loadJournal(journalPath, (o, labels) => labels.get(o.key));
loadJournal(ownJournal, (o) => o.label);
const args = argsPath && argsPath !== '-' ? JSON.parse(readFileSync(argsPath, 'utf8')) : undefined;

let running = 0; const waiters = [];
const acquire = () => new Promise((r) => (running < max ? (running++, r()) : waiters.push(r)));
const release = () => { const n = waiters.shift(); if (n) n(); else running--; };

// OpenAI structured outputs want every object closed and every property required.
const strict = (s) => {
  if (!s || typeof s !== 'object') return s;
  const o = Array.isArray(s) ? s.map(strict) : Object.fromEntries(Object.entries(s).map(([k, v]) => [k, strict(v)]));
  if (o.type === 'object' && o.properties) { o.additionalProperties = false; o.required = Object.keys(o.properties); }
  return o;
};
const safe = (label) => label.replace(/[^A-Za-z0-9._-]+/g, '_').slice(0, 80);
const runLuna = (key, promptFile, schemaFile) => new Promise((resolve) => {
  const p = spawn(LUNA, [key, ROOT, promptFile, ...(schemaFile ? [schemaFile] : [])], { stdio: 'ignore' });
  p.on('exit', (code) => resolve(code));
});

async function agent(prompt, opts = {}) {
  const label = opts.label || `agent-${cached.size}`;
  if (cached.has(label)) {
    const r = cached.get(label);
    if (opts.schema && typeof r === 'string') { try { return JSON.parse(r); } catch { return r; } }
    return r;
  }
  await acquire();
  try {
    const key = `wf-${safe(outdir.split('/').pop())}-${safe(label)}`;
    const promptFile = join(outdir, `${safe(label)}.prompt`);
    const finalRule = opts.schema
      ? '\n\nFinal answer: a JSON object per the output schema.'
      : '\n\nFinal answer: your complete result as plain text (it is the return value, not a message to a human).';
    writeFileSync(promptFile, prompt + finalRule);
    let schemaFile;
    if (opts.schema) { schemaFile = join(outdir, `${safe(label)}.schema.json`); writeFileSync(schemaFile, JSON.stringify(strict(opts.schema))); }
    console.log(`[${new Date().toISOString()}] start ${label}`);
    const code = await runLuna(key, promptFile, schemaFile);
    let text = '';
    try { text = readFileSync(`${ROOT}/.scratch/luna/${key}/last.md`, 'utf8'); } catch {}
    console.log(`[${new Date().toISOString()}] done ${label} exit=${code} bytes=${text.length}`);
    if (!text.trim()) return null;
    let result = text;
    if (opts.schema) { try { result = JSON.parse(text); } catch { return null; } }
    appendFileSync(ownJournal, JSON.stringify({ type: 'result', label, result }) + '\n');
    return result;
  } finally { release(); }
}
async function pipeline(items, ...stages) {
  return Promise.all(items.map(async (item, i) => {
    let r = item;
    for (const stage of stages) {
      try { r = await stage(r, item, i); } catch (e) { console.log(`stage error: ${e.message}`); return null; }
    }
    return r;
  }));
}
const parallel = (thunks) => Promise.all(thunks.map((t) => Promise.resolve().then(t).catch(() => null)));
const phase = (t) => console.log(`== phase ${t}`);
const log = (m) => console.log(`-- ${m}`);
const budget = { total: null, spent: () => 0, remaining: () => Infinity };

const src = readFileSync(scriptPath, 'utf8').replace(/^export const meta/m, 'const meta');
const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
const body = new AsyncFunction('agent', 'pipeline', 'parallel', 'phase', 'log', 'args', 'budget', src);
const result = await body(agent, pipeline, parallel, phase, log, args, budget);
writeFileSync(join(outdir, 'result.json'), JSON.stringify(result, null, 1));
console.log(`[${new Date().toISOString()}] workflow finished`);
