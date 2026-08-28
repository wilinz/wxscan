#!/usr/bin/env python3
"""Every markdown link in this repository resolves.

Relative paths and `#anchor` fragments only. External links are deliberately
not fetched: a CI job that talks to the network fails on rate limits and on
sites that answer robots differently than browsers, and a check that cries wolf
stops being read. crates.io alone answers 404 to anything without a browser's
user agent.

Anchors are generated the way GitHub does: lowercase, punctuation dropped,
spaces to hyphens, non-Latin scripts kept as they are, and a repeated heading
suffixed -1, -2 in order of appearance.
"""
import os
import re
import sys

SKIP = {'.git', 'target', 'build', '.dart_tool', 'Pods', 'node_modules',
        'venv', 'venv4', '.symlinks', 'ephemeral'}

INLINE = re.compile(r'(?<!\\)\[[^\]]*\]\(\s*<?([^)<>\s]+)>?\s*\)')
REFDEF = re.compile(r'^\[[^\]]+\]:\s*(\S+)', re.M)
FENCE = re.compile(r'^\s*(```|~~~)')


def anchors(text):
    """The set of #fragments the headings in `text` define."""
    seen, out = {}, set()
    fenced = False
    for line in text.split('\n'):
        if FENCE.match(line):
            fenced = not fenced
            continue
        if fenced:
            continue
        m = re.match(r'#{1,6}\s+(.*)', line)
        if not m:
            continue
        t = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', m.group(1).strip())
        t = t.replace('`', '').replace('*', '').replace('_', ' ')
        a = re.sub(r'[^\w\- ]', '', t.lower(), flags=re.UNICODE).strip()
        a = re.sub(r'\s+', '-', a)
        n = seen.get(a, 0)
        seen[a] = n + 1
        out.add(a if n == 0 else f'{a}-{n}')
    return out


def links(text):
    """Every link target, inline and reference-style, outside code fences."""
    body, fenced = [], False
    for line in text.split('\n'):
        if FENCE.match(line):
            fenced = not fenced
            body.append('')
            continue
        body.append('' if fenced else line)
    body = '\n'.join(body)
    return [m.group(1) for m in INLINE.finditer(body)] + REFDEF.findall(body)


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else '.'
    cache, problems = {}, []
    files = checked = 0

    def anchors_of(path):
        if path not in cache:
            with open(path, encoding='utf-8') as f:
                cache[path] = anchors(f.read())
        return cache[path]

    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP)
        for name in sorted(filenames):
            if not name.endswith('.md'):
                continue
            path = os.path.join(dirpath, name)
            files += 1
            with open(path, encoding='utf-8') as f:
                text = f.read()
            for link in links(text):
                if link.startswith(('http://', 'https://', 'mailto:', '#!')):
                    continue
                checked += 1
                target, _, fragment = link.partition('#')
                if not target:
                    if fragment and fragment not in anchors(text):
                        problems.append((path, link, 'no heading here makes that anchor'))
                    continue
                resolved = os.path.normpath(os.path.join(dirpath, target))
                if not os.path.exists(resolved):
                    problems.append((path, link, 'no such file'))
                elif fragment and resolved.endswith('.md'):
                    if fragment not in anchors_of(resolved):
                        problems.append((path, link, f'no heading in {target} makes that anchor'))

    for path, link, why in problems:
        print(f'::error file={path}::{link} — {why}')
    print(f'{len(problems)} broken links' if problems
          else f'{checked} links resolve, across {files} files')
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
