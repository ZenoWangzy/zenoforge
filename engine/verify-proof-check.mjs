#!/usr/bin/env node
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const SCRIPT_PATH = fileURLToPath(import.meta.url);
const MIN_SHA_PREFIX = 7;

function sameSha(a, b) {
  if (!a || !b) return false;
  const [short, long] = a.length <= b.length ? [a, b] : [b, a];
  return short.length >= MIN_SHA_PREFIX && long.startsWith(short);
}

function result(status, features, reasons) {
  return { status, features, reasons };
}

export function checkProof(plan, proofText, head) {
  const matched = plan?.matched_features;
  if (!Array.isArray(matched) || matched.some((id) => typeof id !== 'string' || !id)) {
    throw new Error('plan must carry a matched_features array of feature ids');
  }
  if (matched.length === 0) return result('not-required', {}, ['plan matches no feature']);
  if (typeof proofText !== 'string' || proofText.trim() === '') return result('missing', {}, ['proof file is absent or empty']);

  let proof;
  try {
    proof = JSON.parse(proofText);
  } catch (error) {
    return result('invalid', {}, [`proof is not JSON: ${error.message}`]);
  }
  if (!proof || typeof proof !== 'object' || Array.isArray(proof)) return result('invalid', {}, ['proof must be a JSON object']);
  if (!Array.isArray(proof.features) || proof.features.length === 0) {
    return result('invalid', {}, ['proof.features must be a non-empty array of per-feature results']);
  }
  if (typeof proof.source_sha !== 'string' || !proof.source_sha) return result('invalid', {}, ['proof.source_sha is missing']);
  if (!sameSha(proof.source_sha, head)) {
    return result('stale', {}, [`proof.source_sha ${proof.source_sha} differs from head ${head}`]);
  }

  const features = {};
  const reasons = [];
  for (const id of matched) {
    const rows = proof.features.filter((row) => row?.feature_id === id);
    if (rows.length === 0) {
      features[id] = 'missing';
      reasons.push(`no result for feature ${id}`);
    } else if (rows.every((row) => row.status === 'PASS')) {
      features[id] = 'ok';
    } else {
      features[id] = 'failed';
      reasons.push(`feature ${id} status is ${rows.find((row) => row.status !== 'PASS').status ?? 'absent'}, not PASS`);
    }
  }
  const values = Object.values(features);
  if (values.every((value) => value === 'ok')) return result('ok', features, []);
  return result(values.includes('missing') ? 'missing' : 'invalid', features, reasons);
}

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    const value = argv[++i];
    if (!value) throw new Error(`missing value for ${token}`);
    if (token === '--plan') args.plan = value;
    else if (token === '--proof') args.proof = value;
    else if (token === '--head') args.head = value;
    else throw new Error(`unknown argument: ${token}`);
  }
  for (const name of ['plan', 'proof', 'head']) if (!args[name]) throw new Error(`--${name} is required`);
  return args;
}

export function runCli(argv = process.argv.slice(2)) {
  const args = parseArgs(argv);
  let plan;
  try {
    plan = JSON.parse(readFileSync(args.plan, 'utf8'));
  } catch (error) {
    throw new Error(`cannot read plan ${args.plan}: ${error.message}`);
  }
  const proofText = existsSync(args.proof) ? readFileSync(args.proof, 'utf8') : null;
  process.stdout.write(`${JSON.stringify(checkProof(plan, proofText, args.head))}\n`);
}

if (process.argv[1] && existsSync(process.argv[1]) && realpathSync(process.argv[1]) === realpathSync(SCRIPT_PATH)) {
  try {
    runCli();
  } catch (error) {
    console.error(`verify-proof-check: ${error instanceof Error ? error.message : String(error)}`);
    process.exit(2);
  }
}
