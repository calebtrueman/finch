# SPDX-License-Identifier: MIT OR Apache-2.0
# /bin/sh, the shell variant launcher (sh.c).
ROOT ?= ../../build/root
CC   := xcrun -sdk macosx clang
CFLAGS := -arch arm64e -mmacosx-version-min=26.0 -Os -Wall -Wextra -Werror

all: $(ROOT)/bin/sh

$(ROOT)/bin/sh: sh.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -o $@ $<
	codesign -f -s - -i com.apple.sh $@

.PHONY: all
