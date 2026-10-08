# SPDX-License-Identifier: MIT OR Apache-2.0
# finch-init: built with the host Xcode toolchain against the macOS SDK.
# arm64e matches the rest of the Darwin userland; it runs as a platform binary
# because tools/vm/mkramdisk.sh adds its cdhash to the trust cache.

OUT     ?= ../../build/userland
CC      := xcrun -sdk macosx clang
CFLAGS  := -arch arm64e -mmacosx-version-min=26.0 -O2 -Wall -Wextra -Werror

all: $(OUT)/finch-init

# finch_xpc_pipe_request_routine is Finch libxpc SPI, absent from the SDK's
# libxpc stubs: resolved at load time from /usr/lib/system/libxpc.dylib.
SPI     := -Wl,-U,_finch_xpc_pipe_request_routine

SRCS    := finch-init.c bootstrapd.c jobs.c triggers.c

$(OUT)/finch-init: $(SRCS) banner_art.h bootstrapd.h jobs.h triggers.h
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) $(SPI) -o $@ $(SRCS)
	codesign -f -s - -i org.finch.init $@

clean:
	rm -f $(OUT)/finch-init

.PHONY: all clean
