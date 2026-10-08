# SPDX-License-Identifier: MIT OR Apache-2.0
NAME    := libquarantine
VERSION := 196.100.8
SRCS    := quarantine.c
LIBS    := -lsystem_kernel -lsystem_malloc -lsystem_platform -lsystem_pthread -lsystem_c
include ../lib.mk

TESTBIN := $(FINCH_ROOT)/build/obj/quarantine/qtn-compare
test: all
	@mkdir -p $(dir $(TESTBIN))
	$(CC) -arch arm64e -O1 -w -o $(TESTBIN) tests/qtn-compare.c
	$(TESTBIN) $(OUT)/$(NAME).dylib

.PHONY: test
