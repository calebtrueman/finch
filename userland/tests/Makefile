# SPDX-License-Identifier: MIT OR Apache-2.0
# Finch userland tests, installed into the VM image as /usr/local/bin/finch-*.
OUT     ?= ../../build/userland
CC      := xcrun -sdk macosx clang
CFLAGS  := -arch arm64e -mmacosx-version-min=26.0 -O2 -Wall -Wextra -Werror
CXX     := xcrun -sdk macosx clang++

all: $(OUT)/finch-libsystem-test $(OUT)/finch-xpc-service-test $(OUT)/finch-launch-bench $(OUT)/finch-cxx-test $(OUT)/finch-objc-test $(OUT)/finch-crypto-test $(OUT)/finch-log-test $(OUT)/finch-hardened-test $(OUT)/finch-debuggee $(OUT)/finch-introspect-test $(OUT)/finch-socket-test $(OUT)/finch-cf-test $(OUT)/finch-swift-hello $(OUT)/finch-dlopen $(OUT)/finch-pam-test $(OUT)/finch-compression-test $(OUT)/finch-bridge-test $(OUT)/finch-forward-test $(OUT)/finch-foundation-test $(OUT)/finch-runtime-test $(OUT)/finch-files-test $(OUT)/finch-intl-test $(OUT)/finch-kvc-test $(OUT)/finch-data-test $(OUT)/finch-archive-test $(OUT)/finch-collections-test $(OUT)/finch-misc-test $(OUT)/finch-streams-test $(OUT)/finch-predicate-test $(OUT)/finch-documents-test $(OUT)/finch-cg-test $(OUT)/finch-cg-draw-test $(OUT)/finch-ct-test $(OUT)/finch-ctfonts-test $(OUT)/finch-ws-test $(OUT)/finch-appkit-core-test $(OUT)/finch-appkit-window-test $(OUT)/finch-nib-test $(OUT)/finch-appkit-document-test $(OUT)/finch-uti-test $(OUT)/finch-quartzcore-test $(OUT)/finch-calayer-test $(OUT)/finch-cfnotify-test $(OUT)/finch-l10n-test $(OUT)/finch-appkit-containers-test $(OUT)/finch-app-test $(OUT)/apps/Hello.app/Contents/MacOS/Hello $(OUT)/finch-measurement-test $(OUT)/finch-xmlparser-test $(OUT)/finch-imageio-test $(OUT)/finch-cgpdf-test $(OUT)/finch-uifoundation-test $(OUT)/finch-appkit-draw-test $(OUT)/finch-appkit-menu-test $(OUT)/finch-appkit-menu-window-test $(OUT)/finch-appkit-controls-test $(OUT)/finch-appkit-controls-window-test $(OUT)/finch-appkit-text-test $(OUT)/finch-appkit-text-window-test $(OUT)/finch-textkit2-test $(OUT)/finch-appkit-bindings-test $(OUT)/finch-appkit-layout-test $(OUT)/finch-appkit-panels-test $(OUT)/finch-appkit-panels-window-test $(OUT)/finch-imagekit-test

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

# Runs an app on a headless window server and drives it (Finch-only); hello-test.sh drives Hello.app.
$(OUT)/finch-app-test: app-test.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -o $@ $< ../../build/root/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics -framework CoreFoundation

$(OUT)/apps/Hello.app/Contents/MacOS/Hello: apps/Hello/main.m apps/Hello/AppDelegate.m apps/Hello/MainMenu.xib apps/Hello/Info.plist
	apps/Hello/build.sh

# QuartzCore's transforms and constants (diff Apple's run and Finch's).
$(OUT)/finch-quartzcore-test: quartzcore-test.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fobjc-arc -o $@ $< -framework QuartzCore -framework Foundation

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
	rm -rf $(OUT)/apps/Hello.app
	rm -rf $(OUT)/finch-appkit-containers-test $(OUT)/finch-quartzcore-test $(OUT)/finch-calayer-test $(OUT)/finch-cfnotify-test $(OUT)/finch-l10n-test $(OUT)/finch-app-test $(OUT)/finch-uti-test $(OUT)/finch-appkit-controls-test $(OUT)/controls-test.nib $(OUT)/finch-appkit-controls-window-test $(OUT)/finch-appkit-menu-test $(OUT)/menu-test.nib $(OUT)/finch-appkit-menu-window-test $(OUT)/finch-appkit-document-test $(OUT)/doc-test.nib $(OUT)/vc-test.nib $(OUT)/finch-nib-test $(OUT)/nib-test.nib $(OUT)/finch-appkit-draw-test $(OUT)/finch-appkit-window-test $(OUT)/finch-appkit-core-test $(OUT)/finch-uifoundation-test $(OUT)/finch-cgpdf-test $(OUT)/finch-ws-test $(OUT)/finch-ct-test $(OUT)/finch-imageio-test $(OUT)/finch-xmlparser-test $(OUT)/finch-measurement-test $(OUT)/finch-cg-draw-test $(OUT)/finch-cg-test $(OUT)/finch-documents-test $(OUT)/finch-predicate-test $(OUT)/finch-streams-test $(OUT)/finch-misc-test $(OUT)/finch-collections-test $(OUT)/finch-archive-test $(OUT)/finch-data-test $(OUT)/finch-kvc-test $(OUT)/finch-intl-test $(OUT)/finch-files-test $(OUT)/finch-runtime-test $(OUT)/finch-foundation-test $(OUT)/finch-forward-test $(OUT)/finch-bridge-test $(OUT)/finch-compression-test $(OUT)/finch-pam-test $(OUT)/finch-dlopen $(OUT)/finch-swift-hello $(OUT)/finch-cf-test $(OUT)/finch-socket-test $(OUT)/finch-introspect-test $(OUT)/finch-debuggee $(OUT)/finch-libsystem-test $(OUT)/finch-xpc-service-test $(OUT)/finch-launch-bench $(OUT)/finch-cxx-test $(OUT)/finch-objc-test $(OUT)/finch-crypto-test $(OUT)/finch-log-test $(OUT)/finch-hardened-test $(OUT)/finch-appkit-text-test $(OUT)/appkit-text-test.nib $(OUT)/finch-appkit-text-window-test $(OUT)/finch-textkit2-test $(OUT)/finch-appkit-bindings-test $(OUT)/appkit-bindings-test.nib $(OUT)/finch-appkit-layout-test $(OUT)/layout-test.nib $(OUT)/layout-test.storyboardc $(OUT)/finch-appkit-panels-test $(OUT)/finch-appkit-panels-window-test $(OUT)/finch-imagekit-test

.PHONY: all clean

$(OUT)/dispatch-watchdog-compare: dispatch-watchdog-compare.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fblocks $< -o $@

check-dispatch-watchdog: $(OUT)/dispatch-watchdog-compare
	$(OUT)/dispatch-watchdog-compare $(abspath ../../build/root/usr/lib/system/libdispatch.dylib)

.PHONY: check-dispatch-watchdog
