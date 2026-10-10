#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""The alias list (ld -alias_list) giving SwiftUI's extensions of SwiftUICore's structs, enums
and classes Apple's names as well as the Swift compiler's.
    extension-aliases.py OBJECT... > aliases.txt
SwiftUICore's types are named in SwiftUI's module (@_originallyDefinedIn). For a member SwiftUI
adds to one (EnvironmentValues.dismiss), Swift mangles the extension context in
(_$s7SwiftUI17EnvironmentValuesVAAE7dismiss...), Apple's SwiftUI mostly leaves it out
(_$s7SwiftUI17EnvironmentValuesV7dismiss...), and apps import that name. Both are exported.
Protocol extensions (View, Scene) keep the context in Apple's names too.
"""
import re
import subprocess
import sys

PREFIX = re.compile(r'_\$s7SwiftUI(\d+)')

names = set()
for obj in sys.argv[1:]:
    out = subprocess.run(['nm', '-gUj', obj], capture_output=True, text=True).stdout
    names.update(out.split())
for name in sorted(names):
    m = PREFIX.match(name)
    if not m:
        continue
    end = m.end() + int(m.group(1))
    if name[end:end + 1] in ('V', 'O', 'C') and name[end + 1:end + 4] == 'AAE':
        print(name, name[:end + 1] + name[end + 4:])
