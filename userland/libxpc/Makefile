# SPDX-License-Identifier: MIT OR Apache-2.0
# Finch libxpc. See docs/design/XPC.md.
#
#   make            -> build/userland/libxpc/libxpc.dylib   (arm64e, for the VM image)
#   make test       -> host unit tests against an arm64 test build
#
# Needs build/sdk (tools/mksdk.sh) for libdispatch's private os_object headers.

ROOT    := $(abspath ../..)
OUT     := $(ROOT)/build/userland/libxpc
SDK     := $(ROOT)/build/sdk
SDKROOT := $(shell xcrun --sdk macosx --show-sdk-path)
CC      := xcrun -sdk macosx clang

SRCS    := object.m values.c array.c dictionary.c error.c description.c serialize.c ports.c message.c pipe.c connection.c bootstrap.c
HDRS    := internal.h

COMMON  := -mmacosx-version-min=26.0 -O2 -g -fblocks -fno-objc-arc \
           -fvisibility=default -Wall -Wextra -Wno-unused-parameter \
           -Wno-tautological-pointer-compare -Wno-nonnull \
           -I$(SDK)/override -I$(SDK)/availability -idirafter $(SDK)/include
LIBS    := -L$(SDKROOT)/usr/lib/system -lsystem_kernel -lsystem_platform \
           -lsystem_pthread -lsystem_malloc -lsystem_c -lsystem_blocks \
           -ldispatch -lcompiler_rt -lobjc

VERSION := 3102.100.102

all: $(OUT)/libxpc.dylib

# The VM library: arm64e, part of the libSystem umbrella.
$(OUT)/libxpc.dylib: $(SRCS) $(HDRS) Makefile
	@mkdir -p $(OUT)
	$(CC) -arch arm64e $(COMMON) -dynamiclib -nodefaultlibs \
	    -install_name /usr/lib/system/libxpc.dylib -umbrella System \
	    -compatibility_version 1 -current_version $(VERSION) \
	    $(SRCS) $(LIBS) -o $@
	codesign -f -s - $@

# Host test build: arm64, @rpath install name, loaded next to the system libxpc
# (stderr is dropped in `make test`: the ObjC runtime warns about the duplicate
# OS_xpc_* classes, which is expected there).
$(OUT)/test/libxpc-finch.dylib: $(SRCS) $(HDRS) Makefile
	@mkdir -p $(OUT)/test
	$(CC) -arch arm64 $(COMMON) -dynamiclib \
	    -install_name @rpath/libxpc-finch.dylib $(SRCS) -lobjc -o $@

$(OUT)/test/xpc-test: tests/xpc-test.c $(OUT)/test/libxpc-finch.dylib
	$(CC) -arch arm64 -mmacosx-version-min=26.0 -O1 -g -fblocks -Wall \
	    -Wno-incompatible-pointer-types-discards-qualifiers \
	    tests/xpc-test.c -L$(OUT)/test -lxpc-finch -lobjc -Wl,-rpath,$(OUT)/test -o $@

$(OUT)/test/serial-test: tests/serial-test.c $(OUT)/test/libxpc-finch.dylib
	$(CC) -arch arm64 -mmacosx-version-min=26.0 -O1 -g -fblocks -Wall \
	    tests/serial-test.c -L$(OUT)/test -lxpc-finch -lobjc -Wl,-rpath,$(OUT)/test -o $@

$(OUT)/test/interop-test: tests/interop-test.c $(OUT)/test/libxpc-finch.dylib
	$(CC) -arch arm64 -mmacosx-version-min=26.0 -O1 -g -fblocks -Wall \
	    -Wno-incompatible-pointer-types-discards-qualifiers \
	    tests/interop-test.c -L$(OUT)/test -lxpc-finch -lobjc -Wl,-rpath,$(OUT)/test -o $@

$(OUT)/test/conn-test: tests/conn-test.c $(OUT)/test/libxpc-finch.dylib
	$(CC) -arch arm64 -mmacosx-version-min=26.0 -O1 -g -fblocks -Wall \
	    -Wno-incompatible-pointer-types-discards-qualifiers \
	    tests/conn-test.c -L$(OUT)/test -lxpc-finch -lobjc -Wl,-rpath,$(OUT)/test -o $@

test: $(OUT)/test/xpc-test $(OUT)/test/serial-test $(OUT)/test/interop-test $(OUT)/test/conn-test
	$(OUT)/test/xpc-test 2>/dev/null
	$(OUT)/test/serial-test tests/fixtures/apple-25E253.txt 2>/dev/null
	$(OUT)/test/interop-test 2>/dev/null
	$(OUT)/test/conn-test 2>/dev/null

clean:
	rm -rf $(OUT)

.PHONY: all test clean

# Same tests under AddressSanitizer + UndefinedBehaviorSanitizer: the wire
# decoder parses data from other processes, so out-of-bounds reads must fail
# loudly, not silently.
ASAN    := $(OUT)/asan
SANFLAGS := -fsanitize=address,undefined -fno-omit-frame-pointer -O1

asan: $(SRCS) $(HDRS) tests/xpc-test.c tests/serial-test.c
	@mkdir -p $(ASAN)
	$(CC) -arch arm64 $(COMMON) $(SANFLAGS) -dynamiclib \
	    -install_name @rpath/libxpc-finch.dylib $(SRCS) -lobjc -o $(ASAN)/libxpc-finch.dylib
	for t in xpc-test serial-test interop-test conn-test; do \
	    $(CC) -arch arm64 -mmacosx-version-min=26.0 -g -fblocks $(SANFLAGS) \
	        -Wno-incompatible-pointer-types-discards-qualifiers tests/$$t.c \
	        -L$(ASAN) -lxpc-finch -lobjc -Wl,-rpath,$(ASAN) -o $(ASAN)/$$t || exit 1; \
	done
	$(ASAN)/xpc-test 2>&1 | grep -v '^objc\['
	$(ASAN)/serial-test tests/fixtures/apple-25E253.txt 2>&1 | grep -v '^objc\['
	$(ASAN)/interop-test 2>&1 | grep -v '^objc\['

.PHONY: asan
