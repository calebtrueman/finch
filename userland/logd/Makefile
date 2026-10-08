# SPDX-License-Identifier: MIT OR Apache-2.0
# finch-logd (the log daemon) and log(1). See docs/design/LOGD.md.
# finch-logd links libdispatch's firehose server, built by tools/build-system.sh
# (step "firehose") into build/userland/lib/libfirehose_server.a.
FINCH := $(abspath ../..)
ROOT  ?= $(FINCH)/build/root
SDK   := $(FINCH)/build/sdk
CC    := xcrun -sdk macosx clang
CFLAGS := -arch arm64e -mmacosx-version-min=26.4 -O2 -Wall -Wextra -Werror -fblocks \
          -Wno-unused-parameter -DOS_FIREHOSE_SPI=1 -idirafter $(SDK)/include -I$(SDK)/override
LIB   := $(FINCH)/build/userland/lib
SYSLIB := $(shell xcrun --sdk macosx --show-sdk-path)/usr/lib/system

all: $(ROOT)/usr/libexec/finch-logd $(ROOT)/usr/bin/log

$(ROOT)/usr/libexec/finch-logd: logd.c logstore.h $(LIB)/libfirehose_server.a
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -o $@ logd.c $(LIB)/libfirehose_server.a -lobjc \
	    -L$(SYSLIB) -lsystem_trace
	codesign -f -s - -i com.apple.logd $@

$(ROOT)/usr/bin/log: log.c logstore.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -o $@ log.c
	codesign -f -s - -i com.apple.log $@

.PHONY: all
