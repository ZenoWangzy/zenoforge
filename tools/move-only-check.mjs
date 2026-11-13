#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { extname } from 'node:path';
import { shellFunctionRanges } from '../engine/focused-test-paths.mjs';

function gitText(args, cwd) {
  try {
    return execFileSync('git', args, {
      cwd,
      encoding: 'utf8',
      maxBuffer: 64 * 1024 * 1024,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
  } catch (error) {
    if (args[0] === 'show' && error.status === 128) return '';
    const message = error.stderr?.trim() || error.message;
    throw new Error(message);
  }
}

function parseArguments(args) {
  if (args.length === 2) return { base: args[0], head: args[1], allowAdded: new Set() };
  if (args.length === 4 && args[2] === '--allow-added') {
    const names = args[3].split(',');
    if (names.some((name) => !/^[A-Za-z_][A-Za-z0-9_]*$/.test(name))) return null;
    return { base: args[0], head: args[1], allowAdded: new Set(names) };
  }
  return null;
}

function shellPath(path, before, after) {
  if (!path.startsWith('engine/') && !path.startsWith('tools/')) return false;
  if (path.endsWith('.sh')) return true;
  if (extname(path.split('/').at(-1)) !== '') return false;
  return [before, after].some((source) => /^#!.*\bbash\b/.test(source.split('\n', 1)[0] ?? ''));
}

function sourceLines(source) {
  if (source === '') return [];
  const lines = source.split('\n');
  if (source.endsWith('\n')) lines.pop();
  return lines;
}

function shellFile(path, source) {
  const lines = sourceLines(source);
  const ranges = shellFunctionRanges(source);
  if (ranges === null) throw new Error(`cannot parse shell functions in ${path}`);
  const functions = ranges.map(({ name, start, end }) => ({
    name,
    body: lines.slice(start - 1, end).join('\n'),
  }));
  const functionLines = new Set();
  for (const { start, end } of ranges) {
    for (let index = start - 1; index < end; index += 1) functionLines.add(index);
  }
  return {
    functions,
    nonFunctionLines: lines.filter((_, index) => !functionLines.has(index)),
  };
}

function sameBodies(before, after) {
  const left = [...before].sort();
  const right = [...after].sort();
  return left.length === right.length && left.every((body, index) => body === right[index]);
}

function functionTable(files, side) {
  const table = new Map();
  for (const file of files) {
    for (const { name, body } of file[side].functions) {
      const bodies = table.get(name) ?? [];
      bodies.push(body);
      table.set(name, bodies);
    }
  }
  return table;
}

function lineChanges(before, after) {
  let prefix = 0;
  while (prefix < before.length && prefix < after.length && before[prefix] === after[prefix]) prefix += 1;
  let suffix = 0;
  while (
    suffix < before.length - prefix
    && suffix < after.length - prefix
    && before[before.length - suffix - 1] === after[after.length - suffix - 1]
  ) suffix += 1;

  const oldLines = before.slice(prefix, before.length - suffix);
  const newLines = after.slice(prefix, after.length - suffix);
  if (oldLines.length === 0) return { added: newLines.length, removed: 0 };
  if (newLines.length === 0) return { added: 0, removed: oldLines.length };

  const frontier = new Map([[1, 0]]);
  for (let distance = 0; distance <= oldLines.length + newLines.length; distance += 1) {
    for (let diagonal = -distance; diagonal <= distance; diagonal += 2) {
      let oldIndex;
      if (
        diagonal === -distance
        || (diagonal !== distance && (frontier.get(diagonal - 1) ?? -1) < (frontier.get(diagonal + 1) ?? -1))
      ) {
        oldIndex = frontier.get(diagonal + 1) ?? 0;
      } else {
        oldIndex = (frontier.get(diagonal - 1) ?? 0) + 1;
      }
      let newIndex = oldIndex - diagonal;
      while (
        oldIndex < oldLines.length
        && newIndex < newLines.length
        && oldLines[oldIndex] === newLines[newIndex]
      ) {
        oldIndex += 1;
        newIndex += 1;
      }
      frontier.set(diagonal, oldIndex);
      if (oldIndex >= oldLines.length && newIndex >= newLines.length) {
        return {
          added: (distance + newLines.length - oldLines.length) / 2,
          removed: (distance + oldLines.length - newLines.length) / 2,
        };
      }
    }
  }
  return { added: newLines.length, removed: oldLines.length };
}

function list(values) {
  return values.length === 0 ? 'none' : [...values].sort().join(', ');
}

function check(base, head, allowAdded) {
  const cwd = gitText(['rev-parse', '--show-toplevel'], process.cwd()).trim();
  const changedPaths = gitText(['diff', '--name-only', base, head], cwd)
    .split(/\r?\n/)
    .filter(Boolean);
  const files = [];
  for (const path of changedPaths) {
    const before = gitText(['show', `${base}:${path}`], cwd);
    const after = gitText(['show', `${head}:${path}`], cwd);
    if (!shellPath(path, before, after)) continue;
    files.push({
      before: shellFile(path, before),
      after: shellFile(path, after),
    });
  }

  const before = functionTable(files, 'before');
  const after = functionTable(files, 'after');
  const changed = [];
  const removed = [...before.keys()].filter((name) => !after.has(name));
  const added = [...after.keys()].filter((name) => !before.has(name));
  let movedOrUnchanged = 0;
  for (const [name, oldBodies] of before) {
    if (!after.has(name)) continue;
    const newBodies = after.get(name);
    if (!sameBodies(oldBodies, newBodies)) changed.push(name);
    const remaining = [...newBodies];
    for (const body of oldBodies) {
      const match = remaining.indexOf(body);
      if (match === -1) continue;
      movedOrUnchanged += 1;
      remaining.splice(match, 1);
    }
  }

  let nonFunctionAdded = 0;
  let nonFunctionRemoved = 0;
  for (const file of files) {
    const difference = lineChanges(file.before.nonFunctionLines, file.after.nonFunctionLines);
    nonFunctionAdded += difference.added;
    nonFunctionRemoved += difference.removed;
  }

  console.log(`moved-or-unchanged: ${movedOrUnchanged}`);
  console.log(`changed: ${list(changed)}`);
  console.log(`removed: ${list(removed)}`);
  console.log(`added: ${list(added)}`);
  console.log(`non-function lines changed: +${nonFunctionAdded} -${nonFunctionRemoved}`);

  return changed.length === 0 && removed.length === 0 && added.every((name) => allowAdded.has(name)) ? 0 : 1;
}

function main(args) {
  const options = parseArguments(args);
  if (!options) {
    console.error('usage: node tools/move-only-check.mjs <base> <head> [--allow-added a,b,c]');
    return 64;
  }
  try {
    return check(options.base, options.head, options.allowAdded);
  } catch (error) {
    console.error(`move-only-check: ${error.message}`);
    return 2;
  }
}

process.exitCode = main(process.argv.slice(2));
