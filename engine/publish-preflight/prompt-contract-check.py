#!/usr/bin/env python3
"""Fail when a product prompt fork lacks what the engine reads from that prompt's output.

A contract names identifiers and never sentences, so a fork keeps its own wording: the required property names of
the schema paired with a prompt, enum values, and the tokens listed in prompt-contract.json. A prompt passes when
each identifier appears in it or in a repo file it names in backticks, because a fork may delegate to a skill.
A forked schema must require what the engine's schema requires and offer its enum values, except a value the
product renames (aliases) or an enum that belongs to the product (open_enums).

usage: prompt-contract-check.py <new version dir> <target repo> <new ref>
"""
import json, os, re, subprocess, sys

LINK = re.compile(r'`([\w.-]+(?:/[\w.-]+)+\.\w+)`')


def show(repo, ref, path):
    r = subprocess.run(['git', '-C', repo, 'show', f'{ref}:{path}'], capture_output=True, text=True, errors='replace')
    return r.stdout if r.returncode == 0 else None


def has_token(text, token):
    return re.search(r'(?<![\w-])' + re.escape(token) + r'(?![\w-])', text) is not None


def required_at(node, path=()):
    """Every (location, name) a schema requires: a name required elsewhere does not stand in for this one."""
    found = set()
    if isinstance(node, dict):
        if isinstance(node.get('required'), list):
            found |= {(path, name) for name in node['required']}
        for key, value in node.items():
            found |= required_at(value, path + (key,))
    elif isinstance(node, list):
        for index, value in enumerate(node):
            found |= required_at(value, path + (index,))
    return found


def required_names(schema):
    return {name for _, name in required_at(schema)}


def enums_at(node, path=()):
    """Map each location to the enum values offered there."""
    found = {}
    if isinstance(node, dict):
        if isinstance(node.get('enum'), list):
            found[path] = set(node['enum'])
        for key, value in node.items():
            found.update(enums_at(value, path + (key,)))
    elif isinstance(node, list):
        for index, value in enumerate(node):
            found.update(enums_at(value, path + (index,)))
    return found


def where(path):
    return '/'.join(str(part) for part in path) or 'root'


def main(version, repo, ref):
    engine = os.path.join(version, 'engine')
    path = os.path.join(engine, 'publish-preflight', 'prompt-contract.json')
    if not os.path.exists(path):
        print('prompt-contract: this version declares none')
        return 0
    with open(path, encoding='utf-8') as handle:
        contract = json.load(handle)
    failures = []

    def engine_schema(name):
        with open(os.path.join(engine, 'prompts', name), encoding='utf-8') as handle:
            return json.load(handle)

    for prompt, want in contract['prompts'].items():
        fork = show(repo, ref, f'.zenoforge/prompts/{prompt}')
        if fork is None:
            continue
        text = fork + ''.join(show(repo, ref, path) or '' for path in LINK.findall(fork))
        names = set(want.get('tokens', []))
        if 'schema' in want:
            names |= required_names(engine_schema(want['schema']))
        failures += [f'{prompt} never names {name}' for name in sorted(names) if not has_token(text, name)]

    for name, rules in contract['schemas'].items():
        raw = show(repo, ref, f'.zenoforge/prompts/{name}')
        if raw is None:
            continue
        ours, fork = engine_schema(name), json.loads(raw)
        failures += [f'{name} does not require {n} at {where(at)}' for at, n in sorted(required_at(ours) - required_at(fork), key=str)]
        offered, aliases = enums_at(fork), rules.get('aliases', {})
        for at, values in sorted(enums_at(ours).items(), key=str):
            prop = at[-2] if at[-1] == 'items' else at[-1]
            if prop in rules.get('open_enums', []):
                continue
            missing = [v for v in values if not offered.get(at, set()) & {v, aliases.get(v, v)}]
            failures += [f'{name} enum {prop} lacks {v} at {where(at)}' for v in sorted(missing, key=str)]

    for line in failures:
        print(f'prompt-contract: {line}', file=sys.stderr)
    if failures:
        return 1
    print('prompt-contract: OK')
    return 0


if __name__ == '__main__':
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
