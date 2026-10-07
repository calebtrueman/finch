# SPDX-License-Identifier: MIT OR Apache-2.0
NAME    := libsystem_featureflags
VERSION := 103
SRCS    := featureflags.c
include ../lib.mk

# Differential test against the host's Apple library, over every feature in
# the host's FeatureFlags plists.
TESTBIN := $(FINCH_ROOT)/build/obj/featureflags/ff-compare
test: all
	@mkdir -p $(dir $(TESTBIN))
	$(CC) -arch arm64e -O1 -o $(TESTBIN) tests/ff-compare.c
	python3 tests/features.py | $(TESTBIN) $(OUT)/$(NAME).dylib

.PHONY: test
