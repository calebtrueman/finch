# SPDX-License-Identifier: MIT OR Apache-2.0
# Shared rules for Finch's replacements of closed libSystem sub-libraries
# (userland/libsystem/<name>). Each Makefile sets:
#   NAME     install leaf, e.g. libsystem_featureflags
#   VERSION  Apple's current_version (from the shipped dylib)
#   SRCS     sources
#   LIBS     libSystem sub-libraries to link (default: kernel, platform, c)
#   INSTALL_DIR / UMBRELLA  for libraries outside libSystem (default
#            /usr/lib/system, -umbrella System)
# and includes this file. The dylib goes into build/root/usr/lib/system, so
# tools/vm/mkramdisk.sh installs it in place of Apple's.

FINCH_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
INSTALL_DIR ?= /usr/lib/system
UMBRELLA    ?= -umbrella System
OUT     ?= $(FINCH_ROOT)/build/root$(INSTALL_DIR)
SDKROOT := $(shell xcrun --sdk macosx --show-sdk-path)
SDK     := $(FINCH_ROOT)/build/sdk
CC      := xcrun -sdk macosx clang
LIBS    ?= -lsystem_kernel -lsystem_platform -lsystem_c
# Private headers first, as tools/build-oss.sh does for libSystem projects.
XNU_FAKEROOT := $(FINCH_ROOT)/build/xnu-work/fakeroot
PRIVATE := -I$(SDK)/override -I$(SDK)/availability \
           -I$(XNU_FAKEROOT)/System/Library/Frameworks/System.framework/Versions/B/PrivateHeaders \
           -I$(XNU_FAKEROOT)/usr/local/include
CFLAGS  := -arch arm64e -mmacosx-version-min=26.0 -O2 -Wall -Wextra -Werror \
           -fno-common -fvisibility=default $(PRIVATE) -idirafter $(SDK)/include \
           $(EXTRA_CFLAGS)
LDFLAGS := -dynamiclib -nostdlib -install_name $(INSTALL_DIR)/$(NAME).dylib \
           -current_version $(VERSION) -compatibility_version 1 $(UMBRELLA) \
           -L$(SDKROOT)/usr/lib/system -L$(SDKROOT)/usr/lib -L$(FINCH_ROOT)/build/userland/lib $(LIBS) -lcompiler_rt -ldyld

# exports.txt (Apple's export list for this library) makes the export set exact.
ifneq ($(wildcard exports.txt),)
LDFLAGS += -Wl,-exported_symbols_list,exports.txt
EXPORTS := exports.txt
endif

all: $(OUT)/$(NAME).dylib

$(OUT)/$(NAME).dylib: $(SRCS) $(HDRS) $(EXPORTS) Makefile $(FINCH_ROOT)/userland/libsystem/lib.mk
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) $(LDFLAGS) $(SRCS) -o $@
	codesign -f -s - $@

clean:
	rm -f $(OUT)/$(NAME).dylib

.PHONY: all clean
