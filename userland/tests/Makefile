# SPDX-License-Identifier: MIT OR Apache-2.0
# Finch userland tests, installed into the VM image as /usr/local/bin/finch-*.
OUT     ?= ../../build/userland
CC      := xcrun -sdk macosx clang
CFLAGS  := -arch arm64e -mmacosx-version-min=26.0 -O2 -Wall -Wextra -Werror
CXX     := xcrun -sdk macosx clang++

all: $(OUT)/finch-appkit-containers2-test $(OUT)/finch-appkit-misc2-test $(OUT)/finch-swift-runtime-test $(OUT)/finch-coreservices-test $(OUT)/finch-security-core-test $(OUT)/finch-sysconfig-core-test $(OUT)/finch-appkit-gestures-test $(OUT)/finch-appkit-controls2-test $(OUT)/finch-libsystem-test $(OUT)/finch-xpc-service-test $(OUT)/finch-launch-bench $(OUT)/finch-cxx-test $(OUT)/finch-objc-test $(OUT)/finch-crypto-test $(OUT)/finch-log-test $(OUT)/finch-hardened-test $(OUT)/finch-debuggee $(OUT)/finch-introspect-test $(OUT)/finch-socket-test $(OUT)/finch-cf-test $(OUT)/finch-swift-hello $(OUT)/finch-dlopen $(OUT)/finch-pam-test $(OUT)/finch-compression-test $(OUT)/finch-bridge-test $(OUT)/finch-forward-test $(OUT)/finch-foundation-test $(OUT)/finch-runtime-test $(OUT)/finch-files-test $(OUT)/finch-intl-test $(OUT)/finch-kvc-test $(OUT)/finch-data-test $(OUT)/finch-archive-test $(OUT)/finch-collections-test $(OUT)/finch-misc-test $(OUT)/finch-streams-test $(OUT)/finch-predicate-test $(OUT)/finch-documents-test $(OUT)/finch-cg-test $(OUT)/finch-cg-draw-test $(OUT)/finch-ct-test $(OUT)/finch-ctfonts-test $(OUT)/finch-font-replacements-test $(OUT)/finch-ws-test $(OUT)/finch-appkit-core-test $(OUT)/finch-appkit-window-test $(OUT)/finch-nib-test $(OUT)/finch-appkit-document-test $(OUT)/finch-uti-test $(OUT)/finch-quartzcore-test $(OUT)/finch-calayer-test $(OUT)/finch-cfnotify-test $(OUT)/finch-l10n-test $(OUT)/finch-appkit-containers-test $(OUT)/finch-app-test $(OUT)/apps/Hello.app/Contents/MacOS/Hello $(OUT)/finch-measurement-test $(OUT)/finch-xmlparser-test $(OUT)/finch-imageio-test $(OUT)/finch-cgpdf-test $(OUT)/finch-uifoundation-test $(OUT)/finch-appkit-draw-test $(OUT)/finch-appkit-menu-test $(OUT)/finch-appkit-menu-window-test $(OUT)/finch-appkit-controls-test $(OUT)/finch-appkit-controls-window-test $(OUT)/finch-appkit-text-test $(OUT)/finch-appkit-text-window-test $(OUT)/finch-textkit2-test $(OUT)/finch-appkit-bindings-test $(OUT)/finch-appkit-layout-test $(OUT)/finch-appkit-panels-test $(OUT)/finch-appkit-panels-window-test $(OUT)/apps/FinchXPCTest.app/Contents/MacOS/finch-nsxpc-test $(OUT)/finch-imagekit-test $(OUT)/apps/AssetsTest.app/Contents/MacOS/finch-assets-test $(OUT)/finch-appkit-tables-test $(OUT)/finch-appkit-tables-window-test $(OUT)/finch-swift-overlay-test $(OUT)/finch-rtf-test $(OUT)/finch-filecoordinator-test $(OUT)/finch-textfinder-test $(OUT)/finch-ruler-test $(OUT)/finch-textblock-test $(OUT)/finch-combine-test $(OUT)/finch-cftokenizer-test $(OUT)/finch-urlsession-test $(OUT)/finch-typedstream-test $(OUT)/finch-tiff-test

all: $(OUT)/finch-appkit-containers2-render-test $(OUT)/finch-appkit-controls2-render-test $(OUT)/finch-appkit-color-browser-render-test

# Local application lookup, Apple event values and filesystem services.
$(OUT)/finch-coreservices-test: coreservices-test.m coreservices-uttypes.inc
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -o $@ $< -framework CoreServices -framework Foundation

# Finch's supported keys, certificates and explicit unavailable-service errors.
$(OUT)/finch-security-core-test: security-core-test.c security-test-certs.inc
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -Wno-deprecated-declarations -o $@ $< -framework Security -framework CoreFoundation

# Local network state and preferences, without a running configd service.
$(OUT)/finch-sysconfig-core-test: sysconfig-core-test.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -Wno-deprecated-declarations -o $@ $< -framework SystemConfiguration -framework CoreFoundation

# Mouse gestures delivered through the view tree (Finch-only).
$(OUT)/finch-appkit-gestures-test: appkit-gestures-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fno-objc-arc -Wno-unused-parameter -Wno-deprecated-declarations -o $@ $< -framework AppKit

# Animation grouping, Touch Bar state, visual effects and small controls.
$(OUT)/finch-appkit-misc2-test: appkit-misc2-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fno-objc-arc -Wno-unused-parameter -Wno-deprecated-declarations -o $@ $< -framework AppKit -framework QuartzCore

# Search, combo, token, date and path controls, compared with Apple's.
$(OUT)/finch-appkit-controls2-test: appkit-controls2-test.m $(OUT)/appkit-controls2-test.nib
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -Wno-deprecated-declarations -o $@ $< -framework AppKit

$(OUT)/appkit-controls2-test.nib: appkit-controls2-test.xib
	@mkdir -p $(OUT)
	xcrun ibtool --compile $@ $<

# Grids, pages, drawers, popovers, rule editors, browser and color panel.
$(OUT)/finch-appkit-containers2-test: appkit-containers2-test.m appkit-color-browser-test.inc $(OUT)/appkit-containers2-test.nib $(OUT)/appkit-color-browser-test.nib
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fno-objc-arc -Wno-unused-parameter -Wno-deprecated-declarations -o $@ $< -framework AppKit

$(OUT)/appkit-containers2-test.nib: appkit-containers2-test.xib
	@mkdir -p $(OUT)
	xcrun ibtool --compile $@ $<

$(OUT)/appkit-color-browser-test.nib: appkit-color-browser-test.xib
	@mkdir -p $(OUT)
	xcrun ibtool --compile $@ $<

# Finch's drawn controls and containers, with clicks and keys.
$(OUT)/finch-appkit-controls2-render-test: appkit-controls2-render-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -Wno-deprecated-declarations -o $@ $< -framework AppKit

$(OUT)/finch-appkit-containers2-render-test: appkit-containers2-render-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fno-objc-arc -Wno-unused-parameter -Wno-deprecated-declarations -o $@ $< -framework AppKit ../../build/root/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics

$(OUT)/finch-appkit-color-browser-render-test: appkit-color-browser-render-test.m appkit-color-browser-test.inc
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fno-objc-arc -Wno-unused-parameter -Wno-unused-function -Wno-deprecated-declarations -o $@ $< -framework AppKit

$(OUT)/finch-libsystem-test: libsystem-test.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -o $@ $<
	codesign -f -s - -i org.finch.test.libsystem $@

# On the host, pass Finch's libcompression to check it against Apple's:
#   finch-compression-test build/root/usr/lib/libcompression.dylib
$(OUT)/finch-compression-test: compression-test.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -o $@ $< -lcompression

$(OUT)/finch-pam-test: pam-test.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -o $@ $< -lpam

$(OUT)/finch-dlopen: dlopen-test.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -o $@ $<

# Swift on Finch's own libswiftCore (userland/swift). Built with Xcode's
# swiftc; runs against Finch's runtime in the VM.
$(OUT)/finch-swift-hello: swift-hello.swift
	@mkdir -p $(OUT)
	xcrun -sdk macosx swiftc -target arm64e-apple-macos26.0 -O -o $@ $<
	codesign -f -s - -i org.finch.test.swift $@

$(OUT)/finch-swift-runtime-test: swift-runtime-test.swift
	@mkdir -p $(OUT)
	xcrun -sdk macosx swiftc -target arm64e-apple-macos26.0 -parse-as-library -O -o $@ $<
	codesign -f -s - -i org.finch.test.swift-runtime $@

# The Swift overlays (Foundation's and AppKit's Swift halves, /usr/lib/swift's
# overlay libraries): same output against Apple's and Finch's. On the host:
#   DYLD_FRAMEWORK_PATH=build/root/System/Library/Frameworks:build/root/System/Library/PrivateFrameworks \
#   DYLD_LIBRARY_PATH=build/root/usr/lib/swift build/userland/finch-swift-overlay-test
# It doesn't link the overlays it doesn't use (import AppKit would weakly link
# Metal's, Spatial's, ...): on the host those would come from Apple's
# cache and bring Apple's frameworks with them.
$(OUT)/finch-swift-overlay-test: swift-overlay-test.swift
	@mkdir -p $(OUT)
	xcrun -sdk macosx swiftc -target arm64e-apple-macos26.0 -O -o $@ $< \
	    $(foreach l,Metal Spatial OSLog UniformTypeIdentifiers CoreImage QuartzCore simd,-Xfrontend -disable-autolink-library -Xfrontend swift$(l))
	codesign -f -s - -i org.finch.test.swift-overlay $@

# Combine (Finch's from OpenCombine, docs/design/COMBINE.md): same output against Apple's and Finch's.
$(OUT)/finch-combine-test: combine-test.swift
	@mkdir -p $(OUT)
	xcrun -sdk macosx swiftc -target arm64e-apple-macos26.0 -parse-as-library -O -o $@ $<
	codesign -f -s - -i org.finch.test.combine $@

# CFStringTokenizer (diff Apple's run and Finch's).
$(OUT)/finch-cftokenizer-test: cftokenizer-test.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -o $@ $< -framework CoreFoundation

# CoreFoundation (Finch's in the VM, Apple's on the host: diff the two runs).
$(OUT)/finch-cf-test: cf-test.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fblocks -Wno-deprecated-declarations -o $@ $< -framework CoreFoundation -lobjc   # deprecated API is still API

# Toll-free bridging both ways, against CoreFoundation alone (diff host and VM runs).
$(OUT)/finch-bridge-test: bridge-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fno-objc-arc -fblocks -o $@ $< -framework CoreFoundation

# Message forwarding and NSInvocation (diff host and VM runs).
$(OUT)/finch-forward-test: forward-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fno-objc-arc -fblocks -Wno-unused-parameter -o $@ $< -framework CoreFoundation

# Foundation, built as apps are (ARC, literals); diff host and VM runs.
$(OUT)/finch-foundation-test: foundation-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -o $@ $< -framework Foundation

# Threads, run loops, timers, notifications, operation queues (diff host and VM runs).
$(OUT)/finch-runtime-test: runtime-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-but-set-variable -Wno-unused-parameter -o $@ $< -framework Foundation

# URLs, the file manager, bundles (diff host and VM runs).
$(OUT)/finch-files-test: files-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -o $@ $< -framework Foundation

# Locales, time zones, calendars, formatters, defaults (diff host and VM runs).
$(OUT)/finch-intl-test: intl-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -o $@ $< -framework Foundation

# Key-value coding and observing, index sets, geometry (diff host and VM runs).
$(OUT)/finch-kvc-test: kvc-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -o $@ $< -framework Foundation

# TIFF writing and reading through AppKit and ImageIO (diff host and VM runs).
$(OUT)/finch-tiff-test: tiff-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -o $@ $< -framework AppKit -framework ImageIO -lz

# NSArchiver and NSUnarchiver: typedstream bytes and an archive from macOS (diff host and VM runs).
$(OUT)/finch-typedstream-test: typedstream-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -Wno-deprecated-declarations -o $@ $< -framework Foundation

# Decimals, scanners, JSON, UUIDs, sort descriptors (diff host and VM runs).
$(OUT)/finch-data-test: data-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -o $@ $< -framework Foundation

# Keyed archiving (diff host and VM runs).
$(OUT)/finch-archive-test: archive-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -Wno-deprecated-declarations -o $@ $< -framework Foundation

# Attributed strings, regular expressions, ordered sets, pointer collections, caches.
$(OUT)/finch-collections-test: collections-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -Wno-deprecated-declarations -o $@ $< -framework Foundation

# Proxies, assertions, index paths, transforms, undo, notification queues.
$(OUT)/finch-misc-test: misc-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -Wno-deprecated-declarations -o $@ $< -framework Foundation

# Streams, ports, file handles, pipes, tasks, hosts.
$(OUT)/finch-streams-test: streams-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -Wno-deprecated-declarations -o $@ $< -framework Foundation

# Predicates and expressions.
$(OUT)/finch-predicate-test: predicate-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -Wno-format-security -o $@ $< -framework Foundation

# Progress, formatters, differences, file wrappers.
$(OUT)/finch-documents-test: documents-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -o $@ $< -framework Foundation

# Units, measurements and the measurement formatter.
$(OUT)/finch-measurement-test: measurement-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -Wno-arc-performSelector-leaks -o $@ $< -framework Foundation

# NSXMLParser over libxml2.
$(OUT)/finch-xmlparser-test: xmlparser-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -o $@ $< -framework Foundation

# CoreGraphics with exact answers: geometry, transforms, paths (diff host and VM runs).
$(OUT)/finch-cg-test: cg-test.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -Wno-deprecated-declarations -o $@ $< -framework CoreGraphics -framework CoreFoundation

# CoreGraphics drawing, against reference renders from Apple's CG (cg-draw-reference.bin).
$(OUT)/finch-cg-draw-test: cg-draw-test.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -Wno-unused-parameter -Wno-deprecated-declarations -o $@ $< -framework CoreGraphics -framework CoreFoundation -lz

# CoreGraphics PDF: writing, reading, scanning and drawing (diff host and VM runs; on the host,
# Finch's with DYLD_FRAMEWORK_PATH), and pages against Apple's renders (cgpdf-reference.bin).
$(OUT)/finch-cgpdf-test: cgpdf-test.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -Wno-unused-parameter -Wno-deprecated-declarations -o $@ $< -framework CoreGraphics -framework CoreFoundation -lz

# AppKit's drawing classes: state printed for diffing host and VM runs (on the host,
# Finch's with DYLD_FRAMEWORK_PATH), and scenes against Apple's renders (appkit-draw-reference.bin).
$(OUT)/finch-appkit-draw-test: appkit-draw-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fno-objc-arc -Wno-unused-parameter -Wno-deprecated-declarations -o $@ $< -framework AppKit -framework ImageIO -framework CoreGraphics -framework CoreFoundation -lz

# ImageIO: sources, thumbnails, incremental loading, destinations, property keys
# (diff host and VM runs; on the host, Finch's with DYLD_FRAMEWORK_PATH).
$(OUT)/finch-imageio-test: imageio-test.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -Wno-unused-parameter -Wno-deprecated-declarations -o $@ $< -framework ImageIO -framework CoreGraphics -framework CoreFoundation   # deprecated keys are still API

# CoreText: fonts, lines, runs, frames (diff host and VM runs).
$(OUT)/finch-ct-test: ct-test.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -Wno-deprecated-declarations -o $@ $< -framework CoreText -framework CoreGraphics -framework CoreFoundation

# UIFoundation (fonts, paragraph styles, string drawing) through AppKit:
# diff host runs against Apple's and Finch's (DYLD_FRAMEWORK_PATH, FINCH_FONT_DIRS),
# drawing against uifoundation-reference.bin.
$(OUT)/finch-uifoundation-test: uifoundation-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -o $@ $< -framework AppKit -framework CoreText -lz

# The fonts Finch ships and Apple's names for them. Finch-only: diff the
# output with ctfonts-expected.txt (on the host, with FINCH_FONT_DIRS set to
# build/root/System/Library/Fonts and DYLD_FRAMEWORK_PATH to build/root's).
$(OUT)/finch-ctfonts-test: ctfonts-test.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -o $@ $< -framework CoreText -framework CoreGraphics -framework CoreFoundation

# Finch-only: replacement fonts, real glyph data, system weights and missing-style fallbacks.
$(OUT)/finch-font-replacements-test: font-replacements-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -o $@ $< -framework AppKit -framework CoreText -framework CoreGraphics

# The window server and CoreGraphics' client for it (Finch-only: compare with ws-test.expected).
$(OUT)/finch-ws-test: ws-test.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -o $@ $< ../../build/root/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics -framework CoreFoundation -framework ImageIO

# AppKit's core without a screen: responders, events, views, windows, actions (diff Apple's run and Finch's).
$(OUT)/finch-appkit-core-test: appkit-core-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -Wno-deprecated-declarations -o $@ $< -framework AppKit

# AppKit on the window server, end to end (Finch-only: compare with appkit-window-test.expected).
$(OUT)/finch-appkit-window-test: appkit-window-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-deprecated-declarations -o $@ $< -framework AppKit ../../build/root/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics

# AppKit's controls and cells: state, values, actions, and a nib of controls (diff Apple's run and Finch's,
# all but the first line; on the host, Finch's with DYLD_FRAMEWORK_PATH and FINCH_FONT_DIRS).
$(OUT)/finch-appkit-controls-test: appkit-controls-test.m controls-test.xib
	@mkdir -p $(OUT)
	xcrun ibtool --compile $(OUT)/controls-test.nib controls-test.xib
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -Wno-deprecated-declarations -o $@ $< -framework AppKit

# Controls on the window server: clicks, keys, editing, drawing (Finch-only: compare with
# appkit-controls-window-test.expected).
$(OUT)/finch-appkit-controls-window-test: appkit-controls-window-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-deprecated-declarations -o $@ $< -framework AppKit -framework ImageIO ../../build/root/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics

# Text editing and scrolling without a screen, and a scroll view and text view from a nib
# (diff Apple's run and Finch's but the first line; on the host, Finch's with
# DYLD_FRAMEWORK_PATH and FINCH_FONT_DIRS).
$(OUT)/finch-appkit-text-test: appkit-text-test.m appkit-text-test.xib
	@mkdir -p $(OUT)
	xcrun ibtool --compile $(OUT)/appkit-text-test.nib appkit-text-test.xib
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -Wno-deprecated-declarations -o $@ $< -framework AppKit -framework CoreText

# A text view in a scroll view on the window server (Finch-only: compare with appkit-text-window-test.expected).
$(OUT)/finch-appkit-text-window-test: appkit-text-window-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-deprecated-declarations -o $@ $< -framework AppKit -framework CoreText ../../build/root/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics

# Alerts, open and save panels, the workspace without a screen (diff Apple's run and Finch's but the
# first line; on the host, Finch's with DYLD_FRAMEWORK_PATH and FINCH_FONT_DIRS).
$(OUT)/finch-appkit-panels-test: appkit-panels-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -Wno-deprecated-declarations -o $@ $< -framework AppKit -framework UniformTypeIdentifiers

# Alerts, sheets, open and save panels and launching on the window server (Finch-only: compare with
# appkit-panels-window-test.expected).
$(OUT)/finch-appkit-panels-window-test: appkit-panels-window-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -Wno-deprecated-declarations -o $@ $< -framework AppKit -framework UniformTypeIdentifiers -framework ImageIO ../../build/root/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics

# Tables, outline views, collection views and their bindings without a screen, and a nib of them (diff
# Apple's run and Finch's but the first line; on the host, Finch's with DYLD_FRAMEWORK_PATH, including
# PrivateFrameworks, and FINCH_FONT_DIRS).
$(OUT)/finch-appkit-tables-test: appkit-tables-test.m appkit-tables-test.xib
	@mkdir -p $(OUT)
	xcrun ibtool --compile $(OUT)/appkit-tables-test.nib appkit-tables-test.xib
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -Wno-deprecated-declarations -o $@ $< -framework AppKit

# Tables, outlines and collection views on the window server: clicks, keys, sorting, resizing, editing,
# drawing (Finch-only: compare with appkit-tables-window-test.expected).
$(OUT)/finch-appkit-tables-window-test: appkit-tables-window-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -Wno-deprecated-declarations -o $@ $< -framework AppKit -framework ImageIO ../../build/root/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics

# Cocoa bindings, the controllers and NSFontManager without a screen, and a nib of bound controls (diff
# Apple's run and Finch's but the first line; on the host, Finch's with DYLD_FRAMEWORK_PATH and FINCH_FONT_DIRS).
$(OUT)/finch-appkit-bindings-test: appkit-bindings-test.m appkit-bindings-test.xib
	@mkdir -p $(OUT)
	xcrun ibtool --compile $(OUT)/appkit-bindings-test.nib appkit-bindings-test.xib
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -Wno-deprecated-declarations -o $@ $< -framework AppKit -framework CoreText

# Auto Layout without a screen, a nib with constraints and a storyboard (diff Apple's run and Finch's
# but the first line; on the host, Finch's with DYLD_FRAMEWORK_PATH, including PrivateFrameworks).
$(OUT)/finch-appkit-layout-test: appkit-layout-test.m layout-test.xib layout-test.storyboard
	@mkdir -p $(OUT)
	xcrun ibtool --compile $(OUT)/layout-test.nib layout-test.xib
	rm -rf $(OUT)/layout-test.storyboardc
	xcrun ibtool --compile $(OUT)/layout-test.storyboardc layout-test.storyboard
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -Wno-deprecated-declarations -o $@ $< -framework AppKit

# TextKit 2 without a screen: content storage, layout and line fragments, segments, the viewport,
# selection navigation, NSTextView on TextKit 2 and its switch to TextKit 1 (diff Apple's run and
# Finch's but the first line; on the host, Finch's with DYLD_FRAMEWORK_PATH and FINCH_FONT_DIRS).
$(OUT)/finch-textkit2-test: textkit2-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -Wno-deprecated-declarations -o $@ $< -framework AppKit -framework CoreText

# Loading a nib ibtool compiles (diff Apple's run and Finch's).
$(OUT)/finch-nib-test: nib-test.m nib-test.xib
	@mkdir -p $(OUT)
	xcrun ibtool --compile $(OUT)/nib-test.nib nib-test.xib
	$(CC) $(CFLAGS) -fobjc-arc -o $@ $< -framework AppKit

# NSMenu and NSMenuItem without a screen, and a main-menu nib (diff Apple's run and Finch's).
$(OUT)/finch-appkit-menu-test: appkit-menu-test.m menu-test.xib
	@mkdir -p $(OUT)
	xcrun ibtool --compile $(OUT)/menu-test.nib menu-test.xib
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -Wno-deprecated-declarations -o $@ $< -framework AppKit

# The menu bar, menus, context menus on the window server (Finch-only: compare with appkit-menu-window-test.expected).
$(OUT)/finch-appkit-menu-window-test: appkit-menu-window-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-deprecated-declarations -o $@ $< -framework AppKit -framework ImageIO ../../build/root/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics

# Window and view controllers, documents (diff Apple's run and Finch's).
$(OUT)/finch-appkit-document-test: appkit-document-test.m doc-test.xib vc-test.xib
	@mkdir -p $(OUT)
	xcrun ibtool --compile $(OUT)/doc-test.nib doc-test.xib
	xcrun ibtool --compile $(OUT)/vc-test.nib vc-test.xib
	$(CC) $(CFLAGS) -fobjc-arc -Wno-deprecated-declarations -o $@ $< -framework AppKit

# UniformTypeIdentifiers and NSURL's resource values (diff Apple's run and Finch's).
$(OUT)/finch-uti-test: uti-test.m uti-constants.inc
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -I. -o $@ $< -framework Foundation -framework UniformTypeIdentifiers

# Asset catalogs through CoreUI and AppKit, run as AssetsTest.app with actool's catalogs of
# assets-test.xcassets (for macOS 26, 10.9 and 10.11) and a nib using them (diff Apple's run and
# Finch's but the first line; on the host, run the executable directly with DYLD_FRAMEWORK_PATH
# including PrivateFrameworks, and FINCH_FONT_DIRS). In the VM: finch-assets-test (assets-test.sh).
ASSETS_APP := $(OUT)/apps/AssetsTest.app/Contents
$(ASSETS_APP)/MacOS/finch-assets-test: assets-test.m apps/AssetsTest/Info.plist apps/AssetsTest/Extra-Info.plist apps/AssetsTest/AssetsTest.xib $(shell find assets-test.xcassets -type f)
	rm -rf $(OUT)/apps/AssetsTest.app $(OUT)/assets-actool
	mkdir -p $(ASSETS_APP)/MacOS $(ASSETS_APP)/Resources/Extra.bundle/Contents/Resources
	for t in 26.0 10.9 10.11; do \
		mkdir -p $(OUT)/assets-actool/$$t && \
		xcrun actool --compile $(OUT)/assets-actool/$$t --platform macosx --minimum-deployment-target $$t \
			--output-format human-readable-text assets-test.xcassets >/dev/null 2>&1 || exit 1; \
	done
	cp $(OUT)/assets-actool/26.0/Assets.car $(ASSETS_APP)/Resources/Assets.car
	cp $(OUT)/assets-actool/10.9/Assets.car $(ASSETS_APP)/Resources/Assets-10.9.car
	cp $(OUT)/assets-actool/10.11/Assets.car $(ASSETS_APP)/Resources/Assets-10.11.car
	cp $(OUT)/assets-actool/26.0/Assets.car $(ASSETS_APP)/Resources/Extra.bundle/Contents/Resources/Assets.car
	cp apps/AssetsTest/Extra-Info.plist $(ASSETS_APP)/Resources/Extra.bundle/Contents/Info.plist
	cp apps/AssetsTest/Info.plist $(ASSETS_APP)/Info.plist
	xcrun ibtool --compile $(ASSETS_APP)/Resources/AssetsTest.nib apps/AssetsTest/AssetsTest.xib
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -Wno-deprecated-declarations -o $@ assets-test.m -framework AppKit
	codesign -f -s - -i org.finch.test.assets $@

# Runs an app on a headless window server and drives it (Finch-only); hello-test.sh drives Hello.app.
$(OUT)/finch-app-test: app-test.c crashwatch.c crashwatch.h debugger.entitlements
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -o $@ app-test.c crashwatch.c ../../build/root/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics -framework CoreFoundation -framework ImageIO
	codesign -f -s - --entitlements debugger.entitlements $@

$(OUT)/apps/Hello.app/Contents/MacOS/Hello: apps/Hello/main.m apps/Hello/AppDelegate.m apps/Hello/MainMenu.xib apps/Hello/Info.plist
	apps/Hello/build.sh

# QuartzCore's transforms and constants (diff Apple's run and Finch's).
$(OUT)/finch-quartzcore-test: quartzcore-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -o $@ $< -framework QuartzCore -framework Foundation

# NSFileCoordinator and file presenters within a process (diff Apple's run and Finch's).
$(OUT)/finch-filecoordinator-test: filecoordinator-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -o $@ $< -framework Foundation

# The URL loading system against a loopback HTTP server (diff Apple's run and Finch's).
$(OUT)/finch-urlsession-test: urlsession-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -Wno-unused-result -o $@ $< -framework Foundation

# NSTextFinder and the find bar through NSTextView (diff Apple's run and Finch's).
$(OUT)/finch-textfinder-test: textfinder-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -o $@ $< -framework AppKit

# NSRulerView, its markers, and the text view's ruler (diff Apple's run and Finch's).
$(OUT)/finch-ruler-test: ruler-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -o $@ $< -framework AppKit

# Text blocks and tables: the model, archives, and cells side by side (diff Apple's run and Finch's).
$(OUT)/finch-textblock-test: textblock-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -o $@ $< -framework AppKit

# NSAttributedString's document formats: RTF, RTFD, plain text (diff Apple's run and Finch's).
$(OUT)/finch-rtf-test: rtf-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -o $@ $< -framework AppKit

# Bundle localization: preferred localizations, .strings and .loctable tables (diff Apple's run and Finch's).
$(OUT)/finch-l10n-test: l10n-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -o $@ $< -framework Foundation

# CFNotificationCenter's three centers (diff Apple's run and Finch's).
$(OUT)/finch-cfnotify-test: cfnotify-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -o $@ $< -framework Foundation

# Core Animation's layers, animations and transactions (diff Apple's run and Finch's).
$(OUT)/finch-calayer-test: calayer-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -o $@ $< -framework QuartzCore -framework CoreGraphics -framework Foundation

# ImageCaptureCore, ICADevices and ImageKit (through Quartz) as Image Capture uses them (diff Apple's
# run and Finch's but the first line; on the host, Finch's with DYLD_FRAMEWORK_PATH including
# build/root/System/Library/Frameworks/Quartz.framework/Frameworks, where ImageKit is, and FINCH_FONT_DIRS).
$(OUT)/finch-imagekit-test: imagekit-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -Wno-deprecated-declarations -o $@ $< -framework AppKit -framework Quartz -framework ImageCaptureCore -framework ICADevices

# NSSplitView and NSTabView (diff Apple's run and Finch's).
$(OUT)/finch-appkit-containers-test: appkit-containers-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -o $@ $< -framework AppKit

# NSXPCConnection: finch-nsxpc-test inside FinchXPCTest.app with its XPC service
# (Contents/XPCServices/org.finch.test.nsxpc.xpc). Run the app's executable: on
# macOS launchd starts the bundled service; in the VM, finch-init does
# (launchd/org.finch.test.nsxpc.plist). Diff Apple's run and Finch's.
NSXPC_APP := $(OUT)/apps/FinchXPCTest.app
NSXPC_SVC := $(NSXPC_APP)/Contents/XPCServices/org.finch.test.nsxpc.xpc
$(NSXPC_APP)/Contents/MacOS/finch-nsxpc-test: nsxpc-test.m nsxpc-service.m nsxpc-test.h apps/FinchXPCTest/Info.plist apps/FinchXPCTest/Service-Info.plist
	@mkdir -p $(NSXPC_APP)/Contents/MacOS $(NSXPC_SVC)/Contents/MacOS
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -o $(NSXPC_SVC)/Contents/MacOS/org.finch.test.nsxpc nsxpc-service.m -framework Foundation
	cp apps/FinchXPCTest/Service-Info.plist $(NSXPC_SVC)/Contents/Info.plist
	codesign -f -s - -i org.finch.test.nsxpc $(NSXPC_SVC)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-parameter -o $@ nsxpc-test.m -framework Foundation
	cp apps/FinchXPCTest/Info.plist $(NSXPC_APP)/Contents/Info.plist
	codesign -f -s - -i org.finch.test.nsxpc-client $(NSXPC_APP)

$(OUT)/finch-xpc-service-test: xpc-service-test.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fblocks -o $@ $<
	codesign -f -s - -i org.finch.test.xpc-service $@

$(OUT)/finch-launch-bench: launch-bench.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -o $@ $<
	codesign -f -s - -i org.finch.test.launch-bench $@

$(OUT)/finch-cxx-test: cxx-test.cpp
	@mkdir -p $(OUT)
	$(CXX) $(CFLAGS) -std=c++23 -o $@ $<
	codesign -f -s - -i org.finch.test.cxx $@

$(OUT)/finch-objc-test: objc-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -fobjc-exceptions -Wl,-dead_strip_dylibs -o $@ $<   # drops the implicit (unused) Foundation link
	codesign -f -s - -i org.finch.test.objc $@

$(OUT)/finch-crypto-test: crypto-test.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -o $@ $< -L$(shell xcrun --sdk macosx --show-sdk-path)/usr/lib/system -lcorecrypto
	codesign -f -s - -i org.finch.test.crypto $@

$(OUT)/finch-log-test: log-test.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fblocks -o $@ $<
	codesign -f -s - -i org.finch.test.log $@

$(OUT)/finch-hardened-test: hardened-test.c hardened.entitlements
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fblocks -o $@ $<
	codesign -f -s - -i org.finch.test.hardened --entitlements hardened.entitlements $@

$(OUT)/finch-debuggee: debuggee.c debuggee.entitlements
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -o $@ $<
	codesign -f -s - -i org.finch.test.debuggee --entitlements debuggee.entitlements $@

$(OUT)/finch-introspect-test: introspect-test.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fblocks -idirafter ../../build/sdk/include -o $@ $<
	codesign -f -s - -i org.finch.test.introspect $@

$(OUT)/finch-socket-test: socket-test.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -o $@ $<
	codesign -f -s - -i org.finch.test.socket $@

clean:
	rm -f $(OUT)/finch-appkit-containers2-render-test $(OUT)/finch-appkit-controls2-render-test $(OUT)/finch-appkit-color-browser-render-test
	rm -rf $(OUT)/finch-appkit-containers2-test $(OUT)/appkit-containers2-test.nib $(OUT)/appkit-color-browser-test.nib $(OUT)/appkit-controls2-test.nib
	rm -f $(OUT)/finch-appkit-misc2-test
	rm -f $(OUT)/finch-swift-runtime-test
	rm -f $(OUT)/finch-coreservices-test $(OUT)/finch-security-core-test $(OUT)/finch-sysconfig-core-test $(OUT)/finch-appkit-gestures-test $(OUT)/finch-appkit-controls2-test
	rm -rf $(OUT)/apps/Hello.app $(OUT)/apps/FinchXPCTest.app $(OUT)/apps/AssetsTest.app $(OUT)/assets-actool
	rm -rf $(OUT)/finch-imagekit-test $(OUT)/finch-appkit-containers-test $(OUT)/finch-quartzcore-test $(OUT)/finch-calayer-test $(OUT)/finch-cfnotify-test $(OUT)/finch-l10n-test $(OUT)/finch-app-test $(OUT)/finch-uti-test $(OUT)/finch-appkit-controls-test $(OUT)/controls-test.nib $(OUT)/finch-appkit-controls-window-test $(OUT)/finch-appkit-menu-test $(OUT)/menu-test.nib $(OUT)/finch-appkit-menu-window-test $(OUT)/finch-appkit-document-test $(OUT)/doc-test.nib $(OUT)/vc-test.nib $(OUT)/finch-nib-test $(OUT)/nib-test.nib $(OUT)/finch-appkit-draw-test $(OUT)/finch-appkit-window-test $(OUT)/finch-appkit-core-test $(OUT)/finch-uifoundation-test $(OUT)/finch-cgpdf-test $(OUT)/finch-ws-test $(OUT)/finch-ct-test $(OUT)/finch-imageio-test $(OUT)/finch-xmlparser-test $(OUT)/finch-measurement-test $(OUT)/finch-cg-draw-test $(OUT)/finch-cg-test $(OUT)/finch-documents-test $(OUT)/finch-predicate-test $(OUT)/finch-streams-test $(OUT)/finch-misc-test $(OUT)/finch-collections-test $(OUT)/finch-archive-test $(OUT)/finch-data-test $(OUT)/finch-kvc-test $(OUT)/finch-intl-test $(OUT)/finch-files-test $(OUT)/finch-runtime-test $(OUT)/finch-foundation-test $(OUT)/finch-forward-test $(OUT)/finch-bridge-test $(OUT)/finch-compression-test $(OUT)/finch-pam-test $(OUT)/finch-dlopen $(OUT)/finch-swift-hello $(OUT)/finch-cf-test $(OUT)/finch-socket-test $(OUT)/finch-introspect-test $(OUT)/finch-debuggee $(OUT)/finch-libsystem-test $(OUT)/finch-xpc-service-test $(OUT)/finch-launch-bench $(OUT)/finch-cxx-test $(OUT)/finch-objc-test $(OUT)/finch-crypto-test $(OUT)/finch-log-test $(OUT)/finch-hardened-test $(OUT)/finch-appkit-text-test $(OUT)/appkit-text-test.nib $(OUT)/finch-appkit-text-window-test $(OUT)/finch-textkit2-test $(OUT)/finch-appkit-bindings-test $(OUT)/appkit-bindings-test.nib $(OUT)/finch-appkit-layout-test $(OUT)/layout-test.nib $(OUT)/layout-test.storyboardc $(OUT)/finch-appkit-panels-test $(OUT)/finch-appkit-panels-window-test $(OUT)/finch-swift-overlay-test

.PHONY: all clean

$(OUT)/dispatch-watchdog-compare: dispatch-watchdog-compare.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fblocks $< -o $@

check-dispatch-watchdog: $(OUT)/dispatch-watchdog-compare
	$(OUT)/dispatch-watchdog-compare $(abspath ../../build/root/usr/lib/system/libdispatch.dylib)

.PHONY: check-dispatch-watchdog
