#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# ImageCaptureCore.framework: Finch's own, compiled against the SDK's headers:
# ICDeviceBrowser (which finds no devices: Finch has no camera or scanner
# support yet), the device, camera item and scanner classes, and the string
# constants with Apple's values.
#
# Linked as Apple ships it: Versions/A, current version 1, compatibility version 1.
#
#   userland/ImageCaptureCore/build.sh -> build/root/System/Library/Frameworks/ImageCaptureCore.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/ImageCaptureCore"
OBJ="${FINCH_ROOT}/build/obj/ImageCaptureCore"
ROOT="${FINCH_ROOT}/build/root"
FW="${ROOT}/System/Library/Frameworks/ImageCaptureCore.framework"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun -f clang)"
log() { echo "==> $*"; }

[[ -f "${ROOT}/System/Library/Frameworks/Foundation.framework/Foundation" ]] || { echo "build Foundation first" >&2; exit 1; }

CFLAGS=(-arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -Os -g -fno-objc-arc -fobjc-exceptions -fblocks -fno-common
    -Wall -Wextra -Werror -Wno-unused-parameter -Wno-objc-property-implementation -Wno-nullability -I"${HERE}")

log "compiling"
rm -rf "${OBJ}" && mkdir -p "${OBJ}"
for f in "${HERE}"/*.m; do
    "${CC}" "${CFLAGS[@]}" -c "$f" -o "${OBJ}/$(basename "${f%.m}").o"
done

log "linking"
mkdir -p "${FW}/Versions/A"
"${CC}" -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib \
    -install_name /System/Library/Frameworks/ImageCaptureCore.framework/Versions/A/ImageCaptureCore \
    -current_version 1 -compatibility_version 1 "${OBJ}"/*.o -o "${FW}/Versions/A/ImageCaptureCore" \
    -F"${ROOT}/System/Library/Frameworks" -framework Foundation -framework CoreFoundation -framework CoreGraphics -lobjc
ln -sfn A "${FW}/Versions/Current"
ln -sfn Versions/Current/ImageCaptureCore "${FW}/ImageCaptureCore"
"${FINCH_ROOT}/tools/mkframeworkplist.sh" "${FW}" A ImageCaptureCore com.apple.ImageCaptureCore ImageCaptureCore 2020.2.2 2020.2.2 en
codesign -f -s - -i com.apple.ImageCaptureCore "${FW}/Versions/A/ImageCaptureCore" 2>/dev/null
log "installed ${FW#"${FINCH_ROOT}/"}"
