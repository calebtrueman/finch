#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# ColorSync.framework: Finch's. Profiles (ColorSyncProfile.c) are ICC data: read from
# files or memory, or written here for the named profiles; transforms
# (ColorSyncTransform.c) convert matrix/curve, gray, Lab and XYZ profiles themselves and
# lookup-table profiles through skcms. ColorSyncConstants.c has Apple's constant values.
#   userland/ColorSync/build.sh -> build/root/System/Library/Frameworks/ColorSync.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/ColorSync"
SKCMS="${FINCH_ROOT}/build/obj/skia/libskcms.a"
[[ -f "${SKCMS}" ]] || { echo "build Skia first (userland/CoreGraphics)" >&2; exit 1; }
CFLAGS="-I${FINCH_ROOT}/build/src/skia/modules/skcms" \
"${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/ColorSync.framework/Versions/A/ColorSync 3813.3.3 1 com.apple.ColorSync 4.13.0 \
    "${HERE}/ColorSyncConstants.c" "${HERE}/ColorSyncProfile.c" "${HERE}/ColorSyncTransform.c" \
    -- -framework CoreFoundation -L"$(dirname "${SKCMS}")" -Wl,-hidden-lskcms -lc++
