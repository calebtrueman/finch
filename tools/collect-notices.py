#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Collect the licence notices of the third-party sources built into a binary.

    tools/collect-notices.py <title> <output> <source files...>

Reads each file's leading comment blocks (and those of the headers it
includes with "quotes" from its own directory, recursively). Keeps the blocks
that carry a copyright, licence or public-domain statement, starting from the
first such line (a file's description above it is dropped), and writes each
distinct notice once with the files it covers. The output goes to
/usr/share/finch/licenses/<project>/ (docs/LICENSING.md).
"""
import os
import re
import sys

KEEP = re.compile(r'copyright|spdx-license|permission|public domain|licen[cs]e', re.I)
START = re.compile(r'copyright|spdx-license|public domain', re.I)


def leading_comments(text):
    """The comment blocks before the first line of code."""
    blocks, pos = [], 0
    while True:
        m = re.match(r'\s*(/\*.*?\*/|(?://[^\n]*\n)+)', text[pos:], re.S)
        if not m:
            return blocks
        blocks.append(m.group(1))
        pos += m.end()


def clean(block):
    lines = []
    for line in block.splitlines():
        line = re.sub(r'^\s*(/\*+-?|\*/|\*(?!/)|//)', '', line)
        line = re.sub(r'\*/\s*$', '', line)
        lines.append(line[1:] if line.startswith(' ') else line)
    while lines and not lines[0].strip():
        lines.pop(0)
    while lines and not lines[-1].strip():
        lines.pop()
    for i, line in enumerate(lines):
        if START.search(line):
            lines = lines[i:]
            break
    # Decorative rules (==== lines) carry nothing.
    lines = [l for l in lines if not re.fullmatch(r'\s*[=\-*]{8,}\s*', l)]
    return '\n'.join(l.rstrip() for l in lines).strip()


def with_includes(paths):
    seen, todo = [], list(paths)
    while todo:
        p = os.path.realpath(todo.pop(0))
        if p in seen or not os.path.isfile(p):
            continue
        seen.append(p)
        with open(p, errors='replace') as fh:
            for inc in re.findall(r'^\s*#\s*include\s+"([^"]+)"', fh.read(), re.M):
                todo.append(os.path.join(os.path.dirname(p), inc))
    return seen


def main():
    title, out, files = sys.argv[1], sys.argv[2], sys.argv[3:]
    notices, bare = {}, []
    files = with_includes(files)
    for path in files:
        found = False
        with open(path, errors='replace') as fh:
            for block in leading_comments(fh.read()):
                if KEEP.search(block):
                    text = clean(block)
                    if text:
                        notices.setdefault(text, []).append(os.path.basename(path))
                        found = True
        if not found:
            bare.append(os.path.basename(path))
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, 'w') as fh:
        fh.write(f'{title}\n\nNotices collected from the {len(files)} source files built into '
                 f'this component, each listed once with the files it covers.\n')
        for text, names in sorted(notices.items(), key=lambda kv: sorted(kv[1])[0]):
            fh.write('\n' + '=' * 72 + '\n')
            fh.write('Files: ' + ', '.join(sorted(set(names))) + '\n\n')
            fh.write(text + '\n')
        if bare:
            fh.write('\n' + '=' * 72 + '\n')
            fh.write('Files without a notice of their own (covered by the project licence):\n'
                     + ', '.join(sorted(set(bare))) + '\n')
    print(f'{out}: {len(notices)} notices from {len(files)} files'
          + (f'; {len(bare)} without their own: {" ".join(sorted(bare))}' if bare else ''))


if __name__ == '__main__':
    main()
