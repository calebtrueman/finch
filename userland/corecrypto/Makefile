# SPDX-License-Identifier: MIT OR Apache-2.0
# Finch's corecrypto pieces. libcorecrypto_static.a: the digests dyld links
# statically (installed where dyld's archive list expects it).
OUT  ?= ../../build/userland/corecrypto
ROOT ?= ../../build/root
CC   := xcrun -sdk macosx clang
CFLAGS := -arch arm64e -mmacosx-version-min=26.0 -Os -Wall -Wextra -Werror -Iinclude \
          -fno-stack-protector -fno-builtin -fvisibility=hidden

all: $(ROOT)/usr/local/lib/libcorecrypto_static.a

$(OUT)/digest.o: digest.c include/corecrypto/*.h
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -c $< -o $@

$(ROOT)/usr/local/lib/libcorecrypto_static.a: $(OUT)/digest.o
	@mkdir -p $(dir $@)
	rm -f $@ && xcrun libtool -static -o $@ $^

check: $(OUT)/digest.o
	$(CC) -arch arm64e -O1 -Wall -Wextra -Werror -Iinclude -o $(OUT)/digest-compare tests/digest-compare.c $(OUT)/digest.o
	$(OUT)/digest-compare

.PHONY: all check
