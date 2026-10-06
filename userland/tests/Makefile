# SPDX-License-Identifier: MIT OR Apache-2.0
# Finch userland tests, installed into the VM image as /usr/local/bin/finch-*.
OUT     ?= ../../build/userland
CC      := xcrun -sdk macosx clang
CFLAGS  := -arch arm64e -mmacosx-version-min=26.0 -O2 -Wall -Wextra -Werror

all: $(OUT)/finch-libsystem-test

$(OUT)/finch-libsystem-test: libsystem-test.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -o $@ $<
	codesign -f -s - -i org.finch.test.libsystem $@

clean:
	rm -f $(OUT)/finch-libsystem-test

.PHONY: all clean
