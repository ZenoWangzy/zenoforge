import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { analyzeMigrationSql } from './fruit-migration-analyze.mjs';

const sql = `
-- ALTER TABLE app.commented ADD COLUMN ignored integer;
ALTER TABLE app.changed ADD COLUMN changed integer;
CREATE TABLE IF NOT EXISTS app.created (id integer);
CREATE INDEX idx ON "app"."indexed" (id);
ALTER TABLE other.outside ADD COLUMN ignored integer;
`;
assert.deepEqual(analyzeMigrationSql(sql, 'app'), [
  'ANALYZE "app"."changed";', 'ANALYZE "app"."created";', 'ANALYZE "app"."indexed";',
]);
assert.deepEqual(analyzeMigrationSql('ALTER TABLE "a""b"."c""d" ADD x int;', 'a"b'), [
  'ANALYZE "a""b"."c""d";',
]);
const root = mkdtempSync(join(process.cwd(), '.git/analyze-test-'));
const pack = join(root, 'pack');
const config = join(root, 'config');
mkdirSync(pack); mkdirSync(config);
writeFileSync(join(pack, 'release.json'), JSON.stringify({ migration: { schema: 'other' } }));
writeFileSync(join(config, 'release.json'), JSON.stringify({ migration: { schema: 'app' } }));
const run = (env) => spawnSync(process.execPath, ['engine/fruit-migration-analyze.mjs', '--stdin'], {
  input: sql, encoding: 'utf8', env: { ...process.env, ZF_PACK_DIR: pack, ZF_CONFIG_ROOT: config, ...env },
});
let result = run({});
assert.equal(result.status, 0, result.stderr);
assert.equal(JSON.parse(result.stdout).length, 3);
result = run({ ZF_CONFIG_ROOT: join(root, 'missing') });
assert.deepEqual(JSON.parse(result.stdout), ['ANALYZE "other"."outside";']);
writeFileSync(join(pack, 'fruit-migration-analyze.mjs'), "process.stdout.write('legacy');");
result = run({ ZF_CONFIG_ROOT: join(root, 'missing'), ZF_PACK_DIR: join(root, 'legacy-pack') });
assert.equal(result.status, 1);
mkdirSync(join(root, 'legacy-pack'));
writeFileSync(join(root, 'legacy-pack', 'fruit-migration-analyze.mjs'), "process.stdout.write('legacy');");
result = run({ ZF_CONFIG_ROOT: join(root, 'missing'), ZF_PACK_DIR: join(root, 'legacy-pack') });
assert.equal(result.status, 0, result.stderr);
assert.equal(result.stdout, 'legacy');
result = run({ ZF_CONFIG_ROOT: join(root, 'missing'), ZF_PACK_DIR: '' });
assert.equal(result.status, 1);
assert.match(result.stderr, /migration.schema is required/);
console.log('migration ANALYZE parser: ok');
