#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Symbolize the "crash:" backtrace finch-app-test prints when an app crashes (in the VM, over
the console), with the build products the image was made from.
    tools/vm/symbolize-crash.py CONSOLE-LOG
A frame's image is found on the host through tools/vm/overlay.txt (the file it was copied
from) or else build/root (the Finch root the image holds).
"""
import os
import re
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))


def overlay_map():
    paths = {}
    with open(os.path.join(ROOT, 'tools', 'vm', 'overlay.txt')) as f:
        for line in f:
            parts = line.split()
            if len(parts) == 2 and not line.startswith('#'):
                paths[parts[1]] = os.path.join(ROOT, parts[0])
    return paths


def host_path(path, overlay):
    if path in overlay:
        return overlay[path]
    candidate = os.path.join(ROOT, 'build', 'root', path.lstrip('/'))
    return candidate if os.path.exists(candidate) else None


def text_address(binary):
    """The __TEXT segment's address, which atos takes as the load address."""
    out = subprocess.run(['xcrun', 'otool', '-arch', 'arm64e', '-l', binary], capture_output=True, text=True).stdout
    m = re.search(r'segname __TEXT\s+vmaddr (0x[0-9a-f]+)', out)
    return int(m.group(1), 16) if m else 0


def cache_images():
    """The shared cache's images and their (unslid) __TEXT ranges, from its map file, and
    the cache's unslid base."""
    images, base, current = [], None, None
    path = os.path.join(ROOT, 'build', 'vm', 'dyld_shared_cache_arm64e.map')
    if not os.path.exists(path):
        return images, 0
    for line in open(path):
        m = re.match(r'mapping\s+\S+\s+\S+\s+(0x[0-9A-Fa-f]+)', line)
        if m and base is None:
            base = int(m.group(1), 16)
        if line.startswith('/'):
            current = line.strip()
        m = re.match(r'\s+__TEXT (0x[0-9A-Fa-f]+) -> (0x[0-9A-Fa-f]+)', line)
        if m and current:
            images.append((int(m.group(1), 16), int(m.group(2), 16), current))
    return images, base or 0


def main():
    overlay = overlay_map()
    images, unslid_base = cache_images()
    cache_start = cache_size = 0
    frame = re.compile(r'crash:\s+(\d+)\s+(0x[0-9a-f]+)\s+(\S+) \+ (0x[0-9a-f]+)')
    bare = re.compile(r'crash:\s+(\d+)\s+(0x[0-9a-f]+)\s*$')
    for line in open(sys.argv[1], errors='replace'):
        m = re.search(r'crash: shared cache (0x[0-9a-f]+) size (0x[0-9a-f]+)', line)
        if m:
            cache_start, cache_size = int(m.group(1), 16), int(m.group(2), 16)
        m = frame.search(line)
        if not m:
            b = bare.search(line)
            if b and cache_start <= int(b.group(2), 16) < cache_start + cache_size:
                # in the shared cache: its image from the cache's map
                address = int(b.group(2), 16) - cache_start + unslid_base
                hit = next((im for im in images if im[0] <= address < im[1]), None)
                if hit:
                    m = re.match(r'(.*)', f'crash: {b.group(1)} {b.group(2)} {hit[2]} + {address - hit[0]:#x}')
                    m = frame.search(m.group(1))
            if not m:
                if 'crash:' in line:
                    print(line.rstrip())
                continue
        index, path, offset = m.group(1), m.group(3), int(m.group(4), 16)
        binary = host_path(path, overlay)
        symbol = '?'
        if binary:
            base = text_address(binary)
            symbol = subprocess.run(['xcrun', 'atos', '-arch', 'arm64e', '-o', binary, '-l', hex(base),
                                     hex(base + offset)], capture_output=True, text=True).stdout.strip()
        print(f'{index:>3}  {os.path.basename(path)} + {offset:#x}  {symbol}')


main()
