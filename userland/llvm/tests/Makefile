# SPDX-License-Identifier: MIT OR Apache-2.0
# Differential tests of Finch's LLVM runtimes against the host's (Apple's).
#   make -C userland/llvm/tests check     (after tools/build-llvm-runtimes.sh)
ROOT := ../../../build/root
OUT  := ../../../build/obj/llvm-runtimes/tests
CC   := xcrun -sdk macosx clang

check: $(OUT)/crt-compare
	@# dlopen() by a path whose install name differs from Apple's copy
	cp $(ROOT)/usr/lib/system/libcompiler_rt.dylib $(OUT)/finch_compiler_rt.dylib
	$(OUT)/crt-compare $(OUT)/finch_compiler_rt.dylib

$(OUT)/crt-compare: crt-compare.c
	@mkdir -p $(OUT)
	$(CC) -arch arm64e -O1 -Wall -Wextra -Werror -o $@ $<

.PHONY: check
