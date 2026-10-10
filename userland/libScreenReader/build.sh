#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# /usr/lib/libScreenReader.dylib: Finch's (ScreenReader.c).
#   userland/libScreenReader/build.sh -> build/root/usr/lib/libScreenReader.dylib
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec "${FINCH_ROOT}/tools/build-small-framework.sh" /usr/lib/libScreenReader.dylib 1 1 - 1.0 \
    "${FINCH_ROOT}/userland/libScreenReader/ScreenReader.c"
