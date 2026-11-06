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
    r = subprocess.run(['git', '-C', repo, 'show', f'{ref}:{path}'], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None


def has_token(text, token):
    return re.search(r'(?<![\w-])' + re.escape(token) + r'(?![\w-])', text) is not None


def required_names(node):
    names = set()
    if isinstance(node, dict):
        if isinstance(node.get('required'), list):
            names |= set(node['required'])
        for value in node.values():
            names |= required_names(value)
    elif isinstance(node, list):
        for value in node:
            names |= required_names(value)
    return names


def enum_values(node, key=None):
    """Map each property name to the enum values offered for it anywhere in the schema."""
    found = {}
    if isinstance(node, dict):
        if isinstance(node.get('enum'), list):
            found.setdefault(key, set()).update(node['enum'])
        for name, value in node.items():
            for prop, values in enum_values(value, name if key == 'properties' else key if name in ('enum', 'items') else name).items():
                found.setdefault(prop, set()).update(values)
    elif isinstance(node, list):
        for value in node:
            for prop, values in enum_values(value, key).items():
                found.setdefault(prop, set()).update(values)
    return found


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
        failures += [f'{name} does not require {n}' for n in sorted(required_names(ours) - required_names(fork))]
        offered, aliases = enum_values(fork), rules.get('aliases', {})
        for prop, values in sorted(enum_values(ours).items(), key=lambda row: str(row[0])):
            if prop in rules.get('open_enums', []):
                continue
            missing = [v for v in values if not offered.get(prop, set()) & {v, aliases.get(v, v)}]
            failures += [f'{name} enum {prop} lacks {v}' for v in sorted(missing, key=str)]

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
