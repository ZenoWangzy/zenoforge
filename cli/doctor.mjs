// Host requirement checks. Each check returns {id, label, ok, hard, detail, fix}.
import fs from 'node:fs';
import path from 'node:path';
import { run, which } from './util.mjs';

export const AGENT_CLIS = ['codex', 'claude', 'zcode'];

/** "GNU bash, version 5.2.37(1)-release" -> [5, 2, 37]; null when unparseable. */
export function parseVersion(text) {
  const m = /(\d+)\.(\d+)(?:\.(\d+))?/.exec(text ?? '');
  return m ? [Number(m[1]), Number(m[2]), Number(m[3] ?? 0)] : null;
}

export function versionAtLeast(have, min) {
  if (!have) return false;
  for (let i = 0; i < min.length; i++) {
    if ((have[i] ?? 0) !== min[i]) return (have[i] ?? 0) > min[i];
  }
  return true;
}

/** Scopes from `gh auth status` output; null when gh prints none (fine-grained or GH_TOKEN tokens). */
export function parseGhScopes(text) {
  const m = /Token scopes:\s*(.+)/.exec(text ?? '');
  if (!m) return null;
  return [...m[1].matchAll(/'([^']+)'/g)].map((x) => x[1]);
}

export const isGnuDate = (versionOutput) => /GNU coreutils/.test(versionOutput ?? '');

const BREW_GNUBIN = ['/opt/homebrew/opt/coreutils/libexec/gnubin', '/usr/local/opt/coreutils/libexec/gnubin'];

function item(id, label, ok, { hard = true, detail = '', fix = '' } = {}) {
  return { id, label, ok: Boolean(ok), hard, detail, fix };
}

const installHint = {
  jq: { darwin: 'brew install jq', linux: 'sudo apt-get install -y jq   (or: sudo dnf install jq)' },
  python3: { darwin: 'brew install python', linux: 'sudo apt-get install -y python3' },
  flock: { darwin: 'brew install flock', linux: 'sudo apt-get install -y util-linux' },
  timeout: { darwin: 'brew install coreutils', linux: 'sudo apt-get install -y coreutils' },
  setsid: { darwin: 'brew install util-linux', linux: 'sudo apt-get install -y util-linux' },
  tar: { darwin: 'brew install gnu-tar', linux: 'sudo apt-get install -y tar' },
  git: { darwin: 'brew install git', linux: 'sudo apt-get install -y git' },
};
const hint = (tool, platform) => (installHint[tool] ?? {})[platform === 'darwin' ? 'darwin' : 'linux'] ?? `install ${tool}`;

const AGENT_HINT = {
  codex: 'npm i -g @openai/codex',
  claude: 'npm i -g @anthropic-ai/claude-code',
  zcode: 'install the ZCode CLI and make sure `zcode` is on PATH',
};

/**
 * @param {object} env injectable probes so tests can feed canned output
 */
export function runDoctor({
  platform = process.platform,
  envPath = process.env.PATH ?? '',
  nodeVersion = process.versions.node,
  exec = run,
  find = (n) => which(n, envPath),
  exists = fs.existsSync,
} = {}) {
  const out = [];

  const nodeOk = versionAtLeast(parseVersion(nodeVersion), [20, 0, 0]);
  out.push(item('node', `node >= 20 (found ${nodeVersion})`, nodeOk, { fix: 'install Node 20 or newer: https://nodejs.org/' }));

  out.push(item('git', 'git', find('git'), { fix: hint('git', platform) }));

  const ghPath = find('gh');
  out.push(item('gh', 'gh installed', ghPath, { fix: platform === 'darwin' ? 'brew install gh' : 'see https://github.com/cli/cli#installation' }));
  if (ghPath) {
    const st = exec('gh', ['auth', 'status']);
    const combined = `${st.stdout}\n${st.stderr}`;
    out.push(item('gh-auth', 'gh authenticated', st.ok, { fix: 'gh auth login', detail: st.ok ? '' : combined.trim().split('\n')[0] ?? '' }));
    if (st.ok) {
      const scopes = parseGhScopes(combined);
      const scopeOk = scopes === null || scopes.includes('repo');
      out.push(item('gh-scopes', 'gh token can use repos and labels (scope "repo")', scopeOk, {
        hard: scopes !== null,
        detail: scopes === null ? 'token scopes not reported (fine-grained token?); make sure it can write issues, pull requests, labels and variables' : `scopes: ${scopes.join(', ')}`,
        fix: 'gh auth refresh -s repo',
      }));
    }
  } else {
    out.push(item('gh-auth', 'gh authenticated', false, { fix: 'install gh first, then: gh auth login' }));
  }

  const bashPath = find('bash');
  const bashVer = bashPath ? parseVersion(exec(bashPath, ['--version']).stdout.split('\n')[0]) : null;
  out.push(item('bash', `bash >= 4 (found ${bashVer ? bashVer.join('.') : 'none'})`, versionAtLeast(bashVer, [4, 0, 0]), {
    fix: platform === 'darwin' ? 'brew install bash   (macOS ships bash 3.2; make sure the new bash is first on PATH)' : 'sudo apt-get install -y bash',
  }));

  for (const t of ['jq', 'python3', 'flock', 'timeout', 'setsid', 'tar']) {
    out.push(item(t, t, find(t), { fix: hint(t, platform) }));
  }

  // GNU date: the engine parses dates with GNU-only flags (date -d).
  let dateOk = false;
  let dateFix = 'sudo apt-get install -y coreutils';
  const datePath = find('date');
  if (datePath) dateOk = isGnuDate(exec(datePath, ['--version']).stdout);
  if (platform === 'darwin') {
    const gnubin = BREW_GNUBIN.find((d) => exists(path.join(d, 'date')));
    dateFix = gnubin
      ? `export PATH="${gnubin}:$PATH"   (add it to your shell profile)`
      : 'brew install coreutils && export PATH="$(brew --prefix coreutils)/libexec/gnubin:$PATH"   (add the export to your shell profile)';
  }
  out.push(item('gnu-date', 'GNU date', dateOk, { fix: dateFix }));

  const agents = AGENT_CLIS.filter((a) => find(a));
  out.push(item('agent', `at least one agent CLI (found: ${agents.join(', ') || 'none'})`, agents.length > 0, {
    fix: AGENT_CLIS.map((a) => `${a}: ${AGENT_HINT[a]}`).join('\n      '),
  }));
  // The unit loop implements through codex; claude is review-only there. zcode is the bin/worker failover backend.
  out.push(item('implementer', 'an implementing agent (codex or zcode)', agents.some((a) => a !== 'claude'), {
    hard: false,
    fix: `${AGENT_HINT.codex}   (claude alone can review but not implement)`,
  }));

  // Scheduler: soft, because a foreground command exists as a fallback.
  if (platform === 'darwin') {
    out.push(item('scheduler', 'launchd', find('launchctl'), { hard: false, fix: 'launchctl is part of macOS; run Zenoforge on the console user' }));
  } else {
    const sc = find('systemctl') ? exec('systemctl', ['--user', 'show-environment']) : { ok: false };
    out.push(item('scheduler', 'systemd user manager', sc.ok, {
      hard: false,
      fix: 'WSL2: set "[boot]\\nsystemd=true" in /etc/wsl.conf and run "wsl --shutdown". Other Linux: log in with a full session, then "loginctl enable-linger $USER". Without it, init prints a foreground command instead.',
    }));
  }
  return out;
}

export const hardFailures = (results) => results.filter((r) => r.hard && !r.ok);

export function formatDoctor(results) {
  const lines = results.map((r) => {
    const mark = r.ok ? 'PASS' : r.hard ? 'FAIL' : 'WARN';
    let l = `${mark}  ${r.label}`;
    if (r.detail) l += `\n      ${r.detail}`;
    if (!r.ok && r.fix) l += `\n      fix: ${r.fix}`;
    return l;
  });
  const bad = hardFailures(results).length;
  lines.push('', bad ? `${bad} required item(s) missing.` : 'All required items present.');
  return lines.join('\n');
}

export function detectAgents(find = (n) => which(n)) {
  return AGENT_CLIS.filter((a) => find(a));
}
