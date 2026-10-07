# SPDX-License-Identifier: MIT OR Apache-2.0
# Finch's libsystem_m (see build.sh and README.md).
#   make            build build/root/usr/lib/system/libsystem_m.dylib
#   make test       compare with Apple's on the host; judge disagreements
#   make venv       mpmath for the accuracy judge (build/obj/libm/venv)
FINCH_ROOT := $(abspath ../..)
OBJ  := $(FINCH_ROOT)/build/obj/libm
LIB  := $(FINCH_ROOT)/build/root/usr/lib/system/libsystem_m.dylib
PY   := $(OBJ)/venv/bin/python

all:
	./build.sh

test: all
	@mkdir -p $(OBJ)
	xcrun -sdk macosx clang -arch arm64e -O1 -w -o $(OBJ)/libm-compare tests/libm-compare.c
	cp $(LIB) $(OBJ)/finch_libm.dylib
	LIBM_DUMP=$(OBJ)/libm-dump.txt $(OBJ)/libm-compare $(OBJ)/finch_libm.dylib
	python3 -I tests/geometry_judge.py $(OBJ)/libm-dump.txt
	@if [ -x $(PY) ]; then $(PY) tests/judge.py $(OBJ)/libm-dump.txt --check coremath.txt; \
	else echo "(accuracy judge skipped: 'make venv' installs mpmath)"; fi

venv:
	python3 -m venv $(OBJ)/venv && $(OBJ)/venv/bin/pip install -q mpmath

.PHONY: all test venv
