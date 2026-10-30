import { execFileSync, spawnSync } from 'node:child_process';
import process from 'node:process';

import { focusedTestPaths } from './focused-test-paths.mjs';

export { focusedTestPaths };

const RUNNER = 'cihost';
const ARCHIVE_PATHS = [
  'scripts',
  '.agents',
  'docs/agents',
  'lessons',
  '.github/workflows',
  'skills-lock.json',
  'CLAUDE.md',
  'CONTRIBUTING.md',
];
const REGRESSION_ENV = {
  TEST_WAIT_TIMEOUT_MS: '10000',
  ONNXRUNTIME_NODE_INSTALL_CUDA: 'skip',
  POSTGRES_IMAGE: 'registry.example.com/pgvector/pgvector:pg16',
  TESTCONTAINERS_RYUK_DISABLED: 'true',
  TESTCONTAINERS_LOCK_PRIORITY: 'postsubmit',
  NODE_OPTIONS: '--max-old-space-size=4096',
};

function gitRaw(args, options = {}) {
  return execFileSync('git', args, {
    encoding: 'utf8',
    maxBuffer: 8 * 1024 * 1024,
    ...options,
  });
}

function git(args, options = {}) {
  return gitRaw(args, options).trim();
}

function nulSeparated(value) {
  return value ? value.split('\0').filter(Boolean) : [];
}

function shellQuote(value) {
  return `'${value.replaceAll("'", "'\\''")}'`;
}

export function remoteScript(changedPaths, testPaths) {
  const syntaxChecks = changedPaths.flatMap((path) => {
    if (path.startsWith('engine/') && path.endsWith('.sh')) {
      return [`bash -n ${shellQuote(path)}`];
    }
    if (path.startsWith('scripts/') && path.endsWith('.mjs')) {
      return [`node --check ${shellQuote(path)}`];
    }
    return [];
  });
  const testCommands = testPaths.map((path) => path.endsWith('.test.sh')
    ? `bash ${shellQuote(path)}`
    : `node --test ${shellQuote(path)}`);

  const checks = [
    'set -eu',
    'cd "$WORK_DIR"',
    'git init -q',
    'git add --all',
    "git -c user.name='CI toolchain fixture' -c user.email='ci-toolchain@example.invalid' commit -qm 'toolchain preflight snapshot'",
    'command -v gawk >/dev/null || { echo "cihost CI gate requires gawk" >&2; exit 127; }',
    'awk_version=$(awk --version 2>&1 | sed -n \'1p\')',
    'case "$awk_version" in "GNU Awk "*) ;; *) echo "cihost CI gate requires GNU Awk as awk; found: $awk_version" >&2; exit 1 ;; esac',
    'printf "cihost CI runner (%s): " "$(id -un)"; hostname',
    'printf "awk: %s\\n" "$awk_version"',
    'printf "sed: "; sed --version | sed -n \'1p\'',
    'printf "bash: "; bash --version | sed -n \'1p\'',
    "printf 'coreutils: '; dpkg-query -W -f='${Version}\\n' coreutils",
    'printf "jq: "; jq --version',
    'printf "node: "; node --version',
    ...syntaxChecks,
    ...testCommands,
  ].join('\n');

  return [
    'set -eu',
    'work=$(mktemp -d "${TMPDIR:-/tmp}/zf-pipeline-ci.XXXXXX")',
    'trap \'rm -rf "$work"\' EXIT',
    'mkdir "$work/home"',
    'tar -xf - -C "$work"',
    'chown -R zf-ci:zf-ci "$work"',
    `runuser -u zf-ci -- env HOME="$work/home" TMPDIR="$work" WORK_DIR="$work" bash -c ${shellQuote(checks)}`,
  ].join('\n');
}

export function runDeterministicRegressionGate(changedPaths, cwd = process.cwd()) {
  if (!changedPaths.some((path) => path.startsWith('engine/'))) return null;
  const options = {
    cwd,
    encoding: 'utf8',
    maxBuffer: 32 * 1024 * 1024,
    env: { ...process.env, ...REGRESSION_ENV },
  };
  const install = spawnSync('pnpm', ['install', '--frozen-lockfile'], options);
  if (install.error || install.status !== 0) return install;
  return spawnSync('pnpm', ['test:regression'], options);
}

function runGate(base, head) {
  const changedPaths = nulSeparated(gitRaw([
    'diff', '--name-only', '-z', '--no-renames', '--diff-filter=ACMRTUXB', `${base}..${head}`,
  ]));
  const changedAgent = changedPaths.some((path) => path.startsWith('engine/'));
  const regression = runDeterministicRegressionGate(changedPaths);
  if (regression) {
    if (regression.error) throw regression.error;
    if (regression.status !== 0) {
      if (regression.stdout) process.stdout.write(regression.stdout);
      if (regression.stderr) process.stderr.write(regression.stderr);
      process.exit(regression.status ?? 1);
    }
    console.log('Deterministic Postsubmit regression gate passed locally: pnpm test:regression.');
  }

  const trackedPaths = new Set(nulSeparated(gitRaw(['ls-tree', '-r', '--name-only', '-z', head])));
  const testPaths = focusedTestPaths(changedPaths, trackedPaths, { baseRef: base, headRef: head });
  const changedCode = changedPaths.some((path) => (
    path.startsWith('engine/') && /\.(?:sh|mjs)$/.test(path)
  ) || path === 'scripts/branch-delivery-preflight.mjs');

  if (!changedCode && testPaths.length === 0) {
    console.log(changedAgent
      ? 'CI toolchain gate: full deterministic regression passed; no focused runner test applies.'
      : 'CI toolchain gate: no pipeline code or executable contract changed.');
    return;
  }
  if (testPaths.length === 0) {
    throw new Error('Pipeline code changed but no focused runner test was selected.');
  }

  const archive = execFileSync('git', ['archive', '--format=tar', head, '--', ...ARCHIVE_PATHS], {
    encoding: null,
    maxBuffer: 32 * 1024 * 1024,
  });
  const result = spawnSync('ssh', [
    '-o', 'BatchMode=yes',
    '-o', 'ConnectTimeout=15',
    RUNNER,
    `bash -c ${shellQuote(remoteScript(changedPaths, testPaths))}`,
  ], {
    input: archive,
    encoding: 'utf8',
    maxBuffer: 32 * 1024 * 1024,
  });

  if (result.stdout) process.stdout.write(result.stdout);
  if (result.stderr) process.stderr.write(result.stderr);
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
  console.log(`CI toolchain gate passed on ${RUNNER}: ${testPaths.join(', ')}.`);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const [base, head] = process.argv.slice(2);
  if (!base || !head) throw new Error('Usage: node ci-toolchain-preflight.mjs <base> <head>.');
  runGate(base, head);
}
