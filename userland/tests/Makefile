# SPDX-License-Identifier: MIT OR Apache-2.0
# Finch userland tests, installed into the VM image as /usr/local/bin/finch-*.
OUT     ?= ../../build/userland
CC      := xcrun -sdk macosx clang
CFLAGS  := -arch arm64e -mmacosx-version-min=26.0 -O2 -Wall -Wextra -Werror
CXX     := xcrun -sdk macosx clang++

all: $(OUT)/finch-libsystem-test $(OUT)/finch-xpc-service-test $(OUT)/finch-launch-bench $(OUT)/finch-cxx-test $(OUT)/finch-objc-test $(OUT)/finch-crypto-test $(OUT)/finch-log-test $(OUT)/finch-hardened-test $(OUT)/finch-debuggee $(OUT)/finch-introspect-test $(OUT)/finch-socket-test $(OUT)/finch-cf-test $(OUT)/finch-swift-hello $(OUT)/finch-dlopen $(OUT)/finch-pam-test $(OUT)/finch-compression-test $(OUT)/finch-bridge-test $(OUT)/finch-forward-test $(OUT)/finch-foundation-test $(OUT)/finch-runtime-test $(OUT)/finch-files-test $(OUT)/finch-intl-test $(OUT)/finch-kvc-test $(OUT)/finch-data-test $(OUT)/finch-archive-test $(OUT)/finch-collections-test $(OUT)/finch-misc-test $(OUT)/finch-streams-test $(OUT)/finch-predicate-test $(OUT)/finch-documents-test $(OUT)/finch-cg-test $(OUT)/finch-cg-draw-test

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

# CoreGraphics with exact answers: geometry, transforms, paths (diff host and VM runs).
$(OUT)/finch-cg-test: cg-test.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -o $@ $< -framework CoreGraphics -framework CoreFoundation

# CoreGraphics drawing, against reference renders from Apple's CG (cg-draw-reference.bin).
$(OUT)/finch-cg-draw-test: cg-draw-test.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -o $@ $< -framework CoreGraphics -framework CoreFoundation -lz

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
	rm -f $(OUT)/finch-cg-draw-test $(OUT)/finch-cg-test $(OUT)/finch-documents-test $(OUT)/finch-predicate-test $(OUT)/finch-streams-test $(OUT)/finch-misc-test $(OUT)/finch-collections-test $(OUT)/finch-archive-test $(OUT)/finch-data-test $(OUT)/finch-kvc-test $(OUT)/finch-intl-test $(OUT)/finch-files-test $(OUT)/finch-runtime-test $(OUT)/finch-foundation-test $(OUT)/finch-forward-test $(OUT)/finch-bridge-test $(OUT)/finch-compression-test $(OUT)/finch-pam-test $(OUT)/finch-dlopen $(OUT)/finch-swift-hello $(OUT)/finch-cf-test $(OUT)/finch-socket-test $(OUT)/finch-introspect-test $(OUT)/finch-debuggee $(OUT)/finch-libsystem-test $(OUT)/finch-xpc-service-test $(OUT)/finch-launch-bench $(OUT)/finch-cxx-test $(OUT)/finch-objc-test $(OUT)/finch-crypto-test $(OUT)/finch-log-test $(OUT)/finch-hardened-test

.PHONY: all clean

$(OUT)/dispatch-watchdog-compare: dispatch-watchdog-compare.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fblocks $< -o $@

check-dispatch-watchdog: $(OUT)/dispatch-watchdog-compare
	$(OUT)/dispatch-watchdog-compare $(abspath ../../build/root/usr/lib/system/libdispatch.dylib)

.PHONY: check-dispatch-watchdog
