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
    'SwiftUI/View/Control/Button/ButtonStyle/TODO/BorderlessButtonStyle.swift',   # Finch's ButtonStyles.swift
    'SwiftUI/View/Control/Button/ButtonStyle/TODO/PlainButtonStyle.swift',
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
    # the first window: its content at its own size (not upstream's placeholder 500 x 300
    # frame), titled by its scene or else by the app, as Apple's untitled windows are
    ('SwiftUI/App/App/AppKit/AppKitAppDelegate.swift',
     '''        let view = items[0].value.view
        let hostingVC = NSHostingController(rootView: view.frame(width: 500, height: 300).rootEnvironment())''',
     '''        let item = items[0].value
        let hostingVC = NSHostingController(rootView: item.view.rootEnvironment())'''),
    ('SwiftUI/App/App/AppKit/AppKitAppDelegate.swift',
     '''        let windowVC = WindowController(hostingVC)
        windowVC.showWindow(nil)''',
     '''        let windowVC = WindowController(hostingVC)
        if case let .windowGroup(configuration) = item, let title = configuration.title {
            windowVC.window?.title = title._resolveText(in: EnvironmentValues())
        } else {
            windowVC.window?.title = currentAppName()
        }
        windowVC.showWindow(nil)'''),
    # centred at its laid-out size, as Apple's new windows are
    ('SwiftUI/App/App/AppKit/AppWindowsController.swift',
     '''        window = NSWindow(contentViewController: hostingVC)
        window?.center()''',
     '''        window = NSWindow(contentViewController: hostingVC)
        window?.layoutIfNeeded()
        window?.center()'''),
    ('SwiftUICore/Graphic/Color/AccentColor.swift', '// MARK: - Color + accentColor',
     'import Foundation\nimport CoreGraphics\n\n// MARK: - Color + accentColor'),
    # the system accent colour without CoreUI's asset catalogue: AppKit's control accent
    # colour (Finch's accent), looked up at run time, as SwiftUICore doesn't link AppKit
    ('SwiftUICore/Graphic/Color/AccentColor.swift',
     '''        let colorName = systemAccentValueProvider.accentColorName(value: systemAccentValue)
        guard let color = appearance(allowsVibrantBlending: nil)
            .asset(for: colorName)?
            .0
        else {
            return .blue
        }
        return Color(color)''',
     '''        _ = systemAccentValueProvider
        guard let nsColor = (NSClassFromString("NSColor") as? NSObject.Type)?
            .perform(NSSelectorFromString("controlAccentColor"))?.takeUnretainedValue() as? NSObject,
            let cgColor = nsColor.perform(NSSelectorFromString("CGColor"))?.takeUnretainedValue()
        else {
            return .blue
        }
        return Color(cgColor: cgColor as! CGColor)'''),
    # Observation's access list lives in the Swift runtime's thread-local slot for it
    # (__PTK_FRAMEWORK_SWIFT_KEY6, as swift/Threading/Impl/Darwin.h has it), which the real
    # Observation library sets while tracking; Apple's SwiftUI shares it the same way
    ('SwiftUICore/Data/Observation/ObservationUtils.swift', '// MARK: - ObservationEntry',
     '''// MARK: - _ThreadLocal

private enum _ThreadLocal {
    static let key = pthread_key_t(106)   // __PTK_FRAMEWORK_SWIFT_KEY6

    static var value: UnsafeMutableRawPointer? {
        get { pthread_getspecific(key) }
        set { pthread_setspecific(key, newValue) }
    }
}

// MARK: - ObservationEntry'''),
    # a stroked path's outline, through CoreGraphics (dashed first when the style has dashes)
    ('SwiftUICore/Shape/Path.swift',
     '''    public func strokedPath(_ style: StrokeStyle) -> Path {
        _openSwiftUIUnimplementedFailure()
    }''',
     '''    public func strokedPath(_ style: StrokeStyle) -> Path {
        var path = cgPath
        if !style.dash.isEmpty {
            path = path.copy(dashingWithPhase: style.dashPhase, lengths: style.dash)
        }
        return Path(path.copy(strokingWithWidth: style.lineWidth, lineCap: style.lineCap,
                              lineJoin: style.lineJoin, miterLimit: style.miterLimit))
    }'''),
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
            if f.endswith('.swift') and (os.sep + 'SwiftUI' in dirpath):
                # the real Observation, not OpenObservation (see build.sh); its SPI group is SwiftUI
                u = u.replace('@_spi(OpenSwiftUI)\npackage import OpenObservation', '@_spi(SwiftUI)\npackage import Observation')
                u = re.sub(r'\b(import|public import|package import) OpenObservation\b', r'\1 Observation', u)
            if u != t:
                open(path, 'w', encoding='utf-8', errors='surrogateescape').write(u)


main()
