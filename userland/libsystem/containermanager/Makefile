# SPDX-License-Identifier: MIT OR Apache-2.0
NAME    := libsystem_containermanager
VERSION := 1
SRCS    := containermanager.c seams.c stubs.c
HDRS    := errors.h
# The seam tables point into every library Apple's does (dirstat_np is
# libsystem_darwin's, private: link Finch's, which exports it).
LIBS     = -lsystem_kernel -lsystem_platform -lsystem_c -lsystem_malloc -lsystem_blocks \
           -lsystem_info -lsystem_notify -lsystem_sandbox -ldispatch -lxpc -lcopyfile \
           -lremovefile -lquarantine $(FINCH_ROOT)/build/root/usr/lib/system/libsystem_darwin.dylib
include ../lib.mk

TESTBIN := $(FINCH_ROOT)/build/obj/containermanager/cm-compare
test: all
	@mkdir -p $(dir $(TESTBIN))
	$(CC) -arch arm64e -O1 -w -fblocks -o $(TESTBIN) tests/cm-compare.c
	@# containermanagerd keys "this process's container" by code-signing
	@# identifier: use one that has never had a container.
	codesign -f -s - -i org.finch.cm-compare.never-contained $(TESTBIN)
	$(TESTBIN) $(OUT)/$(NAME).dylib

.PHONY: test
