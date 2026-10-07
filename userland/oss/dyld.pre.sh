#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Before building dyld/libdyld: headers Apple's internal SDK has. Runs in the
# dyld source tree (tools/build-oss.sh).
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GEN="${FINCH_ROOT}/build/obj/dyld-generated"
mkdir -p "${GEN}/System"
# <System/atexit.h>: Libc's private atexit structures (APSL, Libc source).
ln -sf "${FINCH_ROOT}/build/src/Libc/stdlib/FreeBSD/atexit.h" "${GEN}/System/atexit.h"
# The cache builder's generated headers (PREBUILTLOADER_VERSION must match).
[[ -s "${FINCH_ROOT}/build/obj/dsc-builder/generated/PrebuiltLoader_version.h" ]] \
    || "${FINCH_ROOT}/tools/dsc/build-builder.sh" >/dev/null
# Finch's static archives dyld links (libcorecrypto_static.a).
make -s -C "${FINCH_ROOT}/userland/corecrypto"
make -s -C "${FINCH_ROOT}/userland/dyld"
