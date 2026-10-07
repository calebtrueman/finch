# SPDX-License-Identifier: MIT OR Apache-2.0
NAME    := libcache
VERSION := 95
SRCS    := cache.c
# os_simple_hash is libsystem_darwin's (private): link Finch's, which exports it.
LIBS     = -lsystem_kernel -lsystem_platform $(FINCH_ROOT)/build/root/usr/lib/system/libsystem_darwin.dylib -lsystem_c -lsystem_malloc -lsystem_blocks -ldispatch
include ../lib.mk

TESTBIN := $(FINCH_ROOT)/build/obj/cache/cache-compare
test: all
	@mkdir -p $(dir $(TESTBIN))
	$(CC) -arch arm64e -O1 -w -o $(TESTBIN) tests/cache-compare.c
	cp $(OUT)/$(NAME).dylib $(dir $(TESTBIN))/finch_libcache.dylib
	$(TESTBIN) $(dir $(TESTBIN))/finch_libcache.dylib

.PHONY: test
