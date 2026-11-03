#!/usr/bin/env node
import { readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const ENGINE_DIR = path.resolve(SCRIPT_DIR);
const REGEX_CALL = /\b(test|match|capture|sub|gsub)\s*\(\s*("(?:\\.|[^"\\])*")/g;

function shellFiles(directory) {
  const found = [];
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const absolute = path.join(directory, entry.name);
    if (entry.isDirectory()) found.push(...shellFiles(absolute));
    else if (entry.isFile() && entry.name.endsWith('.sh')) found.push(absolute);
  }
  return found;
}

function sourceWithoutCommentLines(source) {
  return source.split(/\r?\n/).map((line) => (
    line.trimStart().startsWith('#') ? ' '.repeat(line.length) : line
  )).join('\n');
}

function lineAt(source, offset) {
  return source.slice(0, offset).split('\n').length;
}

function findPatterns(source) {
  const code = sourceWithoutCommentLines(source);
  const patterns = [];
  for (const match of code.matchAll(REGEX_CALL)) {
    let pattern;
    try {
      pattern = JSON.parse(match[2]);
    } catch (error) {
      patterns.push({
        functionName: match[1],
        line: lineAt(code, match.index),
        error: `literal is not a JSON string: ${error.message}`,
      });
      continue;
    }
    patterns.push({ functionName: match[1], line: lineAt(code, match.index), pattern });
  }
  return patterns;
}

function compilePattern(pattern) {
  const filter = `"" | test(${JSON.stringify(pattern)})`;
  const result = spawnSync('jq', ['-n', filter], { encoding: 'utf8' });
  if (result.error) return result.error.message;
  return result.status === 0 ? null : (result.stderr.trim() || `jq exited ${result.status}`);
}

export function checkFiles(files, root = path.resolve(SCRIPT_DIR, '..')) {
  let checked = 0;
  const violations = [];
  for (const file of files) {
    let source;
    try {
      source = readFileSync(file, 'utf8');
    } catch (error) {
      violations.push(`${file}: cannot read: ${error.message}`);
      continue;
    }
    for (const item of findPatterns(source)) {
      if (item.error) {
        violations.push(`${path.relative(root, file)}:${item.line}: ${item.functionName} ${item.error}`);
        continue;
      }
      checked += 1;
      const error = compilePattern(item.pattern);
      if (error) {
        violations.push(`${path.relative(root, file)}:${item.line}: invalid jq ${item.functionName} pattern ${JSON.stringify(item.pattern)}: ${error}`);
      }
    }
  }
  return { checked, files: files.length, violations };
}

function main(args) {
  const repo = path.resolve(SCRIPT_DIR, '..');
  const files = args.length
    ? args.map((file) => path.resolve(file))
    : shellFiles(ENGINE_DIR);
  const result = checkFiles(files, repo);
  if (result.violations.length) {
    for (const violation of result.violations) console.error(`jq-regex-safety: ${violation}`);
    console.error(`jq-regex-safety: ${result.violations.length} invalid literal jq pattern(s) across ${result.files} engine shell file(s)`);
    process.exitCode = 1;
    return;
  }
  console.log(`jq-regex-safety: compiled ${result.checked} literal jq pattern(s) across ${result.files} engine shell file(s)`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2));
}
