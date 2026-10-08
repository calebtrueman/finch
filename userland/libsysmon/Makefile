# SPDX-License-Identifier: MIT OR Apache-2.0
# libsysmon (sysmon.m): /usr/lib/libsysmon.dylib, as Apple ships it (exports.txt,
# version 1, libobjc and libSystem only). make check compares with Apple's.
FINCH := $(abspath ../..)
ROOT ?= $(FINCH)/build/root
OUT ?= $(FINCH)/build/obj/libsysmon
CC := xcrun -sdk macosx clang
SDK_INCLUDES := -I$(FINCH)/build/sdk/override -I$(FINCH)/build/sdk/availability \
                -idirafter $(FINCH)/build/sdk/include
CFLAGS := -arch arm64e -mmacosx-version-min=26.0 -Os -Wall -Wextra -Werror -fno-objc-arc \
          -fvisibility=hidden $(SDK_INCLUDES)
LIB := $(ROOT)/usr/lib/libsysmon.dylib

all: $(LIB)

$(LIB): sysmon.m exports.txt Makefile $(FINCH)/userland/sdk/include/sysmon.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -dynamiclib sysmon.m -lobjc \
	    -install_name /usr/lib/libsysmon.dylib -current_version 1 -compatibility_version 1 \
	    -Wl,-exported_symbols_list,exports.txt -o $@
	codesign -f -s - $@

check: $(LIB) $(OUT)/sysmon-compare
	$(OUT)/sysmon-compare $(LIB)

$(OUT)/sysmon-compare: tests/sysmon-compare.c $(FINCH)/userland/sdk/include/sysmon.h
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O1 -Wall -Wextra -Werror -fblocks $(SDK_INCLUDES) $< -o $@

.PHONY: all check
