# SPDX-License-Identifier: MIT OR Apache-2.0
# Compare the libbsm interfaces Finch adds (finch_compat.c) with Apple's.
# The library itself builds with tools/build-oss.sh OpenBSM bsm.0.
FINCH := $(abspath ../../..)
OUT ?= $(FINCH)/build/obj/OpenBSM-tests
CC := xcrun -sdk macosx clang

check: $(OUT)/bsm-compare
	$(OUT)/bsm-compare $(FINCH)/build/root/usr/lib/libbsm.0.dylib

$(OUT)/bsm-compare: tests/bsm-compare.c
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O1 -Wall -Wextra -Werror -Wno-deprecated-declarations $< -o $@

.PHONY: check
