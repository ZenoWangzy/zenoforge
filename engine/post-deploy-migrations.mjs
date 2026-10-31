import { execFileSync, spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { PACK_DIR, zfConfigFile } from './pack-dir.mjs';

function settings() {
  const file = zfConfigFile('release.json');
  return (file ? JSON.parse(readFileSync(file, 'utf8')) : {}).postDeploy ?? {};
}
import { realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const DESTRUCTIVE = /\bdrop\s+(table|column|schema|database)\b|\balter\s+column\b[^;]*\btype\b|\bdelete\s+from\b/i;
const stripComments = (sql) => sql.replace(/\/\*[\s\S]*?\*\/|--[^\n]*/g, ' ');

function configuredExpansion(parts) {
  const { expansion } = settings();
  if (!expansion || parts.length !== 2) return false;
  const { dropPattern, addPattern, values } = expansion;
  if (typeof dropPattern !== 'string' || typeof addPattern !== 'string' || !Array.isArray(values)) return false;
  if (!new RegExp(dropPattern, 'i').test(parts[0])) return false;
  const match = new RegExp(addPattern, 'i').exec(parts[1]);
  if (!match) return false;
  const found = [...match[1].matchAll(/'([^']*)'/g)].map((item) => item[1]);
  if (match[1].replace(/'[^']*'/g, '').replace(/[\s,]/g, '') !== '') return false;
  return found.length === values.length && new Set(found).size === values.length
    && found.every((value) => values.includes(value));
}

export function isAdditiveMigration(sql) {
  const statements = stripComments(sql);
  if (!statements.trim()) return false;
  if (/\bdo\s*\$/i.test(statements)) return false;
  if (/\b(begin|commit|rollback)\b/i.test(statements)) return false;
  if (DESTRUCTIVE.test(statements) || /\bdrop\s+database\b/i.test(statements)) return false;
  const parts = statements.split(';').map((statement) => statement.trim()).filter(Boolean);
  if (configuredExpansion(parts)) return true;
  const created = new Set();
  const policyOnCreatedTable = (statement) => {
    const match = statement.match(new RegExp(`^create\\s+policy\\s+${name}\\s+on\\s+(${name})\\b`, 'i'));
    return match !== null && created.has(fold(match[1]));
  };
  for (const statement of parts) {
    const table = statement.match(new RegExp(`^create\\s+table\\s+if\\s+not\\s+exists\\s+(${name})`, 'i'));
    if (table) { created.add(fold(table[1])); continue; }
    if (/^create\s+(unique\s+)?index\s+if\s+not\s+exists\b/i.test(statement)) continue;
    const alterTable = statement.match(new RegExp(`^alter\\s+table\\s+(?:if\\s+exists\\s+)?(?:only\\s+)?(${name})\\s+(.*)$`, 'i'));
    if (alterTable) {
      const rest = alterTable[2].replace(/\s+$/, '');
      if (/^(enable|force)\s+row\s+level\s+security$/i.test(rest)) {
        if (created.has(fold(alterTable[1]))) continue;
        return false;
      }
      if (/^add\s+column\s+if\s+not\s+exists\s+/i.test(rest)) {
        if (/\bnot\s+null\b/i.test(rest) && !/\bdefault\b/i.test(rest)) return false;
        continue;
      }
      return false;
    }
    const dropPolicy = statement.match(new RegExp(`^drop\\s+policy\\s+if\\s+exists\\s+${name}\\s+on\\s+(${name})$`, 'i'));
    if (dropPolicy) { if (created.has(fold(dropPolicy[1]))) continue; return false; }
    if (policyOnCreatedTable(statement)) continue;
    return false;
  }
  return parts.length > 0;
}

export function postDeployMigrations(journal, readSql) {
  return journal.entries.flatMap(({ tag }) => {
    const sql = readSql(tag);
    if (!settings().marker || sql.split('\n', 1)[0].replace(/\r$/, '') !== settings().marker) return [];
    const statements = stripComments(sql);
    if (/\bdrop\s+database\b/i.test(statements)) throw new Error(`${tag}: DROP DATABASE is always refused`);
    const destructive = statements.match(DESTRUCTIVE);
    if (destructive) {
      const guard = statements.match(/\braise\s+exception\b/i);
      if (!guard || guard.index >= destructive.index) {
        throw new Error(`${tag} is destructive (${destructive[0]}) and has no fail-closed RAISE EXCEPTION guard before it`);
      }
      return [{ tag, sql, backup: backupTargets(sql) }];
    }
    return [{ tag, sql }];
  });
}

const fold = (target) => target.replace(/"(?:[^"]|"")*"|[^."]+/g, (part) => (part[0] === '"' ? part : part.toLowerCase()));
const name = String.raw`(?:"(?:[^"]|"")*"|[a-z_][\w$]*)(?:\.(?:"(?:[^"]|"")*"|[a-z_][\w$]*))*`;

export function backupTargets(sql) {
  const tables = new Set();
  const schemas = new Set();
  const targets = new RegExp(String.raw`\bdrop\s+(table|schema)\s+(?:if\s+exists\s+)?(${name}(?:\s*,\s*${name})*)|\balter\s+table\s+(?:if\s+exists\s+)?(?:only\s+)?(${name})([^;]*)|\bdelete\s+from\s+(?:only\s+)?(${name})`, 'gi');
  for (const match of stripComments(sql).matchAll(targets)) {
    if (match[5]) {
      tables.add(fold(match[5]));
    } else if (match[1]) {
      const names = match[1].toLowerCase() === 'table' ? tables : schemas;
      for (const [target] of match[2].matchAll(new RegExp(name, 'gi'))) names.add(fold(target));
    } else if (DESTRUCTIVE.test(match[4])) {
      tables.add(fold(match[3]));
    }
  }
  return { tables: [...tables], schemas: [...schemas] };
}

const literal = (value) => `'${value.replaceAll("'", "''")}'`;

export function postDeploySql(migrations, sha, phase = 'post-deploy') {
  if (migrations.length === 0) return '';
  const ledger = settings().ledger;
  if (typeof ledger !== 'string' || !/^[a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*$/.test(ledger)) throw new Error('release.json: postDeploy.ledger must be a qualified SQL identifier');
  const schema = ledger.split('.')[0];
  const echo = phase === 'pre-deploy' ? 'pre-deploy-migration' : 'post-deploy-migration';
  return `CREATE SCHEMA IF NOT EXISTS ${schema};
CREATE TABLE IF NOT EXISTS ${ledger} (
  tag text PRIMARY KEY, release_sha text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now()
);
` + migrations.map(({ tag, sql }) => `BEGIN;
SELECT EXISTS (SELECT 1 FROM ${ledger} WHERE tag = ${literal(tag)}) AS applied \\gset
\\if :applied
\\echo ${echo}: already-applied tag=${tag}
\\else
\\echo ${echo}: applying tag=${tag}
${sql}
INSERT INTO ${ledger} (tag, release_sha) VALUES (${literal(tag)}, ${literal(sha)});
\\endif
COMMIT;
\\echo ${echo}: complete tag=${tag}
`).join('');
}

function migrationsForRelease(repo, sha, phase = 'post-deploy') {
  const git = (args) => execFileSync('git', ['-C', repo, ...args], {
    encoding: 'utf8', maxBuffer: 32 * 1024 * 1024,
  });
  if (!git(['ls-tree', '--name-only', sha, '--', 'migrations/meta/_journal.json']).trim()) return [];
  const journal = JSON.parse(git(['show', `${sha}:migrations/meta/_journal.json`]));
  const migrations = postDeployMigrations(journal, (tag) => git(['show', `${sha}:migrations/${tag}.sql`]));
  if (phase !== 'pre-deploy') return migrations;
  return migrations.filter((migration) => isAdditiveMigration(migration.sql));
}

export function sqlForRelease(repo, sha, phase = 'post-deploy') {
  return postDeploySql(migrationsForRelease(repo, sha, phase), sha, phase);
}

if (process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) {
  try {
    if (!settings().marker && PACK_DIR) {
      const result = spawnSync(process.execPath, [join(PACK_DIR, 'post-deploy-migrations.mjs'), ...process.argv.slice(2)], { stdio: 'inherit' });
      if (result.error) throw result.error;
      process.exit(result.status ?? 1);
    }
    if (!settings().marker) throw new Error('release.json: postDeploy.marker is required');
    const argv = process.argv.slice(2);
    let backups = false;
    let phase = 'post-deploy';
    while (argv[0] === '--backups' || argv[0] === '--phase') {
      if (argv[0] === '--backups') { backups = true; argv.shift(); }
      else { phase = argv[1]; argv.splice(0, 2); }
    }
    if (!['post-deploy', 'pre-deploy'].includes(phase)) throw new Error(`unknown phase ${phase}`);
    const [repo, sha] = argv;
    if (backups) {
      for (const { tag, backup } of migrationsForRelease(repo, sha, phase)) {
        if (backup) process.stdout.write(JSON.stringify({ tag, ...backup }) + '\n');
      }
    } else {
      process.stdout.write(sqlForRelease(repo, sha, phase));
    }
  } catch (error) {
    console.error(`post-deploy-migrations: ${error.message}`);
    process.exitCode = 1;
  }
}
