#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Which closed libraries does anything Finch builds still link?

    tools/check-closed.py [-v]

Finch runs nothing closed (docs/design/COREFOUNDATION.md). Every Mach-O that
the image gets from Finch (build/root, and the overlay manifest
tools/vm/overlay.txt) is checked: each library it links (weak links too, as
dyld loads those when present, except weak links to libraries macOS itself
doesn't ship, such as libobjc's to libobjc-env) must also come from Finch.
Prints each closed library with how many Finch binaries link it; -v lists
them. Exit 1 if any.
check-boot-path.py asks the narrower question of what the boot loads.
"""
import os
import subprocess
import sys
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STAGE = os.path.join(ROOT, 'build', 'root')
OVERLAY = os.path.join(ROOT, 'tools', 'vm', 'overlay.txt')


def finch_files():
    """{image path: host file} for everything Finch puts in the image."""
    files = {}
    for dirpath, _, names in os.walk(STAGE):
        for n in names:
            full = os.path.join(dirpath, n)
            files['/' + os.path.relpath(full, STAGE)] = full
    for line in open(OVERLAY):
        parts = line.split()
        if len(parts) == 2 and not line.lstrip().startswith('#'):
            files[parts[1]] = os.path.join(ROOT, parts[0])
    return files


def provided(path, files):
    """Does Finch provide `path` (directly, or through a symlink in build/root)?"""
    if path in files:
        return True
    real = os.path.realpath(STAGE + path)
    return real.startswith(STAGE + '/') and os.path.exists(real)


def linked(host_file):
    """[(install name, weak)] a Mach-O links, or None if it isn't one."""
    out = subprocess.run(['otool', '-L', host_file], capture_output=True, text=True)
    if out.returncode != 0 or 'is not an object file' in out.stdout:
        return None
    lines = out.stdout.splitlines()[1:]
    own = subprocess.run(['otool', '-D', host_file], capture_output=True, text=True).stdout.splitlines()[1:]
    return [(l.split()[0], l.rstrip().endswith(', weak)')) for l in lines
            if l.strip() and l.split()[0] not in own]


def macos_ships(path):
    """Does the build host's macOS have `path` (on disk or in its shared cache)?"""
    return subprocess.run(['dyld_info', '-exports', path], capture_output=True).returncode == 0


def main():
    verbose = '-v' in sys.argv[1:]
    files = finch_files()
    users = defaultdict(list)
    for image, host in sorted(files.items()):
        if not os.path.isfile(host) or os.path.islink(host):
            continue
        with open(host, 'rb') as f:
            magic = f.read(4)
        if magic not in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'):
            continue
        for dep, weak in linked(host) or []:
            if dep.startswith('@') or provided(dep, files):
                continue
            if weak and not macos_ships(dep):
                continue                       # absent on macOS too: nothing loads
            users[dep].append(image)
    for dep, who in sorted(users.items(), key=lambda kv: (-len(kv[1]), kv[0])):
        print(f'{len(who):4d}  {dep}')
        if verbose:
            for w in who:
                print(f'        {w}')
    print(f'{len(users)} closed libraries linked by Finch-built binaries' if users
          else 'nothing Finch builds links a closed library')
    return 1 if users else 0


if __name__ == '__main__':
    sys.exit(main())
