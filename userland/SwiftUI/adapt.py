#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Adapt a copy of the OpenSwiftUI package so its modules are Apple's: OpenSwiftUI becomes SwiftUI,
OpenSwiftUICore becomes SwiftUICore (with SwiftUI's ABI name, as Apple's SwiftUICore has), so the
symbols are $s7SwiftUI... as apps import them. Its other modules keep their names.
    adapt.py PACKAGE-DIR
"""
import os
import re
import shutil
import sys

# not file names (OpenSwiftUI+NSView.h) or SPI groups the dependencies declare (@_spi(OpenSwiftUI))
MODULE = re.compile(r'(?<!@_spi\()\bOpenSwiftUI(Core)?\b(?!\+)')


# upstream files that Finch's sources replace (relative to Sources/, after the module renames)
REPLACED = [
    'SwiftUI/View/Control/Button/Button.swift',   # an empty placeholder upstream
    'SwiftUI/View/Toggle/Toggle.swift',           # resolves through unfinished toggle styles
    'SwiftUI/View/Control/Slider/SystemSliderStyle.swift',   # draws nothing upstream
]

# (file, upstream declaration, Apple's): the kind and frozenness of Apple's declarations, which
# decide every mangled name and how values are passed
KINDS = [
    ('SwiftUI/App/Scene/SceneBuilder.swift', 'public enum SceneBuilder', 'public struct SceneBuilder'),
    ('SwiftUICore/Data/Binding/Binding.swift', '@dynamicMemberLookup\npublic struct Binding<Value> {',
     '@dynamicMemberLookup\n@frozen\npublic struct Binding<Value> {'),
]


# (file, upstream code, Finch's): fixes to upstream code
FIXES = [
    # the storage type's metadata accessor was called through a C function pointer made from
    # its address, which isn't signed on arm64e: ask for the type through a generic instead
    ('SwiftUICore/Runtime/ConditionalMetadata.swift',
     '''            typealias Accessor =  @convention(c) (UInt, Metadata, Metadata) -> Metadata
            let nominal = Metadata(_ConditionalContent<Void, Void>.Storage.self).nominalDescriptor!
            let accessorRelativePointer = nominal.advanced(by: 12)
            let accessor = unsafeBitCast(
                accessorRelativePointer.advanced(by:Int(accessorRelativePointer.assumingMemoryBound(to: Int32.self).pointee)),
                to: Accessor.self
            )
            let type = accessor(0, Metadata(metadata.genericType(at: 0)), Metadata(metadata.genericType(at: 1)))
            storage = .either(type.type,''',
     '''            let type = conditionalStorageType(metadata.genericType(at: 0), metadata.genericType(at: 1))
            storage = .either(type,'''),
    ('SwiftUICore/Runtime/ConditionalMetadata.swift', '\nextension Optional {',
     '''
/// `_ConditionalContent<T, F>.Storage`, for the true and false content types.
private func conditionalStorageType(_ t: any Any.Type, _ f: any Any.Type) -> any Any.Type {
    func withTrue<T>(_: T.Type) -> any Any.Type {
        func withFalse<F>(_: F.Type) -> any Any.Type { _ConditionalContent<T, F>.Storage.self }
        return _openExistential(f, do: withFalse)
    }
    return _openExistential(t, do: withTrue)
}

extension Optional {'''),
]


def rename(m):
    return 'SwiftUICore' if m.group(1) else 'SwiftUI'


def main():
    root = sys.argv[1]
    p = os.path.join(root, 'Package.swift')
    s = open(p).read()
    s = s.replace('"-module-abi-name", "OpenSwiftUI"', '"-module-abi-name", "SwiftUI"')
    s = re.sub(r'"OpenSwiftUI(Core)?"', lambda m: '"SwiftUICore"' if m.group(1) else '"SwiftUI"', s)
    # the build switches stay OPENSWIFTUI_*, as its dependencies read them
    s = s.replace('register(domain: "SwiftUI")', 'register(domain: "OpenSwiftUI")')
    open(p, 'w').write(s)
    src = os.path.join(root, 'Sources')
    # the bridge to Apple's SwiftUI: there is none to bridge to (and the module is SwiftUI itself)
    bridge = os.path.join(src, 'OpenSwiftUIBridge', 'SwiftUI')
    if os.path.isdir(bridge):
        for f in os.listdir(bridge):
            os.remove(os.path.join(bridge, f))
        os.rmdir(bridge)
    for old, new in (('OpenSwiftUICore', 'SwiftUICore'), ('OpenSwiftUI', 'SwiftUI')):
        if os.path.isdir(os.path.join(src, old)):
            os.rename(os.path.join(src, old), os.path.join(src, new))
    # Finch's own sources (userland/SwiftUI/Finch/<module>/), and the upstream files they replace
    finch = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'Finch')
    for module in os.listdir(finch):
        if not os.path.isdir(os.path.join(finch, module)):
            continue
        dest = os.path.join(src, module, 'Finch')
        os.makedirs(dest, exist_ok=True)
        for f in os.listdir(os.path.join(finch, module)):
            if f.endswith('.swift'):
                shutil.copy(os.path.join(finch, module, f), dest)
    for rel in REPLACED:
        os.remove(os.path.join(src, rel))
    # kinds Apple's declarations have (the kind is part of every mangled name)
    for rel, old, new in KINDS + FIXES:
        path = os.path.join(src, rel)
        t = open(path).read()
        assert old in t, (rel, old)
        open(path, 'w').write(t.replace(old, new))
    for dirpath, _, files in os.walk(src):
        for f in files:
            if not f.endswith(('.swift', '.modulemap', '.c', '.h', '.m', '.cpp', '.mm')):
                continue
            path = os.path.join(dirpath, f)
            t = open(path, encoding='utf-8', errors='surrogateescape').read()
            # mangled names in strings (@_silgen_name, protocol descriptor lookups) name the modules too
            u = t.replace('15OpenSwiftUICore', '11SwiftUICore').replace('11OpenSwiftUI', '7SwiftUI')
            if f.endswith(('.swift', '.modulemap')):
                u = MODULE.sub(rename, u)
            if u != t:
                open(path, 'w', encoding='utf-8', errors='surrogateescape').write(u)


main()
