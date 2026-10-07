#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Phase 1 exit check: is everything the boot path loads above the kernel Finch-built?

    tools/check-boot-path.py [image path...]

Starts from the programs the VM's boot runs (finch-init, the rc script's shell
and tools, notifyd, the console shell and its modules, dyld) plus any paths
given, follows their dylib dependencies recursively, and reports every image
that build/root (or tools/vm/overlay.txt) doesn't provide. Weak and delay-init
links are skipped, as dyld only loads those on demand or when present.
Exit 0 when nothing is missing.
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STAGE = os.path.join(ROOT, 'build', 'root')

BOOT = [
    '/usr/appleinternal/sbin/launchd.finch',   # finch-init (PID 1)
    '/bin/sh', '/bin/bash',                    # the rc script
    '/System/Library/Filesystems/tmpfs.fs/Contents/Resources/mount_tmpfs',
    '/bin/chmod', '/bin/mkdir',
    '/usr/sbin/notifyd',                       # demand-started by the first notify client
    '/bin/zsh',                                # the console shell
    '/usr/lib/dyld',
]


def overlay():
    paths = {}
    with open(os.path.join(ROOT, 'tools', 'vm', 'overlay.txt')) as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith('#'):
                src, dst = line.split()[:2]
                paths[dst] = os.path.join(ROOT, src)
    return paths


def dependencies(path):
    """Load paths dyld loads eagerly: not weak, not delay-init."""
    out = subprocess.run(['dyld_info', '-dependents', path], capture_output=True,
                         text=True).stdout.splitlines()
    deps = []
    in_table = False
    for line in out:
        fields = line.split()
        if not in_table:
            in_table = fields[-2:] == ['load', 'path']
            continue
        if not fields:
            continue
        attrs, dep = fields[:-1], fields[-1]
        if 'weak-link' in attrs or 'weak' in attrs or 'delay-init' in attrs:
            continue
        deps.append(dep)
    return deps


def main():
    provided = overlay()
    zsh_modules = []
    zdir = os.path.join(STAGE, 'usr', 'lib', 'zsh')
    for dirpath, _, files in os.walk(zdir):
        zsh_modules += ['/' + os.path.relpath(os.path.join(dirpath, f), STAGE)
                        for f in files if f.endswith('.so')]
    todo = BOOT + zsh_modules + sys.argv[1:]
    seen, missing, parent = set(), {}, {}
    while todo:
        path = todo.pop()
        if path in seen:
            continue
        seen.add(path)
        local = provided.get(path) or (STAGE + path if os.path.exists(STAGE + path) else None)
        if local is None:
            missing[path] = parent.get(path, '(start)')
            continue
        for dep in dependencies(local):
            if not dep.startswith('@') and dep not in seen:
                parent.setdefault(dep, path)
                todo.append(dep)
    print(f'{len(seen)} images on the boot path; {len(missing)} not built by Finch')
    for path in sorted(missing):
        print(f'  {path}  (loaded by {missing[path]})')
    return 1 if missing else 0


if __name__ == '__main__':
    sys.exit(main())
