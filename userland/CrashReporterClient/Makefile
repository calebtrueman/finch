# SPDX-License-Identifier: MIT OR Apache-2.0
# libCrashReporterClient.a for Apple open-source projects that link it.
# tools/build-oss.sh adds $(OUT) to their library search path.
OUT     ?= ../../build/userland/lib
CC      := xcrun -sdk macosx clang
CFLAGS  := -arch arm64e -arch arm64 -arch x86_64 -mmacosx-version-min=26.0 -O2 -Wall -Wextra -Werror

all: $(OUT)/libCrashReporterClient.a

$(OUT)/libCrashReporterClient.a: CrashReporterClient.c CrashReporterClient.h
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -c -o $(OUT)/CrashReporterClient.o CrashReporterClient.c
	rm -f $@
	xcrun libtool -static -o $@ $(OUT)/CrashReporterClient.o
	rm -f $(OUT)/CrashReporterClient.o

clean:
	rm -f $(OUT)/libCrashReporterClient.a

.PHONY: all clean
