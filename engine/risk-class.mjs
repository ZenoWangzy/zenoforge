#!/usr/bin/env node
// Phase 0 risk gate for an agent-authored diff: does it touch a P2/L4 durable
// write boundary that the pipeline is not allowed to ship unattended? Run by
// run-implement.sh's wrapper before push. Exit 1 (and print the offending
// paths) means the caller relabels the issue ready-for-human instead of
// opening a draft PR.
//
// Each rule carries a `kind`:
//   - 'control-surface': the pipeline's own control surface, its outputs, and
//     infra it can execute through. Not "how risky" but the PAYLOAD: a
//     model-authored change here runs as the operator account on the next tick
//     or on the build host at the next image build.
//   - 'durable-write': a persisted-state or access-control boundary: schema,
//     migrations, auth, RBAC, ledger, policy.
// classify() returns the flat array of matched paths; classifyWithKind() also
// exposes WHICH boundary a hit crosses, for the guarded-merge admission path
// (run-implement.sh). Kind is evidence, not an admission exception: every
// guarded risk-class hit uses the same merge-condition checklist.
//
// A test file cannot itself migrate a database, alter a permission, or reach
// the control surface, and a path parked in an archive, a superseded plan or a
// throwaway spike is wired into nothing. Both are exempt, but ONLY from
// `durable-write` rules, and not from the rls/rbac/permission/policy keyword
// rule (keepTests): its own test files stay classified. Control-surface rules
// are never exempt: the pipeline's tests and prompts ARE its own guard.
//
// These patterns are layout conventions of a typical repository. Adjust them to
// the target repository's own schema, auth and deployment directories.
import { execFileSync } from 'node:child_process';
import { readPackJson } from './pack-dir.mjs';

const isTestPath = (path) =>
  /(?:^|\/)(?:__tests__|tests)\//.test(path) || /\.(?:test|spec)\.[^/]+$/.test(path);
const DEFAULT_INERT_PATTERNS = [/(?:^|\/)(?:archive|plans|spike)\//];

const DEFAULT_RISK_RULES = [
  { kind: 'durable-write', pattern: /(?:^|\/)db\/schema\// },
  { kind: 'durable-write', pattern: /(?:^|\/)migrations\// },
  // The drizzle-kit config decides which schema is read and where migrations are written.
  { kind: 'durable-write', pattern: /(?:^|\/)drizzle\.config\.[^/]+$/ },
  { kind: 'durable-write', pattern: /(?:^|\/)[^/]*(?:rls|rbac|permission|policy)[^/]*\.[^/]+$/i, keepTests: true },
  { kind: 'durable-write', pattern: /(?:^|\/)rbac\// },
  { kind: 'durable-write', pattern: /(?:^|\/)auth\// },
  { kind: 'durable-write', pattern: /(?:^|\/)ledger(?:[-_./]|$)/i },
  { kind: 'control-surface', pattern: /^\.github\/workflows\// },
  { kind: 'control-surface', pattern: /(?:^|\/)docker-compose[^/]*\.[^/]+$/ },
  { kind: 'control-surface', pattern: /^infra\// },
  { kind: 'control-surface', pattern: /(?:^|\/)\.env[^/]*$/ },
  // The guard itself, its prompts and its permissions file.
  { kind: 'control-surface', pattern: /^engine\// },
  { kind: 'control-surface', pattern: /^scripts\/ops\// },
  { kind: 'control-surface', pattern: /^\.claude\// },
  // A Dockerfile's RUN steps execute during the image build on the build host:
  // `Dockerfile`, `Dockerfile.foo` and `foo.Dockerfile` at any depth, plus
  // .dockerignore, which shapes what that build reads.
  { kind: 'control-surface', pattern: /(?:^|\/)Dockerfile(?:\.[^/]*)?$/i },
  { kind: 'control-surface', pattern: /(?:^|\/)[^/]+\.Dockerfile$/i },
  { kind: 'control-surface', pattern: /(?:^|\/)\.dockerignore$/ },
];

// A pack's state/risk-paths.json ({ rules: [{ kind, pattern, flags?, keepTests? }], inert: [{ pattern, flags? }] }) replaces both
// default lists wholesale: it states the target repository's own schema, auth and deployment directories. No pack, no file: defaults.
const pack = readPackJson('state/risk-paths.json');
const toRegExp = (entry) => new RegExp(entry.pattern, entry.flags ?? '');
const RISK_RULES = pack ? pack.rules.map((rule) => ({ ...rule, pattern: toRegExp(rule) })) : DEFAULT_RISK_RULES;
const INERT_PATTERNS = pack ? pack.inert.map(toRegExp) : DEFAULT_INERT_PATTERNS;
const isInertPath = (path) => INERT_PATTERNS.some((pattern) => pattern.test(path));

// classifyWithKind(changedPaths) -> [{path, kind}], one entry per matched
// path (a path matching more than one rule takes the FIRST rule's kind). A
// durable-write hit is dropped when the path is a test file (unless the
// matched rule sets keepTests) or an inert archive/plan/spike path.
// control-surface hits are never exempted. classify() is classifyWithKind()
// mapped to bare paths, so both share this exemption logic (same flat array
// of matched paths, same order).
export function classifyWithKind(changedPaths) {
  const hits = [];
  for (const path of changedPaths) {
    const rule = RISK_RULES.find((r) => r.pattern.test(path));
    if (!rule) continue;
    if (rule.kind === 'durable-write') {
      if (isInertPath(path)) continue;
      if (!rule.keepTests && isTestPath(path)) continue;
    }
    hits.push({ path, kind: rule.kind });
  }
  return hits;
}

export function classify(changedPaths) {
  return classifyWithKind(changedPaths).map((hit) => hit.path);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  // --json: print classifyWithKind()'s result as JSON on stdout and exit 0
  // always -- for a caller that needs to decide WHAT to do with a hit
  // (run-implement.sh's guarded-merge admission path), not just whether
  // one exists. Default (no flag): unchanged pass/fail CLI, still the one
  // every existing caller (the pre-push gate, the plain merge-time
  // re-check, run-advisor.sh's advisor_footprint_risky()) uses.
  const jsonFlagIndex = process.argv.indexOf('--json');
  const asJson = jsonFlagIndex !== -1;
  if (asJson) process.argv.splice(jsonFlagIndex, 1);
  const range = process.argv[2] ?? 'origin/main...HEAD';
  const changedPaths = execFileSync('git', ['diff', '--name-only', range], { encoding: 'utf8' })
    .split('\n')
    .filter(Boolean);
  if (asJson) {
    console.log(JSON.stringify(classifyWithKind(changedPaths)));
  } else {
    const offending = classify(changedPaths);
    if (offending.length > 0) {
      console.error('risk-class: P2/L4 path(s) touched, this diff needs a human:');
      for (const path of offending) console.error(`  ${path}`);
      process.exit(1);
    }
    console.log('risk-class: no P2/L4 paths touched.');
  }
}
