# SPDX-License-Identifier: MIT OR Apache-2.0
NAME := libsystem_sandbox
VERSION := 2680.100.174
SRCS := sandbox.c rootless.c unsupported.c
HDRS := internal.h
LIBS = -lsystem_kernel -lsystem_platform -lsystem_c -lsystem_malloc -lsystem_pthread
include ../lib.mk

TESTBIN := $(FINCH_ROOT)/build/obj/sandbox/sb-compare
$(TESTBIN): tests/sb-compare.c Makefile
	@mkdir -p $(dir $@)
	$(CC) -arch arm64e -O2 -Wall -Wextra -Werror $< -o $@

$(TESTBIN)-wire: tests/rootless-wire.c rootless.c internal.h Makefile
	@mkdir -p $(dir $@)
	$(CC) -arch arm64e -O1 -Wall -Wextra -Werror $< -o $@

check test: all $(TESTBIN) $(TESTBIN)-wire
	$(TESTBIN) $(OUT)/$(NAME).dylib
	$(TESTBIN)-wire

.PHONY: check test
