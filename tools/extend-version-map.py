#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
# Extend dyld's VersionMap.h (the OS version sets: aligned releases across platforms) past
# the 2023 sets that AvailabilityVersions-157.2 publishes, with the 2024 and 2025 sets in
# the same derived form as tools/gen-dyld-versions.py's constants: fall = .9.1, then SU_B,
# SU_C, ... = .12.1, .13.1, ... Without them, a program built with the macOS 15 or 26 SDK
# reads as linked before the 2024 set, and frameworks take their legacy paths.
#   tools/extend-version-map.py path/to/dyld/VersionMap.h
import re
import sys

path = sys.argv[1]
s = open(path).read()
if '0x007e80901' in s:
    sys.exit(0)  # already extended
# (set year, macOS major, iOS/tvOS major, watchOS major, visionOS major, bridgeOS major, DriverKit major)
years = [(2024, 15, 18, 11, 2, 9, 24), (2025, 26, 26, 26, 26, 10, 25)]
rows = []
for year, mac, ios, watch, vision, bridge, dk in years:
    for minor, n in enumerate([9, 12, 13, 14, 15, 16, 17]):
        v = lambda major: f'0x{(major << 16) | (minor << 8):08x}'
        rows.append(f'\t{{ .set = 0x{(year << 16) | (n << 8) | 1:09x}, .bridgeos = {v(bridge)}, .driverkit = {v(dk)}, '
                    f'.ios = {v(ios)}, .macos = {v(mac)}, .tvos = {v(ios)}, .visionos = {v(vision)}, .watchos = {v(watch)} }}')
m = re.search(r'std::array<VersionSetEntry, (\d+)> sVersionMap = \{\{(.*?)\n\}\};', s, re.S)
count = int(m.group(1)) + len(rows)
body = m.group(2).rstrip() + ',\n' + ',\n'.join(rows)
s = s[:m.start()] + f'std::array<VersionSetEntry, {count}> sVersionMap = {{{{{body}\n}}}};' + s[m.end():]
open(path, 'w').write(s)
