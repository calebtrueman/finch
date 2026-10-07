# SPDX-License-Identifier: MIT OR Apache-2.0
# Finch developer tools, installed into the VM image as /usr/local/bin/*.
OUT     ?= ../../build/userland
CC      := xcrun -sdk macosx clang
CFLAGS  := -arch arm64e -mmacosx-version-min=26.0 -O2 -Wall -Wextra -Werror

all: $(OUT)/finch-trace $(OUT)/finch-images

$(OUT)/finch-trace: finch-trace.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -o $@ $<
	codesign -f -s - -i org.finch.trace $@

$(OUT)/finch-images: finch-images.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -o $@ $<
	codesign -f -s - -i org.finch.images $@

clean:
	rm -f $(OUT)/finch-trace $(OUT)/finch-images

.PHONY: all clean
