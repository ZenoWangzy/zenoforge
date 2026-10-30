// gh wrappers. Reads go through run(); mutations go through Actions.exec so --dry-run covers them.
import { run } from './util.mjs';

export const REPO_RE = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;

export function listRepos(exec = run) {
  const r = exec('gh', ['repo', 'list', '--limit', '100', '--json', 'nameWithOwner', '--jq', '.[].nameWithOwner']);
  return r.ok ? r.stdout.split('\n').map((s) => s.trim()).filter(Boolean) : [];
}

/** {ok, defaultBranch, permission} or {ok:false, error}. */
export function viewRepo(repo, exec = run) {
  const r = exec('gh', ['repo', 'view', repo, '--json', 'defaultBranchRef,viewerPermission']);
  if (!r.ok) return { ok: false, error: (r.stderr || r.stdout || 'gh failed').trim().split('\n')[0] };
  try {
    const j = JSON.parse(r.stdout);
    return { ok: true, defaultBranch: j.defaultBranchRef?.name ?? null, permission: j.viewerPermission ?? null };
  } catch {
    return { ok: false, error: 'unreadable gh output' };
  }
}

/** Required status checks of branch protection, or [] when unprotected or not visible to this token. */
export function requiredChecks(repo, branch, exec = run) {
  const r = exec('gh', ['api', `repos/${repo}/branches/${branch}/protection/required_status_checks`]);
  if (!r.ok) return [];
  try {
    const j = JSON.parse(r.stdout);
    return [...new Set([...(j.contexts ?? []), ...(j.checks ?? []).map((c) => c.context)])];
  } catch {
    return [];
  }
}

export function existingLabels(repo, exec = run) {
  const r = exec('gh', ['label', 'list', '--repo', repo, '--limit', '500', '--json', 'name', '--jq', '.[].name']);
  return r.ok ? new Set(r.stdout.split('\n').map((s) => s.trim()).filter(Boolean)) : null;
}

/** Create the missing labels; idempotent. `existing` null (unreadable) means try all and ignore "already exists". */
export function ensureLabels(act, repo, labels, existing) {
  const created = [];
  for (const name of labels) {
    if (existing?.has(name)) continue;
    const r = act.exec('gh', ['label', 'create', name, '--repo', repo, '--color', 'ededed', '--description', 'Zenoforge pipeline state label']);
    if (r.ok) created.push(name);
  }
  return created;
}

export const setVariable = (act, repo, name, value) =>
  act.exec('gh', ['variable', 'set', name, '--repo', repo, '--body', value]);

/** gh keeps tokens in a keyring or in GH_TOKEN; background jobs cannot read either. */
export const needsTokenCopy = (statusText) => /\((keyring|GH_TOKEN|GITHUB_TOKEN)\)/.test(statusText ?? '');
