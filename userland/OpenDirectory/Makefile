# SPDX-License-Identifier: MIT OR Apache-2.0
# OpenDirectory.framework, laid out as Apple's: the C API lives in
# Versions/A/Frameworks/CFOpenDirectory.framework, which OpenDirectory
# re-exports (its Objective-C API comes later). Finch's implementation:
# CFOpenDirectory.c.
FINCH_ROOT := $(abspath ../..)
ROOT    ?= $(FINCH_ROOT)/build/root
OBJ     := $(FINCH_ROOT)/build/obj/OpenDirectory
SDKROOT := $(shell xcrun --sdk macosx --show-sdk-path)
CC      := xcrun -sdk macosx clang
FW      := $(ROOT)/System/Library/Frameworks/OpenDirectory.framework
CFOD    := $(FW)/Versions/A/Frameworks/CFOpenDirectory.framework
CFSRC   := $(FINCH_ROOT)/build/src/swift-corelibs-foundation/Sources/CoreFoundation/include
CFLAGS  := -arch arm64e -mmacosx-version-min=26.0 -O2 -Wall -Wextra -Werror -fblocks \
           -F$(SDKROOT)/System/Library/Frameworks/OpenDirectory.framework/Frameworks -I$(OBJ)/hdr

all: $(FW)/Versions/A/OpenDirectory

# CF's private <CoreFoundation/CFRuntime.h>, from the source Finch's CoreFoundation is built from.
$(OBJ)/hdr/CoreFoundation/CFRuntime.h: $(CFSRC)/CFRuntime.h
	@mkdir -p $(dir $@)
	sed -E 's|#include "(CF[A-Za-z]+\.h)"|#include <CoreFoundation/\1>|' $< > $@

$(CFOD)/Versions/A/CFOpenDirectory: CFOpenDirectory.c $(OBJ)/hdr/CoreFoundation/CFRuntime.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -dynamiclib -o $@ CFOpenDirectory.c \
	    -install_name /System/Library/Frameworks/OpenDirectory.framework/Versions/A/Frameworks/CFOpenDirectory.framework/Versions/A/CFOpenDirectory \
	    -current_version 1.0.0 -compatibility_version 1.0.0 -framework CoreFoundation
	ln -sfn A $(CFOD)/Versions/Current
	ln -sfn Versions/Current/CFOpenDirectory $(CFOD)/CFOpenDirectory
	$(FINCH_ROOT)/tools/mkframeworkplist.sh $(CFOD) A CFOpenDirectory com.apple.CFOpenDirectory CFOpenDirectory 26.4 666.100.1 English
	codesign -f -s - $@ 2>/dev/null

$(FW)/Versions/A/OpenDirectory: $(CFOD)/Versions/A/CFOpenDirectory
	@mkdir -p $(OBJ)
	echo 'int finch_opendirectory_placeholder;' | $(CC) -arch arm64e -mmacosx-version-min=26.0 -x c -c - -o $(OBJ)/od.o
	$(CC) -arch arm64e -mmacosx-version-min=26.0 -dynamiclib -o $@ $(OBJ)/od.o \
	    -install_name /System/Library/Frameworks/OpenDirectory.framework/Versions/A/OpenDirectory \
	    -current_version 1.0.0 -compatibility_version 1.0.0 -Wl,-reexport_library,$< -Wl,-unexported_symbol,_finch_opendirectory_placeholder
	ln -sfn A $(FW)/Versions/Current
	ln -sfn Versions/Current/OpenDirectory $(FW)/OpenDirectory
	$(FINCH_ROOT)/tools/mkframeworkplist.sh $(FW) A OpenDirectory com.apple.OpenDirectory OpenDirectory 26.4 666.100.1 English
	codesign -f -s - $@ 2>/dev/null

clean:
	rm -rf $(FW) $(OBJ)
.PHONY: all clean
