// Guard: every bare import in engine/**/*.mjs must be a node builtin or a package the
// root package.json declares. ts-judge.mjs imported @typesafe-ai/sdk undeclared since
// v0.1.0, so suites only passed in clones where someone had installed it by hand (#220).
import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";
import { isBuiltin } from "node:module";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const ENGINE_DIR = path.dirname(fileURLToPath(import.meta.url));
const ROOT_DIR = path.dirname(ENGINE_DIR);

async function mjsFiles(dir) {
  const files = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    if (entry.isDirectory()) files.push(...await mjsFiles(path.join(dir, entry.name)));
    else if (entry.name.endsWith(".mjs")) files.push(path.join(dir, entry.name));
  }
  return files.sort();
}

// Real imports and exports here always start a line; anchoring keeps sample source
// embedded in fixture strings (e.g. "import { test } from 'vitest'") out of the scan.
// The gap before `from` cannot cross a quote or semicolon, so one statement's `import`
// never matches a later statement's `from`.
const SPECIFIER_PATTERNS = [
  /^[ \t]*(?:import|export)\b[^;'"]*?\bfrom\s*(['"])([^'"\n]+)\1/gm,
  /^[ \t]*import\s*(['"])([^'"\n]+)\1/gm,
  /\bimport\s*\(\s*(['"])([^'"\n]+)\1/g,
];

function specifiers(source) {
  const found = [];
  for (const pattern of SPECIFIER_PATTERNS) {
    for (const match of source.matchAll(pattern)) found.push(match[2]);
  }
  return found;
}

// "@scope/name/subpath" -> "@scope/name"; "name/subpath" -> "name".
function packageName(specifier) {
  const parts = specifier.split("/");
  return specifier.startsWith("@") ? parts.slice(0, 2).join("/") : parts[0];
}

test("every bare import in engine/**/*.mjs is a node builtin or a declared dependency", async () => {
  const manifest = JSON.parse(await readFile(path.join(ROOT_DIR, "package.json"), "utf8"));
  const declared = new Set([...Object.keys(manifest.dependencies ?? {}), ...Object.keys(manifest.devDependencies ?? {})]);
  const violations = [];
  for (const file of await mjsFiles(ENGINE_DIR)) {
    const relative = path.relative(ROOT_DIR, file);
    for (const specifier of specifiers(await readFile(file, "utf8"))) {
      if (specifier.startsWith(".") || specifier.startsWith("/") || specifier.startsWith("#") || /^[a-z][a-z0-9+.-]*:/i.test(specifier)) continue;
      if (isBuiltin(specifier)) continue;
      if (!declared.has(packageName(specifier))) {
        violations.push(`${relative}: "${specifier}" is not a node builtin and ${packageName(specifier)} is not declared in package.json`);
      }
    }
  }
  assert.deepEqual(violations, []);
});
