#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Pre-build step for libdispatch (run by tools/build-oss.sh in the source
# tree): generate the DTrace provider header, as Apple's build does.
set -euo pipefail
dtrace -h -s src/provider.d -o src/provider.h
