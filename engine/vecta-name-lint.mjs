import { execFileSync } from 'node:child_process';
import { existsSync, realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const TARGET_NAME_PATTERN = /\bvecta[-_][a-z0-9][a-z0-9_-]*\b/gi;
const CONFIG_DEFAULT = /^\s*const [A-Z][A-Z0-9_]*_DEFAULT = ['"]vecta[-_][a-z0-9][a-z0-9_-]*['"];?\s*$/i;

export function findForbiddenVectaNames(diff) {
  const findings = [];
  let path = '';
  for (const line of diff.split('\n')) {
    if (line.startsWith('+++ b/')) {
      path = line.slice('+++ b/'.length);
      continue;
    }
    if (!line.startsWith('+') || line.startsWith('+++') || !path.startsWith('engine/')) continue;
    if (/(?:^|\/)[^/]*\.test\.[^/]+$/.test(path)) continue;
    const source = line.slice(1);
    const isDefault = path === 'engine/ci-target-config.mjs' && CONFIG_DEFAULT.test(source);
    if (isDefault) continue;
    for (const match of source.matchAll(TARGET_NAME_PATTERN)) findings.push(`${path}: ${match[0]}`);
  }
  return findings;
}

function run(base, head) {
  const diff = execFileSync('git', ['diff', '--unified=0', `${base}...${head}`, '--', 'engine'], { encoding: 'utf8' });
  const findings = findForbiddenVectaNames(diff);
  if (findings.length) {
    console.error(`target-name-lint: literals must use config defaults:\n${findings.join('\n')}`);
    process.exitCode = 1;
    return;
  }
  console.log('target-name-lint: passed');
}

if (process.argv[1] && existsSync(process.argv[1]) && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) {
  const [baseFlag, base, headFlag, head] = process.argv.slice(2);
  if (baseFlag !== '--base' || headFlag !== '--head' || !base || !head) {
    throw new Error('Usage: node <script> --base <ref> --head <ref>');
  }
  run(base, head);
}
