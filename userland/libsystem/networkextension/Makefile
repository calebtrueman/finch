# SPDX-License-Identifier: MIT OR Apache-2.0
NAME    := libsystem_networkextension
VERSION := 1
SRCS    := networkextension.c stubs.c
# os_variant_has_internal_diagnostics is libsystem_darwin's (private): link
# Finch's, which exports it.
LIBS     = -lsystem_kernel -lsystem_platform -lsystem_c -lsystem_malloc -lsystem_blocks \
           -lsystem_notify -lsystem_trace -ldispatch -lxpc \
           $(FINCH_ROOT)/build/root/usr/lib/system/libsystem_darwin.dylib
include ../lib.mk

TESTBIN := $(FINCH_ROOT)/build/obj/networkextension/ne-compare
test: all
	@mkdir -p $(dir $(TESTBIN))
	$(CC) -arch arm64e -O1 -w -fblocks -o $(TESTBIN) tests/ne-compare.c
	$(TESTBIN) $(OUT)/$(NAME).dylib

.PHONY: test
