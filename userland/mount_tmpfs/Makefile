# SPDX-License-Identifier: MIT OR Apache-2.0
# mount_tmpfs (mount_tmpfs.c), installed where macOS keeps it; /sbin/mount_tmpfs
# links to it.
FINCH := $(abspath ../..)
ROOT ?= $(FINCH)/build/root
CC   := xcrun -sdk macosx clang
CFLAGS := -arch arm64e -mmacosx-version-min=26.0 -Os -Wall -Wextra -Werror \
          -idirafter $(FINCH)/build/src/libutil
DEST := $(ROOT)/System/Library/Filesystems/tmpfs.fs/Contents/Resources/mount_tmpfs

all: $(DEST)

$(DEST): mount_tmpfs.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -o $@ $< -lutil
	codesign -f -s - -i com.apple.mount_tmpfs $@

.PHONY: all
