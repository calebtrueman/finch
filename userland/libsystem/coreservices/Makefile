# SPDX-License-Identifier: MIT OR Apache-2.0
# libsystem_coreservices: per-user directories (dirhelper) and sysdir search
# paths. _dirhelper.c and NSSystemDirectories.c are APSL 2.0 (Libc-997.90.3).
NAME    := libsystem_coreservices
VERSION := 129
SRCS    := _dirhelper.c NSSystemDirectories.c finch_coreservices.c
HDRS    := dirhelper_priv.h NSSystemDirectories.h
LIBS    := -lsystem_kernel -lsystem_platform -lsystem_c -lsystem_pthread -lsystem_malloc \
           -lsystem_info -lsystem_blocks -lxpc -lCrashReporterClient
EXTRA_CFLAGS := -I. -Wno-unused-parameter -Wno-sign-compare -Wno-missing-field-initializers -Wno-gcc-compat
include ../lib.mk

# Differential tests against the host's Apple library.
TESTDIR := $(FINCH_ROOT)/build/obj/coreservices
test: all
	@mkdir -p $(TESTDIR)
	$(CC) -arch arm64e -O1 -o $(TESTDIR)/sysdir-compare tests/sysdir-compare.c
	$(CC) -arch arm64e -O1 -o $(TESTDIR)/dirhelper-compare tests/dirhelper-compare.c
	$(TESTDIR)/sysdir-compare $(OUT)/$(NAME).dylib
	$(TESTDIR)/dirhelper-compare $(OUT)/$(NAME).dylib | tail -1

.PHONY: test
