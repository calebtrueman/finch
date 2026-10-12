# SPDX-License-Identifier: MIT OR Apache-2.0
# Finch's pieces of dyld that Apple links from closed static libraries.
# libfinch_dyld.a goes where dyld's archive list picks up every .a
# (userland/patches/dyld, configure-dyld-archives.sh).
include ../variant.mk
OUT  ?= ../../build/userland$(V)/dyld
ROOT ?= ../../build/root$(V)
CC   := xcrun -sdk macosx clang
CFLAGS := -arch $(FINCH_ARCH) $(FINCH_VARIANT_CFLAGS) -mmacosx-version-min=26.0 -Os -Wall -Wextra -Werror \
          -I../sdk/include -fno-stack-protector -fno-builtin -fvisibility=hidden

all: $(ROOT)/usr/local/lib/dyld/libfinch_dyld.a

$(OUT)/amfi.o: amfi.c ../sdk/include/libamfi.h
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -c $< -o $@

$(OUT)/sandbox.o: sandbox.c ../sdk/include/sandbox/private.h
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -c $< -o $@

$(ROOT)/usr/local/lib/dyld/libfinch_dyld.a: $(OUT)/amfi.o $(OUT)/sandbox.o
	@mkdir -p $(dir $@)
	rm -f $@ && xcrun libtool -static -o $@ $^

.PHONY: all
