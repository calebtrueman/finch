#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""How much of what this Mac's SwiftUI apps import Finch's SwiftUI has: per app, the share
of its SwiftUI imports that Finch's SwiftUI and SwiftUICore export, and the missing symbols
most apps import, to work through in that order.
    tools/swiftui-coverage.py [--top N] [--apps DIR ...] [--json OUT]
The apps are read from the host's install (their import tables only); nothing is copied.
"""
import argparse
import collections
import json
import os
import subprocess

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
FRAMEWORKS = os.path.join(ROOT, 'build', 'root', 'System', 'Library', 'Frameworks')


def executables(dirs):
    for d in dirs:
        if not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d)):
            macos = os.path.join(d, name, 'Contents', 'MacOS')
            if name.endswith('.app') and os.path.isdir(macos):
                info = os.path.join(d, name, 'Contents', 'Info.plist')
                exe = None
                if os.path.exists(info):
                    out = subprocess.run(['plutil', '-extract', 'CFBundleExecutable', 'raw', info],
                                         capture_output=True, text=True).stdout.strip()
                    exe = os.path.join(macos, out) if out else None
                if exe and os.path.isfile(exe):
                    yield name[:-4], exe


def swiftui_imports(exe):
    out = subprocess.run(['xcrun', 'dyld_info', '-imports', exe], capture_output=True, text=True).stdout
    names = set()
    for line in out.splitlines():
        if '(from SwiftUI)' in line or '(from SwiftUICore)' in line:
            parts = line.split()
            names.add(parts[1] if parts[0].startswith('0x') else parts[0])
    return names


def finch_exports():
    names = set()
    for fw in ('SwiftUI', 'SwiftUICore'):
        binary = os.path.join(FRAMEWORKS, f'{fw}.framework', 'Versions', 'A', fw)
        out = subprocess.run(['nm', '-gU', binary], capture_output=True, text=True).stdout
        names.update(line.split()[-1] for line in out.splitlines() if line.strip())
    return names


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--top', type=int, default=40)
    ap.add_argument('--apps', nargs='*',
                    default=['/System/Applications', '/System/Applications/Utilities', '/Applications'])
    ap.add_argument('--json')
    args = ap.parse_args()
    exports = finch_exports()
    uses = collections.defaultdict(set)
    apps = {}
    for name, exe in executables(args.apps):
        imports = swiftui_imports(exe)
        if not imports:
            continue
        apps[name] = (len(imports), len(imports & exports))
        for sym in imports:
            uses[sym].add(name)
    total = len(uses)
    have = sum(1 for s in uses if s in exports)
    print(f'{len(apps)} SwiftUI apps import {total} SwiftUI symbols; Finch has {have} ({100 * have // max(total, 1)}%)')
    for name, (n, h) in sorted(apps.items(), key=lambda kv: -kv[1][1] / kv[1][0]):
        print(f'  {name:28} {h:5}/{n:<5} {100 * h // n:3}%')
    missing = sorted((s for s in uses if s not in exports), key=lambda s: (-len(uses[s]), s))
    demangled = subprocess.run(['xcrun', 'swift-demangle', '--simplified', '--compact'],
                               input='\n'.join(s[1:] for s in missing[:args.top]), capture_output=True,
                               text=True).stdout.splitlines()
    print(f'\nmost imported of the {len(missing)} missing:')
    for sym, readable in zip(missing, demangled):
        print(f'  {len(uses[sym]):3}  {readable[:160]}')
    if args.json:
        with open(args.json, 'w') as f:
            json.dump({'apps': apps, 'missing': {s: sorted(uses[s]) for s in missing}}, f, indent=1)


main()
