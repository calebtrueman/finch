#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# QuartzCore.framework (Core Animation): Finch's own, compiled against the
# SDK's headers. So far the CATransform3D functions, CACurrentMediaTime and
# the string constants; layers and animation are next.
#
# Linked as Apple ships it: Versions/A, current version 1195.9, compatibility version 1.2.
#
#   userland/QuartzCore/build.sh -> build/root/System/Library/Frameworks/QuartzCore.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/QuartzCore"
OBJ="${FINCH_ROOT}/build/obj/QuartzCore"
ROOT="${FINCH_ROOT}/build/root"
FW="${ROOT}/System/Library/Frameworks/QuartzCore.framework"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun -f clang)"
log() { echo "==> $*"; }

CFLAGS=(-arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -Os -g -fno-objc-arc -fblocks -fno-common
    -Wall -Wextra -Werror -Wno-unused-parameter -Wno-incomplete-implementation -Wno-objc-property-implementation
    -Wno-nullability -Wno-deprecated-declarations -I"${HERE}")

log "compiling"
rm -rf "${OBJ}" && mkdir -p "${OBJ}"
for f in "${HERE}"/*.m; do
    "${CC}" "${CFLAGS[@]}" -c "$f" -o "${OBJ}/$(basename "${f%.m}").o"
done

log "linking"
mkdir -p "${FW}/Versions/A"
"${CC}" -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib \
    -install_name /System/Library/Frameworks/QuartzCore.framework/Versions/A/QuartzCore \
    -current_version 1195.9 -compatibility_version 1.2 "${OBJ}"/*.o -o "${FW}/Versions/A/QuartzCore" \
    -F"${ROOT}/System/Library/Frameworks" -framework Foundation -framework CoreFoundation -framework CoreGraphics -lobjc
ln -sfn A "${FW}/Versions/Current"
ln -sfn Versions/Current/QuartzCore "${FW}/QuartzCore"
"${FINCH_ROOT}/tools/mkframeworkplist.sh" "${FW}" A QuartzCore com.apple.QuartzCore QuartzCore 1.11 1195.9 English
codesign -f -s - -i com.apple.QuartzCore "${FW}/Versions/A/QuartzCore" 2>/dev/null
log "installed ${FW#"${FINCH_ROOT}/"}"
