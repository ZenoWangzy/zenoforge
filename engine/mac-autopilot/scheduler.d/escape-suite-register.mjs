import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { ESCAPE_SUITE_REGISTRY, validateRegistry } from './escape-suite-runner.mjs';

function parseArgs(args) {
  const separator = args.indexOf('--');
  if (separator === -1) throw new Error('expected -- before the command');
  const options = {};
  const allowed = new Set(['--repo', '--package', '--test']);
  for (let index = 0; index < separator; index += 2) {
    const name = args[index];
    const value = args[index + 1];
    if (!allowed.has(name) || !value || Object.hasOwn(options, name)) {
      throw new Error('expected --repo, --package, and --test once each before --');
    }
    options[name] = value;
  }
  if (Object.keys(options).length !== allowed.size) {
    throw new Error('expected --repo, --package, and --test once each before --');
  }
  return {
    repo: options['--repo'],
    packagePath: options['--package'],
    testPath: options['--test'],
    command: args.slice(separator + 1),
  };
}

function registerEscapeSuite({ repo, packagePath, testPath, command }) {
  const candidate = validateRegistry({
    version: 1,
    packages: {
      [packagePath]: [{ test: testPath, command }],
    },
  }, 'new escape suite');
  const [validatedPackagePath, tests] = candidate.entries().next().value;
  const [validatedTestPath, entry] = tests.entries().next().value;
  const repoPath = path.resolve(repo);
  if (!existsSync(repoPath) || !statSync(repoPath).isDirectory()) {
    throw new Error('--repo must name an existing directory');
  }
  const registryPath = path.join(repoPath, ESCAPE_SUITE_REGISTRY);
  const registry = existsSync(registryPath)
    ? JSON.parse(readFileSync(registryPath, 'utf8'))
    : { version: 1, packages: {} };
  const existingPackages = validateRegistry(registry, 'escape suite registry');
  const existingEntry = existingPackages.get(validatedPackagePath)?.get(validatedTestPath);
  if (existingEntry && JSON.stringify(existingEntry.command) === JSON.stringify(entry.command)) return;
  if (!Object.hasOwn(registry.packages, validatedPackagePath)) {
    Object.defineProperty(registry.packages, validatedPackagePath, {
      value: [],
      enumerable: true,
      configurable: true,
      writable: true,
    });
  }
  const entries = registry.packages[validatedPackagePath];
  const existingIndex = entries.findIndex((registered) => registered.test === validatedTestPath);
  const registeredEntry = { test: validatedTestPath, command: entry.command };
  if (existingIndex === -1) entries.push(registeredEntry);
  else entries[existingIndex] = registeredEntry;
  mkdirSync(path.dirname(registryPath), { recursive: true });
  writeFileSync(registryPath, `${JSON.stringify(registry, null, 2)}\n`);
}

function main(args) {
  try {
    registerEscapeSuite(parseArgs(args));
    return 0;
  } catch (error) {
    process.stderr.write(`${String(error?.message ?? error)}\n`);
    return 1;
  }
}

process.exitCode = main(process.argv.slice(2));
