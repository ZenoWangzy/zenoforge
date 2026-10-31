import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { PACK_DIR, zfConfigFile } from './pack-dir.mjs';

const identifier = '(?:"(?:[^"]|"")*"|[A-Za-z_][A-Za-z0-9_$]*)';
const target = `(?<schema>${identifier})\\s*\\.\\s*(?<table>${identifier})`;

function removeCommentsAndStrings(sql) {
  return sql
    .replace(/\$([A-Za-z_][A-Za-z_0-9]*|)\$[\s\S]*?\$\1\$/g, ' ')
    .replace(/'(?:''|\\[\s\S]|[^'\\])*'/g, ' ')
    .replace(/--[^\r\n]*/g, ' ')
    .replace(/\/\*[\s\S]*?\*\//g, ' ');
}

function identifierValue(value) {
  return value.startsWith('"') ? value.slice(1, -1).replace(/""/g, '"') : value.toLowerCase();
}

function quoteIdentifier(value) {
  return `"${value.replace(/"/g, '""')}"`;
}

export function analyzeMigrationSql(sql, schema) {
  if (typeof schema !== 'string' || !schema) throw new Error('release.json: migration.schema is required');
  const source = removeCommentsAndStrings(sql);
  const patterns = [
    new RegExp(`\\bALTER\\s+TABLE\\s+(?:IF\\s+EXISTS\\s+)?(?:ONLY\\s+)?${target}`, 'gi'),
    new RegExp(`\\bCREATE\\s+TABLE\\s+(?:IF\\s+NOT\\s+EXISTS\\s+)?${target}`, 'gi'),
    new RegExp(`\\bCREATE\\s+(?:UNIQUE\\s+)?INDEX\\s+(?:CONCURRENTLY\\s+)?(?:IF\\s+NOT\\s+EXISTS\\s+)?${identifier}(?:\\s*\\.\\s*${identifier})?\\s+ON\\s+(?:ONLY\\s+)?${target}`, 'gi'),
  ];
  const tables = new Set();
  for (const pattern of patterns) {
    for (const match of source.matchAll(pattern)) {
      if (identifierValue(match.groups.schema) === schema) tables.add(identifierValue(match.groups.table));
    }
  }
  return [...tables].map((table) => `ANALYZE ${quoteIdentifier(schema)}.${quoteIdentifier(table)};`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    if (process.argv[2] !== '--stdin') throw new Error('usage: fruit-migration-analyze.mjs --stdin');
    const configPath = zfConfigFile('release.json');
    const config = configPath ? JSON.parse(readFileSync(configPath, 'utf8')) : {};
    const schema = config.migration?.schema;
    if (!schema && PACK_DIR) {
      const legacy = join(PACK_DIR, 'fruit-migration-analyze.mjs');
      const result = spawnSync(process.execPath, [legacy, '--stdin'], { stdio: 'inherit' });
      if (result.error) throw result.error;
      process.exitCode = result.status ?? 1;
    } else {
      process.stdout.write(`${JSON.stringify(analyzeMigrationSql(readFileSync(0, 'utf8'), schema))}\n`);
    }
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
