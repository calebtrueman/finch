# SPDX-License-Identifier: MIT OR Apache-2.0
# Finch userland tests, installed into the VM image as /usr/local/bin/finch-*.
OUT     ?= ../../build/userland
CC      := xcrun -sdk macosx clang
CFLAGS  := -arch arm64e -mmacosx-version-min=26.0 -O2 -Wall -Wextra -Werror
CXX     := xcrun -sdk macosx clang++

all: $(OUT)/finch-libsystem-test $(OUT)/finch-xpc-service-test $(OUT)/finch-launch-bench $(OUT)/finch-cxx-test

$(OUT)/finch-libsystem-test: libsystem-test.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -o $@ $<
	codesign -f -s - -i org.finch.test.libsystem $@

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

clean:
	rm -f $(OUT)/finch-libsystem-test $(OUT)/finch-xpc-service-test $(OUT)/finch-launch-bench $(OUT)/finch-cxx-test

.PHONY: all clean
