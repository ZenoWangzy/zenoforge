import assert from 'node:assert/strict';
import { test } from 'node:test';
import { formatDoctor, hardFailures, isGnuDate, parseGhScopes, parseVersion, runDoctor, versionAtLeast } from './doctor.mjs';

test('version parsing', () => {
  assert.deepEqual(parseVersion('GNU bash, version 5.2.37(1)-release'), [5, 2, 37]);
  assert.deepEqual(parseVersion('GNU bash, version 3.2.57(1)-release (arm64-apple-darwin23)'), [3, 2, 57]);
  assert.equal(parseVersion('no digits'), null);
  assert.ok(versionAtLeast([5, 0, 0], [4, 0, 0]));
  assert.ok(!versionAtLeast([3, 2, 57], [4, 0, 0]));
  assert.ok(!versionAtLeast(null, [4, 0, 0]));
});

test('gh scopes and GNU date detection', () => {
  const out = "github.com\n  ✓ Logged in to github.com account octo (keyring)\n  - Token scopes: 'gist', 'read:org', 'repo', 'workflow'\n";
  assert.deepEqual(parseGhScopes(out), ['gist', 'read:org', 'repo', 'workflow']);
  assert.equal(parseGhScopes('✓ Logged in (GH_TOKEN)\n'), null);
  assert.ok(isGnuDate('date (GNU coreutils) 9.4'));
  assert.ok(!isGnuDate('date: illegal option -- -'));
});

const ghOk = "✓ Logged in to github.com account octo (keyring)\n- Token scopes: 'repo'\n";
function probe({ missing = [], bashOut = 'GNU bash, version 5.2.37(1)-release', dateOut = 'date (GNU coreutils) 9.4', gh = { ok: true, stdout: ghOk, stderr: '' }, systemd = true } = {}) {
  return {
    platform: 'linux',
    nodeVersion: '22.1.0',
    find: (n) => (missing.includes(n) ? null : `/usr/bin/${n}`),
    exec: (cmd, args) => {
      if (args[0] === '--version' && cmd.endsWith('bash')) return { ok: true, stdout: bashOut, stderr: '' };
      if (args[0] === '--version' && cmd.endsWith('date')) return { ok: true, stdout: dateOut, stderr: '' };
      if (cmd === 'gh') return gh;
      if (cmd === 'systemctl') return { ok: systemd, stdout: '', stderr: '' };
      return { ok: false, stdout: '', stderr: '' };
    },
  };
}
const byId = (r, id) => r.find((x) => x.id === id);

test('healthy Linux host passes with no hard failure', () => {
  const r = runDoctor(probe());
  assert.deepEqual(hardFailures(r), []);
  assert.ok(byId(r, 'gh-scopes').ok);
});

test('each missing tool is a hard failure with its own fix command', () => {
  const r = runDoctor(probe({ missing: ['jq', 'flock', 'codex', 'claude', 'zcode'] }));
  const bad = hardFailures(r).map((x) => x.id).sort();
  assert.deepEqual(bad, ['agent', 'flock', 'jq']);
  assert.match(byId(r, 'jq').fix, /apt-get install -y jq/);
  assert.match(byId(r, 'agent').fix, /npm i -g @openai\/codex/);
  assert.equal(byId(r, 'implementer').hard, false);
});

test('old bash, non-GNU date, unauthenticated gh and missing repo scope', () => {
  assert.ok(!byId(runDoctor(probe({ bashOut: 'GNU bash, version 3.2.57(1)-release' })), 'bash').ok);
  assert.ok(!byId(runDoctor(probe({ dateOut: 'usage: date' })), 'gnu-date').ok);
  const noAuth = runDoctor(probe({ gh: { ok: false, stdout: '', stderr: 'You are not logged into any GitHub hosts.\n' } }));
  assert.ok(!byId(noAuth, 'gh-auth').ok);
  assert.equal(byId(noAuth, 'gh-auth').fix, 'gh auth login');
  assert.ok(!byId(noAuth, 'gh-scopes'));
  const narrow = runDoctor(probe({ gh: { ok: true, stdout: "- Token scopes: 'gist'\n", stderr: '' } }));
  assert.ok(!byId(narrow, 'gh-scopes').ok);
  assert.equal(byId(narrow, 'gh-scopes').fix, 'gh auth refresh -s repo');
});

test('fine-grained tokens without a scopes line are a warning, not a failure', () => {
  const r = runDoctor(probe({ gh: { ok: true, stdout: '✓ Logged in (GH_TOKEN)\n', stderr: '' } }));
  assert.equal(byId(r, 'gh-scopes').hard, false);
  assert.deepEqual(hardFailures(r), []);
});

test('macOS: brew commands for date and bash, launchd instead of systemd', () => {
  const r = runDoctor({ ...probe({ dateOut: 'usage: date', bashOut: 'GNU bash, version 3.2.57(1)-release' }), platform: 'darwin', exists: () => false });
  assert.match(byId(r, 'gnu-date').fix, /brew install coreutils/);
  assert.match(byId(r, 'gnu-date').fix, /gnubin/);
  assert.match(byId(r, 'bash').fix, /brew install bash/);
  assert.equal(byId(r, 'scheduler').label, 'launchd');
  assert.match(byId(r, 'jq').fix, /brew install jq/);
});

test('no systemd user bus is a warning with a fallback, and formatting shows PASS/FAIL/WARN', () => {
  const r = runDoctor(probe({ systemd: false, missing: ['jq'] }));
  assert.equal(byId(r, 'scheduler').hard, false);
  const text = formatDoctor(r);
  assert.match(text, /^FAIL  jq/m);
  assert.match(text, /^WARN  systemd user manager/m);
  assert.match(text, /^PASS  git/m);
  assert.match(text, /1 required item\(s\) missing\./);
});
