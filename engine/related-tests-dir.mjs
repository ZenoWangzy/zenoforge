import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

// New focused-test rows go in engine/related-tests.d/<name>.json ({"<path>": ["<test>", ...]}), one file per change:
// appends to the RELATED_TESTS literal conflicted with every parallel land (five 20-minute lands lost on 2026-11-20).
export const RELATED_TESTS_DIR = fileURLToPath(new URL('related-tests.d/', import.meta.url));

// A key already in the map gains the fragment's tests; a new key is added.
export function addRelatedTestFragments(map, toPath, dir = RELATED_TESTS_DIR) {
  for (const name of existsSync(dir) ? readdirSync(dir).filter((file) => file.endsWith('.json')).sort() : []) {
    for (const [key, tests] of Object.entries(JSON.parse(readFileSync(join(dir, name), 'utf8')))) {
      const path = toPath(key);
      map.set(path, [...new Set([...(map.get(path) ?? []), ...tests.map(toPath)])]);
    }
  }
  return map;
}
