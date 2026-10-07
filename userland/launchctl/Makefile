# SPDX-License-Identifier: MIT OR Apache-2.0
# launchctl: installed as /bin/launchctl in the VM image (as on macOS).
OUT     ?= ../../build/userland
CC      := xcrun -sdk macosx clang
CFLAGS  := -arch arm64e -mmacosx-version-min=26.0 -O2 -Wall -Wextra -Werror -fblocks

all: $(OUT)/launchctl

$(OUT)/launchctl: launchctl.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -o $@ $<
	codesign -f -s - -i org.finch.launchctl $@

clean:
	rm -f $(OUT)/launchctl

.PHONY: all clean
